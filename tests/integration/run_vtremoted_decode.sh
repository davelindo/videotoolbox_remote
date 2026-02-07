#!/usr/bin/env bash
set -euo pipefail

# Integration regression: start vtremoted locally, run remote VideoToolbox decode
# Requirements: built ffmpeg binary at ../ffmpeg/ffmpeg and vtremoted at ../vtremoted/.build/debug/vtremoted

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG:-${ROOT}/ffmpeg/ffmpeg}"
FFMPEG_LOCAL_BIN="${FFMPEG_LOCAL:-ffmpeg}"
VTREMOTED_BIN="${VTREMOTED:-${ROOT}/vtremoted/.build/debug/vtremoted}"
source "${ROOT}/tests/integration/vtremoted_common.sh"
LOCAL_ALLOW_SW="${VTREMOTE_LOCAL_ALLOW_SW:-1}"

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg not found at $FFMPEG_BIN (override with FFMPEG)" >&2; exit 1
fi
if [[ ! -x "$VTREMOTED_BIN" ]]; then
  echo "vtremoted not found at $VTREMOTED_BIN (build it or set VTREMOTED)" >&2; exit 1
fi

PORT="${VTREMOTE_PORT:-5555}"
TOKEN="${VTREMOTE_TOKEN:-}"
USE_EXISTING="${VTREMOTE_USE_EXISTING:-}"
DECODE_ASYNC="${VTREMOTE_DECODE_ASYNC:-0}"
REORDER_DEPTH="${VTREMOTE_DECODE_REORDER_DEPTH:-2}"
TOKEN_ARGS=()
DECODE_ARGS=()
SKIP_HEVC=0
VTREMOTED="$VTREMOTED_BIN"
VTREMOTE_PORT="$PORT"
VTREMOTE_TOKEN="$TOKEN"
RUN_DIR="$(mktemp -d /tmp/vtremote_decode.XXXXXX)"
IN_H264="${RUN_DIR}/input_h264.mp4"
IN_HEVC="${RUN_DIR}/input_hevc.mp4"
SERVER_PID=""
cleanup() {
  vtremote_stop_server
  if [[ -n "${RUN_DIR:-}" && -d "${RUN_DIR:-}" ]]; then
    rm -rf "$RUN_DIR"
  fi
}
trap cleanup EXIT

if [[ -n "$TOKEN" ]]; then
  TOKEN_ARGS=( -vt_remote_token "$TOKEN" )
fi
if [[ "$DECODE_ASYNC" != "0" ]]; then
  DECODE_ARGS=( -vt_remote_decode_async 1 -vt_remote_decode_reorder_depth "$REORDER_DEPTH" )
fi

echo "Generating local H.264 + HEVC inputs..."
H264_OK=1
if ! "$FFMPEG_LOCAL_BIN" -v warning -f lavfi -i testsrc2=size=320x180:rate=5 -t 2 -pix_fmt nv12 \
  -c:v h264_videotoolbox -an -sn -y "$IN_H264"; then
  if [[ "$LOCAL_ALLOW_SW" != "0" ]]; then
    echo "WARN: local h264_videotoolbox failed; retrying with -allow_sw 1" >&2
    if ! "$FFMPEG_LOCAL_BIN" -v warning -f lavfi -i testsrc2=size=320x180:rate=5 -t 2 -pix_fmt nv12 \
      -c:v h264_videotoolbox -allow_sw 1 -an -sn -y "$IN_H264"; then
      H264_OK=0
    fi
  else
    H264_OK=0
  fi
