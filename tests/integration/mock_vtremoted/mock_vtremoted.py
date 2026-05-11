#!/usr/bin/env python3
"""
Minimal portable mock vtremoted.

Purpose: exercise VideoToolbox Remote framing/handshake without VideoToolbox. It accepts a
single connection, validates the token, echoes CONFIGURE_ACK, and emits dummy
PACKETs in Annex B form when FRAMEs arrive. On FLUSH it sends DONE and exits.

Compressed FRAME payload validation uses system liblz4/libzstd via ctypes, so
no extra Python packages are required.
"""

import argparse
import ctypes
import ctypes.util
import socket
import struct
import sys
import threading
from typing import Dict, Tuple

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
STREAM_CHUNK_BYTES = 64 * 1024
DEFAULT_CAPABILITIES = [
    "h264",
    "hevc",
    "pixfmt.nv12",
    "pixfmt.p010",
    "pixfmt.bgra",
    "pixfmt.ayuv",
    "pixfmt.p210",
    "hwframes.videotoolbox.input",
    "hwframes.videotoolbox.output",
    "side_data.v2",
]
PIX_FMT_CAPABILITY = {
    1: "pixfmt.nv12",
    2: "pixfmt.p010",
    3: "pixfmt.bgra",
    4: "pixfmt.ayuv",
    5: "pixfmt.p210",
}

_LZ4 = None
_ZSTD = None


def _find_library(name: str, candidates):
    path = ctypes.util.find_library(name)
    if path:
        return path
    for candidate in candidates:
        if candidate:
            try:
                with open(candidate, "rb"):
                    return candidate
            except OSError:
                pass
    return None


def _load_lz4():
    global _LZ4
    if _LZ4 is not None:
        return _LZ4
    path = _find_library(
        "lz4",
        (
            "/opt/homebrew/lib/liblz4.dylib",
            "/usr/local/lib/liblz4.dylib",
            "/usr/lib/liblz4.so",
            "/usr/local/lib/liblz4.so",
        ),
    )
    if not path:
        raise RuntimeError("liblz4 not found")
    lib = ctypes.CDLL(path)
    lib.LZ4_decompress_safe.argtypes = [
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.c_int,
        ctypes.c_int,
    ]
    lib.LZ4_decompress_safe.restype = ctypes.c_int
    _LZ4 = lib
    return lib


def _load_zstd():
    global _ZSTD
    if _ZSTD is not None:
        return _ZSTD
    path = _find_library(
        "zstd",
        (
            "/opt/homebrew/lib/libzstd.dylib",
            "/usr/local/lib/libzstd.dylib",
            "/usr/lib/libzstd.so",
            "/usr/local/lib/libzstd.so",
        ),
    )
    if not path:
        raise RuntimeError("libzstd not found")
    lib = ctypes.CDLL(path)
    lib.ZSTD_decompress.argtypes = [
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_void_p,
        ctypes.c_size_t,
    ]
    lib.ZSTD_decompress.restype = ctypes.c_size_t
    lib.ZSTD_isError.argtypes = [ctypes.c_size_t]
    lib.ZSTD_isError.restype = ctypes.c_uint
    lib.ZSTD_getErrorName.argtypes = [ctypes.c_size_t]
    lib.ZSTD_getErrorName.restype = ctypes.c_char_p
    _ZSTD = lib
    return lib


def lz4_decompress(data: bytes, expected_size: int) -> bytes:
    lib = _load_lz4()
    src = ctypes.create_string_buffer(data)
    dst = ctypes.create_string_buffer(expected_size)
    decoded = lib.LZ4_decompress_safe(src, dst, len(data), expected_size)
    if decoded != expected_size:
        raise ValueError(f"lz4 decode failed: got={decoded} expected={expected_size}")
    return dst.raw[:decoded]


def zstd_decompress(data: bytes, expected_size: int) -> bytes:
    lib = _load_zstd()
    src = ctypes.create_string_buffer(data)
    dst = ctypes.create_string_buffer(expected_size)
    decoded = lib.ZSTD_decompress(dst, expected_size, src, len(data))
    if lib.ZSTD_isError(decoded):
        err = lib.ZSTD_getErrorName(decoded).decode("utf-8", "replace")
        raise ValueError(f"zstd decode failed: {err}")
    if decoded != expected_size:
        raise ValueError(f"zstd decode size mismatch: got={decoded} expected={expected_size}")
    return dst.raw[:decoded]


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


