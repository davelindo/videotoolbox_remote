#!/usr/bin/env bash
set -euo pipefail

# Real vtremoted regressions:
# - send frame side-data through the encoder wire path and verify it returns on PACKET
# - encode an HEVC Main10 HDR-signaled source and verify mux-facing HDR/color fields

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG_BIN:-${ROOT}/ffmpeg/ffmpeg}"
FFPROBE_BIN="${FFPROBE_BIN:-${ROOT}/ffmpeg/ffprobe}"
VTREMOTED_BIN="${VTREMOTED:-${ROOT}/vtremoted/.build/debug/vtremoted}"
source "${ROOT}/tests/integration/vtremoted_common.sh"

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg not found at $FFMPEG_BIN (override with FFMPEG_BIN)" >&2
  exit 1
fi
if [[ ! -x "$FFPROBE_BIN" ]]; then
  echo "ffprobe not found at $FFPROBE_BIN (override with FFPROBE_BIN)" >&2
  exit 1
fi
if [[ -z "${VTREMOTE_USE_EXISTING:-}" && ! -x "$VTREMOTED_BIN" ]]; then
  echo "vtremoted not found at $VTREMOTED_BIN (build it or set VTREMOTED)" >&2
  exit 1
fi

PORT="${VTREMOTE_PORT:-5555}"
TOKEN="${VTREMOTE_TOKEN:-}"
TOKEN_ARGS=()
RUN_DIR="$(mktemp -d /tmp/vtremote_hdr_side_data.XXXXXX)"
OUT_MP4="${RUN_DIR}/remote_hdr_hevc.mp4"
SERVER_LOG="${RUN_DIR}/vtremoted.log"
KEEP_OUTPUT="${VTREMOTE_KEEP_OUTPUT:-0}"
SERVER_PID=""

cleanup() {
  local exit_code=$?
  vtremote_stop_server
  if [[ "$KEEP_OUTPUT" != "0" || "$exit_code" != "0" ]]; then
    echo "KEEP: outputs preserved (exit_code=${exit_code}): ${RUN_DIR}"
  else
    rm -rf "$RUN_DIR"
  fi
}
trap cleanup EXIT

if [[ -n "$TOKEN" ]]; then
  TOKEN_ARGS=( -vt_remote_token "$TOKEN" )
fi

VTREMOTED="$VTREMOTED_BIN"
VTREMOTE_PORT="$PORT"
VTREMOTE_TOKEN="$TOKEN"

if [[ -z "${VTREMOTE_USE_EXISTING:-}" ]]; then
  echo "Starting vtremoted for HDR side-data test..."
  vtremote_start_server "$SERVER_LOG"
  SERVER_PID="${VTREMOTE_SERVER_PID:-}"
  PORT="$VTREMOTE_PORT"
  echo "Using vtremoted on 127.0.0.1:${PORT} (pid=${SERVER_PID})"
else
  echo "Using existing vtremoted on 127.0.0.1:${PORT}..."
fi

echo "Verifying real vtremoted frame side-data wire round-trip..."
python3 - "$PORT" "$TOKEN" <<'PY'
import socket
import struct
import sys

port = int(sys.argv[1])
token = sys.argv[2]

magic = 0x56545231
version = 1
header = struct.Struct(">IHHI")
MSG_HELLO = 1
MSG_HELLO_ACK = 2
MSG_CONFIGURE = 3
MSG_CONFIGURE_ACK = 4
MSG_FRAME = 5
MSG_PACKET = 6
MSG_FLUSH = 7
MSG_DONE = 8
MSG_ERROR = 9


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
        raise RuntimeError("bad message header")
    payload = read_exact(sock, length)
    if typ == MSG_ERROR:
        msg = payload[6:].decode("utf-8", "replace") if len(payload) >= 6 else repr(payload)
        raise RuntimeError(f"server error: {msg}")
    return typ, payload


def write_config_option(key: str, value: str) -> bytes:
    return write_str(key) + write_str(value)


side_payload = b"vtremote-real-frame-side-data"
side_blob = struct.pack(">BII", 1, 11, len(side_payload)) + side_payload

