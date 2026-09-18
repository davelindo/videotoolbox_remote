#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
from __future__ import annotations

import argparse
import concurrent.futures
import pathlib
import socket
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests/integration"))
from run_transport_regressions import accept_h264_encoder, message, read_message


def terminal_peer(listener: socket.socket, mode: str) -> None:
    with listener.accept()[0] as peer:
        peer.settimeout(5)
        accept_h264_encoder(peer, "reconnect-fault", "1")
        assert read_message(peer)[0] == 5
        if mode == "send":
            assert peer.recv(1) == b""
        else:
            wire = message(6, b"x" * 64)
            peer.sendall(wire[:7] if mode == "header" else wire[:17])


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


def run_case(args: argparse.Namespace, mode: str) -> int:
    with tempfile.TemporaryDirectory(prefix="vtremote-reconnect-") as temp, \
            socket.socket() as listener, \
            concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
        directory = pathlib.Path(temp)
        failed_ready = directory / "failed.ready"
        success_ready = directory / "success.ready"
        servers = []
        try:
            future = None
            if mode == "handshake":
                failed = start_mock(args.mock, failed_ready, "--token", "expected-token")
                servers.append(failed)
                failed_endpoint = wait_endpoint(failed, failed_ready)
            else:
                listener.bind(("127.0.0.1", 0))
                listener.listen()
                listener.settimeout(5)
                failed_endpoint = f"127.0.0.1:{listener.getsockname()[1]}"
                future = executor.submit(terminal_peer, listener, mode)
            success = start_mock(
                args.mock, success_ready,
                "--configure-extradata-hex", "000000016764001e0000000168ee3c80",
                "--packet-data-hex", "000000016588",
            )
            servers.append(success)
            success_endpoint = wait_endpoint(success, success_ready)
            completed = subprocess.run(
                [args.test, failed_endpoint, success_endpoint, mode],
                check=False,
                capture_output=True,
                text=True,
                timeout=15,
            )
            if completed.stdout:
                print(completed.stdout, end="")
            if completed.stderr:
                print(completed.stderr, end="", file=sys.stderr)
            if future:
                future.result(timeout=5)
            if completed.returncode:
                return completed.returncode
            for server in servers:
                server.wait(timeout=5)
            return next((server.returncode for server in servers if server.returncode), 0)
        finally:
            for server in servers:
                if server.poll() is None:
                    server.kill()
                    server.wait()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--test", required=True)
    parser.add_argument("--mock", required=True)
    args = parser.parse_args()
    for mode in ("handshake", "header", "body", "send"):
        result = run_case(args, mode)
        if result:
            return result
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
