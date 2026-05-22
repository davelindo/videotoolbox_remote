#!/usr/bin/env bash
set -euo pipefail

# Protocol-level packet side-data round-trip coverage against the Python mock.
# This does not require VideoToolbox or FFmpeg media generation; it verifies the
# v1 optional PACKET side-data extension remains parseable and echoable.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import socket
import struct
import subprocess
import sys
import time

root = sys.argv[1]
magic = 0x56545231
version = 1
header = struct.Struct(">IHHI")
MSG_HELLO = 1
MSG_HELLO_ACK = 2
MSG_CONFIGURE = 3
MSG_CONFIGURE_ACK = 4
MSG_PACKET = 6
MSG_FLUSH = 7
MSG_DONE = 8
MSG_PACKET_ACK = 12


def write_str(value: str) -> bytes:
    raw = value.encode("utf-8")
    return struct.pack(">H", len(raw)) + raw


def write_msg(sock: socket.socket, typ: int, payload: bytes = b"") -> None:
    sock.sendall(header.pack(magic, version, typ, len(payload)) + payload)


def read_exact(sock: socket.socket, n: int) -> bytes:
    data = bytearray()
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise RuntimeError("socket closed")
        data.extend(chunk)
    return bytes(data)


def read_msg(sock: socket.socket):
    raw = read_exact(sock, header.size)
    got_magic, got_version, typ, length = header.unpack(raw)
    if got_magic != magic or got_version != version:
        raise RuntimeError("bad header")
    return typ, read_exact(sock, length)


def read_packet(sock: socket.socket):
    while True:
        typ, payload = read_msg(sock)
        if typ == MSG_PACKET_ACK:
            continue
        if typ != MSG_PACKET:
            raise RuntimeError(f"expected PACKET, got {typ}")
        return payload


listener = socket.socket()
listener.bind(("127.0.0.1", 0))
port = listener.getsockname()[1]
listener.close()

proc = subprocess.Popen(
    [
        "python3",
        f"{root}/tests/integration/mock_vtremoted/mock_vtremoted.py",
        "--listen",
        f"127.0.0.1:{port}",
        "--packet-reply",
        "packet",
        "--once",
    ],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.PIPE,
    text=True,
)
try:
    deadline = time.time() + 5
    sock = None
    while time.time() < deadline:
        try:
            sock = socket.create_connection(("127.0.0.1", port), timeout=0.2)
            break
        except OSError:
            time.sleep(0.05)
    if sock is None:
        raise RuntimeError("mock server did not start")

    with sock:
        hello = write_str("") + write_str("h264") + write_str("side-data-test") + write_str("test")
        write_msg(sock, MSG_HELLO, hello)
        typ, payload = read_msg(sock)
        if typ != MSG_HELLO_ACK or payload[0] != 0:
            raise RuntimeError("HELLO_ACK failed")

        config = bytearray()
        config.extend(struct.pack(">IIBIIII", 320, 180, 1, 1, 1000, 5, 1))
        config.extend(struct.pack(">H", 0))
        config.extend(struct.pack(">I", 0))
        write_msg(sock, MSG_CONFIGURE, bytes(config))
        typ, _payload = read_msg(sock)
        if typ != MSG_CONFIGURE_ACK:
            raise RuntimeError("CONFIGURE_ACK failed")

        packet_data = b"\x00\x00\x00\x01\x65\x88"
        side_payload = b"side-data-payload"
        side_type = 4
        side = struct.pack(">BII", 1, side_type, len(side_payload)) + side_payload
        pkt = (
            struct.pack(">qqqII", 100, 90, 10, 1, len(packet_data))
            + packet_data
            + side
        )
        write_msg(sock, MSG_PACKET, pkt)
        payload = read_packet(sock)
        off = 8 + 8 + 8 + 4
        data_len = struct.unpack_from(">I", payload, off)[0]
        off += 4 + data_len
        got_side = payload[off:]
        if got_side != side:
            raise RuntimeError(f"side data mismatch: {got_side!r} != {side!r}")

        write_msg(sock, MSG_FLUSH)
        typ, _payload = read_msg(sock)
        if typ != MSG_DONE:
            raise RuntimeError("DONE missing")
finally:
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
    if proc.returncode not in (0, None):
        err = proc.stderr.read() if proc.stderr else ""
        raise RuntimeError(f"mock server failed: {err}")

print("OK: mock packet side-data round-trip passed")
PY