with socket.create_connection(("127.0.0.1", port), timeout=10) as sock:
    hello = write_str(token) + write_str("h264") + write_str("hdr-side-data-test") + write_str("test")
    write_msg(sock, MSG_HELLO, hello)
    typ, payload = read_msg(sock)
    if typ != MSG_HELLO_ACK or not payload or payload[0] != 0:
        raise RuntimeError("HELLO_ACK failed")

    options = [
        ("mode", "encode"),
        ("wire_compression", "0"),
        ("bitrate", "200000"),
        ("gop", "10"),
        ("max_b_frames", "0"),
    ]
    config = bytearray()
    config.extend(struct.pack(">IIBIIII", 64, 64, 1, 1, 1000, 5, 1))
    config.extend(struct.pack(">H", len(options)))
    for key, value in options:
        config.extend(write_config_option(key, value))
    config.extend(struct.pack(">I", 0))
    write_msg(sock, MSG_CONFIGURE, bytes(config))
    typ, payload = read_msg(sock)
    if typ != MSG_CONFIGURE_ACK or not payload or payload[0] != 0:
        raise RuntimeError("CONFIGURE_ACK failed")

    y = bytes([0x40]) * (64 * 64)
    uv = bytes([0x80]) * (64 * 32)
    frame = bytearray()
    frame.extend(struct.pack(">qqIB", 0, 200, 1, 2))
    frame.extend(struct.pack(">III", 64, 64, len(y)))
    frame.extend(y)
    frame.extend(struct.pack(">III", 64, 32, len(uv)))
    frame.extend(uv)
    frame.extend(side_blob)
    write_msg(sock, MSG_FRAME, bytes(frame))
    write_msg(sock, MSG_FLUSH)

    saw_packet = False
    while True:
        typ, payload = read_msg(sock)
        if typ == MSG_PACKET:
            saw_packet = True
            off = 8 + 8 + 8 + 4
            data_len = struct.unpack_from(">I", payload, off)[0]
            off += 4 + data_len
            got_side = payload[off:]
            if got_side != side_blob:
                raise RuntimeError(f"side-data mismatch: {got_side!r} != {side_blob!r}")
        elif typ == MSG_DONE:
            break
    if not saw_packet:
        raise RuntimeError("server returned DONE without PACKET")

print("OK: real vtremoted frame side-data round-trip passed")
PY

echo "Encoding remote HEVC Main10 with HDR color signaling..."
"$FFMPEG_BIN" -hide_banner -v warning -y \
  -f lavfi -i testsrc2=size=160x90:rate=10 \
  -frames:v 20 \
  -vf format=p010le,setparams=range=limited:color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc \
  -c:v hevc_videotoolbox_remote \
  -profile:v main10 \
  -b:v 300k -g 20 -bf 0 \
  -color_range:v tv \
  -color_primaries:v bt2020 \
  -color_trc:v smpte2084 \
  -colorspace:v bt2020nc \
  -tag:v hvc1 \
  -vt_remote_host "127.0.0.1:${PORT}" ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  "$OUT_MP4"

probe_output=$("$FFPROBE_BIN" -hide_banner -v error \
  -show_entries stream=codec_name,codec_tag_string,pix_fmt,color_range,color_space,color_transfer,color_primaries \
  -of default=nw=1 \
  "$OUT_MP4")

for expected in \
  "codec_name=hevc" \
  "codec_tag_string=hvc1" \
  "color_range=tv" \
  "color_space=bt2020nc" \
  "color_transfer=smpte2084" \
  "color_primaries=bt2020"; do
  if ! grep -Fx "$expected" <<<"$probe_output" >/dev/null; then
    echo "ERROR: missing expected probe field '$expected'" >&2
    echo "$probe_output" >&2
    exit 1
  fi
done

echo "Verifying HDR output decodes cleanly..."
"$FFMPEG_BIN" -hide_banner -v error -xerror -err_detect explode -i "$OUT_MP4" -f null - >/dev/null

echo "OK: vtremoted HDR side-data case passed; logs at ${RUN_DIR}"
