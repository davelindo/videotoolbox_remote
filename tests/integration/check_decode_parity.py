#!/usr/bin/env python3
"""Compare remote decoded pixels, timestamps and color metadata across binaries."""

import argparse
from pathlib import Path
import socket
import subprocess
import time
from bench_sustained import ROOT, identity, probe
import json


def decode(args, daemon, label, compression, pixel_format):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    base = args.output / f"{label}-{compression}"
    with base.with_suffix(".server.log").open("w") as log:
        server = subprocess.Popen(
            [daemon, "--listen", f"127.0.0.1:{port}", "--log-level", "1"], stdout=log, stderr=log
        )
        try:
            deadline = time.monotonic() + 5
            while True:
                try:
                    with socket.create_connection(("127.0.0.1", port), 0.1):
                        break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise RuntimeError("test daemon failed to listen")
                    time.sleep(0.02)
            command = [
                args.ffmpeg,
                "-hide_banner",
                "-v",
                "info",
                "-xerror",
                "-nostdin",
                "-c:v",
                f"{args.codec}_videotoolbox_remote",
                "-vt_remote_host",
                f"127.0.0.1:{port}",
                "-vt_remote_wire_compression",
                compression,
                "-i",
                str(args.input),
                "-map",
                "0:v:0",
                "-an",
                "-vf",
                "showinfo",
                "-pix_fmt",
                pixel_format,
                "-fps_mode",
                "passthrough",
                "-f",
                "framehash",
                "-hash",
                "sha256",
                str(base.with_suffix(".hash")),
            ]
            result = subprocess.run(command, capture_output=True, text=True, timeout=120)
            base.with_suffix(".client.log").write_text(result.stderr)
            assert result.returncode == 0, f"decode failed: {base}.client.log"
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
    hashes = [
        line
        for line in base.with_suffix(".hash").read_text().splitlines()
        if not line.startswith("#")
    ]
    colors = [
        line.split("] ", 1)[-1].strip()
        for line in result.stderr.splitlines()
        if "color_range:" in line
    ]
    assert len(hashes) == args.frames and len(colors) == args.frames
    return hashes, colors


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--baseline-daemon", required=True)
    parser.add_argument("--daemon", default=str(ROOT / "vtremoted/.build/release/vtremoted"))
    parser.add_argument("--ffmpeg", default=str(ROOT / "ffmpeg/ffmpeg"))
    parser.add_argument("--ffprobe", default=str(ROOT / "ffmpeg/ffprobe"))
    args = parser.parse_args()
    stream = probe(args.ffprobe, str(args.input))
    args.codec, args.frames = stream["codec_name"], int(stream["nb_read_frames"])
    pixel_format = "p010le" if "10" in stream["pix_fmt"] else "nv12"
    args.output.mkdir(parents=True, exist_ok=False)
    records = []
    reference = decode(args, args.baseline_daemon, "baseline", "lz4", pixel_format)
    for compression in ("none", "lz4", "zstd"):
        candidate = decode(args, args.daemon, "candidate", compression, pixel_format)
        assert candidate == reference, (
            f"wire compression changed pixels/timestamps/colors: {compression}"
        )
        records.append(
            {
                "compression": compression,
                "frames": args.frames,
                "pixel_format": pixel_format,
                "exact_match": True,
            }
        )
        print(
            f"PASS {compression}: {args.frames} {pixel_format} frames, timestamps and color metadata match",
            flush=True,
        )
    (args.output / "results.json").write_text(
        json.dumps(
            {
                "fixture": identity(args.input),
                "baseline": identity(args.baseline_daemon),
                "candidate": identity(args.daemon),
                "cases": records,
            },
            indent=2,
        )
        + "\n"
    )
