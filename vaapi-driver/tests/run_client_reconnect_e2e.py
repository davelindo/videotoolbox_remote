#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys
import tempfile
import time


def start_mock(mock: str, ready: pathlib.Path, *extra: str) -> subprocess.Popen[str]:
    return subprocess.Popen(
        [
            sys.executable,
            mock,
            "--listen",
            "127.0.0.1:0",
            "--ready-file",
            str(ready),
            "--once",
            *extra,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def wait_endpoint(server: subprocess.Popen[str], ready: pathlib.Path) -> str:
    for _ in range(100):
        if ready.exists():
            endpoint = ready.read_text(encoding="utf-8").strip()
            if endpoint:
                return endpoint
        if server.poll() is not None:
            stdout, stderr = server.communicate()
            raise RuntimeError(f"mock exited early: {stdout}\n{stderr}")
        time.sleep(0.02)
    raise RuntimeError("mock did not publish its endpoint")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--test", required=True)
    parser.add_argument("--mock", required=True)
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="vtremote-reconnect-") as temp:
        directory = pathlib.Path(temp)
        failed_ready = directory / "failed.ready"
        success_ready = directory / "success.ready"
        failed = start_mock(args.mock, failed_ready, "--token", "expected-token")
        success = start_mock(args.mock, success_ready)
        servers = (failed, success)
        try:
            failed_endpoint = wait_endpoint(failed, failed_ready)
            success_endpoint = wait_endpoint(success, success_ready)
            completed = subprocess.run(
                [args.test, failed_endpoint, success_endpoint],
                check=False,
                capture_output=True,
                text=True,
                timeout=15,
            )
            if completed.stdout:
                print(completed.stdout, end="")
            if completed.stderr:
                print(completed.stderr, end="", file=sys.stderr)
            for server in servers:
                server.wait(timeout=5)
            return completed.returncode or failed.returncode or success.returncode or 0
        finally:
            for server in servers:
                if server.poll() is None:
                    server.kill()
                    server.wait()


if __name__ == "__main__":
    raise SystemExit(main())