def write_filled_msg(conn: socket.socket, msg_type: int, length: int, fill: bytes = b"\0") -> None:
    if len(fill) != 1:
        raise ValueError("fill byte must be exactly one byte")
    header = HEADER_STRUCT.pack(MAGIC, VERSION, msg_type, length)
    conn.sendall(header)
    if length <= 0:
        return
    chunk = fill * min(STREAM_CHUNK_BYTES, length)
    remaining = length
    while remaining > 0:
        to_send = min(len(chunk), remaining)
        conn.sendall(chunk[:to_send])
        remaining -= to_send


def read_u16(buf: memoryview, offset: int) -> Tuple[int, int]:
    return struct.unpack_from(">H", buf, offset)[0], offset + 2


def read_u32(buf: memoryview, offset: int) -> Tuple[int, int]:
    return struct.unpack_from(">I", buf, offset)[0], offset + 4


def read_u64(buf: memoryview, offset: int) -> Tuple[int, int]:
    return struct.unpack_from(">q", buf, offset)[0], offset + 8


def read_str(buf: memoryview, offset: int) -> Tuple[str, int]:
    length, offset = read_u16(buf, offset)
    if offset + length > len(buf):
        raise ValueError("string length exceeds payload")
    s = bytes(buf[offset : offset + length]).decode("utf-8")
    offset += length
    return s, offset


def write_str(s: str) -> bytes:
    encoded = s.encode("utf-8")
    return struct.pack(">H", len(encoded)) + encoded


def parse_hex_payload(raw: str, label: str) -> bytes:
    normalized = "".join(raw.split())
    if not normalized:
        return b""
    try:
        return bytes.fromhex(normalized)
    except ValueError as exc:
        raise ValueError(f"invalid {label} hex: {exc}") from exc


def load_hex_payload(inline_hex: str, hex_file: str, label: str) -> bytes:
    if inline_hex and hex_file:
        raise ValueError(f"use only one of --{label}-hex or --{label}-hex-file")
    if hex_file:
        with open(hex_file, "r", encoding="utf-8") as handle:
            return parse_hex_payload(handle.read(), label)
    return parse_hex_payload(inline_hex, label)


def validate_payload_size(payload: bytes, label: str, max_bytes: int) -> bytes:
    if len(payload) > max_bytes:
        raise ValueError(
            f"{label} is too large for the protocol field: "
            f"{len(payload)} bytes > {max_bytes} bytes"
        )
    return payload


def parse_config_options(buf: memoryview, offset: int) -> Tuple[Dict[str, str], int]:
    options: Dict[str, str] = {}
    if offset + 2 > len(buf):
        return options, offset
    opt_count, offset = read_u16(buf, offset)
    for _ in range(opt_count):
        key, offset = read_str(buf, offset)
        value, offset = read_str(buf, offset)
        options[key] = value
    return options, offset


def validate_frame_plane(wire_compression: int, plane_data: bytes, expected_size: int) -> None:
    if wire_compression == 0:
        if len(plane_data) != expected_size:
            raise ValueError(f"raw plane size mismatch: got={len(plane_data)} expected={expected_size}")
        return
    if wire_compression == 1:
        lz4_decompress(plane_data, expected_size)
        return
    if wire_compression == 2:
        zstd_decompress(plane_data, expected_size)
        return
    raise ValueError(f"unsupported wire_compression={wire_compression}")


def validate_required_config_options(config_options: Dict[str, str]) -> None:
    required = ("bitrate", "gop", "wire_compression")
    missing = [key for key in required if key not in config_options]
    if missing:
        raise ValueError(f"missing configure options: {missing}")

    for key in required:
        if not config_options[key].isdigit():
            raise ValueError(f"non-numeric configure option: {key}={config_options[key]}")


def make_configure_ack(pix_fmt: int, extradata: bytes = b"") -> bytes:
    body = struct.pack(">B", 0) + struct.pack(">H", len(extradata)) + extradata
    body += struct.pack(">B", pix_fmt)
    body += struct.pack(">B", 0)
    return body


