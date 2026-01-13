#!/usr/bin/env bash
set -euo pipefail

# Integration regression: start vtremoted locally, run remote VideoToolbox decode
# Requirements: built ffmpeg binary at ../ffmpeg/ffmpeg and vtremoted at ../vtremoted/.build/debug/vtremoted

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG:-${ROOT}/ffmpeg/ffmpeg}"
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
IN_H264="$(mktemp /tmp/vtremote_dec_h264XXXX.mp4)"
IN_HEVC="$(mktemp /tmp/vtremote_dec_hevcXXXX.mp4)"
SERVER_PID=""
cleanup() {
  if [[ -n "${SERVER_PID}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f "$IN_H264" "$IN_HEVC"
}
trap cleanup EXIT

if [[ -z "$USE_EXISTING" ]]; then
  echo "Starting vtremoted on 127.0.0.1:${PORT}..."
  if [[ -n "$TOKEN" ]]; then
    "$VTREMOTED_BIN" --listen 127.0.0.1:${PORT} --token "$TOKEN" > /tmp/vtremoted_decode.log 2>&1 &
  else
    "$VTREMOTED_BIN" --listen 127.0.0.1:${PORT} > /tmp/vtremoted_decode.log 2>&1 &
  fi
  SERVER_PID=$!
  sleep 0.3
else
  echo "Using existing vtremoted on 127.0.0.1:${PORT}..."
fi

if [[ -n "$TOKEN" ]]; then
  TOKEN_ARGS=( -vt_remote_token "$TOKEN" )
fi

echo "Generating local H.264 + HEVC inputs..."
"$FFMPEG_BIN" -v warning -f lavfi -i testsrc2=size=320x180:rate=5 -t 2 -pix_fmt nv12 \
  -c:v h264_videotoolbox -an -sn -y "$IN_H264"
"$FFMPEG_BIN" -v warning -f lavfi -i testsrc2=size=320x180:rate=5 -t 2 -pix_fmt p010le \
  -c:v hevc_videotoolbox -an -sn -y "$IN_HEVC"

echo "Remote decode H.264..."
"$FFMPEG_BIN" -v error -xerror \
  -vt_remote_host 127.0.0.1:${PORT} ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  -c:v h264_videotoolbox_remote -i "$IN_H264" -f null - >/dev/null

echo "Remote decode HEVC..."
"$FFMPEG_BIN" -v error -xerror \
  -vt_remote_host 127.0.0.1:${PORT} ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  -c:v hevc_videotoolbox_remote -i "$IN_HEVC" -f null - >/dev/null

echo "Decode OK"
if [[ -n "${SERVER_PID}" ]]; then
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
fi
