#!/usr/bin/env python3
"""Reproducible Intel/software/local-Mac/LAN-Mac performance comparisons.

Prepare and measure on the designated hosts. The coordinating computer only
dispatches jobs and collects results; it never encodes benchmark video.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import platform
import re
import shlex
import signal
import statistics
import subprocess
import sys
import time
import zipfile

BACKENDS = ("intel-vaapi", "cpu-fast", "cpu-medium", "videotoolbox", "videotoolbox-remote")
FIXTURES = ("big-buck-bunny", "testsrc2", "smptebars")
BITRATES = {("h264", 720): 4_000_000, ("hevc", 720): 3_000_000,
            ("h264", 1080): 6_000_000, ("hevc", 1080): 4_000_000}
BBB_URL = "https://download.blender.org/demo/movies/BBB/bbb_sunflower_1080p_30fps_normal.mp4.zip"
LABELS = {"intel-vaapi": "Intel iGPU VA-API", "cpu-fast": "CPU fast", "cpu-medium": "CPU medium",
          "videotoolbox": "VideoToolbox local", "videotoolbox-remote": "VideoToolbox remote"}


def public_results(summary):
    """Export a strict allowlist, never host inventory, paths or commands."""
    metadata = summary["metadata"]
    if metadata["frames"] != 1800 or metadata["repeats"] != 3 or not summary["all_correct"]:
        raise ValueError("only complete, validated three-repeat comparisons can be published")
    expected = set(itertools.product(FIXTURES, ("h264", "hevc"), ("1280x720", "1920x1080"), BACKENDS))
    actual = [(row["fixture"], row["codec"], row["size"], row["backend"]) for row in summary["rows"]]
    if len(actual) != len(expected) or set(actual) != expected or not all(row["all_correct"] for row in summary["rows"]):
        raise ValueError("public comparison is incomplete or contains duplicate or invalid rows")
    if any(row["vmaf_frame_stride"] != 1 or row["vmaf_sampled_frames"] != metadata["frames"] for row in summary["rows"]):
        raise ValueError("public quality measurements must score every frame")
    if not re.fullmatch(r"v\d+\.\d+\.\d+", metadata["release"]):
        raise ValueError("invalid public release identifier")
    keys = ("fixture", "codec", "size", "backend", "median_fps", "min_fps", "max_fps", "fps_cv_percent",
            "median_cpu_seconds", "median_peak_rss_bytes", "median_video_mbps", "median_file_bytes", "median_container_mbps",
            "median_filler_mbps", "target_mbps", "requested_mbps", "all_correct",
            "all_file_within_2_percent_target", "max_file_target_deviation_percent", "max_b_picture_frames", "max_decoder_reorder_frames",
            "max_gop_frames", "vmaf", "ssim", "vmaf_frame_stride", "vmaf_sampled_frames")
    rows = [{**{key: row[key] for key in keys}, "label": LABELS[row["backend"]],
             "comparison": "control" if row["fixture"] == "smptebars" else "common-bitrate-budget",
             "scored_output": row["scored_output"], "measured_repeats": row["measured_repeats"]} for row in summary["rows"]]
    numeric_keys = set(keys) - {"fixture", "codec", "size", "backend", "all_correct", "all_file_within_2_percent_target"}
    for row in rows:
        if any(isinstance(row[key], bool) or not isinstance(row[key], (int, float)) or not math.isfinite(row[key]) for key in numeric_keys):
            raise ValueError("public measurements must be finite numbers")
        if type(row["all_correct"]) is not bool or type(row["all_file_within_2_percent_target"]) is not bool:
            raise ValueError("public validation fields must be boolean")
    fixtures = [{"id": name, "label": {"big-buck-bunny": "Big Buck Bunny", "testsrc2": "Moving testsrc2 signal", "smptebars": "Static SMPTE bars (control)"}[name]}
                for name in FIXTURES]
    outputs = [{"label": f"{'H.264 High' if codec == 'h264' else 'HEVC Main'} · {size.split('x')[1]}p",
                "codec": codec, "size": size} for codec, size in itertools.product(("h264", "hevc"), ("1280x720", "1920x1080"))]
    source_hashes = []
    builds = []
    for host in metadata["hosts"].values():
        for fixture in host["fixture_manifest"]["fixtures"]:
            if fixture["name"] not in FIXTURES or not re.fullmatch(r"[0-9a-f]{64}", fixture["sha256"]):
                raise ValueError("invalid public fixture identity")
            record = {"fixture": fixture["name"], "sha256": fixture["sha256"]}
            if record not in source_hashes:
                source_hashes.append(record)
        for key in ("native_ffmpeg", "remote_ffmpeg", "quality_ffmpeg"):
            info = host[key]
            match = re.match(r"ffmpeg version (git-\d{4}-\d{2}-\d{2}-[0-9a-f]+|\d+\.\d+(?:\.\d+|\.git)?(?:-\d+ubuntu[0-9.+a-z]+)?) ", info["version"])
            if not match or not re.fullmatch(r"[0-9a-f]{64}", info["sha256"]):
                raise ValueError("build identity needs a safe public version and hash")
            record = {"version": match[1], "sha256": info["sha256"]}
            if record not in builds:
                builds.append(record)
    scorer = next(build for build in builds if build["sha256"] == metadata["quality_scorer"]["sha256"])
    return {"date": datetime.fromisoformat(metadata["created_at"]).date().isoformat() + " UTC",
            "release": metadata["release"], "fixtures": fixtures, "outputs": outputs,
            "source_hashes": source_hashes, "builds": builds, "quality_scorer": scorer,
            "frames": metadata["frames"], "repeats": metadata["repeats"],
            "warmup_frames": metadata["warmup_frames"], "vmaf_model": "vmaf_v0.6.1",
            "rate_control": "average/VBR, -bf 0 and zero frame reordering, 60-frame maximum GOP",
            "intel_hevc_picture_types": "Driver-required GPB B-slices use past references; no future references or frame reordering",
            "output_cost_scope": "physical output files including container overhead and every filler byte",
            "calibration_measurement": metadata["calibration_measurement"],
            "rows": rows}


def identity(path):
    path = Path(path).resolve()
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"path": str(path), "sha256": digest, "bytes": path.stat().st_size}


def capture(command, **kwargs):
    return subprocess.check_output(command, text=True, **kwargs).strip()


def probe(ffprobe, path, count=False, pictures=False):
    command = [ffprobe, "-v", "error", "-select_streams", "v:0"]
    if count:
        command += ["-count_frames", "-count_packets"]
    if pictures:
        command += ["-show_frames", "-show_entries", "frame=key_frame,pict_type:stream:format"]
    command += ["-show_streams", "-show_format", "-of", "json", str(path)]
    return json.loads(capture(command))


def measure(command, log, env=None):
    started = time.monotonic()
    with Path(log).open("w") as output:
        process = subprocess.Popen(command, stdout=output, stderr=output, env=env)
        try:
            _, status, usage = os.wait4(process.pid, 0)
        except BaseException:
            process.terminate()
            process.wait()
            raise
    process.returncode = os.waitstatus_to_exitcode(status)
    result = {
        "elapsed_seconds": time.monotonic() - started,
        "cpu_seconds": usage.ru_utime + usage.ru_stime,
        "peak_rss_bytes": usage.ru_maxrss * (1024 if platform.system() == "Linux" else 1),
        "exit_code": process.returncode,
    }
    if process.returncode:
        raise RuntimeError(f"command failed ({process.returncode}); inspect {log}")
    return result


def rapl():
    directory = Path("/sys/class/powercap/intel-rapl:0")
    if not directory.exists():
        return None
    return {"energy_uj": int((directory / "energy_uj").read_text()),
            "range_uj": int((directory / "max_energy_range_uj").read_text())}


def prepare(args):
    directory = args.workdir / "fixtures"
    directory.mkdir(exist_ok=False)
    archive = args.workdir / "downloads/bbb_sunflower_1080p_30fps_normal.mp4.zip"
    with zipfile.ZipFile(archive) as bundle:
        names = [name for name in bundle.namelist() if name.endswith(".mp4")]
        if len(names) != 1:
            raise RuntimeError("expected exactly one Big Buck Bunny MP4")
        # Extract the known media member only; do not unpack arbitrary paths.
        source = args.workdir / "downloads/big-buck-bunny.mp4"
        with source.open("xb") as output, bundle.open(names[0]) as media:
            import shutil
            shutil.copyfileobj(media, output)
    records = []
    for name in FIXTURES:
        output = directory / f"{name}.mkv"
        command = [args.ffmpeg, "-hide_banner", "-nostdin", "-v", "warning", "-xerror"]
        if name == "big-buck-bunny":
            command += ["-ss", "60", "-i", str(source), "-vf", "scale=1920:1080:flags=bicubic,format=yuv420p"]
        else:
            command += ["-f", "lavfi", "-i", f"{name}=size=1920x1080:rate=30"]
        command += ["-map", "0:v:0", "-an", "-sn", "-t", str(args.duration), "-r", "30",
                    "-c:v", "libx264", "-preset", "fast", "-crf", "10", "-pix_fmt", "yuv420p",
                    "-g", "60", "-bf", "2", "-color_range", "tv", "-colorspace", "bt709",
                    "-color_primaries", "bt709", "-color_trc", "bt709", str(output)]
        measure(command, directory / f"{name}.prepare.log")
        info = probe(args.ffprobe, output, count=True)
        frames = int(info["streams"][0]["nb_read_frames"])
        if frames != args.duration * 30:
            raise RuntimeError(f"fixture frame count mismatch: {name}: {frames}")
        records.append({"name": name, **identity(output), "frames": frames, "command": command,
                        "source": BBB_URL if name == "big-buck-bunny" else f"FFmpeg lavfi {name}",
                        "source_start_seconds": 60 if name == "big-buck-bunny" else 0})
    manifest = {"archive": identity(archive), "bbb_project": "https://peach.blender.org/",
                "credit": "Big Buck Bunny, Blender Foundation; Sunflower stereoscopic release, Blender Institute",
                "reference": "Software-decoded prepared H.264 High 8-bit fixtures, not uncompressed movie masters",
                "generator": identity(args.ffmpeg), "fixtures": records}
    (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest), flush=True)


def encoder_command(args, source, output):
    width, height = map(int, args.size.split("x"))
    bitrate = getattr(args, "bitrate", None) or BITRATES[(args.codec, height)]
    ffmpeg = args.remote_ffmpeg if args.backend == "videotoolbox-remote" else args.ffmpeg
    command = [ffmpeg, "-hide_banner", "-nostdin", "-nostats", "-v", "info", "-xerror"]
    if args.backend == "intel-vaapi":
        command += ["-hwaccel", "vaapi", "-hwaccel_device", args.render_node,
                    "-hwaccel_output_format", "vaapi"]
    elif args.backend == "videotoolbox":
        command += ["-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld"]
    # Bound demuxing as well as output: older VA-API filter pools can exhaust
    # when downstream stops accepting frames but the input continues decoding.
    command += ["-t", str(args.frames / 30), "-i", str(source), "-map", "0:v:0", "-an", "-sn",
                "-frames:v", str(args.frames), "-fps_mode", "passthrough"]
    profile = "high" if args.codec == "h264" else "main"
    if args.backend == "videotoolbox-remote":
        bsf = (f"vtremote_transcode=vt_remote_host={args.server}:vt_remote_port={args.port}"
               f":vt_remote_out_codec={args.codec}:vt_remote_out_width={width}:vt_remote_out_height={height}"
               f":vt_remote_pix_fmt=1:vt_remote_bitrate={bitrate}:vt_remote_maxrate=0"
               f":vt_remote_gop=60:vt_remote_max_b_frames=0:vt_remote_constant_bit_rate=0"
               f":vt_remote_prio_speed=0:vt_remote_realtime=0:vt_remote_allow_sw=0"
               f":vt_remote_profile={100 if args.codec == 'h264' else 1}:vt_remote_inflight=32")
        command += ["-c:v", "copy", "-bsf:v", bsf]
    else:
        if args.backend == "intel-vaapi":
            command += ["-vf", f"scale_vaapi=w={width}:h={height}:format=nv12",
                        "-c:v", f"{args.codec}_vaapi", "-rc_mode", "VBR"]
        elif args.backend == "videotoolbox":
            command += ["-vf", f"scale_vt=w={width}:h={height}", "-c:v", f"{args.codec}_videotoolbox",
                        "-constant_bit_rate", "0", "-allow_sw", "0", "-realtime", "0", "-prio_speed", "0"]
        else:
            preset = args.backend.removeprefix("cpu-")
            command += ["-vf", f"scale={width}:{height}:flags=bicubic,format=yuv420p",
                        "-c:v", "libx264" if args.codec == "h264" else "libx265", "-preset", preset,
                        "-pix_fmt", "yuv420p"]
            if args.codec == "h264":
                command += ["-x264-params", "scenecut=0:keyint=60:min-keyint=60"]
            else:
                command += ["-x265-params", "scenecut=0:keyint=60:min-keyint=60"]
        command += ["-profile:v", profile, "-b:v", str(bitrate), "-g", "60", "-bf", "0",
                    "-color_range", "tv", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"]
    return command + [str(output)], bitrate


def quality(args, source, output, directory):
    width, height = map(int, args.size.split("x"))
    vmaf_log = directory / "vmaf.json"
    graph = (f"[0:v]trim=end_frame={args.frames},scale={width}:{height}:flags=bicubic,format=yuv420p,"
             "settb=AVTB,setpts=N/(30*TB),split=2[rv][rs];"
             "[1:v]format=yuv420p,settb=AVTB,setpts=N/(30*TB),split=2[dv][ds];"
             f"[dv][rv]libvmaf=model=version=vmaf_v0.6.1:n_threads=8:n_subsample=1:log_fmt=json:log_path={vmaf_log}[v];"
             "[ds][rs]ssim[s]")
    command = [args.quality_ffmpeg, "-hide_banner", "-nostdin", "-nostats", "-v", "info", "-xerror",
               "-i", str(source), "-i", str(output), "-filter_complex", graph,
               "-map", "[v]", "-map", "[s]", "-f", "null", "-"]
    measure(command, directory / "quality.log")
    metrics = json.loads(vmaf_log.read_text())
    ssim = re.search(r"SSIM .* All:([0-9.]+)", (directory / "quality.log").read_text())
    if not ssim or len(metrics["frames"]) != args.frames:
        raise RuntimeError(f"quality metrics incomplete: {directory}")
    return {"vmaf": metrics["pooled_metrics"]["vmaf"]["mean"], "ssim": float(ssim[1]),
            "vmaf_frame_stride": 1, "vmaf_sampled_frames": len(metrics["frames"]),
            "model": "vmaf_v0.6.1", "command": command}


def filler_rate(args, output, directory, original_packets):
    """Diagnose filler on a separate copy; retain all bytes in reported output cost."""
    stripped = directory / "without-filler.mkv"
    bsf = "h264_metadata=delete_filler=1" if args.codec == "h264" else "filter_units=remove_types=38"
    measure([args.quality_ffmpeg, "-hide_banner", "-nostdin", "-v", "error", "-xerror",
             "-i", str(output), "-map", "0:v:0", "-c:v", "copy", "-bsf:v", bsf,
             str(stripped)], directory / "remove-filler.log")
    packets = json.loads(capture([args.ffprobe, "-v", "error", "-select_streams", "v:0", "-show_packets",
                                 "-show_entries", "packet=size", "-of", "json", str(stripped)]))["packets"]
    before = sum(int(packet["size"]) for packet in original_packets)
    after = sum(int(packet["size"]) for packet in packets)
    if len(packets) != len(original_packets) or after > before:
        raise RuntimeError("filler removal changed packet counts or added encoded bytes")
    return (before - after) * 8 / (args.frames / 30)


def quality_worker(args):
    source = args.workdir / "fixtures" / f"{args.fixture}.mkv"
    directory = args.workdir / "quality" / args.run_id
    directory.mkdir(parents=True, exist_ok=False)
    if identity(args.input)["sha256"] != args.sha256:
        raise RuntimeError("copied output identity differs from the measured output")
    result = quality(args, source, args.input, directory)
    (directory / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)


def worker(args):
    source = args.workdir / "fixtures" / f"{args.fixture}.mkv"
    directory = args.workdir / "runs" / args.run_id
    directory.mkdir(parents=True, exist_ok=False)
    output = directory / "output.mkv"
    command, requested_bitrate = encoder_command(args, source, output)
    target_bitrate = BITRATES[(args.codec, int(args.size.split("x")[1]))]
    env = os.environ.copy()
    if args.backend == "intel-vaapi":
        env["LIBVA_DRIVER_NAME"] = "iHD"
    before = rapl()
    usage = measure(command, directory / "encode.log", env=env)
    after = rapl()
    if before and after:
        usage["intel_package_joules"] = ((after["energy_uj"] - before["energy_uj"]) % before["range_uj"]) / 1_000_000
    info = probe(args.ffprobe, output, count=True, pictures=True)
    stream = info["streams"][0]
    packets = json.loads(capture([args.ffprobe, "-v", "error", "-select_streams", "v:0", "-show_packets",
                                  "-show_entries", "packet=size,pts_time,dts_time", "-of", "json", str(output)]))["packets"]
    timestamps = [float(packet["dts_time"]) for packet in packets]
    frames = int(stream["nb_read_frames"])
    pictures = info["frames"]
    keyframes = [index for index, frame in enumerate(pictures) if frame["key_frame"]]
    b_pictures = sum(frame["pict_type"] == "B" for frame in pictures)
    longest_gop = max(second - first for first, second in zip(keyframes, [*keyframes[1:], frames])) if keyframes else frames
    intel_gpb = args.backend == "intel-vaapi" and args.codec == "hevc"
    width, height = map(int, args.size.split("x"))
    correct = (frames == args.frames and len(packets) == args.frames and stream["codec_name"] == args.codec
               and stream["width"] == width and stream["height"] == height
               and stream["profile"] == ("High" if args.codec == "h264" else "Main")
               and stream["pix_fmt"] == "yuv420p"
               and len(pictures) == frames and bool(keyframes) and keyframes[0] == 0 and longest_gop <= 60
               and stream["has_b_frames"] == 0 and (b_pictures == 0 or intel_gpb)
               and all(packet["pts_time"] == packet["dts_time"] for packet in packets)
               and all(second > first for first, second in zip(timestamps, timestamps[1:])))
    if not correct:
        raise RuntimeError(f"media validation failed: {directory}")
    measure([args.quality_ffmpeg, "-v", "error", "-nostdin", "-xerror", "-i", str(output), "-map", "0:v:0", "-f", "null", "-"], directory / "decode.log")
    delivered = sum(int(packet["size"]) for packet in packets) * 8 / (args.frames / 30)
    filler = filler_rate(args, output, directory, packets)
    container_bitrate = int(info["format"]["bit_rate"])
    result = {"backend": args.backend, "codec": args.codec, "fixture": args.fixture, "size": args.size,
              "run_id": args.run_id, "host": platform.node(), "frames": frames, "correct": correct,
              "b_picture_frames": b_pictures, "decoder_reorder_frames": stream["has_b_frames"],
              "gop_frames": longest_gop,
              "target_bitrate": target_bitrate, "requested_bitrate": requested_bitrate,
              "delivered_bitrate": delivered,
              "container_bitrate": container_bitrate, "duration_seconds": float(info["format"]["duration"]),
              "filler_bitrate": filler,
              "file_within_2_percent_target": abs(container_bitrate / target_bitrate - 1) <= 0.02,
              "fps": frames / usage["elapsed_seconds"], "usage": usage,
              "output": identity(output), "source": identity(source), "command": command,
              "output_stream": {key: stream.get(key) for key in ("codec_name", "profile", "pix_fmt", "color_range", "color_space", "color_transfer", "color_primaries")}}
    if args.quality:
        result["quality"] = quality(args, source, output, directory)
    (directory / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)


def serve(args):
    log_path = args.workdir / f"daemon-{time.time_ns()}.log"
    with log_path.open("x") as log:
        process = subprocess.Popen([args.daemon, "--listen", f"{args.server}:{args.port}", "--max-sessions", "2", "--log-level", "1"], stdout=log, stderr=log)
        import socket
        try:
            deadline = time.monotonic() + 10
            while True:
                if process.poll() is not None:
                    raise RuntimeError(f"benchmark daemon exited; inspect {log_path}")
                try:
                    with socket.create_connection((args.server, args.port), 0.2):
                        break
                except OSError:
                    if time.monotonic() > deadline:
                        raise RuntimeError("benchmark daemon did not listen")
                    time.sleep(0.1)
            print(json.dumps({"ready": True, "pid": process.pid, "log": str(log_path), "daemon": identity(args.daemon), "version": capture([args.daemon, "--version"])}), flush=True)
            sys.stdin.readline()
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
                _, status, usage = os.wait4(process.pid, 0)
                process.returncode = os.waitstatus_to_exitcode(status)
                print(json.dumps({"cpu_seconds": usage.ru_utime + usage.ru_stime, "peak_rss_bytes": usage.ru_maxrss, "exit_code": process.returncode}), flush=True)


def remote_command(host, argv):
    return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, shlex.join(argv)]


def suite(args):
    args.output.mkdir(parents=True, exist_ok=False)
    script = str(args.workdir / "performance.py")
    python_mac = "/opt/homebrew/bin/python3"
    binary = str(args.workdir / "bin" / "ffmpeg")
    native_linux = str(args.workdir / "native-bin" / "ffmpeg")
    common = [script, "--workdir", str(args.workdir), "--server", args.server, "--port", str(args.port)]
    server_log = (args.output / "server-ssh.log").open("w")
    server = subprocess.Popen(remote_command(args.mac_host, [python_mac, *common, "serve", "--daemon", str(args.workdir / "vtremoted/vtremoted")]), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=server_log, text=True)
    try:
        ready_line = server.stdout.readline()
        if not ready_line:
            raise RuntimeError("could not start Mac benchmark daemon; inspect server-ssh.log")
        ready = json.loads(ready_line)
        if ready["version"] != f"vtremoted {args.release.removeprefix('v')}":
            raise RuntimeError("daemon version does not match the requested benchmark release")
        host_info = {}
        for host, py in ((args.linux_host, "python3"), (args.mac_host, python_mac)):
            native_mac = "/opt/homebrew/bin/ffmpeg"
            host_info[host] = json.loads(capture(remote_command(host, [py, *common, "inventory", "--ffmpeg", native_linux if host == args.linux_host else "/opt/homebrew/bin/ffmpeg",
                                                                       "--remote-ffmpeg", binary if host == args.linux_host else native_mac,
                                                                       "--ffprobe", str(args.workdir / "bin/ffprobe") if host == args.linux_host else "/opt/homebrew/bin/ffprobe",
                                                                       "--quality-ffmpeg", binary if host == args.linux_host else "/opt/homebrew/bin/ffmpeg"])))
        fixture_hashes = [{item["name"]: item["sha256"] for item in info["fixture_manifest"]["fixtures"]} for info in host_info.values()]
        if fixture_hashes[0] != fixture_hashes[1]:
            raise RuntimeError("Intel and Mac fixtures differ; refusing the comparison")
        metadata = {"created_at": datetime.now(timezone.utc).isoformat(), "release": args.release, "server": ready,
                    "hosts": host_info, "method": f"Sequential full-video pipelines; average/VBR on every backend; common -bf 0 and zero frame reordering, with driver-required past-reference GPB slices on Intel HEVC; 60-frame maximum GOP; identical byte-only full-clip calibration for every moving-video backend; whole-file bitrate within 2%; {args.warmup_frames}-frame warm-up and {args.repeats} rotating measured repeats; static bars are a control; VMAF and SSIM over every frame on one common Linux scorer on the first measured repeat",
                    "calibration_measurement": "Whole-file bitrate reported by ffprobe; container overhead and codec filler included",
                    "quality_scorer": host_info[args.linux_host]["quality_ffmpeg"],
                    "frames": args.frames, "warmup_frames": args.warmup_frames, "repeats": args.repeats,
                    "sizes": args.sizes, "fixtures": args.fixtures, "codecs": args.codecs, "backends": args.backends,
                    "power_scope": "Intel package RAPL includes other host work; no wall power or Mac power measurement"}
        (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
        capture(remote_command(args.linux_host, ["mkdir", "-p", str(args.workdir / "quality")]))
        runs = []
        cases = list(itertools.product(args.fixtures, args.codecs, args.sizes))
        for case_index, (fixture, codec, size) in enumerate(cases):
            requested_rates = {backend: BITRATES[(codec, int(size.split("x")[1]))] for backend in args.backends}

            def run_job(backend, run_id, frames, with_quality=False):
                host = args.mac_host if backend == "videotoolbox" else args.linux_host
                py = python_mac if host == args.mac_host else "python3"
                command = [py, *common, "worker", "--backend", backend, "--codec", codec, "--fixture", fixture,
                           "--size", size, "--frames", str(frames), "--run-id", run_id,
                           "--bitrate", str(requested_rates[backend]),
                           "--ffmpeg", "/opt/homebrew/bin/ffmpeg" if host == args.mac_host else native_linux, "--remote-ffmpeg", binary,
                           "--ffprobe", str(args.workdir / "bin/ffprobe") if host == args.linux_host else "/opt/homebrew/bin/ffprobe",
                           "--quality-ffmpeg", "/opt/homebrew/bin/ffmpeg" if host == args.mac_host else binary]
                if with_quality and host == args.linux_host:
                    command += ["--quality"]
                with (args.output / f"{run_id}.ssh.log").open("w") as log:
                    result = json.loads(capture(remote_command(host, command), stderr=log))
                if with_quality and host == args.mac_host:
                    copied = args.workdir / "quality" / f"{run_id}.mkv"
                    subprocess.run(["scp", "-3", "-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                                    f"{args.mac_host}:{result['output']['path']}",
                                    f"{args.linux_host}:{copied}"], check=True)
                    quality_command = ["python3", *common, "quality", "--input", str(copied),
                                       "--sha256", result["output"]["sha256"], "--fixture", fixture,
                                       "--size", size, "--frames", str(frames), "--run-id", run_id,
                                       "--quality-ffmpeg", binary]
                    with (args.output / f"{run_id}.quality.ssh.log").open("w") as log:
                        result["quality"] = json.loads(capture(remote_command(args.linux_host, quality_command), stderr=log))
                return result

            # Calibrate actual whole-file rate on the complete clip before timing.
            # Static bars are a control: sparse encoders may not fill a budget.
            if fixture != "smptebars":
                for backend in args.backends:
                    for attempt in range(4):
                        run_id = f"{args.output.name}-{fixture}-{codec}-{size}-{backend}-cal{attempt}"
                        print(f"PERFORMANCE calibration={case_index + 1}/{len(cases)} attempt={attempt + 1} {backend} {fixture} {codec} {size}", flush=True)
                        result = run_job(backend, run_id, args.frames)
                        with (args.output / "calibration.jsonl").open("a") as stream:
                            stream.write(json.dumps(result) + "\n")
                        ratio = result["container_bitrate"] / result["target_bitrate"]
                        if abs(ratio - 1) <= 0.02:
                            break
                        requested_rates[backend] = round(requested_rates[backend] / ratio)
                    else:
                        raise RuntimeError(f"could not match whole-file bitrate for {fixture} {codec} {size} {backend}")
            for repeat in range(args.repeats + 1):
                order = list(args.backends)
                offset = (case_index + max(repeat - 1, 0)) % len(order)
                order = order[offset:] + order[:offset]
                for backend in order:
                    run_id = f"{args.output.name}-{fixture}-{codec}-{size}-{backend}-r{repeat}"
                    print(f"PERFORMANCE case={case_index + 1}/{len(cases)} repeat={repeat}/{args.repeats} {backend} {fixture} {codec} {size}", flush=True)
                    result = run_job(backend, run_id, args.warmup_frames if repeat == 0 else args.frames, repeat == 1)
                    if repeat and fixture != "smptebars" and not result["file_within_2_percent_target"]:
                        raise RuntimeError(f"whole-file bitrate outside 2% comparison tolerance: {run_id}")
                    result["repeat"] = repeat
                    with (args.output / "runs.jsonl").open("a") as stream:
                        stream.write(json.dumps(result) + "\n")
                    if repeat:
                        runs.append(result)
        summary = summarize(metadata, runs)
        (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(f"PERFORMANCE complete rows={len(summary['rows'])} all_correct={summary['all_correct']} output={args.output}", flush=True)
    finally:
        if server.poll() is None:
            server.stdin.write("stop\n")
            server.stdin.flush()
            server.stdin.close()
        server.stdin = None
        server_output, _ = server.communicate(timeout=30)
        (args.output / "server-final.json").write_text(server_output)
        server_log.close()


def summarize(metadata, runs):
    """Aggregate validated measured runs, including preserved completed cases."""
    source_hashes = {fixture: {record["sha256"] for host in metadata["hosts"].values()
                               for record in host["fixture_manifest"]["fixtures"] if record["name"] == fixture}
                     for fixture in metadata["fixtures"]}
    if any(len(hashes) != 1 for hashes in source_hashes.values()):
        raise ValueError("fixture identities differ between the measured hosts")
    rows = []
    for fixture, codec, size, backend in itertools.product(metadata["fixtures"], metadata["codecs"], metadata["sizes"], metadata["backends"]):
        group = [run for run in runs if (run["fixture"], run["codec"], run["size"], run["backend"]) == (fixture, codec, size, backend)]
        if len(group) != metadata["repeats"] or {run["repeat"] for run in group} != set(range(1, metadata["repeats"] + 1)):
            raise ValueError("each case needs exactly the configured measured repeats")
        if any(run["frames"] != metadata["frames"] or not run["correct"] for run in group):
            raise ValueError("measured runs failed media validation")
        if any(run["source"]["sha256"] not in source_hashes[fixture] for run in group):
            raise ValueError("a measured run used a different input from the recorded fixture")
        rates = [run["fps"] for run in group]
        scored_run = next(run for run in group if run["repeat"] == 1)
        measured_quality = scored_run["quality"]
        repeats = [{"repeat": run["repeat"], "output_sha256": run["output"]["sha256"],
                    "file_bytes": run["output"]["bytes"], "duration_seconds": run["duration_seconds"],
                    "container_mbps": run["container_bitrate"] / 1_000_000,
                    "video_mbps": run["delivered_bitrate"] / 1_000_000,
                    "filler_mbps": run["filler_bitrate"] / 1_000_000, "fps": run["fps"],
                    "client_cpu_seconds": run["usage"]["cpu_seconds"], "correct": run["correct"]}
                   for run in sorted(group, key=lambda run: run["repeat"])]
        rows.append({"fixture": fixture, "codec": codec, "size": size, "backend": backend,
                     "median_fps": statistics.median(rates), "min_fps": min(rates), "max_fps": max(rates),
                     "fps_cv_percent": statistics.stdev(rates) / statistics.mean(rates) * 100 if len(rates) > 1 else 0,
                     "median_cpu_seconds": statistics.median(run["usage"]["cpu_seconds"] for run in group),
                     "median_peak_rss_bytes": statistics.median(run["usage"]["peak_rss_bytes"] for run in group),
                     "median_video_mbps": statistics.median(run["delivered_bitrate"] for run in group) / 1_000_000,
                     "median_file_bytes": statistics.median(run["output"]["bytes"] for run in group),
                     "median_container_mbps": statistics.median(run["container_bitrate"] for run in group) / 1_000_000,
                     "median_filler_mbps": statistics.median(run["filler_bitrate"] for run in group) / 1_000_000,
                     "target_mbps": group[0]["target_bitrate"] / 1_000_000,
                     "requested_mbps": group[0]["requested_bitrate"] / 1_000_000,
                     "all_correct": all(run["correct"] for run in group),
                     "all_file_within_2_percent_target": all(run["file_within_2_percent_target"] for run in group),
                     "max_file_target_deviation_percent": max(abs(run["container_bitrate"] / run["target_bitrate"] - 1) * 100 for run in group),
                     "max_b_picture_frames": max(run["b_picture_frames"] for run in group),
                     "max_decoder_reorder_frames": max(run["decoder_reorder_frames"] for run in group),
                     "max_gop_frames": max(run["gop_frames"] for run in group),
                     "scored_output": repeats[0], "measured_repeats": repeats,
                     **{key: measured_quality[key] for key in ("vmaf", "ssim", "vmaf_frame_stride", "vmaf_sampled_frames")}})
    return {"metadata": metadata, "rows": rows, "all_correct": all(row["all_correct"] for row in rows)}


def inventory(args):
    information = {"host": platform.node(), "platform": platform.platform(), "cpu_count": os.cpu_count(), "load_average": os.getloadavg()}
    if platform.system() == "Darwin":
        information["hardware"] = capture(["/usr/sbin/sysctl", "-n", "hw.model", "hw.memsize", "machdep.cpu.brand_string"])
    else:
        information["hardware"] = capture(["lscpu", "--json"])
        information["vaapi"] = capture(["vainfo", "--display", "drm", "--device", args.render_node], stderr=subprocess.STDOUT)
    for label, path in (("native_ffmpeg", args.ffmpeg), ("remote_ffmpeg", args.remote_ffmpeg), ("quality_ffmpeg", args.quality_ffmpeg), ("ffprobe", args.ffprobe)):
        information[label] = {**identity(path), "version": capture([path, "-version"])}
    information["fixture_manifest"] = json.loads((args.workdir / "fixtures/manifest.json").read_text())
    for fixture in information["fixture_manifest"]["fixtures"]:
        actual = identity(args.workdir / "fixtures" / f"{fixture['name']}.mkv")
        if actual["sha256"] != fixture["sha256"]:
            raise ValueError("prepared input no longer matches its recorded SHA-256")
    print(json.dumps(information), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", type=Path, required=True)
    parser.add_argument("--server", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5569)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("--duration", type=int, default=60)
    prepare_parser.add_argument("--ffmpeg", default="/usr/bin/ffmpeg")
    prepare_parser.add_argument("--ffprobe", default="/usr/bin/ffprobe")
    for name in ("worker", "inventory"):
        job = commands.add_parser(name)
        job.add_argument("--ffmpeg", required=True)
        job.add_argument("--remote-ffmpeg", required=True)
        job.add_argument("--quality-ffmpeg", required=True)
        job.add_argument("--ffprobe", default="/usr/bin/ffprobe")
        job.add_argument("--render-node", default="/dev/dri/renderD128")
        if name == "worker":
            job.add_argument("--backend", choices=BACKENDS, required=True)
            job.add_argument("--codec", choices=("h264", "hevc"), required=True)
            job.add_argument("--fixture", choices=FIXTURES, required=True)
            job.add_argument("--size", choices=("1280x720", "1920x1080"), required=True)
            job.add_argument("--frames", type=int, required=True)
            job.add_argument("--run-id", required=True)
            job.add_argument("--bitrate", type=int)
            job.add_argument("--quality", action="store_true")
    server = commands.add_parser("serve")
    server.add_argument("--daemon", required=True)
    quality_parser = commands.add_parser("quality")
    quality_parser.add_argument("--input", type=Path, required=True)
    quality_parser.add_argument("--sha256", required=True)
    quality_parser.add_argument("--fixture", choices=FIXTURES, required=True)
    quality_parser.add_argument("--size", choices=("1280x720", "1920x1080"), required=True)
    quality_parser.add_argument("--frames", type=int, required=True)
    quality_parser.add_argument("--run-id", required=True)
    quality_parser.add_argument("--quality-ffmpeg", required=True)
    run = commands.add_parser("suite")
    run.add_argument("--linux-host", required=True)
    run.add_argument("--mac-host", required=True)
    run.add_argument("--release", required=True)
    run.add_argument("--output", type=Path, required=True)
    run.add_argument("--frames", type=int, default=1800)
    run.add_argument("--warmup-frames", type=int, default=60)
    run.add_argument("--repeats", type=int, default=3)
    run.add_argument("--fixtures", nargs="+", choices=FIXTURES, default=list(FIXTURES))
    run.add_argument("--codecs", nargs="+", choices=("h264", "hevc"), default=["h264", "hevc"])
    run.add_argument("--sizes", nargs="+", choices=("1280x720", "1920x1080"), default=["1280x720", "1920x1080"])
    run.add_argument("--backends", nargs="+", choices=BACKENDS, default=list(BACKENDS))
    public = commands.add_parser("public-results")
    public.add_argument("--input", type=Path, required=True)
    args = parser.parse_args()
    if getattr(args, "frames", 1) <= 0 or getattr(args, "repeats", 1) <= 0:
        parser.error("frames and repeats must be positive")
    if args.command == "public-results":
        print(json.dumps(public_results(json.loads(args.input.read_text())), indent=2))
        return
    {"prepare": prepare, "worker": worker, "quality": quality_worker,
     "serve": serve, "suite": suite, "inventory": inventory}[args.command](args)


if __name__ == "__main__":
    main()