def make_packet_body(data: bytes, pts: int, dts: int, duration: int, flags: int) -> bytes:
    return make_packet_body_with_side_data(data, pts, dts, duration, flags, b"")


def make_packet_body_with_side_data(
    data: bytes,
    pts: int,
    dts: int,
    duration: int,
    flags: int,
    side_data_blob: bytes,
) -> bytes:
    pkt_flags = 1 if (flags & 0x1) else 0
    return (
        struct.pack(">q", pts)
        + struct.pack(">q", dts)
        + struct.pack(">q", duration)
        + struct.pack(">I", pkt_flags)
        + struct.pack(">I", len(data))
        + data
        + side_data_blob
    )


def parse_packet_body(payload: memoryview) -> Tuple[int, int, int, int, bytes]:
    off = 0
    pts, off = read_u64(payload, off)
    dts, off = read_u64(payload, off)
    dur, off = read_u64(payload, off)
    flags, off = read_u32(payload, off)
    data_len, off = read_u32(payload, off)
    if off + data_len > len(payload):
        raise ValueError("packet data length exceeds payload")
    off += data_len
    if off == len(payload):
        return pts, dts, dur, flags, b""

    side_start = off
    side_count = payload[off]
    off += 1
    for _ in range(side_count):
        _side_type, off = read_u32(payload, off)
        side_size, off = read_u32(payload, off)
        if off + side_size > len(payload):
            raise ValueError("packet side-data length exceeds payload")
        off += side_size
    if off != len(payload):
        raise ValueError("unexpected trailing bytes in PACKET payload")
    return pts, dts, dur, flags, bytes(payload[side_start:off])


def make_dummy_frame_body(pts: int, duration: int) -> bytes:
    width = 320
    height = 180
    y_stride = width
    y_height = height
    uv_stride = width
    uv_height = height // 2

    y_data = b"\x80" * (y_stride * y_height)
    uv_data = b"\x80" * (uv_stride * uv_height)

    body = bytearray()
    body.extend(struct.pack(">q", pts))
    body.extend(struct.pack(">q", duration))
    body.extend(struct.pack(">I", 0))
    body.extend(struct.pack(">B", 2))
    body.extend(struct.pack(">III", y_stride, y_height, len(y_data)))
    body.extend(y_data)
    body.extend(struct.pack(">III", uv_stride, uv_height, len(uv_data)))
    body.extend(uv_data)
    return bytes(body)


