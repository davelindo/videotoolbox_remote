#!/usr/bin/env python3
"""Exercise automatic transcode BSF options through the CLI and an authenticated mock."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
FFMPEG = os.environ.get("FFMPEG_BIN", str(ROOT / "ffmpeg/ffmpeg"))


def main() -> None:
    run_dir = Path(tempfile.mkdtemp(prefix="vtremote-cli-options-"))
    print(f"Logs and samples: {run_dir}", flush=True)
    source = run_dir / "input.mp4"
    subprocess.run(
        [FFMPEG, "-hide_banner", "-v", "error", "-f", "lavfi", "-i",
         "testsrc2=size=64x64:rate=5:duration=1", "-c:v", "libx264",
         "-preset", "ultrafast", "-bf", "0", str(source)],
        check=True, timeout=20,
    )
    # Both CLI option paths must preserve delimiters, quotes, backslashes and
    # surrounding whitespace through the BSF-list and AVOption parsers.
    cases = [
        ("host-port", False, True, "", []),
        ("stream-host-port", True, True, "", []),
        ("separate-port", False, False, "", []),
        ("token", False, False, " :comma,quote'back\\slash=token \t", []),
        ("stream-token", True, True, " :comma,quote'back\\slash=token \t", []),
        ("bsf-chain", True, True, " :comma,quote'back\\slash=token \t",
         ["-bsf:v", "h264_mp4toannexb", "-vt_remote_out_codec:v:0", "h264",
          "-pix_fmt:v:0", "nv12", "-s:v:0", "32x32"]),
    ]
    for name, scoped, combined_host, token, extra_options in cases:
        ready = run_dir / f"{name}.ready"
        with (run_dir / f"{name}-server.log").open("w") as server_log:
            server = subprocess.Popen(
                [sys.executable, str(ROOT / "tests/integration/mock_vtremoted/mock_vtremoted.py"),
                 "--listen", "127.0.0.1:0", "--ready-file", str(ready),
                 "--token", token, "--packet-reply", "none", "--once"],
                stdout=server_log, stderr=subprocess.STDOUT,
            )
            try:
                deadline = time.monotonic() + 5
                while not ready.exists():
                    if server.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError(f"{name}: mock failed to listen; logs at {run_dir}")
                    time.sleep(0.02)
                host, port = ready.read_text().strip().rsplit(":", 1)
                suffix = ":v:0" if scoped else ""
                options = [f"-vt_remote_host{suffix}", f"{host}:{port}" if combined_host else host]
                if not combined_host:
                    options += [f"-vt_remote_port{suffix}", port]
                if token:
                    options += [f"-vt_remote_token{suffix}", token]
                with (run_dir / f"{name}-client.log").open("w") as client_log:
                    subprocess.run(
                        [FFMPEG, "-hide_banner", "-v", "verbose", "-i", str(source),
                         "-map", "0:v:0", "-c:v", "copy", "-vt_remote_transcode:v:0",
                         *options, "-vt_remote_timeout_ms", "3000", "-b:v:0", "800k",
                         "-maxrate:v:0", "1000k", "-g:v:0", "10", *extra_options,
                         "-f", "null", "-"],
                        stdout=subprocess.DEVNULL, stderr=client_log, check=True, timeout=15,
                    )
                if server.wait(timeout=5) != 0:
                    raise RuntimeError(f"{name}: mock failed; logs at {run_dir}")
                print(f"OK: {name}", flush=True)
            finally:
                if server.poll() is None:
                    server.terminate()
                    server.wait(timeout=5)
    print(f"OK: transcode CLI option round trips; logs at {run_dir}")


if __name__ == "__main__":
    main()
