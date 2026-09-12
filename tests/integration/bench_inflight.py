#!/usr/bin/env python3
"""Compare FFmpeg in-flight limits with an isolated, capacity-limited peer.

The mock emits protocol packets, not decodable video. This measures scheduling
and exact packet delivery; bench_sustained.py supplies media correctness gates.
"""

import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import platform
import queue
import socket
import statistics
import struct
import subprocess
import threading
import time

from run_transport_regressions import ROOT, accept_h264_encoder, message, read_message


def trial(binary, depth, count, delay, service, changing, realtime):
    timings = []
    failures = queue.Queue()
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        listener.settimeout(10)
        port = listener.getsockname()[1]

        def serve():
            with listener.accept()[0] as peer:
                peer.settimeout(20)
                peer.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                accept_h264_encoder(peer, "inflight-benchmark", "1")
                outgoing = queue.Queue()
                next_due = time.monotonic()
                submitted = 0

                def sender():
                    try:
                        while True:
                            item = outgoing.get()
                            if item is None:
                                break
                            due, started, wire = item
                            time.sleep(max(0, due - time.monotonic()))
                            peer.sendall(wire)
                            if started is not None:
                                timings.append((time.monotonic() - started) * 1000)
                    except Exception as error:
                        failures.put(error)

                worker = threading.Thread(target=sender, daemon=True)
                worker.start()
                try:
                    while True:
                        kind, payload = read_message(peer)
                        if kind == 7:
                            outgoing.put((next_due, None, message(8)))
                            break
                        assert kind == 5
                        pts = struct.unpack_from(">q", payload)[0]
                        started = time.monotonic()
                        interval = service * (
                            2 if changing and count // 3 <= submitted < count * 2 // 3 else 1
                        )
                        next_due = max(started + delay, next_due + interval)
                        nal = b"\0\0\0\1\x65\x88"
                        packet = struct.pack(">qqqII", pts, pts, 1, 1, len(nal)) + nal
                        outgoing.put((next_due, started, message(6, packet)))
                        submitted += 1
                finally:
                    outgoing.put(None)
                    worker.join(timeout=20)
                assert submitted == count and not worker.is_alive(), (submitted, count)

        command = [binary, "-hide_banner", "-v", "verbose", "-xerror", "-nostdin"]
        if realtime:
            command += ["-re"]
        command += [
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=64x64:rate=60",
            "-frames:v",
            str(count),
            "-pix_fmt",
            "nv12",
            "-c:v",
            "h264_videotoolbox_remote",
            "-bf",
            "0",
            "-vt_remote_host",
            f"127.0.0.1:{port}",
            "-vt_remote_wire_compression",
            "none",
            "-vt_remote_inflight",
            str(depth),
            "-vt_remote_log_level",
            "40",
            "-progress",
            "pipe:1",
            "-f",
            "null",
            "-",
        ]
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(serve)
            started = time.monotonic()
            client = subprocess.run(command, capture_output=True, text=True, timeout=90)
            elapsed = time.monotonic() - started
            try:
                future.result(timeout=20)
            except Exception as error:
                raise RuntimeError(client.stderr + client.stdout) from error
        if not failures.empty():
            raise failures.get()
        assert client.returncode == 0 and f"frame={count}\n" in client.stdout, client.stderr
        assert len(timings) == count
        timings.sort()
        return {
            "depth": depth,
            "frames": count,
            "seconds": elapsed,
            "fps": count / elapsed,
            "p50_ms": timings[int((count - 1) * 0.50)],
            "p95_ms": timings[int((count - 1) * 0.95)],
            "p99_ms": timings[int((count - 1) * 0.99)],
            "delay_ms": delay * 1000,
            "service_ms": service * 1000,
            "changing_capacity": changing,
            "realtime": realtime,
            "adjustments": [line for line in client.stderr.splitlines() if "inflight auto" in line],
        }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", default=str(ROOT / "ffmpeg/ffmpeg"))
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--frames", type=int, default=1200)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--depths", default="8,16,32,64,0")
    parser.add_argument("--delay-ms", type=float, default=80)
    parser.add_argument("--service-ms", type=float, default=4)
    parser.add_argument("--changing-capacity", action="store_true")
    parser.add_argument("--realtime", action="store_true")
    args = parser.parse_args()
    digest = hashlib.sha256()
    binary = Path(args.ffmpeg).resolve()
    with binary.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    metadata = {
        "ffmpeg": str(binary),
        "sha256": digest.hexdigest(),
        "platform": platform.platform(),
        "started_unix_seconds": time.time(),
    }
    depths = [int(value) for value in args.depths.split(",")]
    if not depths or any(value < 0 or value > 128 for value in depths):
        parser.error("depths must be between 0 (auto) and 128")
    records = []
    for repeat in range(args.repeats):
        order = list(depths)
        if repeat % 2:
            order.reverse()
        for depth in order:
            record = trial(
                args.ffmpeg,
                depth,
                args.frames,
                args.delay_ms / 1000,
                args.service_ms / 1000,
                args.changing_capacity,
                args.realtime,
            )
            record["repeat"] = repeat
            records.append(record)
            args.output.write_text(
                json.dumps({"metadata": metadata, "runs": records}, indent=2) + "\n"
            )
            print(json.dumps(record), flush=True)
    args.output.write_text(
        json.dumps(
            {
                "metadata": metadata,
                "runs": records,
                "summary": [
                    {
                        "depth": depth,
                        "fps_mean": statistics.mean(
                            r["fps"] for r in records if r["depth"] == depth
                        ),
                        "fps_stdev": statistics.stdev(
                            r["fps"] for r in records if r["depth"] == depth
                        )
                        if args.repeats > 1
                        else None,
                        "p95_ms_mean": statistics.mean(
                            r["p95_ms"] for r in records if r["depth"] == depth
                        ),
                    }
                    for depth in depths
                ],
            },
            indent=2,
        )
        + "\n"
    )