def handle_client(conn: socket.socket, expected_token: str, args: argparse.Namespace) -> None:
    with conn:
        try:
            config_options: Dict[str, str] = {}

            msg_type, length = read_header(conn)
            if msg_type != MSG_HELLO:
                write_msg(conn, MSG_ERROR, b"\x00\x00\x00\x03bad first msg")
                return
            payload = memoryview(read_exact(conn, length))
            token, off = read_str(payload, 0)
            requested_codec, off = read_str(payload, off)
            client_name, off = read_str(payload, off)
            client_build, _ = read_str(payload, off)
            _ = requested_codec, client_name, client_build

            def hello_ack(status: int) -> bytes:
                capabilities = args.capabilities
                body = struct.pack(">B", status)
                body += write_str("mock-vtremoted")
                body += write_str("test")
                body += struct.pack(">B", len(capabilities))
                body += b"".join(write_str(cap) for cap in capabilities)
                body += struct.pack(">HH", args.max_sessions, 1)
                return body

            if expected_token and token != expected_token:
                write_msg(conn, MSG_HELLO_ACK, hello_ack(2))
                return

            if args.hello_ack_bytes > 0:
                write_filled_msg(conn, MSG_HELLO_ACK, args.hello_ack_bytes)
                return

            write_msg(conn, MSG_HELLO_ACK, hello_ack(0))

            while True:
                msg_type, length = read_header(conn)
                payload = memoryview(read_exact(conn, length))

                if msg_type == MSG_PING:
                    write_msg(conn, MSG_PONG)
                    continue

                if msg_type == MSG_CONFIGURE:
                    off = 0
                    width, off = read_u32(payload, off)
                    height, off = read_u32(payload, off)
                    pix_fmt = payload[off]
                    off += 1
                    _tb_num, off = read_u32(payload, off)
                    _tb_den, off = read_u32(payload, off)
                    _fr_num, off = read_u32(payload, off)
                    _fr_den, off = read_u32(payload, off)
                    _ = width, height

                    config_options, off = parse_config_options(payload, off)
                    required_cap = PIX_FMT_CAPABILITY.get(pix_fmt)
                    if required_cap and required_cap not in args.capabilities:
                        write_msg(
                            conn,
                            MSG_ERROR,
                            b"\x00\x00\x00\x03" + f"missing capability {required_cap}".encode("utf-8"),
                        )
                        return

                    if off + 4 > len(payload):
                        raise ValueError("missing extradata length")
                    extradata_len, off = read_u32(payload, off)
                    if off + extradata_len > len(payload):
                        raise ValueError("extradata length exceeds payload")
                    off += extradata_len

                    if args.strict_config_options:
                        validate_required_config_options(config_options)
                        if off != len(payload):
                            raise ValueError("unexpected trailing bytes in CONFIGURE payload")

                    if args.expect_wire_compression is not None:
                        actual = config_options.get("wire_compression")
                        expected = str(args.expect_wire_compression)
                        if actual != expected:
                            raise ValueError(
                                f"wire_compression mismatch: expected={expected} actual={actual}"
                            )

                    if args.expect_bitrate is not None:
                        actual = config_options.get("bitrate")
                        expected = str(args.expect_bitrate)
                        if actual != expected:
                            raise ValueError(
                                f"bitrate mismatch: expected={expected} actual={actual}"
                            )

                    if args.expect_gop is not None:
                        actual = config_options.get("gop")
                        expected = str(args.expect_gop)
                        if actual != expected:
                            raise ValueError(f"gop mismatch: expected={expected} actual={actual}")

                    for arg_name, option_name in (
                        ("expect_color_range", "color_range"),
                        ("expect_colorspace", "colorspace"),
                        ("expect_color_primaries", "color_primaries"),
                        ("expect_color_trc", "color_trc"),
                    ):
                        expected_value = getattr(args, arg_name)
                        if expected_value is None:
                            continue
                        actual = config_options.get(option_name)
                        expected = str(expected_value)
                        if actual != expected:
                            raise ValueError(
                                f"{option_name} mismatch: expected={expected} actual={actual}"
                            )

                    if args.configure_ack_bytes > 0:
                        write_filled_msg(conn, MSG_CONFIGURE_ACK, args.configure_ack_bytes)
                        return

                    write_msg(conn, MSG_CONFIGURE_ACK,
                              make_configure_ack(pix_fmt, args.configure_extradata))
                    continue

                if msg_type == MSG_FRAME:
                    off = 0
                    pts, off = read_u64(payload, off)
                    duration, off = read_u64(payload, off)
                    flags, off = read_u32(payload, off)
                    plane_count = payload[off]
                    off += 1

                    wire_compression = int(config_options.get("wire_compression", "0"))

                    for _ in range(plane_count):
                        stride, off = read_u32(payload, off)
                        plane_height, off = read_u32(payload, off)
                        data_len, off = read_u32(payload, off)
                        if off + data_len > len(payload):
                            raise ValueError("frame plane length exceeds payload")
                        plane_data = bytes(payload[off : off + data_len])
                        off += data_len
                        validate_frame_plane(wire_compression, plane_data, stride * plane_height)

                    if off < len(payload):
                        side_data_count = payload[off]
                        off += 1
                        for _ in range(side_data_count):
                            _side_type, off = read_u32(payload, off)
                            side_size, off = read_u32(payload, off)
                            if off + side_size > len(payload):
                                raise ValueError("side-data length exceeds payload")
                            off += side_size

                    if off != len(payload):
                        raise ValueError("unexpected trailing bytes in FRAME payload")

                    if args.packet_bytes > 0:
                        write_filled_msg(conn, MSG_PACKET, args.packet_bytes)
                        return

                    dts = pts + int(getattr(args, "packet_dts_offset", 0))
                    write_msg(conn, MSG_PACKET,
                              make_packet_body(args.packet_data, pts, dts, duration, flags))
                    continue

                if msg_type == MSG_PACKET:
                    pts, dts, dur, flags, side_data_blob = parse_packet_body(payload)
                    _ = dts

                    if getattr(args, "packet_reply", "frame") == "packet":
                        out_dts = pts + int(getattr(args, "packet_dts_offset", 0))
                        write_msg(conn, MSG_PACKET,
                                  make_packet_body_with_side_data(
                                      args.packet_data,
                                      pts,
                                      out_dts,
                                      dur,
                                      flags,
                                      side_data_blob,
                                  ))
                        continue

                    write_msg(conn, MSG_FRAME, make_dummy_frame_body(pts, dur))
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
    parser.add_argument(
        "--packet-dts-offset",
        type=int,
        default=0,
        help="When replying with PACKET, set packet DTS = PTS + offset (default: 0)",
    )
    parser.add_argument(
        "--packet-reply",
        choices=["frame", "packet"],
        default="frame",
        help="Reply to PACKET with FRAME (decode) or PACKET (transcode-style) (default: frame)",
    )
    parser.add_argument(
        "--strict-config-options",
        action="store_true",
        help="Validate CONFIGURE options as length-prefixed UTF-8 key/value pairs",
    )
    parser.add_argument(
        "--expect-wire-compression",
        type=int,
        choices=[0, 1, 2],
        default=None,
        help="Expected CONFIGURE wire_compression value (0=none, 1=lz4, 2=zstd)",
    )
    parser.add_argument(
        "--expect-bitrate",
        type=int,
        default=None,
        help="Expected CONFIGURE bitrate value",
    )
    parser.add_argument(
        "--expect-gop",
        type=int,
        default=None,
        help="Expected CONFIGURE gop value",
    )
    parser.add_argument(
        "--expect-color-range",
        type=int,
        default=None,
        help="Expected CONFIGURE color_range value",
    )
    parser.add_argument(
        "--expect-colorspace",
        type=int,
        default=None,
        help="Expected CONFIGURE colorspace value",
    )
    parser.add_argument(
        "--expect-color-primaries",
        type=int,
        default=None,
        help="Expected CONFIGURE color_primaries value",
    )
    parser.add_argument(
        "--expect-color-trc",
        type=int,
        default=None,
        help="Expected CONFIGURE color_trc value",
    )
    parser.add_argument(
        "--hello-ack-bytes",
        type=int,
        default=0,
        help="Send HELLO_ACK with this many body bytes, then exit",
    )
    parser.add_argument(
        "--configure-ack-bytes",
        type=int,
        default=0,
        help="Send CONFIGURE_ACK with this many body bytes, then exit",
    )
    parser.add_argument(
        "--packet-bytes",
        type=int,
        default=0,
        help="Send PACKET with this many body bytes after FRAME, then exit",
    )
    parser.add_argument(
        "--configure-extradata-hex",
        default="",
        help="Hex-encoded extradata payload to send in CONFIGURE_ACK",
    )
    parser.add_argument(
        "--configure-extradata-hex-file",
        default="",
        help="Path to a file containing hex-encoded extradata for CONFIGURE_ACK",
    )
    parser.add_argument(
        "--packet-data-hex",
        default="",
        help="Hex-encoded packet payload to send in PACKET replies",
    )
    parser.add_argument(
        "--packet-data-hex-file",
        default="",
        help="Path to a file containing hex-encoded packet payload for PACKET replies",
    )
    parser.add_argument(
        "--capabilities",
        default=",".join(DEFAULT_CAPABILITIES),
        help="Comma-separated HELLO_ACK capabilities advertised by the mock",
    )
    parser.add_argument("--once", action="store_true", help="handle a single connection then exit")
    args = parser.parse_args()
    try:
        args.capabilities = [cap for cap in args.capabilities.split(",") if cap]
        args.configure_extradata = validate_payload_size(
            load_hex_payload(
                args.configure_extradata_hex,
                args.configure_extradata_hex_file,
                "configure-extradata",
            ),
            "configure-extradata",
            0xFFFF,
        )
        args.packet_data = validate_payload_size(
            load_hex_payload(
                args.packet_data_hex,
                args.packet_data_hex_file,
                "packet-data",
            ),
            "packet-data",
            0xFFFFFFFF,
        ) or b"\x00\x00\x00\x01\x65\x88"
    except ValueError as exc:
        parser.error(str(exc))
    serve(args.listen, args.token, args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
