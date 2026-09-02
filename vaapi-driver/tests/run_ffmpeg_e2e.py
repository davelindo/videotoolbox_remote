#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Exercise the driver through stock FFmpeg + the installed libva runtime."""
from __future__ import annotations

import argparse
import os
import pathlib
import subprocess
import sys
import tempfile
import time
from typing import Optional


def run_case(args: argparse.Namespace, codec: str, pixel_format: str,
             muxer: str, expected: bytes, wire: str,
             automatic_vgem: bool = False, qp: Optional[int] = None) -> None:
    with tempfile.TemporaryDirectory(prefix="vtremote-ffmpeg-e2e-") as temp_text:
        temp = pathlib.Path(temp_text)
        ready = temp / "ready"
        node = temp / "renderD128"
        output = temp / ("output.h264" if muxer == "h264" else "output.h265")
        node.touch()
        server_command = [
            sys.executable, args.mock, "--listen", "127.0.0.1:0",
            "--ready-file", str(ready), "--once", "--strict-config-options",
            "--expect-wire-compression",
            str({"none": 0, "lz4": 1, "zstd": 2}[wire]),
            "--packet-data-hex", expected.hex(),
        ]
        if qp is not None:
            quality = 1 + (51 - qp) * 99 // 50
            server_command.extend(("--expect-global-quality", str(quality)))
        server = subprocess.Popen(
            server_command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            for _ in range(500):
                if ready.exists() and ready.read_text(encoding="utf-8").strip():
                    break
                if server.poll() is not None:
                    stdout, stderr = server.communicate()
                    raise RuntimeError(f"mock failed early: {stdout}\n{stderr}")
                time.sleep(0.02)
            else:
                raise RuntimeError("mock server did not become ready")

            env = os.environ.copy()
            old_preload = env.get("LD_PRELOAD", "")
            env.update(
                LIBVA_DRIVERS_PATH=str(pathlib.Path(args.driver).resolve().parent),
                VTREMOTE_HOST=ready.read_text(encoding="utf-8").strip(),
                VTREMOTE_LOG="0",
                VTREMOTE_WIRE_COMPRESSION=wire,
                LIBVA_MESSAGING_LEVEL="0",
                LD_PRELOAD=((old_preload + ":") if old_preload else "")
                           + str(pathlib.Path(args.interposer).resolve()),
            )
            if automatic_vgem:
                env.pop("LIBVA_DRIVER_NAME", None)
            else:
                env["LIBVA_DRIVER_NAME"] = "vtremote"
            rate_control = (["-qp", str(qp)] if qp is not None
                            else ["-b:v", "3M"])
            command = [
                args.ffmpeg,
                "-hide_banner",
                "-loglevel", "warning",
                "-init_hw_device", f"vaapi=remote:{node}",
                "-filter_hw_device", "remote",
                "-f", "lavfi",
                "-i", "testsrc2=size=320x180:rate=3",
                "-vf", f"format={pixel_format},hwupload",
                "-frames:v", "3",
                "-c:v", codec,
                *rate_control,
                "-bf", "0",
                "-y",
                "-f", muxer,
                str(output),
            ]
            completed = subprocess.run(
                command, env=env, text=True, capture_output=True, timeout=30
            )
            if completed.returncode:
                raise RuntimeError(
                    f"FFmpeg {codec}/{pixel_format} failed ({completed.returncode})\n"
                    f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
                )
            actual = output.read_bytes()
            if actual != expected * 3:
                raise RuntimeError(
                    f"unexpected {codec}/{pixel_format} output: {actual.hex()}"
                )
            server.wait(timeout=5)
            if server.returncode:
                stdout, stderr = server.communicate()
                raise RuntimeError(f"mock failed: {stdout}\n{stderr}")
            print(f"ok: stock FFmpeg {codec} {pixel_format} {wire} -> {len(actual)} bytes")
        finally:
            if server.poll() is None:
                server.kill()
                server.wait()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ffmpeg", required=True)
    parser.add_argument("--driver", required=True)
    parser.add_argument("--interposer", required=True)
    parser.add_argument("--mock", required=True)
    args = parser.parse_args()
    # The first case exercises automatic DRM-name discovery through the
    # build-tree vgem_drv_video.so alias.  The remaining cases exercise the
    # explicit LIBVA_DRIVER_NAME=vtremote path.
    profiles = (
        ("h264_vaapi", "nv12", "h264", bytes.fromhex("0000000165888421")),
        ("hevc_vaapi", "nv12", "hevc", bytes.fromhex("000000012601af09")),
        ("hevc_vaapi", "p010le", "hevc", bytes.fromhex("000000012601af09")),
    )
    first = True
    for wire in ("none", "lz4", "zstd"):
        for codec, pixel_format, muxer, expected in profiles:
            run_case(args, codec, pixel_format, muxer, expected, wire,
                     automatic_vgem=first)
            first = False
    run_case(args, "h264_vaapi", "nv12", "h264", profiles[0][3],
             "zstd", qp=20)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
