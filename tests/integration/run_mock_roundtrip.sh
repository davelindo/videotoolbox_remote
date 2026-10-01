#!/usr/bin/env bash
set -euo pipefail

# Simple framing roundtrip using the Python mock server and h264_videotoolbox_remote encoder.
# Requirements:
# - python3 available
# - ffmpeg binary built in ../ffmpeg/ffmpeg with h264_videotoolbox_remote enabled

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG_BIN:-${ROOT}/ffmpeg/ffmpeg}"
source "${ROOT}/tests/integration/mock_vtremoted_common.sh"
SERVER_TOKEN=${SERVER_TOKEN:-}
SERVER_ADDR=${SERVER_ADDR:-127.0.0.1:0}
RUN_DIR="$(mktemp -d /tmp/mock_vtremoted_roundtrip.XXXXXX)"
SERVER_LOG="${RUN_DIR}/server.log"
FFMPEG_LOG="${RUN_DIR}/ffmpeg.log"
READY_FILE="${RUN_DIR}/server.ready"
TOKEN_ARGS=()

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg binary not found at $FFMPEG_BIN" >&2
  exit 1
fi

python3 "${ROOT}/tests/integration/mock_vtremoted/mock_vtremoted.py" \
  --listen "$SERVER_ADDR" --ready-file "$READY_FILE" \
  --token "$SERVER_TOKEN" --once >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
trap 'vtremote_stop_mock "$SERVER_PID"' EXIT
SERVER_ADDR="$(vtremote_wait_mock_ready "$SERVER_PID" "$READY_FILE" "$SERVER_LOG")"

if [[ -n "$SERVER_TOKEN" ]]; then
  TOKEN_ARGS=( -vt_remote_token "$SERVER_TOKEN" )
fi

"$FFMPEG_BIN" -v info -f lavfi -i testsrc2=size=320x180:rate=5 -t 1 -pix_fmt nv12 \
  -c:v h264_videotoolbox_remote -vt_remote_host "$SERVER_ADDR" \
  -vt_remote_wire_compression none ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  -f null - >"$FFMPEG_LOG" 2>&1 || { cat "$FFMPEG_LOG" >&2; exit 1; }

echo "OK: vtremote framing exercised; logs at ${RUN_DIR}"
