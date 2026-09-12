#!/usr/bin/env python3
"""Loopback-only regression tests for daemon deadlines and encoder completion."""

import argparse
import os
from pathlib import Path
import queue
import socket
import struct
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[2]


def string(value):
    data = value.encode()
    return struct.pack(">H", len(data)) + data


def message(kind, body=b""):
    return struct.pack(">IHHI", 0x56545231, 1, kind, len(body)) + body


def read_exact(connection, size):
    data = bytearray()
    while len(data) < size:
        chunk = connection.recv(size - len(data))
        if not chunk:
            raise EOFError("incomplete protocol message")
        data.extend(chunk)
    return bytes(data)


def read_message(connection):
    magic, version, kind, size = struct.unpack(">IHHI", read_exact(connection, 12))
    assert magic == 0x56545231 and version == 1 and size <= 32 * 1024 * 1024
    return kind, read_exact(connection, size)


def hello():
    return message(1, b"".join(string(s) for s in ("", "h264", "regression", "test")))


def accept_h264_encoder(peer, name, build):
    """Complete the shared H.264/NV12 handshake for controlled encoder peers."""
    assert read_message(peer)[0] == 1
    capabilities = ["h264", "pixfmt.nv12"]
    ack = b"\0" + string(name) + string(build) + bytes([len(capabilities)])
    ack += b"".join(string(cap) for cap in capabilities) + struct.pack(">HH", 4, 1)
    peer.sendall(message(2, ack))
    assert read_message(peer)[0] == 3
    fixture = ROOT / "tests/integration/mock_vtremoted/fixtures/h264_test_avcc.hex"
    extra = bytes.fromhex(fixture.read_text())
    peer.sendall(message(4, b"\0" + struct.pack(">H", len(extra)) + extra + b"\1\0"))


def reset_on_close(peer):
    # Winsock's linger fields are unsigned shorts; POSIX uses ints.
    peer.setsockopt(
        socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("HH" if os.name == "nt" else "ii", 1, 0)
    )


