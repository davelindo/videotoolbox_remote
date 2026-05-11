#!/usr/bin/env bash
set -euo pipefail

# Integration regression: verify remote encoders accept AV_PIX_FMT_VIDEOTOOLBOX
# frames produced by FFmpeg's VideoToolbox hwupload path.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG:-${ROOT}/ffmpeg/ffmpeg}"
FFPROBE_BIN="${FFPROBE:-${ROOT}/ffmpeg/ffprobe}"
VTREMOTED_BIN="${VTREMOTED:-${ROOT}/vtremoted/.build/debug/vtremoted}"
source "${ROOT}/tests/integration/vtremoted_common.sh"

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg not found at $FFMPEG_BIN (override with FFMPEG)" >&2
  exit 1
fi
if [[ ! -x "$FFPROBE_BIN" ]]; then
  echo "ffprobe not found at $FFPROBE_BIN (override with FFPROBE)" >&2
  exit 1
fi
if [[ -z "${VTREMOTE_USE_EXISTING:-}" && ! -x "$VTREMOTED_BIN" ]]; then
  echo "vtremoted not found at $VTREMOTED_BIN (build it or set VTREMOTED)" >&2
  exit 1
fi

RUN_DIR="$(mktemp -d /tmp/vtremote_hwframe_ingest.XXXXXX)"
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

echo "Starting vtremoted for hardware-frame ingest..."
vtremote_start_server "${RUN_DIR}/vtremoted.log"
SERVER_PID="${VTREMOTE_SERVER_PID:-}"
HOST="${VTREMOTE_HOST:-127.0.0.1}"
PORT="${VTREMOTE_PORT:-5555}"

run_case() {
  local codec="$1"
  local sw_fmt="$2"
  local stream_codec="$3"
  local out_file="${RUN_DIR}/${codec}_${sw_fmt}.mp4"
  local log_file="${RUN_DIR}/${codec}_${sw_fmt}.log"
  local probe_file="${RUN_DIR}/${codec}_${sw_fmt}.probe"

  echo "STEP: ${codec} hardware-frame ingest sw_format=${sw_fmt}"
  "$FFMPEG_BIN" -hide_banner -v verbose -xerror \
    -init_hw_device videotoolbox=vt -filter_hw_device vt \
    -f lavfi -i testsrc2=size=128x72:rate=5 -frames:v 5 \
    -vf "format=${sw_fmt},hwupload" \
    -c:v "${codec}_videotoolbox_remote" \
    -vt_remote_host "${HOST}:${PORT}" \
    -vt_remote_wire_compression none \
    "${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"}" \
    -allow_sw 1 -b:v 500k -g 12 \
    -y "$out_file" >"$log_file" 2>&1

  if ! grep -q "Uploading VideoToolbox hardware frame as" "$log_file"; then
    echo "ERROR: ${codec}/${sw_fmt} did not exercise hardware-frame ingest" >&2
    cat "$log_file" >&2
    exit 1
  fi

  echo "STEP: verify decode clean ${codec} sw_format=${sw_fmt}"
  "$FFMPEG_BIN" -hide_banner -v warning -xerror -i "$out_file" -f null - >>"$log_file" 2>&1

  "$FFPROBE_BIN" -v error -select_streams v:0 \
    -show_entries stream=codec_name,width,height \
    -of default=nk=1:nw=1 "$out_file" >"$probe_file"

  if ! grep -qx "$stream_codec" "$probe_file"; then
    echo "ERROR: expected ${stream_codec} stream for ${codec}/${sw_fmt}" >&2
    cat "$probe_file" >&2
    exit 1
  fi
}

run_case h264 nv12 h264
run_case hevc nv12 hevc
run_case hevc p010le hevc
run_case hevc bgra hevc

echo "OK: hardware-frame ingest cases passed; logs at ${RUN_DIR}"
