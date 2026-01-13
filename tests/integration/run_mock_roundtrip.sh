#!/usr/bin/env bash
set -euo pipefail

# Simple framing roundtrip using the Python mock server and h264_videotoolbox_remote encoder.
# Requirements:
# - python3 available
# - ffmpeg binary built in ../ffmpeg/ffmpeg with h264_videotoolbox_remote enabled

FFMPEG_BIN=${FFMPEG_BIN:-../ffmpeg/ffmpeg}
SERVER_TOKEN=${SERVER_TOKEN:-}
SERVER_ADDR=${SERVER_ADDR:-}

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

if [[ -n "$SERVER_TOKEN" ]]; then
  python3 "$(dirname "$0")/mock_vtremoted/mock_vtremoted.py" --listen "$SERVER_ADDR" --token "$SERVER_TOKEN" --once >/tmp/mock_vtremoted.log 2>&1 &
else
  python3 "$(dirname "$0")/mock_vtremoted/mock_vtremoted.py" --listen "$SERVER_ADDR" --once >/tmp/mock_vtremoted.log 2>&1 &
fi
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
sleep 0.2

if [[ -n "$SERVER_TOKEN" ]]; then
  TOKEN_ARGS=( -vt_remote_token "$SERVER_TOKEN" )
fi

"$FFMPEG_BIN" -v info -f lavfi -i testsrc2=size=320x180:rate=5 -t 1 -pix_fmt nv12 \
  -c:v h264_videotoolbox_remote -vt_remote_host "$SERVER_ADDR" ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  -f null - >/tmp/mock_vtremoted_ffmpeg.log 2>&1

echo "OK: vtremote framing exercised; logs at /tmp/mock_vtremoted*.log"