def daemon_deadlines(binary):
    cli_version = subprocess.check_output([binary, "--version"], text=True).strip().split()[-1]

    def ack_version(body):
        name_size = struct.unpack_from(">H", body, 1)[0]
        offset = 3 + name_size
        size = struct.unpack_from(">H", body, offset)[0]
        return body[offset + 2 : offset + 2 + size].decode()

    for prefix in (b"", b"V", hello()[:13], "trickle"):
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        environment = dict(os.environ)
        environment.pop("VTREMOTED_VERSION", None)
        process = subprocess.Popen(
            [
                binary,
                "--listen",
                f"127.0.0.1:{port}",
                "--max-sessions",
                "1",
                "--handshake-timeout",
                "1",
                "--idle-timeout",
                "1",
                "--log-level",
                "0",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=environment,
        )
        stalled = None
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                try:
                    stalled = socket.create_connection(("127.0.0.1", port), 0.1)
                    break
                except OSError:
                    if process.poll() is not None:
                        raise RuntimeError(process.communicate()[0].decode())
                    time.sleep(0.02)
            assert stalled is not None, "daemon failed to listen"
            stop = threading.Event()
            trickle = None
            if prefix == "trickle":

                def trickle_bytes():
                    for byte in hello():
                        try:
                            stalled.sendall(bytes([byte]))
                        except OSError:
                            break
                        if stop.wait(0.2):
                            break

                trickle = threading.Thread(target=trickle_bytes, daemon=True)
                trickle.start()
            else:
                stalled.sendall(prefix)
            stalled.settimeout(2)
            started = time.monotonic()
            try:
                assert stalled.recv(1) == b"", "stalled connection did not expire"
            except ConnectionResetError:
                # Closing while trickled bytes arrive can produce RST instead of FIN.
                pass
            assert time.monotonic() - started < 1.8
            stop.set()
            if trickle:
                trickle.join(timeout=0.5)
            with socket.create_connection(("127.0.0.1", port), 2) as peer:
                # A fragmented message that finishes within the deadline works.
                for offset in range(0, len(hello()), 3):
                    peer.sendall(hello()[offset : offset + 3])
                    time.sleep(0.01)
                kind, body = read_message(peer)
                assert kind == 2 and body[0] == 0, "expired session slot was not released"
                assert ack_version(body) == cli_version
                with socket.create_connection(("127.0.0.1", port), 2) as busy:
                    busy.sendall(hello())
                    kind, body = read_message(busy)
                    assert kind == 2 and body[0] == 1
                    assert ack_version(body) == cli_version
        finally:
            if stalled:
                stalled.close()
            process.terminate()
            try:
                process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
        print(
            f"PASS daemon deadline prefix={prefix!r}; slot released; fragmented HELLO; success/BUSY versions"
        )


def encoder_drain(binary, completion):
    failures = queue.Queue()
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        listener.settimeout(10)
        port = listener.getsockname()[1]

        def server():
            try:
                with listener.accept()[0] as peer:
                    peer.settimeout(10)
                    accept_h264_encoder(peer, "mock", "test")
                    timestamps = []
                    while True:
                        kind, body = read_message(peer)
                        if kind == 5:
                            timestamps.append(struct.unpack_from(">q", body)[0])
                        elif kind == 7:
                            break
                        else:
                            raise AssertionError(f"unexpected message {kind}")
                    assert len(timestamps) == 3, timestamps
                    if completion == "reset":
                        reset_on_close(peer)
                    elif completion == "partial":
                        peer.sendall(message(6, b"x" * 32)[:15])
                    elif completion == "early_done":
                        peer.sendall(message(8))
                    elif completion == "done":
                        for pts in timestamps:
                            nal = b"\0\0\0\1\x65\x88"
                            body = struct.pack(">qqqII", pts, pts, 1, 1, len(nal)) + nal
                            peer.sendall(message(6, body))
                        peer.sendall(message(8))
            except Exception as error:
                failures.put(error)

        thread = threading.Thread(target=server, daemon=True)
        thread.start()
        result = subprocess.run(
            [
                binary,
                "-hide_banner",
                "-v",
                "error",
                "-xerror",
                "-f",
                "lavfi",
                "-i",
                "testsrc2=size=64x64:rate=30",
                "-frames:v",
                "3",
                "-pix_fmt",
                "nv12",
                "-c:v",
                "h264_videotoolbox_remote",
                "-vt_remote_host",
                f"127.0.0.1:{port}",
                "-vt_remote_wire_compression",
                "none",
                "-vt_remote_inflight",
                "8",
                "-progress",
                "pipe:1",
                "-f",
                "null",
                "-",
            ],
            capture_output=True,
            text=True,
            timeout=15,
        )
        thread.join(timeout=2)
        assert not thread.is_alive(), "mock did not finish"
        if not failures.empty():
            raise failures.get()
        if completion == "done":
            assert result.returncode == 0 and "frame=3" in result.stdout, result.stderr
        elif completion == "early_done":
            assert result.returncode != 0 and "incomplete output" in result.stderr, result.stderr
        else:
            assert result.returncode != 0 and "before DONE" in result.stderr, result.stderr
        print(f"PASS encoder drain completion={completion}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", default=str(ROOT / "ffmpeg/ffmpeg"))
    parser.add_argument("--vtremoted", default=str(ROOT / "vtremoted/.build/debug/vtremoted"))
    parser.add_argument("--skip-daemon", action="store_true")
    parser.add_argument("--skip-ffmpeg", action="store_true")
    args = parser.parse_args()
    if not args.skip_daemon:
        daemon_deadlines(args.vtremoted)
    if not args.skip_ffmpeg:
        for completion in ("eof", "reset", "partial", "early_done", "done"):
            encoder_drain(args.ffmpeg, completion)
