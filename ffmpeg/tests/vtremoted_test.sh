#!/bin/sh
set -eu

# Requirements:
# - python3 available
# - ffmpeg binary available in current dir or $FFMPEG_BIN

FFMPEG_BIN=${FFMPEG_BIN:-./ffmpeg}
SERVER_TOKEN="secret_test_token"
SERVER_ADDR=""

if [ ! -x "$FFMPEG_BIN" ]; then
  # Fallback to looking in PATH
  if command -v ffmpeg >/dev/null 2>&1; then
      FFMPEG_BIN=ffmpeg
  else
      echo "ffmpeg binary not found at $FFMPEG_BIN" >&2
      exit 1
  fi
fi

# Find a free port
if [ -z "$SERVER_ADDR" ]; then
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

MOCK_SCRIPT="$(dirname "$0")/mock_vtremoted.py"

# Start mock server
python3 "$MOCK_SCRIPT" --listen "$SERVER_ADDR" --token "$SERVER_TOKEN" --once >/dev/null 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
sleep 0.2

# Run ffmpeg
"$FFMPEG_BIN" -v error -f lavfi -i testsrc2=size=320x180:rate=5 -t 0.5 -pix_fmt nv12 \
  -c:v h264_videotoolbox_remote -vt_remote_host "$SERVER_ADDR" -vt_remote_token "$SERVER_TOKEN" \
  -f null - 

echo "OK"
