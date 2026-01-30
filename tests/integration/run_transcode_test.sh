#!/usr/bin/env bash
set -euo pipefail

# Integration test for simultaneous remote decoding and encoding
# Workflow:
# 1. Generate local H.264 input
# 2. Start vtremoted (unless VTREMOTE_USE_EXISTING=1)
# 3. Decode (remote) -> Filter (scale) -> Encode (remote)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG_BIN:-${ROOT}/ffmpeg/ffmpeg}"
FFMPEG_LOCAL_BIN="${FFMPEG_LOCAL_BIN:-ffmpeg}"
VTREMOTED_BIN="${VTREMOTED:-${ROOT}/vtremoted/.build/debug/vtremoted}"
SERVER_TOKEN="${SERVER_TOKEN:-}"
SERVER_ADDR="${SERVER_ADDR:-}"
DECODE_ASYNC="${VTREMOTE_DECODE_ASYNC:-0}"
REORDER_DEPTH="${VTREMOTE_DECODE_REORDER_DEPTH:-2}"
LOCAL_ALLOW_SW="${VTREMOTE_LOCAL_ALLOW_SW:-1}"
USE_EXISTING="${VTREMOTE_USE_EXISTING:-}"

if [[ -n "$SERVER_ADDR" ]]; then
  if [[ "$SERVER_ADDR" == *:* ]]; then
    VTREMOTE_PORT="${VTREMOTE_PORT:-${SERVER_ADDR##*:}}"
  fi
else
  if [[ -n "${VTREMOTE_PORT:-}" ]]; then
    SERVER_ADDR="127.0.0.1:${VTREMOTE_PORT}"
  fi
fi

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg binary not found at $FFMPEG_BIN" >&2
  exit 1
fi
if ! command -v "$FFMPEG_LOCAL_BIN" >/dev/null 2>&1; then
  FFMPEG_LOCAL_BIN="$FFMPEG_BIN"
fi

source "${ROOT}/tests/integration/vtremoted_common.sh"

INPUT_FILE="$(mktemp /tmp/vtremote_transcode_inputXXXXXX.mp4)"
cleanup() {
  vtremote_stop_server
  rm -f "$INPUT_FILE"
}
trap cleanup EXIT

echo "Generating input file..."
if ! "$FFMPEG_LOCAL_BIN" -y -f lavfi -i testsrc2=size=1280x720:rate=30:duration=2 \
  -c:v h264_videotoolbox -b:v 2M -pix_fmt nv12 "$INPUT_FILE" >/dev/null 2>&1; then
  if [[ "$LOCAL_ALLOW_SW" != "0" ]]; then
    echo "WARN: local h264_videotoolbox failed; retrying with -allow_sw 1" >&2
    if ! "$FFMPEG_LOCAL_BIN" -y -f lavfi -i testsrc2=size=1280x720:rate=30:duration=2 \
      -c:v h264_videotoolbox -allow_sw 1 -b:v 2M -pix_fmt nv12 "$INPUT_FILE" >/dev/null 2>&1; then
      have_libopenh264=0
      if command -v rg >/dev/null 2>&1; then
        "$FFMPEG_LOCAL_BIN" -encoders 2>/dev/null | rg -q "libopenh264" && have_libopenh264=1 || true
      else
        "$FFMPEG_LOCAL_BIN" -encoders 2>/dev/null | grep -q "libopenh264" && have_libopenh264=1 || true
      fi
      if [[ "$have_libopenh264" -eq 1 ]]; then
        echo "WARN: local h264_videotoolbox unavailable; using libopenh264 for input" >&2
        "$FFMPEG_LOCAL_BIN" -y -f lavfi -i testsrc2=size=1280x720:rate=30:duration=2 \
          -c:v libopenh264 -b:v 2M -pix_fmt nv12 "$INPUT_FILE" >/dev/null 2>&1
      else
        exit 1
      fi
    fi
  else
    exit 1
  fi
fi

if [[ ! -x "$VTREMOTED_BIN" ]]; then
  echo "vtremoted binary not found at $VTREMOTED_BIN" >&2
  exit 1
fi

VTREMOTED="$VTREMOTED_BIN"
VTREMOTE_TOKEN="$SERVER_TOKEN"
if [[ -z "$USE_EXISTING" ]]; then
  echo "Starting vtremoted on 127.0.0.1:${VTREMOTE_PORT:-<auto>}..."
  vtremote_start_server /tmp/vtremoted_transcode.log
  if [[ -z "$SERVER_ADDR" ]]; then
    SERVER_ADDR="127.0.0.1:${VTREMOTE_PORT}"
  fi
else
  echo "Using existing vtremoted on ${SERVER_ADDR:-127.0.0.1:${VTREMOTE_PORT:-5555}}..."
  if [[ -z "$SERVER_ADDR" ]]; then
    SERVER_ADDR="127.0.0.1:${VTREMOTE_PORT:-5555}"
  fi
fi

TOKEN_ARGS=()
DECODE_ARGS=()
if [[ -n "$SERVER_TOKEN" ]]; then
  TOKEN_ARGS=( -vt_remote_token "$SERVER_TOKEN" )
fi
if [[ "$DECODE_ASYNC" != "0" ]]; then
  DECODE_ARGS=( -vt_remote_decode_async 1 -vt_remote_decode_reorder_depth "$REORDER_DEPTH" )
fi

echo "Running simultaneous decode/encode test..."
"$FFMPEG_BIN" -v info -y \
  -c:v h264_videotoolbox_remote ${DECODE_ARGS[@]+"${DECODE_ARGS[@]}"} -vt_remote_host "$SERVER_ADDR" ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  -i "$INPUT_FILE" \
  -vf "scale=640:360,format=nv12" \
  -c:v h264_videotoolbox_remote -vt_remote_host "$SERVER_ADDR" ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  -b:v 1M \
  -f null - >/tmp/vtremoted_ffmpeg_transcode.log 2>&1

echo "OK: Transcode test passed; logs at /tmp/vtremoted_*.log"
