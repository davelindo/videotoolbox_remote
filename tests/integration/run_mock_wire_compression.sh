#!/usr/bin/env bash
set -euo pipefail

# Explicit mock-backed coverage for compressed FRAME payloads. Framing-only mock
# tests pin wire compression to none; this script verifies LZ4 and Zstd paths
# separately so default compression changes do not alter framing test intent.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG_BIN:-${ROOT}/ffmpeg/ffmpeg}"
SERVER_TOKEN=${SERVER_TOKEN:-}

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg binary not found at $FFMPEG_BIN" >&2
  exit 1
fi

run_case() {
  local name="$1"
  local expect="$2"
  local port
  local server_addr
  local server_log="/tmp/mock_vtremoted_wire_${name}.log"
  local ffmpeg_log="/tmp/mock_vtremoted_wire_${name}_ffmpeg.log"
  local token_args=()

  port=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
  server_addr="127.0.0.1:${port}"

  if [[ -n "$SERVER_TOKEN" ]]; then
    python3 "${ROOT}/tests/integration/mock_vtremoted/mock_vtremoted.py" \
      --listen "$server_addr" \
      --token "$SERVER_TOKEN" \
      --strict-config-options \
      --expect-wire-compression "$expect" \
      --once >"$server_log" 2>&1 &
    token_args=( -vt_remote_token "$SERVER_TOKEN" )
  else
    python3 "${ROOT}/tests/integration/mock_vtremoted/mock_vtremoted.py" \
      --listen "$server_addr" \
      --strict-config-options \
      --expect-wire-compression "$expect" \
      --once >"$server_log" 2>&1 &
  fi
  local server_pid=$!
  trap 'kill "$server_pid" 2>/dev/null || true' RETURN
  sleep 0.2

  "$FFMPEG_BIN" -v info \
    -f lavfi -i testsrc2=size=320x180:rate=5 \
    -t 1 -pix_fmt nv12 \
    -c:v h264_videotoolbox_remote \
    -vt_remote_host "$server_addr" \
    -vt_remote_wire_compression "$name" \
    ${token_args[@]+"${token_args[@]}"} \
    -b:v 500k -g 10 \
    -f null - >"$ffmpeg_log" 2>&1

  wait "$server_pid"
  trap - RETURN
  echo "OK: mock wire_compression=${name}; logs at ${server_log} and ${ffmpeg_log}"
}

run_case lz4 1
run_case zstd 2
