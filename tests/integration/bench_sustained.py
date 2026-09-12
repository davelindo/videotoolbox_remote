#!/usr/bin/env python3
"""Repeated encode/decode/transcode comparisons with isolated local daemons.

Extends bench_vtremote.sh with reusable video, concurrent sessions, correctness
gates and JSON results. Latencies are server submission-to-send measurements.
"""

import argparse
import concurrent.futures
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import socket
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]


def identity(path):
    path = Path(path).resolve()
    with path.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    return {"path": str(path), "sha256": digest}


def reap(process, timeout=300):
    deadline = time.monotonic() + timeout
    while True:
        pid, status, usage = os.wait4(process.pid, os.WNOHANG)
        if pid:
            process.returncode = os.waitstatus_to_exitcode(status)
            return {
                "exit_code": process.returncode,
                "cpu_seconds": usage.ru_utime + usage.ru_stime,
                "peak_rss_bytes": usage.ru_maxrss * (1 if platform.system() == "Darwin" else 1024),
            }
        if time.monotonic() >= deadline:
            process.kill()
        time.sleep(0.02)


def probe(ffprobe, path):
    return json.loads(
        subprocess.check_output(
            [
                ffprobe,
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-count_frames",
                "-show_streams",
                "-of",
                "json",
                path,
            ],
            text=True,
        )
    )["streams"][0]


def summaries(log):
    sessions, stages, buffers = [], [], []
    for line in log.splitlines():
        for marker, destination in (
            ("SUMMARY ", sessions),
            ("DECODE_STAGES ", stages),
            ("DECODE_BUFFERS ", buffers),
        ):
            if marker not in line:
                continue
            values = {}
            for key, value in re.findall(r"(\w+)=([^ ]+)", line.split(marker, 1)[1]):
                number = re.fullmatch(r"(-?[0-9.]+)(?:B|s)?", value)
                values[key] = float(number[1]) if number else value
            destination.append(values)
    return sessions, stages, buffers


def aggregate_metrics(runs):
    def distribution(values):
        return {
            "mean": statistics.mean(values),
            "stdev": statistics.stdev(values) if len(values) > 1 else None,
            "min": min(values),
            "max": max(values),
        }

    metrics = {}
    for name, values in {
        "fps": [r["aggregate_fps"] for r in runs],
        "cpu_seconds": [
            r["server"]["cpu_seconds"] + sum(c["cpu_seconds"] for c in r["clients"]) for r in runs
        ],
        "server_cpu_seconds": [r["server"]["cpu_seconds"] for r in runs],
        "server_peak_rss_bytes": [r["server"]["peak_rss_bytes"] for r in runs],
        "client_peak_rss_bytes_sum": [sum(c["peak_rss_bytes"] for c in r["clients"]) for r in runs],
        "wire_bytes_in": [sum(s.get("in", 0) for s in r["server_sessions"]) for r in runs],
        "wire_bytes_out": [sum(s.get("out", 0) for s in r["server_sessions"]) for r in runs],
        "output_frames": [sum(c["frames"] for c in r["clients"]) for r in runs],
        "raw_fps_fairness": [r["raw_fps_fairness"] for r in runs],
    }.items():
        metrics[name] = distribution(values)
    sessions = [s for r in runs for s in r["server_sessions"]]
    buckets = {}
    for session in sessions:
        for item in str(session.get("latency_histogram", "")).split(","):
            if item:
                index, count = map(int, item.split(":"))
                buckets[index] = buckets.get(index, 0) + count
    complete_histogram = sum(buckets.values()) == sum(s.get("latency_samples", 0) for s in sessions)
    for percentile in (50, 95, 99):
        # Merge counts, never average percentiles. Old baselines may lack bins.
        metrics[f"server_p{percentile}_ms"] = None
        if complete_histogram and buckets:
            rank, accumulated = math.ceil(sum(buckets.values()) * percentile / 100), 0
            for index, count in sorted(buckets.items()):
                accumulated += count
                if accumulated >= rank:
                    metrics[f"server_p{percentile}_ms"] = 2 ** ((index + 1) / 16) / 1000
                    break
    metrics["all_correct"] = all(r["correct"] for r in runs)
    metrics["all_sustained"] = all(r["sustained"] for r in runs)
    return metrics


