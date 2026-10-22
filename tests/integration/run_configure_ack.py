#!/usr/bin/env python3
"""Reject truncated server avcC records through encoder and transcode APIs."""

import argparse
import concurrent.futures
from pathlib import Path
import socket
import struct
import subprocess
import tempfile

from run_transport_regressions import ROOT, message, read_message, string


def run(probe, mode, name, extra=b"", ack=None):
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        listener.settimeout(5)

        def serve():
            with listener.accept()[0] as peer:
                peer.settimeout(5)
                assert read_message(peer)[0] == 1
                caps = ("h264", "pixfmt.nv12")
                hello_ack = b"\0" + string("configure-test") + string("1") + bytes([len(caps)])
                hello_ack += b"".join(string(cap) for cap in caps) + struct.pack(">HH", 4, 1)
                peer.sendall(message(2, hello_ack))
                assert read_message(peer)[0] == 3
                # Omit trailing fields for missing-pps-count: reading a PPS count
                # outside extradata then also leaves the allocated message buffer.
                tail = b"" if name == "missing-pps-count" else b"\1\0"
                body = ack if ack is not None else b"\0" + struct.pack(">H", len(extra)) + extra + tail
                peer.sendall(message(4, body))

        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(serve)
            result = subprocess.run(
                [str(probe), mode, f"127.0.0.1:{listener.getsockname()[1]}",
                 "valid" if name == "valid" else "truncated" if ack is not None else "invalid"],
                capture_output=True, text=True, timeout=10,
            )
            future.result(timeout=5)
            assert result.returncode == 0, f"{mode}/{name}: {result.stderr}{result.stdout}"
    print(f"PASS server avcC {mode}/{name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, help="Use an already-built public API probe")
    args = parser.parse_args()
    prefix = bytes.fromhex("0142001effe1")
    sps = prefix + bytes.fromhex("000167")
    fixture = ROOT / "tests/integration/mock_vtremoted/fixtures/h264_test_avcc.hex"
    cases = {
        "valid": bytes.fromhex(fixture.read_text()),
        "short-avcc": prefix,
        "sps-length": prefix + b"\0",
        "sps-data": prefix + bytes.fromhex("000267"),
        "missing-pps-count": sps,
        "pps-length": sps + bytes.fromhex("0100"),
        "pps-data": sps + bytes.fromhex("01000268"),
    }
    with tempfile.TemporaryDirectory(prefix="vtremote-configure-ack-") as directory:
        probe = args.probe or Path(directory) / "configure_ack"
        if not args.probe:
            subprocess.run(
                ["make", "-f", "tests/integration/api-regressions.mk",
                 f"API_BUILD_DIR={directory}", str(probe)],
                cwd=ROOT, check=True,
            )
        for mode in ("encoder", "transcode"):
            for name, extra in cases.items():
                run(probe, mode, name, extra)
            run(probe, mode, "status-only", ack=b"\0")
            run(probe, mode, "truncated-length", ack=b"\0\0")


if __name__ == "__main__":
    main()
