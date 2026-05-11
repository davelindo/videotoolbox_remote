#!/usr/bin/env bash
set -euo pipefail

# Mock-backed HEVC pixel-format negotiation coverage for the 0.4.1 formats.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG_BIN:-${ROOT}/ffmpeg/ffmpeg}"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
}
trap cleanup EXIT

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg binary not found at $FFMPEG_BIN" >&2
  exit 1
fi

free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

run_case() {
  local pix_fmt="$1"
  local port
  local server_log="/tmp/mock_vtremote_hevc_${pix_fmt}.log"
  local ffmpeg_log="/tmp/mock_vtremote_hevc_${pix_fmt}_ffmpeg.log"

  port="$(free_port)"
  python3 "${ROOT}/tests/integration/mock_vtremoted/mock_vtremoted.py" \
    --listen "127.0.0.1:${port}" \
    --strict-config-options \
    --once >"$server_log" 2>&1 &
  SERVER_PID=$!
  sleep 0.2

  "$FFMPEG_BIN" -hide_banner -v warning -xerror \
    -f lavfi -i testsrc2=size=160x90:rate=5 -frames:v 3 \
    -vf "format=${pix_fmt}" \
    -c:v hevc_videotoolbox_remote \
    -vt_remote_host "127.0.0.1:${port}" \
    -vt_remote_wire_compression lz4 \
    -b:v 500k -g 10 \
    -f null - >"$ffmpeg_log" 2>&1

  wait "$SERVER_PID"
  SERVER_PID=""
  echo "OK: mock HEVC pix_fmt=${pix_fmt} negotiation passed"
}

run_case bgra
run_case ayuv
run_case p210le
