#!/usr/bin/env python3
"""
Minimal portable mock vtremoted.

Purpose: exercise VideoToolbox Remote framing/handshake without VideoToolbox. It accepts a
single connection, validates the token, echoes CONFIGURE_ACK, and emits dummy
PACKETs in Annex B form when FRAMEs arrive. On FLUSH it sends DONE and exits.

This is intentionally small and dependency-free (Python 3 standard library).
"""

import argparse
import socket
import struct
import sys
import threading
from typing import Tuple

MAGIC = 0x56545231  # 'VTR1'
VERSION = 1

MSG_HELLO = 1
MSG_HELLO_ACK = 2
MSG_CONFIGURE = 3
MSG_CONFIGURE_ACK = 4
MSG_FRAME = 5
MSG_PACKET = 6
MSG_FLUSH = 7
MSG_DONE = 8
MSG_ERROR = 9
MSG_PING = 10
MSG_PONG = 11

HEADER_STRUCT = struct.Struct(">IHHI")  # magic, version, type, length


def read_exact(conn: socket.socket, n: int) -> bytes:
    data = bytearray()
    while len(data) < n:
        chunk = conn.recv(n - len(data))
        if not chunk:
            raise ConnectionError("socket closed")
        data.extend(chunk)
    return bytes(data)


def read_header(conn: socket.socket) -> Tuple[int, int]:
    raw = read_exact(conn, HEADER_STRUCT.size)
    magic, version, msg_type, length = HEADER_STRUCT.unpack(raw)
    if magic != MAGIC or version != VERSION:
        raise ValueError("bad magic/version")
    return msg_type, length


def write_msg(conn: socket.socket, msg_type: int, payload: bytes = b"") -> None:
    header = HEADER_STRUCT.pack(MAGIC, VERSION, msg_type, len(payload))
    conn.sendall(header + payload)


def read_u16(buf: memoryview, offset: int) -> Tuple[int, int]:
    return struct.unpack_from(">H", buf, offset)[0], offset + 2


def read_u32(buf: memoryview, offset: int) -> Tuple[int, int]:
    return struct.unpack_from(">I", buf, offset)[0], offset + 4


def read_u64(buf: memoryview, offset: int) -> Tuple[int, int]:
    return struct.unpack_from(">q", buf, offset)[0], offset + 8


def read_str(buf: memoryview, offset: int) -> Tuple[str, int]:
    length, offset = read_u16(buf, offset)
    s = bytes(buf[offset : offset + length]).decode("utf-8")
    offset += length
    return s, offset


def write_str(s: str) -> bytes:
    encoded = s.encode("utf-8")
    return struct.pack(">H", len(encoded)) + encoded


def handle_client(conn: socket.socket, expected_token: str, args: argparse.Namespace) -> None:
    with conn:
        try:
            msg_type, length = read_header(conn)
            if msg_type != MSG_HELLO:
                write_msg(conn, MSG_ERROR, b"\x00\x00\x00\x03bad first msg")
                return
            payload = memoryview(read_exact(conn, length))
            token, off = read_str(payload, 0)
            requested_codec, off = read_str(payload, off)
            client_name, off = read_str(payload, off)
            client_build, _ = read_str(payload, off)

            def hello_ack(status: int) -> bytes:
                codecs = ["h264", "hevc"]
                body = struct.pack(">B", status)
                body += struct.pack(">H", 0)  # reserved
                body += struct.pack(">H", 0)  # reserved
                body += struct.pack(">B", len(codecs))
                body += b"".join(write_str(c) for c in codecs)
                body += struct.pack(">HH", 4, 1)  # nal length size, reserved
                return body

            if expected_token and token != expected_token:
                write_msg(conn, MSG_HELLO_ACK, hello_ack(2))
                return

            write_msg(conn, MSG_HELLO_ACK, hello_ack(0))

            while True:
                msg_type, length = read_header(conn)
                payload = memoryview(read_exact(conn, length))

                if msg_type == MSG_PING:
                    write_msg(conn, MSG_PONG)
                    continue

                if msg_type == MSG_CONFIGURE:
                    # width, height (u32), pix_fmt (u8), time_base num/den (u32), framerate num/den (u32)
                    off = 0
                    width, off = read_u32(payload, off)
                    height, off = read_u32(payload, off)
                    pix_fmt = payload[off]
                    off += 1
                    _tb_num, off = read_u32(payload, off)
                    _tb_den, off = read_u32(payload, off)
                    _fr_num, off = read_u32(payload, off)
                    _fr_den, off = read_u32(payload, off)
                    # options map (count + key/value pairs) may follow; skip rest
                    # For mock we ignore options and return empty extradata.
                    extradata = b""
                    status = 0  # ok
                    body = struct.pack(">B", status) + struct.pack(">H", len(extradata)) + extradata
                    body += struct.pack(">B", pix_fmt)
                    body += struct.pack(">B", 0)  # warnings count
                    write_msg(conn, MSG_CONFIGURE_ACK, body)
                    continue

                if msg_type == MSG_FRAME:
                    off = 0
                    pts, off = read_u64(payload, off)
                    duration, off = read_u64(payload, off)
                    flags, off = read_u32(payload, off)
                    plane_count = payload[off]
                    off += 1
                    for _ in range(plane_count):
                        _, off = read_u32(payload, off)  # stride
                        _, off = read_u32(payload, off)  # height
                        data_len, off = read_u32(payload, off)
                        off += data_len
                    # Dummy Annex B IDR slice (non-compliant but frame-like)
                    data = b"\x00\x00\x00\x01\x65\x88"
                    pkt_flags = 1 if (flags & 0x1) else 0  # keyframe if requested
                    body = (
                        struct.pack(">q", pts)
                        + struct.pack(">q", pts)          # dts = pts in mock
                        + struct.pack(">q", duration)
                        + struct.pack(">I", pkt_flags)
                        + struct.pack(">I", len(data))
                        + data
                    )
                    write_msg(conn, MSG_PACKET, body)
                    continue

                if msg_type == MSG_FLUSH:
                    write_msg(conn, MSG_DONE)
                    return

                write_msg(conn, MSG_ERROR, b"\x00\x00\x00\x07unknown msg")
                return
        except Exception as exc:  # pragma: no cover - best-effort mock
            try:
                write_msg(conn, MSG_ERROR, b"\x00\x00\x00\x05" + str(exc).encode("utf-8"))
            except Exception:
                pass


def serve(listen: str, token: str, args: argparse.Namespace) -> None:
    host, port_str = listen.rsplit(":", 1)
    port = int(port_str)
    with socket.create_server((host, port), reuse_port=False) as srv:
        print(f"mock_vtremoted listening on {listen}", file=sys.stderr)
        while True:
            conn, addr = srv.accept()
            print(f"connection from {addr}", file=sys.stderr)
            thread = threading.Thread(target=handle_client, args=(conn, token, args), daemon=True)
            thread.start()
            if args.once:
                thread.join()
                break


def main() -> int:
    parser = argparse.ArgumentParser(description="Mock vtremoted for protocol framing tests.")
    parser.add_argument("--listen", default="127.0.0.1:5555", help="host:port to bind (default: 127.0.0.1:5555)")
    parser.add_argument("--token", default="", help="expected HELLO token (empty to disable)")
    parser.add_argument("--max-sessions", type=int, default=4, help="max_sessions reported in HELLO_ACK")
    parser.add_argument("--once", action="store_true", help="handle a single connection then exit")
    args = parser.parse_args()
    serve(args.listen, args.token, args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
