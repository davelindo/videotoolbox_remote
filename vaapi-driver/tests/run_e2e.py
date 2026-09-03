#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
from __future__ import annotations

import argparse
import os
import pathlib
import subprocess
import sys
import tempfile
import time


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--driver", required=True)
    parser.add_argument("--test", required=True)
    parser.add_argument("--mock", required=True)
    parser.add_argument("--codec", choices=("h264", "hevc", "hevc10"),
                        default="h264")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="vtremote-vaapi-test-") as temp:
        ready = pathlib.Path(temp) / "ready"
        fixture_dir = pathlib.Path(args.mock).parent / "fixtures"
        if args.codec == "h264":
            extradata_args = [
                "--configure-extradata-hex-file",
                str(fixture_dir / "h264_test_avcc.hex"),
            ]
        else:
            extradata_args = [
                "--configure-extradata-hex-file",
                str(fixture_dir / "hevc_main10_bt2020_pq_hvcc.hex"),
            ]
        server = subprocess.Popen(
            [sys.executable, args.mock, "--listen", "127.0.0.1:0",
             "--ready-file", str(ready), "--once", "--strict-config-options",
             *extradata_args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            for _ in range(100):
                if ready.exists() and ready.read_text(encoding="utf-8").strip():
                    break
                if server.poll() is not None:
                    stdout, stderr = server.communicate()
                    print(stdout, file=sys.stderr)
                    print(stderr, file=sys.stderr)
                    return 1
                time.sleep(0.02)
            else:
                print("mock server did not become ready", file=sys.stderr)
                return 1

            env = os.environ.copy()
            env["VTREMOTE_HOST"] = ready.read_text(encoding="utf-8").strip()
            env["VTREMOTE_LOG"] = "1"
            test = subprocess.run([args.test, args.driver, args.codec],
                                  env=env, text=True)
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.terminate()
                server.wait(timeout=5)
            stdout, stderr = server.communicate()
            if stdout:
                print(stdout, end="")
            if stderr:
                print(stderr, end="", file=sys.stderr)
            return test.returncode or server.returncode or 0
        finally:
            if server.poll() is None:
                server.kill()
                server.wait()


if __name__ == "__main__":
    raise SystemExit(main())
