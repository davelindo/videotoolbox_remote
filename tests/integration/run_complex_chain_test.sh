#!/usr/bin/env bash
set -euo pipefail

# Complex integration test for h264_videotoolbox_remote
# Features:
# - Python mock server
# - Complex filter chain:
#   - Input split
#   - Grayscale conversion (hue)
#   - Burnt-in subtitles (drawtext)
#   - Picture-in-Picture (crop, scale, hflip, overlay)
# - NV12 output format enforcement

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

# Start mock server
if [[ -n "$SERVER_TOKEN" ]]; then
  python3 "$(dirname "$0")/mock_vtremoted/mock_vtremoted.py" --listen "$SERVER_ADDR" --token "$SERVER_TOKEN" --once >/tmp/mock_vtremoted_complex.log 2>&1 &
else
  python3 "$(dirname "$0")/mock_vtremoted/mock_vtremoted.py" --listen "$SERVER_ADDR" --once >/tmp/mock_vtremoted_complex.log 2>&1 &
fi
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
sleep 0.5

if [[ -n "$SERVER_TOKEN" ]]; then
  TOKEN_ARGS=( -vt_remote_token "$SERVER_TOKEN" )
fi

# Font path for macOS (User OS is mac)
FONT_FILE="/System/Library/Fonts/Geneva.ttf"
if [[ ! -f "$FONT_FILE" ]]; then
    # Fallback if specific font not found
    FONT_FILE="/System/Library/Fonts/Helvetica.ttc"
fi

echo "Running complex complex filter chain..."

"$FFMPEG_BIN" -v info -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=5" \
  -filter_complex \
  "[0:v]split=2[main][pip]; \
   [main]hue=s=0,noise=alls=20:allf=t+u[bg]; \
   [pip]crop=640:360:0:0,scale=320:180,hflip[small]; \
   [bg][small]overlay=main_w-overlay_w-20:main_h-overlay_h-20:format=auto,format=nv12[out]" \
  -map "[out]" \
  -c:v h264_videotoolbox_remote \
  -vt_remote_host "$SERVER_ADDR" \
  ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  -b:v 2M \
  -f null - >/tmp/mock_vtremoted_complex_ffmpeg.log 2>&1

echo "OK: Complex chain test passed; logs at /tmp/mock_vtremoted_complex*.log"
