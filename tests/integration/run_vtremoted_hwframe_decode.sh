#!/usr/bin/env bash
set -euo pipefail

# Integration regression: verify remote decoders can return local
# AV_PIX_FMT_VIDEOTOOLBOX frames, then hwdownload them back to software.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG:-${ROOT}/ffmpeg/ffmpeg}"
FFMPEG_LOCAL_BIN="${FFMPEG_LOCAL:-$FFMPEG_BIN}"
VTREMOTED_BIN="${VTREMOTED:-${ROOT}/vtremoted/.build/debug/vtremoted}"
source "${ROOT}/tests/integration/vtremoted_common.sh"

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg not found at $FFMPEG_BIN (override with FFMPEG)" >&2
  exit 1
fi
if [[ -z "${VTREMOTE_USE_EXISTING:-}" && ! -x "$VTREMOTED_BIN" ]]; then
  echo "vtremoted not found at $VTREMOTED_BIN (build it or set VTREMOTED)" >&2
  exit 1
fi
if ! command -v "$FFMPEG_LOCAL_BIN" >/dev/null 2>&1; then
  FFMPEG_LOCAL_BIN="$FFMPEG_BIN"
fi

RUN_DIR="$(mktemp -d /tmp/vtremote_hwframe_decode.XXXXXX)"
KEEP_OUTPUT="${VTREMOTE_KEEP_OUTPUT:-0}"
SERVER_PID=""

cleanup() {
  local exit_code=$?
  vtremote_stop_server
  if [[ "$KEEP_OUTPUT" != "0" || "$exit_code" != "0" ]]; then
    echo "KEEP: outputs preserved (exit_code=${exit_code}): ${RUN_DIR}"
  else
    rm -rf "$RUN_DIR"
  fi
}
trap cleanup EXIT

TOKEN_ARGS=()
if [[ -n "${VTREMOTE_TOKEN:-}" ]]; then
  TOKEN_ARGS=( -vt_remote_token "$VTREMOTE_TOKEN" )
fi

VTREMOTED="$VTREMOTED_BIN"
VTREMOTE_PORT="${VTREMOTE_PORT:-}"

echo "Generating local decode inputs..."
"$FFMPEG_LOCAL_BIN" -hide_banner -v warning \
  -f lavfi -i testsrc2=size=128x72:rate=5 -frames:v 5 \
  -pix_fmt nv12 -c:v h264_videotoolbox -allow_sw 1 \
  -y "${RUN_DIR}/input_h264.mp4"

HEVC_OK=1
if ! "$FFMPEG_LOCAL_BIN" -hide_banner -v warning \
  -f lavfi -i testsrc2=size=128x72:rate=5 -frames:v 5 \
  -pix_fmt p010le -c:v hevc_videotoolbox -allow_sw 1 \
  -y "${RUN_DIR}/input_hevc.mp4"; then
  HEVC_OK=0
  echo "WARN: local HEVC input generation failed; skipping HEVC hardware decode output" >&2
fi

echo "Starting vtremoted for hardware-frame decode output..."
vtremote_start_server "${RUN_DIR}/vtremoted.log"
SERVER_PID="${VTREMOTE_SERVER_PID:-}"
HOST="${VTREMOTE_HOST:-127.0.0.1}"
PORT="${VTREMOTE_PORT:-5555}"

run_case() {
  local codec="$1"
  local input="$2"
  local sw_fmt="$3"
  local log_file="${RUN_DIR}/${codec}_${sw_fmt}.log"
  local raw_file="${RUN_DIR}/${codec}_${sw_fmt}.raw"

  echo "STEP: ${codec} hardware-frame decode output sw_format=${sw_fmt}"
  "$FFMPEG_BIN" -hide_banner -v verbose -xerror \
    -vt_remote_output_hw_frames 1 \
    -vt_remote_host "${HOST}:${PORT}" \
    -vt_remote_wire_compression none \
    "${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"}" \
    -c:v "${codec}_videotoolbox_remote" -i "$input" \
    -vf "hwdownload,format=${sw_fmt}" \
    -frames:v 5 -f rawvideo -y "$raw_file" >"$log_file" 2>&1

  if [[ ! -s "$raw_file" ]]; then
    echo "ERROR: ${codec}/${sw_fmt} produced no downloaded rawvideo output" >&2
    cat "$log_file" >&2
    exit 1
  fi
}

run_case h264 "${RUN_DIR}/input_h264.mp4" nv12
if [[ "$HEVC_OK" -eq 1 ]]; then
  run_case hevc "${RUN_DIR}/input_hevc.mp4" p010le
fi

echo "OK: hardware-frame decode output cases passed; logs at ${RUN_DIR}"
