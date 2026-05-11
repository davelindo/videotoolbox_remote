#!/usr/bin/env bash
set -euo pipefail

# Real vtremoted regression: encode an HEVC Main10 HDR-signaled source through
# the remote encoder and verify the mux-facing stream keeps the HDR/color fields.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG_BIN:-${ROOT}/ffmpeg/ffmpeg}"
FFPROBE_BIN="${FFPROBE_BIN:-${ROOT}/ffmpeg/ffprobe}"
VTREMOTED_BIN="${VTREMOTED:-${ROOT}/vtremoted/.build/debug/vtremoted}"
source "${ROOT}/tests/integration/vtremoted_common.sh"

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg not found at $FFMPEG_BIN (override with FFMPEG_BIN)" >&2
  exit 1
fi
if [[ ! -x "$FFPROBE_BIN" ]]; then
  echo "ffprobe not found at $FFPROBE_BIN (override with FFPROBE_BIN)" >&2
  exit 1
fi
if [[ -z "${VTREMOTE_USE_EXISTING:-}" && ! -x "$VTREMOTED_BIN" ]]; then
  echo "vtremoted not found at $VTREMOTED_BIN (build it or set VTREMOTED)" >&2
  exit 1
fi

PORT="${VTREMOTE_PORT:-5555}"
TOKEN="${VTREMOTE_TOKEN:-}"
TOKEN_ARGS=()
RUN_DIR="$(mktemp -d /tmp/vtremote_hdr_side_data.XXXXXX)"
OUT_MP4="${RUN_DIR}/remote_hdr_hevc.mp4"
SERVER_LOG="${RUN_DIR}/vtremoted.log"
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

if [[ -n "$TOKEN" ]]; then
  TOKEN_ARGS=( -vt_remote_token "$TOKEN" )
fi

VTREMOTED="$VTREMOTED_BIN"
VTREMOTE_PORT="$PORT"
VTREMOTE_TOKEN="$TOKEN"

if [[ -z "${VTREMOTE_USE_EXISTING:-}" ]]; then
  echo "Starting vtremoted for HDR side-data test..."
  vtremote_start_server "$SERVER_LOG"
  SERVER_PID="${VTREMOTE_SERVER_PID:-}"
  PORT="$VTREMOTE_PORT"
  echo "Using vtremoted on 127.0.0.1:${PORT} (pid=${SERVER_PID})"
else
  echo "Using existing vtremoted on 127.0.0.1:${PORT}..."
fi

echo "Encoding remote HEVC Main10 with HDR color signaling..."
"$FFMPEG_BIN" -hide_banner -v warning -y \
  -f lavfi -i testsrc2=size=160x90:rate=10 \
  -frames:v 20 \
  -vf format=p010le,setparams=range=limited:color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc \
  -c:v hevc_videotoolbox_remote \
  -profile:v main10 \
  -b:v 300k -g 20 -bf 0 \
  -color_range:v tv \
  -color_primaries:v bt2020 \
  -color_trc:v smpte2084 \
  -colorspace:v bt2020nc \
  -tag:v hvc1 \
  -vt_remote_host "127.0.0.1:${PORT}" ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  "$OUT_MP4"

probe_output=$("$FFPROBE_BIN" -hide_banner -v error \
  -show_entries stream=codec_name,codec_tag_string,pix_fmt,color_range,color_space,color_transfer,color_primaries \
  -of default=nw=1 \
  "$OUT_MP4")

for expected in \
  "codec_name=hevc" \
  "codec_tag_string=hvc1" \
  "color_range=tv" \
  "color_space=bt2020nc" \
  "color_transfer=smpte2084" \
  "color_primaries=bt2020"; do
  if ! grep -Fx "$expected" <<<"$probe_output" >/dev/null; then
    echo "ERROR: missing expected probe field '$expected'" >&2
    echo "$probe_output" >&2
    exit 1
  fi
done

echo "Verifying HDR output decodes cleanly..."
"$FFMPEG_BIN" -hide_banner -v error -xerror -err_detect explode -i "$OUT_MP4" -f null - >/dev/null

echo "OK: vtremoted HDR side-data case passed; logs at ${RUN_DIR}"
