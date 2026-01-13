#!/usr/bin/env bash
set -euo pipefail

# Integration regression: start vtremoted locally, run remote VideoToolbox encode, assert
# - PTS/DTS monotonic (no pts<dts)
# - Bitstream decodes cleanly with ffmpeg -xerror
# Requirements: built ffmpeg binary at ../ffmpeg/ffmpeg and vtremoted at ../vtremoted/.build/debug/vtremoted
# Note: runs against loopback with a single vtremoted instance. Uses short synthetic sources to keep runtime low.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG:-${ROOT}/ffmpeg/ffmpeg}"
FFPROBE_BIN="${FFPROBE:-${ROOT}/ffmpeg/ffprobe}"
VTREMOTED_BIN="${VTREMOTED:-${ROOT}/vtremoted/.build/debug/vtremoted}"

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg not found at $FFMPEG_BIN (override with FFMPEG)" >&2; exit 1
fi
if [[ ! -x "$VTREMOTED_BIN" ]]; then
  echo "vtremoted not found at $VTREMOTED_BIN (build it or set VTREMOTED)" >&2; exit 1
fi

PORT="${VTREMOTE_PORT:-5555}"
TOKEN="${VTREMOTE_TOKEN:-}"
USE_EXISTING="${VTREMOTE_USE_EXISTING:-}"
TOKEN_ARGS=()
OUT_MP4_H264="$(mktemp /tmp/vtremote_h264_outXXXX.mp4)"
OUT_MP4_HEVC="$(mktemp /tmp/vtremote_hevc_outXXXX.mp4)"
OUT_MP4_H264_LOCAL="$(mktemp /tmp/vtlocal_h264_outXXXX.mp4)"
OUT_MP4_HEVC_LOCAL="$(mktemp /tmp/vtlocal_hevc_outXXXX.mp4)"
SERVER_PID=""
cleanup() {
  if [[ -n "${SERVER_PID}" ]]; then
    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
  rm -f "$OUT_MP4_H264" "$OUT_MP4_HEVC" "$OUT_MP4_H264_LOCAL" "$OUT_MP4_HEVC_LOCAL"
}
trap cleanup EXIT

start_server() {
  echo "Starting vtremoted on 127.0.0.1:${PORT}..."
  if [[ -n "$TOKEN" ]]; then
    "$VTREMOTED_BIN" --listen 127.0.0.1:${PORT} --token "$TOKEN" > /tmp/vtremoted_it.log 2>&1 &
  else
    "$VTREMOTED_BIN" --listen 127.0.0.1:${PORT} > /tmp/vtremoted_it.log 2>&1 &
  fi
  SERVER_PID=$!
  if command -v lsof >/dev/null 2>&1; then
    for _ in $(seq 1 20); do
      if lsof -nP -iTCP:${PORT} -sTCP:LISTEN >/dev/null 2>&1; then
        return 0
      fi
      sleep 0.1
    done
    echo "vtremoted did not start listening on ${PORT}" >&2
    exit 1
  else
    sleep 0.6
  fi
}

if [[ -z "$USE_EXISTING" ]]; then
  start_server
else
  echo "Using existing vtremoted on 127.0.0.1:${PORT}..."
fi

if [[ -n "$TOKEN" ]]; then
  TOKEN_ARGS=( -vt_remote_token "$TOKEN" )
fi

echo "Computing local H.264/HEVC baselines..."
"$FFMPEG_BIN" -v warning \
  -f lavfi -i testsrc2=size=320x180:rate=30 -t 5 -pix_fmt nv12 \
  -c:v h264_videotoolbox -b:v 300k -g 30 \
  -y "$OUT_MP4_H264_LOCAL"

"$FFMPEG_BIN" -v warning \
  -f lavfi -i testsrc2=size=320x180:rate=30 -t 5 -pix_fmt p010le \
  -c:v hevc_videotoolbox -b:v 300k -g 30 \
  -y "$OUT_MP4_HEVC_LOCAL"

LOCAL_H264_BPS=$(python3 - <<PY
import os, subprocess
ffprobe = "${FFPROBE_BIN}"
path = "${OUT_MP4_H264_LOCAL}"
dur = subprocess.check_output([ffprobe, "-v", "error", "-show_entries", "format=duration", "-of", "default=nk=1:nw=1", path]).strip()
dur = float(dur) if dur else 0.0
size = os.path.getsize(path)
print(int(size * 8 / dur) if dur > 0 else 0)
PY
)

LOCAL_HEVC_BPS=$(python3 - <<PY
import os, subprocess
ffprobe = "${FFPROBE_BIN}"
path = "${OUT_MP4_HEVC_LOCAL}"
dur = subprocess.check_output([ffprobe, "-v", "error", "-show_entries", "format=duration", "-of", "default=nk=1:nw=1", path]).strip()
dur = float(dur) if dur else 0.0
size = os.path.getsize(path)
print(int(size * 8 / dur) if dur > 0 else 0)
PY
)

echo "Running remote H.264 encode..."
"$FFMPEG_BIN" -v warning \
  -f lavfi -i testsrc2=size=320x180:rate=30 -t 5 -pix_fmt nv12 \
  -c:v h264_videotoolbox_remote -b:v 300k -g 30 \
  -vt_remote_host 127.0.0.1:${PORT} ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  -y "$OUT_MP4_H264"

echo "Checking PTS/DTS monotonicity..."
"$ROOT/tests/integration/check_pts_dts.sh" "$OUT_MP4_H264" 30

echo "Checking frame/packet parity..."
"$ROOT/tests/integration/check_frame_packet_count.sh" "$OUT_MP4_H264"

echo "Checking bitrate near target..."
"$ROOT/tests/integration/check_bitrate.sh" "$OUT_MP4_H264" "${LOCAL_H264_BPS}" 0.01

echo "Verifying decode clean with -xerror..."
"$FFMPEG_BIN" -v error -xerror -i "$OUT_MP4_H264" -f null - >/dev/null

echo "Running remote HEVC encode..."
"$FFMPEG_BIN" -v warning \
  -f lavfi -i testsrc2=size=320x180:rate=30 -t 5 -pix_fmt p010le \
  -c:v hevc_videotoolbox_remote -b:v 300k -g 30 \
  -vt_remote_host 127.0.0.1:${PORT} ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  -y "$OUT_MP4_HEVC"

echo "Checking HEVC PTS/DTS monotonicity..."
"$ROOT/tests/integration/check_pts_dts.sh" "$OUT_MP4_HEVC" 30

echo "Checking HEVC frame/packet parity..."
"$ROOT/tests/integration/check_frame_packet_count.sh" "$OUT_MP4_HEVC"

echo "Checking HEVC bitrate near target..."
"$ROOT/tests/integration/check_bitrate.sh" "$OUT_MP4_HEVC" "${LOCAL_HEVC_BPS}" 0.01

echo "Verifying HEVC decode clean with -xerror..."
"$FFMPEG_BIN" -v error -xerror -i "$OUT_MP4_HEVC" -f null - >/dev/null

echo "Roundtrip OK"
