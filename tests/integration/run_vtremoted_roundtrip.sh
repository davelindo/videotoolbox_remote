#!/usr/bin/env bash
set -euo pipefail

# Integration regression: start vtremoted locally, run remote VideoToolbox encode, assert
# - PTS/DTS monotonic (no pts<dts)
# - Bitstream decodes cleanly with ffmpeg -xerror
# Requirements: built ffmpeg binary at ../ffmpeg/ffmpeg and vtremoted at ../vtremoted/.build/debug/vtremoted
# Note: runs against loopback with a single vtremoted instance. Uses short synthetic sources to keep runtime low.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG:-${ROOT}/ffmpeg/ffmpeg}"
FFMPEG_LOCAL_BIN="${FFMPEG_LOCAL:-ffmpeg}"
FFPROBE_BIN="${FFPROBE:-${ROOT}/ffmpeg/ffprobe}"
VTREMOTED_BIN="${VTREMOTED:-${ROOT}/vtremoted/.build/debug/vtremoted}"
source "${ROOT}/tests/integration/vtremoted_common.sh"
LOCAL_ALLOW_SW="${VTREMOTE_LOCAL_ALLOW_SW:-1}"

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg not found at $FFMPEG_BIN (override with FFMPEG)" >&2; exit 1
fi
# Optional check for local ffmpeg if we need it
if ! command -v "$FFMPEG_LOCAL_BIN" >/dev/null 2>&1; then
    # Fallback to FFMPEG_BIN if local not found, hoping it supports what we need
    FFMPEG_LOCAL_BIN="$FFMPEG_BIN"
fi
if [[ ! -x "$VTREMOTED_BIN" ]]; then
  echo "vtremoted not found at $VTREMOTED_BIN (build it or set VTREMOTED)" >&2; exit 1
fi

PORT="${VTREMOTE_PORT:-5555}"
TOKEN="${VTREMOTE_TOKEN:-}"
USE_EXISTING="${VTREMOTE_USE_EXISTING:-}"
H264_BITRATE_TOL="${VTREMOTE_H264_BITRATE_TOL:-0.5}"
HEVC_BITRATE_TOL="${VTREMOTE_HEVC_BITRATE_TOL:-0.1}"
BFRAMES="${VTREMOTE_TEST_BFRAMES:-0}"
TOKEN_ARGS=()
OUT_MP4_H264="$(mktemp /tmp/vtremote_h264_outXXXXXX.mp4)"
OUT_MP4_HEVC="$(mktemp /tmp/vtremote_hevc_outXXXXXX.mp4)"
OUT_MP4_H264_LOCAL="$(mktemp /tmp/vtlocal_h264_outXXXXXX.mp4)"
OUT_MP4_HEVC_LOCAL="$(mktemp /tmp/vtlocal_hevc_outXXXXXX.mp4)"
KEEP_OUTPUT="${VTREMOTE_KEEP_OUTPUT:-0}"
SERVER_PID=""
cleanup() {
  vtremote_stop_server
  if [[ "$KEEP_OUTPUT" != "0" ]]; then
    echo "KEEP: outputs preserved:"
    echo "  $OUT_MP4_H264"
    echo "  $OUT_MP4_HEVC"
    echo "  $OUT_MP4_H264_LOCAL"
    echo "  $OUT_MP4_HEVC_LOCAL"
  else
    rm -f "$OUT_MP4_H264" "$OUT_MP4_HEVC" "$OUT_MP4_H264_LOCAL" "$OUT_MP4_HEVC_LOCAL"
  fi
}
trap cleanup EXIT

if [[ -n "$TOKEN" ]]; then
  TOKEN_ARGS=( -vt_remote_token "$TOKEN" )
fi
VTREMOTED="$VTREMOTED_BIN"
VTREMOTE_PORT="$PORT"
VTREMOTE_TOKEN="$TOKEN"

echo "Computing local H.264/HEVC baselines..."
H264_BASELINE_OK=1
HEVC_BASELINE_OK=1
if ! "$FFMPEG_LOCAL_BIN" -v warning \
  -f lavfi -i testsrc2=size=320x180:rate=30 -t 5 -pix_fmt nv12 \
  -c:v h264_videotoolbox -b:v 300k -g 30 -bf "$BFRAMES" \
  -y "$OUT_MP4_H264_LOCAL"; then
  if [[ "$LOCAL_ALLOW_SW" != "0" ]]; then
    echo "WARN: local h264_videotoolbox failed; retrying with -allow_sw 1" >&2
    if ! "$FFMPEG_LOCAL_BIN" -v warning \
      -f lavfi -i testsrc2=size=320x180:rate=30 -t 5 -pix_fmt nv12 \
      -c:v h264_videotoolbox -allow_sw 1 -b:v 300k -g 30 -bf "$BFRAMES" \
      -y "$OUT_MP4_H264_LOCAL"; then
      H264_BASELINE_OK=0
    fi
  else
    H264_BASELINE_OK=0
  fi