def run_batch(args, variant, label, sessions, depth, frame_counts, directory):
    directory.mkdir()
    frame_counts = [
        math.ceil(frames / args.source_frames) * args.source_frames for frames in frame_counts
    ]
    ffmpeg, daemon = variant
    # Materialize repeated packets once so measured decoding does not seek and
    # reconnect at every loop boundary. No pixels are re-encoded here.
    for frames in set(frame_counts):
        input_path = args.output / f"input-{frames}.mkv"
        if not input_path.exists():
            subprocess.run(
                [
                    args.ffmpeg,
                    "-v",
                    "error",
                    "-xerror",
                    "-nostdin",
                    "-stream_loop",
                    str(frames // args.source_frames - 1),
                    "-i",
                    str(args.input),
                    "-map",
                    "0:v:0",
                    "-c:v",
                    "copy",
                    str(input_path),
                ],
                check=True,
            )
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    server_log = directory / "server.log"
    with server_log.open("w") as log:
        server = subprocess.Popen(
            [
                daemon,
                "--listen",
                f"127.0.0.1:{port}",
                "--max-sessions",
                str(max(4, sessions * 2)),
                "--log-level",
                "1",
            ],
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        try:
            deadline = time.monotonic() + 5
            while True:
                try:
                    with socket.create_connection(("127.0.0.1", port), 0.1):
                        break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise RuntimeError("test daemon did not listen")
                    time.sleep(0.02)

            def client(index):
                mode = args.modes[index % len(args.modes)]
                input_path = args.output / f"input-{frame_counts[index]}.mkv"
                output = directory / f"{index}-{mode}.mkv"
                progress = directory / f"{index}-{mode}.progress"
                codec = args.codec
                remote = ["-vt_remote_host", f"127.0.0.1:{port}"]
                command = [ffmpeg, "-hide_banner", "-v", "info", "-xerror", "-nostdin", "-y"]
                if args.realtime:
                    command += ["-re"]
                if mode == "decode":
                    command += [
                        "-c:v",
                        f"{args.input_codec}_videotoolbox_remote",
                        *remote,
                        "-vt_remote_wire_compression",
                        args.wire,
                    ]
                command += [
                    "-i",
                    str(input_path),
                    "-map",
                    "0:v:0",
                    "-an",
                    "-fps_mode",
                    "passthrough",
                    "-progress",
                    str(progress),
                ]
                if mode == "encode":
                    command += [
                        "-c:v",
                        f"{codec}_videotoolbox_remote",
                        *remote,
                        "-vt_remote_inflight",
                        str(depth),
                        "-vt_remote_wire_compression",
                        args.wire,
                        "-pix_fmt",
                        "p010le" if args.ten_bit else "nv12",
                        "-b:v",
                        args.bitrate,
                        "-bf",
                        "0",
                        str(output),
                    ]
                elif mode == "transcode":
                    bsf = (
                        f"vtremote_transcode=vt_remote_host=127.0.0.1:vt_remote_port={port}"
                        f":vt_remote_out_codec={codec}:vt_remote_pix_fmt={2 if args.ten_bit else 1}"
                        f":vt_remote_bitrate={args.bitrate_bits}:vt_remote_max_b_frames=0"
                    )
                    command += ["-c:v", "copy", "-bsf:v", bsf, str(output)]
                else:
                    command += ["-c:v", "wrapped_avframe", "-f", "null", "-"]
                started = time.monotonic()
                with (directory / f"{index}-{mode}.log").open("w") as client_log:
                    process = subprocess.Popen(command, stdout=client_log, stderr=subprocess.STDOUT)
                    usage = reap(process, timeout=max(180, args.min_seconds * 5))
                elapsed = time.monotonic() - started
                counts = re.findall(
                    r"^frame=(\d+)$", progress.read_text() if progress.exists() else "", re.M
                )
                observed = int(counts[-1]) if counts else 0
                return {
                    "session": index,
                    "mode": mode,
                    "frames": observed,
                    "expected_frames": frame_counts[index],
                    "seconds": elapsed,
                    "fps": observed / elapsed,
                    "command": command,
                    "output": str(output) if mode != "decode" else None,
                    **usage,
                }

            with concurrent.futures.ThreadPoolExecutor(max_workers=sessions) as executor:
                clients = list(executor.map(client, range(sessions)))
            # Session summaries are written after the last callback returns.
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                if len(summaries(server_log.read_text())[0]) >= sessions:
                    break
                time.sleep(0.02)
        finally:
            server.terminate()
            server_usage = reap(server, timeout=5)
    server_sessions, stages, buffers = summaries(server_log.read_text())
    # FFmpeg may open a decoder for probing and close it before the real run.
    server_sessions = [s for s in server_sessions if s.get("frames_in", s.get("packets_in", 0)) > 0]
    stages = [s for s in stages if s.get("planes", 0) > 0]
    correct = True
    for client in clients:
        validation = {
            "count_matches": client["frames"] == client["expected_frames"],
            "software_decode": None,
        }
        if client["output"] and client["exit_code"] == 0:
            with (directory / f"{client['session']}-validation.log").open("w") as log:
                result = subprocess.run(
                    [
                        ffmpeg,
                        "-v",
                        "error",
                        "-xerror",
                        "-err_detect",
                        "explode",
                        "-i",
                        client["output"],
                        "-f",
                        "null",
                        "-",
                    ],
                    stdout=log,
                    stderr=log,
                )
            output_info = probe(args.ffprobe, client["output"])
            validation["software_decode"] = result.returncode == 0
            validation["container_codec"] = output_info["codec_name"]
            validation["decoded_frames"] = int(output_info["nb_read_frames"])
            validation["count_matches"] &= validation["decoded_frames"] == client["expected_frames"]
            correct &= validation["software_decode"] and validation["container_codec"] == args.codec
            if not args.keep_video:
                Path(client["output"]).unlink()
        client["validation"] = validation
        correct &= client["exit_code"] == 0 and validation["count_matches"]
    rates = [client["fps"] for client in clients]
    return {
        "variant": label,
        "sessions": sessions,
        "depth": depth,
        "requested_frames": frame_counts,
        "clients": clients,
        "server": server_usage,
        "server_sessions": server_sessions,
        "decode_stages": stages,
        "decode_buffers": buffers,
        "correct": bool(correct),
        "aggregate_fps": sum(rates),
        "raw_fps_fairness": sum(rates) ** 2 / (len(rates) * sum(rate**2 for rate in rates))
        if any(rates)
        else 0,
        "directory": str(directory),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ffmpeg", default=str(ROOT / "ffmpeg/ffmpeg"))
    parser.add_argument("--ffprobe", default=str(ROOT / "ffmpeg/ffprobe"))
    parser.add_argument("--daemon", default=str(ROOT / "vtremoted/.build/release/vtremoted"))
    parser.add_argument("--baseline-ffmpeg")
    parser.add_argument("--baseline-daemon")
    parser.add_argument("--modes", default="encode,decode,transcode")
    parser.add_argument("--sessions", default="1,2,4")
    parser.add_argument("--depths", default="0")
    parser.add_argument("--frames", type=int, default=900)
    parser.add_argument("--warmup-frames", type=int, default=120)
    parser.add_argument("--min-seconds", type=float, default=30)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--wire", choices=("none", "lz4", "zstd"), default="lz4")
    parser.add_argument("--codec", choices=("h264", "hevc"), default="hevc")
    parser.add_argument("--bitrate", default="20M")
    parser.add_argument("--realtime", action="store_true")
    parser.add_argument(
        "--synthetic", action="store_true", help="Label generated fixtures honestly in results"
    )
    parser.add_argument("--keep-video", action="store_true")
    parser.add_argument("--link-mbps", type=float, help="Measured link capacity, if known")
    parser.add_argument("--fixture-source", help="Provenance URL or description for the input")
    args = parser.parse_args()
    args.input = args.input.resolve()
    args.output = args.output.resolve()
    args.modes = args.modes.split(",")
    args.sessions = [int(value) for value in args.sessions.split(",")]
    args.depths = [int(value) for value in args.depths.split(",")]
    if not set(args.modes) <= {"encode", "decode", "transcode"} or not all(
        value > 0 for value in args.sessions
    ):
        parser.error("invalid modes or session counts")
    if args.frames <= 0 or args.warmup_frames <= 0 or args.repeats <= 0 or args.min_seconds < 0:
        parser.error("positive frames/repeats and nonnegative duration are required")
    info = probe(args.ffprobe, str(args.input))
    args.input_codec = info["codec_name"]
    args.source_frames = int(info["nb_read_frames"])
    args.ten_bit = "10" in info.get("pix_fmt", "")
    if args.input_codec not in ("h264", "hevc") or (args.codec == "h264" and args.ten_bit):
        parser.error("use an H.264/HEVC input and HEVC output for 10-bit video")
    args.bitrate_bits = int(
        float(args.bitrate.rstrip("kKmM"))
        * (1e6 if args.bitrate[-1:] in "mM" else 1e3 if args.bitrate[-1:] in "kK" else 1)
    )
    variants = {"candidate": (args.ffmpeg, args.daemon)}
    if args.baseline_daemon or args.baseline_ffmpeg:
        variants["baseline"] = (
            args.baseline_ffmpeg or args.ffmpeg,
            args.baseline_daemon or args.daemon,
        )
    args.output.mkdir(parents=True, exist_ok=False)
    metadata = {
        "host": platform.node(),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "cpu_count": os.cpu_count(),
        "link_mbps": args.link_mbps,
        "transport": "loopback",
        "source_commit": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
        ).strip(),
        "source_diff_sha256": hashlib.sha256(
            subprocess.check_output(["git", "diff", "HEAD"], cwd=ROOT)
        ).hexdigest(),
        "untracked_files": {
            path: identity(ROOT / path)["sha256"]
            for path in subprocess.check_output(
                ["git", "ls-files", "--others", "--exclude-standard"], cwd=ROOT, text=True
            ).splitlines()
        },
        "fixture": {
            **identity(args.input),
            "source": args.fixture_source,
            "synthetic": args.synthetic,
            "stream": info,
        },
        "variants": {
            label: {"ffmpeg": identity(paths[0]), "daemon": identity(paths[1])}
            for label, paths in variants.items()
        },
        "latency_definition": "server FIFO submission through completed socket send; logarithmic upper bounds <=4.5% error",
        "fairness_definition": "Jain index of raw client fps; compare like workloads, mixed modes have different costs",
        "rss_definition": "process lifetime peak; sum of client peaks is an upper bound, not a simultaneous measurement",
        "parameters": {
            key: str(value) if isinstance(value, Path) else value
            for key, value in vars(args).items()
        },
    }
    if platform.system() == "Darwin":
        hardware = subprocess.check_output(
            ["sysctl", "-n", "machdep.cpu.brand_string", "hw.memsize", "hw.model"], text=True
        ).splitlines()
        metadata["hardware"] = {
            "cpu": hardware[0],
            "memory_bytes": int(hardware[1]),
            "model": hardware[2],
        }
    (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    records = []
    for sessions in args.sessions:
        for depth in args.depths:
            frames = [args.frames] * sessions
            for label, variant in variants.items():
                warmup = run_batch(
                    args,
                    variant,
                    label,
                    sessions,
                    depth,
                    [args.warmup_frames] * sessions,
                    args.output / f"warmup-{sessions}-{depth}-{label}",
                )
                if not warmup["correct"]:
                    raise RuntimeError(f"warmup correctness failure: {warmup['directory']}")
                if args.min_seconds:
                    for client in warmup["clients"]:
                        index = client["session"]
                        frames[index] = max(
                            frames[index], math.ceil(client["fps"] * args.min_seconds * 1.5)
                        )
            for repeat in range(args.repeats):
                order = list(variants)
                if repeat % 2:
                    order.reverse()
                for label in order:
                    record = run_batch(
                        args,
                        variants[label],
                        label,
                        sessions,
                        depth,
                        frames,
                        args.output / f"run-{sessions}-{depth}-{repeat}-{label}",
                    )
                    record["repeat"] = repeat
                    record["sustained"] = (
                        min(c["seconds"] for c in record["clients"]) >= args.min_seconds
                    )
                    records.append(record)
                    with (args.output / "runs.jsonl").open("a") as output:
                        output.write(json.dumps(record) + "\n")
                    print(
                        f"{label} sessions={sessions} depth={depth} fps={record['aggregate_fps']:.1f} correct={record['correct']} sustained={record['sustained']}",
                        flush=True,
                    )
                    if not record["correct"]:
                        raise RuntimeError(f"correctness failure: {record['directory']}")
    aggregates = []
    for sessions in args.sessions:
        for depth in args.depths:
            for label in variants:
                runs = [
                    r
                    for r in records
                    if (r["sessions"], r["depth"], r["variant"]) == (sessions, depth, label)
                ]
                aggregates.append(
                    {
                        "sessions": sessions,
                        "depth": depth,
                        "variant": label,
                        **aggregate_metrics(runs),
                    }
                )
    (args.output / "summary.json").write_text(json.dumps(aggregates, indent=2) + "\n")
    print(f"Results: {args.output}")


if __name__ == "__main__":
    main()
