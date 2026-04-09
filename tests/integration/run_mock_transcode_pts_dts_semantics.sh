#!/usr/bin/env bash
set -euo pipefail

# Ensure the vtremote_transcode BSF does not clamp PTS to DTS on output packets.
#
# The mock server can reply to PACKET with PACKET timestamps where DTS > PTS.
# This is valid (e.g. B-frames / reordering). We assert FFmpeg preserves this
# relationship instead of forcing PTS >= DTS.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG_BIN:-${ROOT}/ffmpeg/ffmpeg}"
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

SERVER_HOST="${SERVER_ADDR%:*}"
SERVER_PORT="${SERVER_ADDR##*:}"

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg binary not found at $FFMPEG_BIN" >&2
  exit 1
fi

have_encoder() {
  local enc="$1"
  # Don't use grep -q here: it can exit early, causing ffmpeg to hit SIGPIPE.
  # With `set -o pipefail`, that would make the probe look like a failure.
  "$FFMPEG_BIN" -encoders 2>/dev/null | grep -w "$enc" >/dev/null
}

ENCODER=""
PIX_FMT="yuv420p"
ENC_ARGS=()
if have_encoder "libopenh264"; then
  ENCODER="libopenh264"
elif have_encoder "libx264"; then
  ENCODER="libx264"
  ENC_ARGS=( -preset ultrafast -tune zerolatency )
elif have_encoder "h264_videotoolbox"; then
  ENCODER="h264_videotoolbox"
  PIX_FMT="nv12"
  ENC_ARGS=( -allow_sw 1 -color_range:v limited )
else
  echo "ERROR: no local H.264 encoder available (need libopenh264/libx264/h264_videotoolbox)" >&2
  exit 1
fi

SERVER_LOG=/tmp/mock_vtremoted_transcode_pts_dts.log
FFMPEG_LOG=/tmp/mock_vtremoted_transcode_pts_dts_ffmpeg.log

if [[ -n "$SERVER_TOKEN" ]]; then
  python3 "$(dirname "$0")/mock_vtremoted/mock_vtremoted.py" \
    --listen "$SERVER_ADDR" \
    --token "$SERVER_TOKEN" \
    --packet-reply packet \
    --packet-dts-offset 1 \
    --once >"$SERVER_LOG" 2>&1 &
  TOKEN_ARGS=( -bsf:v "vtremote_transcode=vt_remote_host=${SERVER_HOST}:vt_remote_port=${SERVER_PORT}:vt_remote_token=${SERVER_TOKEN}" )
else
  python3 "$(dirname "$0")/mock_vtremoted/mock_vtremoted.py" \
    --listen "$SERVER_ADDR" \
    --packet-reply packet \
    --packet-dts-offset 1 \
    --once >"$SERVER_LOG" 2>&1 &
  TOKEN_ARGS=( -bsf:v "vtremote_transcode=vt_remote_host=${SERVER_HOST}:vt_remote_port=${SERVER_PORT}" )
fi
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
sleep 0.2

"$FFMPEG_BIN" -hide_banner -loglevel verbose -debug_ts \
  -f lavfi -i testsrc2=size=64x64:rate=5 -t 1 -pix_fmt "$PIX_FMT" \
  -c:v "$ENCODER" "${ENC_ARGS[@]+"${ENC_ARGS[@]}"}" -bf 0 -g 10 \
  ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  -f null - > /dev/null 2>"$FFMPEG_LOG"

python3 - <<PY
import re, sys

log_path = "$FFMPEG_LOG"
pat = re.compile(r"\\bmuxer <- .*\\bpts:(-?\\d+)\\b.*\\bdts:(-?\\d+)\\b")

seen = 0
seen_pts_lt_dts = 0
lines = []

with open(log_path, "r", errors="ignore") as f:
    for line in f:
        m = pat.search(line)
        if not m:
            continue
        seen += 1
        pts = int(m.group(1))
        dts = int(m.group(2))
        lines.append((pts, dts, line.strip()))
        if pts < dts:
            seen_pts_lt_dts = 1
            break

if seen == 0:
    print("ERROR: did not observe any muxer packet timestamps in ffmpeg log", file=sys.stderr)
    sys.exit(1)

if not seen_pts_lt_dts:
    print("ERROR: expected at least one muxer packet with pts < dts; timestamps may have been clamped", file=sys.stderr)
    for pts, dts, line in lines[-10:]:
        print("  " + line, file=sys.stderr)
    sys.exit(1)
PY

echo "OK: vtremote_transcode preserved pts<dts; logs at ${SERVER_LOG} and ${FFMPEG_LOG}"