fi

if ! "$FFMPEG_LOCAL_BIN" -v warning \
  -f lavfi -i testsrc2=size=320x180:rate=30 -t 5 -pix_fmt p010le \
  -c:v hevc_videotoolbox -b:v 300k -g 30 -bf "$BFRAMES" \
  -y "$OUT_MP4_HEVC_LOCAL"; then
  if [[ "$LOCAL_ALLOW_SW" != "0" ]]; then
    echo "WARN: local hevc_videotoolbox failed; retrying with -allow_sw 1" >&2
    if ! "$FFMPEG_LOCAL_BIN" -v warning \
      -f lavfi -i testsrc2=size=320x180:rate=30 -t 5 -pix_fmt p010le \
      -c:v hevc_videotoolbox -allow_sw 1 -b:v 300k -g 30 -bf "$BFRAMES" \
      -y "$OUT_MP4_HEVC_LOCAL"; then
      HEVC_BASELINE_OK=0
    fi
  else
    HEVC_BASELINE_OK=0
  fi
fi

if [[ -z "$USE_EXISTING" ]]; then
  echo "Starting vtremoted on 127.0.0.1:${VTREMOTE_PORT}..."
  vtremote_start_server /tmp/vtremoted_it.log
  SERVER_PID="${VTREMOTE_SERVER_PID:-}"
  PORT="$VTREMOTE_PORT"
else
  echo "Using existing vtremoted on 127.0.0.1:${PORT}..."
fi

LOCAL_H264_BPS=0
if [[ "$H264_BASELINE_OK" -eq 1 ]]; then
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
fi

LOCAL_HEVC_BPS=0
if [[ "$HEVC_BASELINE_OK" -eq 1 ]]; then
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
fi

echo "Running remote H.264 encode..."
"$FFMPEG_BIN" -v warning \
  -f lavfi -i testsrc2=size=320x180:rate=30 -t 5 -pix_fmt nv12 \
  -c:v h264_videotoolbox_remote -b:v 300k -g 30 -bf "$BFRAMES" \
  -vt_remote_host 127.0.0.1:${PORT} ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  -y "$OUT_MP4_H264"

echo "Checking PTS/DTS monotonicity..."
"$ROOT/tests/integration/check_pts_dts.sh" "$OUT_MP4_H264" 30

echo "Checking frame/packet parity..."
"$ROOT/tests/integration/check_frame_packet_count.sh" "$OUT_MP4_H264"

if [[ "$H264_BASELINE_OK" -eq 1 ]]; then
  echo "Checking bitrate near target..."
  "$ROOT/tests/integration/check_bitrate.sh" "$OUT_MP4_H264" "${LOCAL_H264_BPS}" "${H264_BITRATE_TOL}"
else
  echo "WARN: skipping H.264 bitrate check (local baseline unavailable)" >&2
fi

echo "Verifying decode clean with -xerror..."
"$FFMPEG_BIN" -v error -xerror -i "$OUT_MP4_H264" -f null - >/dev/null

echo "Running remote HEVC encode..."
"$FFMPEG_BIN" -v warning \
  -f lavfi -i testsrc2=size=320x180:rate=30 -t 5 -pix_fmt p010le \
  -c:v hevc_videotoolbox_remote -b:v 300k -g 30 -bf "$BFRAMES" \
  -vt_remote_host 127.0.0.1:${PORT} ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  -y "$OUT_MP4_HEVC"

echo "Checking HEVC PTS/DTS monotonicity..."
"$ROOT/tests/integration/check_pts_dts.sh" "$OUT_MP4_HEVC" 30

echo "Checking HEVC frame/packet parity..."
"$ROOT/tests/integration/check_frame_packet_count.sh" "$OUT_MP4_HEVC"

if [[ "$HEVC_BASELINE_OK" -eq 1 ]]; then
  echo "Checking HEVC bitrate near target..."
  "$ROOT/tests/integration/check_bitrate.sh" "$OUT_MP4_HEVC" "${LOCAL_HEVC_BPS}" "${HEVC_BITRATE_TOL}"
else
  echo "WARN: skipping HEVC bitrate check (local baseline unavailable)" >&2
fi

echo "Verifying HEVC decode clean with -xerror..."
"$FFMPEG_BIN" -v error -xerror -i "$OUT_MP4_HEVC" -f null - >/dev/null

echo "Roundtrip OK"
