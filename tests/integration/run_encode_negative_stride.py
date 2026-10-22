#!/usr/bin/env python3
"""Check encoder wire pixels for positive, negative and mixed plane strides."""

import argparse
import concurrent.futures
from pathlib import Path
import socket
import struct
import subprocess
import tempfile

from mock_vtremoted.mock_vtremoted import lz4_decompress, zstd_decompress
from run_transport_regressions import ROOT, message, read_message, string

WIDTH, HEIGHT, FRAME_COUNT = 34, 18, 4
FORMATS = {
    "nv12": 1,
    "yuv420p": 1,
    "p010le": 2,
    "yuv420p10le": 2,
    "yuv420p10be": 2,
    "bgra": 3,
    "ayuv": 4,
    "p210le": 5,
}


def source_row(index, plane, row, rows, samples, depth=8):
    inverted = index == 1 or (index == 2 and plane > 0) or (index == 3 and plane == 0)
    physical_row = rows - 1 - row if inverted else row
    return [
        (index * 17 + plane * 43 + physical_row * 7 + x * 3 + 11) % (1 << depth)
        for x in range(samples)
    ]


def expected_row(pixel_format, index, plane, row, rows):
    if pixel_format == "yuv420p":
        if plane == 0:
            return bytes(source_row(index, 0, row, rows, WIDTH))
        u = source_row(index, 1, row, rows, WIDTH // 2)
        v = source_row(index, 2, row, rows, WIDTH // 2)
        return bytes(value for pair in zip(u, v) for value in pair)
    if pixel_format.startswith("yuv420p10"):
        if plane == 0:
            values = source_row(index, 0, row, rows, WIDTH, 10)
        else:
            u = source_row(index, 1, row, rows, WIDTH // 2, 10)
            v = source_row(index, 2, row, rows, WIDTH // 2, 10)
            values = [value for pair in zip(u, v) for value in pair]
        return b"".join(struct.pack("<H", value << 6) for value in values)
    bytes_per_pixel = 4 if pixel_format in ("bgra", "ayuv") else 1 if pixel_format == "nv12" else 2
    return bytes(source_row(index, plane, row, rows, WIDTH * bytes_per_pixel))


def check_frame(body, pixel_format, compression, index):
    pts, duration, flags, plane_count = struct.unpack_from(">qqIB", body)
    packed = pixel_format in ("bgra", "ayuv")
    assert pts == index and duration == 1 and plane_count == (1 if packed else 2), (
        f"{pixel_format}/{compression} frame={index}: "
        f"pts={pts}, duration={duration}, planes={plane_count}"
    )
    offset = 21
    for plane in range(plane_count):
        stride, rows, size = struct.unpack_from(">III", body, offset)
        offset += 12
        expected_rows = HEIGHT if plane == 0 or pixel_format == "p210le" else HEIGHT // 2
        assert rows == expected_rows and 0 < stride <= 256
        encoded = body[offset : offset + size]
        assert len(encoded) == size
        offset += size
        data = (lz4_decompress(encoded, stride * rows) if compression == "lz4" else
                zstd_decompress(encoded, stride * rows) if compression == "zstd" else encoded)
        assert len(data) == stride * rows
        for row in range(rows):
            expected = expected_row(pixel_format, index, plane, row, rows)
            actual = data[row * stride : row * stride + len(expected)]
            assert actual == expected, (
                f"{pixel_format}/{compression} frame={index} plane={plane} row={row}: "
                f"pixels {actual.hex()} != {expected.hex()}"
            )
    assert offset == len(body)


def run(probe, pixel_format, compression):
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        listener.settimeout(5)

        def serve():
            with listener.accept()[0] as peer:
                peer.settimeout(5)
                assert read_message(peer)[0] == 1
                caps = ["h264", "hevc"] + ["pixfmt." + fmt for fmt in ("nv12", "p010", "bgra", "ayuv", "p210")]
                ack = b"\0" + string("stride-test") + string("1") + bytes([len(caps)])
                ack += b"".join(string(cap) for cap in caps) + struct.pack(">HH", 4, 1)
                peer.sendall(message(2, ack))
                kind, configure = read_message(peer)
                assert kind == 3 and configure[8] == FORMATS[pixel_format]
                peer.sendall(message(4, b"\0\0\0" + bytes([FORMATS[pixel_format], 0])))
                for index in range(FRAME_COUNT):
                    kind, body = read_message(peer)
                    assert kind == 5
                    check_frame(body, pixel_format, compression, index)
                    nal = b"\0\0\0\1\x65\x88"
                    packet = struct.pack(">qqqII", index, index, 1, 1, len(nal)) + nal
                    peer.sendall(message(6, packet))
                assert read_message(peer)[0] == 7
                peer.sendall(message(8))

        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(serve)
            result = subprocess.run(
                [str(probe), f"127.0.0.1:{listener.getsockname()[1]}", pixel_format, compression],
                capture_output=True, text=True, timeout=15,
            )
            future.result(timeout=5)
            assert result.returncode == 0, result.stderr + result.stdout
    print(f"PASS encoder signed strides {pixel_format}/{compression}: all pixels and timestamps")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, help="Use an already-built public API probe")
    parser.add_argument("--format", choices=FORMATS, action="append", dest="formats")
    parser.add_argument("--compression", choices=("none", "lz4", "zstd"), action="append")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="vtremote-encode-stride-") as directory:
        probe = args.probe or Path(directory) / "encode_negative_stride"
        if not args.probe:
            subprocess.run(
                ["make", "-f", "tests/integration/api-regressions.mk",
                 f"API_BUILD_DIR={directory}", str(probe)],
                cwd=ROOT, check=True,
            )
        for pixel_format in args.formats or FORMATS:
            for compression in args.compression or ("none", "lz4", "zstd"):
                run(probe, pixel_format, compression)


if __name__ == "__main__":
    main()
