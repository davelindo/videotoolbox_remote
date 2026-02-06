#!/usr/bin/env bash
set -euo pipefail

# Simple decode framing test using the Python mock server and h264_videotoolbox_remote decoder.
# Requirements:
# - python3 available
# - ffmpeg binary built in ../ffmpeg/ffmpeg with h264_videotoolbox_remote enabled
#
# Note: the mock server does not implement wire compression; force `none`.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG_BIN:-${ROOT}/ffmpeg/ffmpeg}"
FFMPEG_LOCAL_BIN="${FFMPEG_LOCAL:-ffmpeg}"
SERVER_TOKEN=${SERVER_TOKEN:-}
SERVER_ADDR=${SERVER_ADDR:-}
SERVER_PID=""

if [[ -z "$SERVER_ADDR" ]]; then
  PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
  SERVER_ADDR="127.0.0.1:${PORT}"
fi
TOKEN_ARGS=()

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg binary not found at $FFMPEG_BIN" >&2
  exit 1
fi
if ! command -v "$FFMPEG_LOCAL_BIN" >/dev/null 2>&1; then
  FFMPEG_LOCAL_BIN="$FFMPEG_BIN"
fi

RUN_DIR="$(mktemp -d /tmp/vtremote_mock_decode.XXXXXX)"
INPUT_FILE="${RUN_DIR}/input.mp4"
cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ -n "${RUN_DIR:-}" && -d "${RUN_DIR:-}" ]]; then
    rm -rf "$RUN_DIR"
  fi
}
trap cleanup EXIT

echo "Generating input file..."
if ! "$FFMPEG_LOCAL_BIN" -v warning -f lavfi -i testsrc2=size=320x180:rate=5 -t 1 -pix_fmt yuv420p \
  -c:v libopenh264 -an -sn -y "$INPUT_FILE" >/tmp/mock_vtremoted_decode_gen.log 2>&1; then
  echo "WARN: libopenh264 encode failed; trying libx264 (if available)..." >&2
  "$FFMPEG_LOCAL_BIN" -v warning -f lavfi -i testsrc2=size=320x180:rate=5 -t 1 -pix_fmt yuv420p \
    -c:v libx264 -preset ultrafast -tune zerolatency -an -sn -y "$INPUT_FILE" >/tmp/mock_vtremoted_decode_gen.log 2>&1
fi

echo "Starting mock server..."
if [[ -n "$SERVER_TOKEN" ]]; then
  python3 "$(dirname "$0")/mock_vtremoted/mock_vtremoted.py" --listen "$SERVER_ADDR" --token "$SERVER_TOKEN" --once >/tmp/mock_vtremoted_decode.log 2>&1 &
else
  python3 "$(dirname "$0")/mock_vtremoted/mock_vtremoted.py" --listen "$SERVER_ADDR" --once >/tmp/mock_vtremoted_decode.log 2>&1 &
fi
SERVER_PID=$!
sleep 0.2

if [[ -n "$SERVER_TOKEN" ]]; then
  TOKEN_ARGS=( -vt_remote_token "$SERVER_TOKEN" )
fi

echo "Running remote decode against mock server..."
"$FFMPEG_BIN" -v error -xerror \
  -vt_remote_host "$SERVER_ADDR" \
  -vt_remote_wire_compression none \
  -vt_remote_decode_async 0 \
  ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  -c:v h264_videotoolbox_remote -i "$INPUT_FILE" \
  -f null - >/tmp/mock_vtremoted_decode_ffmpeg.log 2>&1

echo "OK: vtremote decode framing exercised; logs at /tmp/mock_vtremoted_decode*.log"
