#!/usr/bin/env python3
import concurrent.futures
import socket
import struct
import subprocess
import tempfile
import time
from pathlib import Path
from run_transport_regressions import ROOT, message, read_message, string


def run(probe, fault):
    # Large padded frames must tolerate shared-runner scheduling delays.
    timeout_ms = 3000
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        listener.settimeout(10)
        port = listener.getsockname()[1]

        def serve():
            with listener.accept()[0] as peer:
                peer.settimeout(10)
                peer.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 65536)
                peer.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 65536)
                assert read_message(peer)[0] == 1
                caps = ["h264", "pixfmt.nv12", "mode.decode", "decode.async"]
                ack = b"\0" + string("duplex-test") + string("1") + bytes([len(caps)])
                ack += b"".join(string(c) for c in caps) + struct.pack(">HH", 4, 1)
                peer.sendall(message(2, ack))
                assert read_message(peer)[0] == 3
                peer.sendall(message(4, b"\0\0\0\1\0"))
                for index in range(3):
                    kind, payload = read_message(peer)
                    assert kind == 6 and struct.unpack_from(">q", payload)[0] == index
                    stride = 262144
                    body = struct.pack(">qqIB", index, 1, 0, 2)
                    body += struct.pack(">III", stride, 64, stride * 64) + bytes([index + 16]) * (
                        stride * 64
                    )
                    body += struct.pack(">III", stride, 32, stride * 32) + bytes([128]) * (
                        stride * 32
                    )
                    wire = message(5, body)
                    if fault == "truncated":
                        peer.sendall(wire[:100])
                        return
                    if fault == "timeout":
                        peer.sendall(wire[:1])
                        time.sleep(timeout_ms / 1000 + 0.5)
                        return
                    # The client has started its next large upload by this point.
                    time.sleep(0.02)
                    peer.sendall(wire)
                assert read_message(peer)[0] == 7
                peer.sendall(message(8))

        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(serve)
            result = subprocess.run(
                [
                    str(probe),
                    f"127.0.0.1:{port}",
                    str(ROOT / "tests/integration/mock_vtremoted/fixtures/h264_test_avcc.hex"),
                    str(int(fault != "none")),
                    str(timeout_ms),
                ],
                capture_output=True,
                text=True,
                timeout=20,
            )
            assert result.returncode == 0, result.stderr + result.stdout
            future.result(timeout=5)
        print(f"PASS decoder duplex fault={fault}")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="vtremote-duplex-") as directory:
        probe = Path(directory) / "decode_duplex"
        subprocess.run(
            [
                "make",
                "-f",
                "tests/integration/api-regressions.mk",
                f"API_BUILD_DIR={directory}",
                str(probe),
            ],
            cwd=ROOT,
            check=True,
        )
        for fault in ("none", "truncated", "timeout"):
            run(probe, fault)
