#!/usr/bin/env bash
set -euo pipefail

# Integration regression: verify remote HEVC accepts the broader VideoToolbox
# input pixel formats that local VideoToolbox exposes beyond 4:2:0.

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

RUN_DIR="$(mktemp -d /tmp/vtremote_hevc_pixfmt.XXXXXX)"
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

echo "Starting vtremoted for HEVC pixel-format parity..."
vtremote_start_server "${RUN_DIR}/vtremoted.log"
SERVER_PID="${VTREMOTE_SERVER_PID:-}"
HOST="${VTREMOTE_HOST:-127.0.0.1}"
PORT="${VTREMOTE_PORT:-5555}"

run_case() {
  local pix_fmt="$1"
  local out_file="${RUN_DIR}/hevc_${pix_fmt}.mp4"
  local log_file="${RUN_DIR}/ffmpeg_${pix_fmt}.log"
  local probe_file="${RUN_DIR}/ffprobe_${pix_fmt}.txt"

  echo "STEP: remote HEVC encode pix_fmt=${pix_fmt}"
  "$FFMPEG_BIN" -hide_banner -v warning -xerror \
    -f lavfi -i testsrc2=size=128x72:rate=5 -t 1 \
    -vf "format=${pix_fmt}" \
    -c:v hevc_videotoolbox_remote \
    -vt_remote_host "${HOST}:${PORT}" \
    -vt_remote_wire_compression none \
    "${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"}" \
    -allow_sw 1 -b:v 500k -g 12 \
    -y "$out_file" >"$log_file" 2>&1

  echo "STEP: verify decode clean pix_fmt=${pix_fmt}"
  "$FFMPEG_BIN" -hide_banner -v warning -xerror -i "$out_file" -f null - >>"$log_file" 2>&1

  "$FFPROBE_BIN" -v error -select_streams v:0 \
    -show_entries stream=codec_name,width,height,nb_frames,pix_fmt \
    -of default=nk=1:nw=1 "$out_file" >"$probe_file"

  if ! grep -qx "hevc" "$probe_file"; then
    echo "ERROR: expected HEVC stream for pix_fmt=${pix_fmt}" >&2
    cat "$probe_file" >&2
    exit 1
  fi
}

run_case bgra
run_case ayuv
run_case p210le

echo "OK: HEVC remote pixel-format parity cases passed; logs at ${RUN_DIR}"

