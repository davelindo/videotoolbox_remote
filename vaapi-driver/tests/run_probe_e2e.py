#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys
import tempfile
import time


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", required=True)
    parser.add_argument("--mock", required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="vtremote-probe-") as temp:
        ready = pathlib.Path(temp) / "ready"
        server = subprocess.Popen(
            [sys.executable, args.mock, "--listen", "127.0.0.1:0",
             "--ready-file", str(ready), "--once", "--strict-config-options",
             "--expect-wire-compression", "2"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            for _ in range(100):
                if ready.exists() and ready.read_text(encoding="utf-8").strip():
                    break
                time.sleep(0.02)
            completed = subprocess.run(
                [args.probe, "--host", ready.read_text(encoding="utf-8").strip(),
                 "--codec", "h264"],
                text=True, capture_output=True, timeout=15,
            )
            if completed.returncode:
                print(completed.stdout, file=sys.stderr)
                print(completed.stderr, file=sys.stderr)
                return completed.returncode
            if "connected:" not in completed.stdout:
                print("probe did not report a connection", file=sys.stderr)
                return 1
            server.wait(timeout=5)
            print(completed.stdout, end="")
            return server.returncode or 0
        finally:
            if server.poll() is None:
                server.kill()
                server.wait()


if __name__ == "__main__":
    raise SystemExit(main())
