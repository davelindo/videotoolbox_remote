#!/usr/bin/env bash
set -euo pipefail

# Integration test for simultaneous remote decoding and encoding
# Workflow:
# 1. Generate local H.264 file (known good)
# 2. Start mock server
# 3. Decode (remote) -> Filter (scale) -> Encode (remote)

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

# 1. Generate Input File
INPUT_FILE="/tmp/transcode_input.mp4"
echo "Generating input file..."
# Use native VideoToolbox encoder to generate valid H.264 input
"$FFMPEG_BIN" -y -f lavfi -i testsrc2=size=1280x720:rate=30:duration=2 \
  -c:v h264_videotoolbox -b:v 2M -pix_fmt nv12 "$INPUT_FILE" >/dev/null 2>&1

# 2. Start Real VTRemoted Server
VTREMOTED_BIN="../../vtremoted/.build/debug/vtremoted"
if [[ ! -x "$VTREMOTED_BIN" ]]; then
  echo "vtremoted binary not found at $VTREMOTED_BIN" >&2
  exit 1
fi

if [[ -n "$SERVER_TOKEN" ]]; then
   "$VTREMOTED_BIN" --listen "$SERVER_ADDR" --token "$SERVER_TOKEN" >/tmp/vtremoted_transcode.log 2>&1 &
else
   "$VTREMOTED_BIN" --listen "$SERVER_ADDR" >/tmp/vtremoted_transcode.log 2>&1 &
fi
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
sleep 1.0

if [[ -n "$SERVER_TOKEN" ]]; then
  TOKEN_ARGS=( -vt_remote_token "$SERVER_TOKEN" )
fi

echo "Running simultaneous decode/encode test using real vtremoted..."

# 3. Run Transcode
# Decode (Remote) -> Scale -> Encode (Remote)
"$FFMPEG_BIN" -v info -y \
  -c:v h264_videotoolbox_remote -vt_remote_host "$SERVER_ADDR" ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  -i "$INPUT_FILE" \
  -vf "scale=640:360" \
  -c:v h264_videotoolbox_remote -vt_remote_host "$SERVER_ADDR" ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  -b:v 1M \
  -f null - >/tmp/vtremoted_ffmpeg_transcode.log 2>&1

echo "OK: Transcode test passed; logs at /tmp/vtremoted_*.log"
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
sleep 0.5

if [[ -n "$SERVER_TOKEN" ]]; then
  TOKEN_ARGS=( -vt_remote_token "$SERVER_TOKEN" )
fi

echo "Running simultaneous decode/encode test..."

# 3. Run Transcode
# Input options: -c:v h264_videotoolbox_remote -vt_remote_host ...
# Output options: -c:v h264_videotoolbox_remote -vt_remote_host ...
"$FFMPEG_BIN" -v info -y \
  -c:v h264_videotoolbox_remote -vt_remote_host "$SERVER_ADDR" ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  -i "$INPUT_FILE" \
  -vf "scale=640:360" \
  -c:v h264_videotoolbox_remote -vt_remote_host "$SERVER_ADDR" ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  -b:v 1M \
  -f null - >/tmp/mock_vtremoted_transcode_ffmpeg.log 2>&1

echo "OK: Transcode test passed; logs at /tmp/mock_vtremoted_transcode*.log"