fi
if [[ "$H264_OK" -eq 0 ]]; then
  have_libopenh264=0
  if command -v rg >/dev/null 2>&1; then
    "$FFMPEG_LOCAL_BIN" -encoders 2>/dev/null | rg -q "libopenh264" && have_libopenh264=1 || true
  else
    "$FFMPEG_LOCAL_BIN" -encoders 2>/dev/null | grep -q "libopenh264" && have_libopenh264=1 || true
  fi
  if [[ "$have_libopenh264" -eq 1 ]]; then
    echo "WARN: local h264_videotoolbox unavailable; using libopenh264 for input" >&2
    "$FFMPEG_LOCAL_BIN" -v warning -f lavfi -i testsrc2=size=320x180:rate=5 -t 2 -pix_fmt nv12 \
      -c:v libopenh264 -an -sn -y "$IN_H264"
  else
    exit 1
  fi
fi

HEVC_OK=1
if ! "$FFMPEG_LOCAL_BIN" -v warning -f lavfi -i testsrc2=size=320x180:rate=5 -t 2 -pix_fmt p010le \
  -c:v hevc_videotoolbox -an -sn -y "$IN_HEVC"; then
  if [[ "$LOCAL_ALLOW_SW" != "0" ]]; then
    echo "WARN: local hevc_videotoolbox failed; retrying with -allow_sw 1" >&2
    if ! "$FFMPEG_LOCAL_BIN" -v warning -f lavfi -i testsrc2=size=320x180:rate=5 -t 2 -pix_fmt p010le \
      -c:v hevc_videotoolbox -allow_sw 1 -an -sn -y "$IN_HEVC"; then
      HEVC_OK=0
    fi
  else
    HEVC_OK=0
  fi
fi
if [[ "$HEVC_OK" -eq 0 ]]; then
  echo "WARN: local hevc_videotoolbox unavailable; skipping HEVC decode test" >&2
  SKIP_HEVC=1
fi

if [[ -z "$USE_EXISTING" ]]; then
  echo "Starting vtremoted on 127.0.0.1:${VTREMOTE_PORT:-<auto>}..."
  vtremote_start_server /tmp/vtremoted_decode.log
  SERVER_PID="${VTREMOTE_SERVER_PID:-}"
  PORT="$VTREMOTE_PORT"
  echo "Using vtremoted on 127.0.0.1:${PORT} (pid=${SERVER_PID})"
else
  echo "Using existing vtremoted on 127.0.0.1:${PORT}..."
fi

ensure_server_running() {
  if [[ -n "${SERVER_PID:-}" ]] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "WARN: vtremoted died; restarting..." >&2
    vtremote_restart_server /tmp/vtremoted_decode.log
    SERVER_PID="${VTREMOTE_SERVER_PID:-}"
    PORT="$VTREMOTE_PORT"
  fi
}

echo "Remote decode H.264..."
"$FFMPEG_BIN" -v error -xerror \
  -vt_remote_host 127.0.0.1:${PORT} ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  ${DECODE_ARGS[@]+"${DECODE_ARGS[@]}"} \
  -c:v h264_videotoolbox_remote -i "$IN_H264" -f null - >/dev/null

ensure_server_running
if [[ "$SKIP_HEVC" -eq 0 ]]; then
  echo "Remote decode HEVC..."
  set +e
  "$FFMPEG_BIN" -v error -xerror \
    -vt_remote_host 127.0.0.1:${PORT} ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
    ${DECODE_ARGS[@]+"${DECODE_ARGS[@]}"} \
    -c:v hevc_videotoolbox_remote -i "$IN_HEVC" -f null - >/dev/null
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "WARN: HEVC decode failed; retrying with fresh vtremoted..." >&2
    vtremote_restart_server /tmp/vtremoted_decode.log
    SERVER_PID="${VTREMOTE_SERVER_PID:-}"
    PORT="$VTREMOTE_PORT"
    "$FFMPEG_BIN" -v error -xerror \
      -vt_remote_host 127.0.0.1:${PORT} ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
      ${DECODE_ARGS[@]+"${DECODE_ARGS[@]}"} \
      -c:v hevc_videotoolbox_remote -i "$IN_HEVC" -f null - >/dev/null
  fi
else
  echo "SKIP: HEVC decode (no local HEVC input available)"
fi

echo "Decode OK"
if [[ -n "${SERVER_PID}" ]]; then
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
fi
