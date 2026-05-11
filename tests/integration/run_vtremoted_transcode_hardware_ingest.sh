#!/usr/bin/env bash
set -euo pipefail

# Integration regression: verify a local hardware-decode -> remote hardware-frame
# encode pipeline feeds AV_PIX_FMT_VIDEOTOOLBOX frames into vtremote.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG:-${ROOT}/ffmpeg/ffmpeg}"
FFMPEG_LOCAL_BIN="${FFMPEG_LOCAL:-$FFMPEG_BIN}"
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
if ! command -v "$FFMPEG_LOCAL_BIN" >/dev/null 2>&1; then
  FFMPEG_LOCAL_BIN="$FFMPEG_BIN"
fi
if [[ -z "${VTREMOTE_USE_EXISTING:-}" && ! -x "$VTREMOTED_BIN" ]]; then
  echo "vtremoted not found at $VTREMOTED_BIN (build it or set VTREMOTED)" >&2
  exit 1
fi

RUN_DIR="$(mktemp -d /tmp/vtremote_transcode_hwframe_ingest.XXXXXX)"
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

echo "Generating local H.264 input..."
"$FFMPEG_LOCAL_BIN" -hide_banner -v warning -xerror \
  -f lavfi -i testsrc2=size=128x72:rate=5 -frames:v 8 \
  -pix_fmt nv12 -c:v h264_videotoolbox -allow_sw 1 \
  -y "${RUN_DIR}/input_h264.mp4"

VTREMOTED="$VTREMOTED_BIN"
VTREMOTE_PORT="${VTREMOTE_PORT:-}"

echo "Starting vtremoted for transcode hardware-frame ingest..."
vtremote_start_server "${RUN_DIR}/vtremoted.log"
SERVER_PID="${VTREMOTE_SERVER_PID:-}"
HOST="${VTREMOTE_HOST:-127.0.0.1}"
PORT="${VTREMOTE_PORT:-5555}"

OUT_FILE="${RUN_DIR}/transcoded_hevc.mp4"
LOG_FILE="${RUN_DIR}/transcoded_hevc.log"
PROBE_FILE="${RUN_DIR}/transcoded_hevc.probe"

"$FFMPEG_BIN" -hide_banner -v verbose -xerror \
  -hwaccel videotoolbox -hwaccel_output_format videotoolbox_vld \
  -i "${RUN_DIR}/input_h264.mp4" \
  -c:v hevc_videotoolbox_remote \
  -vt_remote_host "${HOST}:${PORT}" \
  -vt_remote_wire_compression none \
  "${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"}" \
  -allow_sw 1 -b:v 500k -g 12 \
  -y "$OUT_FILE" >"$LOG_FILE" 2>&1

if ! grep -q "Uploading VideoToolbox hardware frame as" "$LOG_FILE"; then
  echo "ERROR: transcode did not exercise remote hardware-frame ingest" >&2
  cat "$LOG_FILE" >&2
  exit 1
fi

"$FFMPEG_BIN" -hide_banner -v warning -xerror -i "$OUT_FILE" -f null - >>"$LOG_FILE" 2>&1
"$FFPROBE_BIN" -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height \
  -of default=nk=1:nw=1 "$OUT_FILE" >"$PROBE_FILE"

if ! grep -qx "hevc" "$PROBE_FILE"; then
  echo "ERROR: expected HEVC stream from transcode hardware-frame ingest" >&2
  cat "$PROBE_FILE" >&2
  exit 1
fi

echo "OK: transcode hardware-frame ingest case passed; logs at ${RUN_DIR}"
