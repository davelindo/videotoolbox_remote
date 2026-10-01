#!/usr/bin/env bash
set -euo pipefail

# Synthetic progressive and interlaced H.264 through server decode/encode.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG_BIN:-${ROOT}/ffmpeg/ffmpeg}"
FFMPEG_LOCAL_BIN="${FFMPEG_LOCAL_BIN:-ffmpeg}"
FFPROBE_BIN="${FFPROBE_BIN:-${ROOT}/ffmpeg/ffprobe}"
VTREMOTED="${VTREMOTED:-${ROOT}/vtremoted/.build/debug/vtremoted}"
source "${ROOT}/tests/integration/vtremoted_common.sh"

RUN_DIR="$(mktemp -d /tmp/vtremote_interlaced.XXXXXX)"
trap 'vtremote_stop_server; echo "Logs and samples: ${RUN_DIR}"' EXIT
vtremote_start_server "${RUN_DIR}/server.log"

for scan in progressive tff bff; do
  INPUT="${RUN_DIR}/${scan}.mp4"
  INPUT_ARGS=()
  if [[ "$scan" == "progressive" ]]; then
    RATE=25
  else
    RATE=50
    MODE=interleave_top
    [[ "$scan" == "bff" ]] && MODE=interleave_bottom
    INPUT_ARGS=( -vf "tinterlace=mode=${MODE}" -flags +ilme+ildct -x264-params "${scan}=1" )
  fi
  "$FFMPEG_LOCAL_BIN" -hide_banner -v error -y \
    -f lavfi -i "testsrc2=size=1920x1080:rate=${RATE}:duration=1" \
    ${INPUT_ARGS[@]+"${INPUT_ARGS[@]}"} -c:v libx264 -preset fast -g 25 -bf 2 -pix_fmt yuv420p "$INPUT"
  FIELD_ORDER="$("$FFPROBE_BIN" -v error -select_streams v:0 \
    -show_entries stream=field_order -of csv=p=0 "$INPUT")"
  case "$scan" in
    progressive) EXPECTED_ORDER=progressive ;;
    tff) EXPECTED_ORDER=tt ;;
    bff) EXPECTED_ORDER=bb ;;
  esac
  if [[ "$FIELD_ORDER" != "$EXPECTED_ORDER" ]]; then
    echo "ERROR: ${scan}: expected ${EXPECTED_ORDER} field order, got ${FIELD_ORDER}" >&2
    exit 1
  fi
  "$FFMPEG_LOCAL_BIN" -hide_banner -v error -y -i "$INPUT" -c:v copy "${RUN_DIR}/${scan}.ts"
  for container in mp4 ts; do
    INPUT="${RUN_DIR}/${scan}.${container}"
    OUTPUT="${RUN_DIR}/${scan}-${container}-out.mp4"
    "$FFMPEG_BIN" -hide_banner -v verbose -y -i "$INPUT" -map 0:v:0 -c:v copy \
      -vt_remote_transcode:v:0 -vt_remote_host "$VTREMOTE_HOST" -vt_remote_port "$VTREMOTE_PORT" \
      -vt_remote_out_codec:v:0 h264 -b:v:0 8M -g:v:0 25 \
      "$OUTPUT" >"${RUN_DIR}/${scan}-${container}-client.log" 2>&1
    "$FFMPEG_LOCAL_BIN" -hide_banner -v error -xerror -i "$OUTPUT" -f null -
    FRAMES="$("$FFPROBE_BIN" -v error -select_streams v:0 -count_frames \
      -show_entries stream=nb_read_frames -of csv=p=0 "$OUTPUT")"
    if [[ "$FRAMES" != "25" ]]; then
      echo "ERROR: ${scan}/${container}: expected 25 decoded frames, got ${FRAMES}" >&2
      exit 1
    fi
    echo "OK: ${scan}/${container}: 25 frames transcoded and decoded"
  done
done

# Verify the documented path when server-side decode cannot handle a source.
OUTPUT="${RUN_DIR}/local-decode-out.mp4"
"$FFMPEG_BIN" -hide_banner -v verbose -y -i "${RUN_DIR}/tff.ts" -map 0:v:0 \
  -vf bwdif=mode=send_frame -pix_fmt nv12 -c:v h264_videotoolbox_remote \
  -vt_remote_host "${VTREMOTE_HOST}:${VTREMOTE_PORT}" -b:v 8M -g:v 25 \
  "$OUTPUT" >"${RUN_DIR}/local-decode-client.log" 2>&1
"$FFMPEG_LOCAL_BIN" -hide_banner -v error -xerror -i "$OUTPUT" -f null -
FRAMES="$("$FFPROBE_BIN" -v error -select_streams v:0 -count_frames \
  -show_entries stream=nb_read_frames -of csv=p=0 "$OUTPUT")"
[[ "$FRAMES" == "25" ]] || { echo "ERROR: local decode: expected 25 frames, got ${FRAMES}" >&2; exit 1; }
echo "OK: local decode + bwdif + remote encode: 25 frames"

# Keep real in-band SPS/PPS changes while giving each segment continuous DTS.
# A decoder configured for the first progressive segment must be rebuilt when
# interlaced coding changes the sequence parameters, then switch back again.
INPUT="${RUN_DIR}/scan-switch.ts"
"$FFMPEG_LOCAL_BIN" -hide_banner -v error -y -dts_delta_threshold 0.1 \
  -i "concat:${RUN_DIR}/progressive.ts|${RUN_DIR}/tff.ts|${RUN_DIR}/bff.ts|${RUN_DIR}/progressive.ts" \
  -map 0:v:0 -c:v copy "$INPUT"
for asynchronous in 0 1; do
  OUTPUT="${RUN_DIR}/scan-switch-async${asynchronous}-out.mp4"
  CLIENT_LOG="${RUN_DIR}/scan-switch-async${asynchronous}-client.log"
  "$FFMPEG_BIN" -hide_banner -v verbose -xerror -y -i "$INPUT" -map 0:v:0 -c:v copy \
    -vt_remote_transcode:v:0 -vt_remote_host "$VTREMOTE_HOST" -vt_remote_port "$VTREMOTE_PORT" \
    -vt_remote_decode_async "$asynchronous" -vt_remote_out_codec:v:0 h264 -b:v 8M -g:v 25 \
    "$OUTPUT" >"$CLIENT_LOG" 2>&1
  "$FFMPEG_LOCAL_BIN" -hide_banner -v error -xerror -i "$OUTPUT" -f null -
  FRAMES="$("$FFPROBE_BIN" -v error -select_streams v:0 -count_frames \
    -show_entries stream=nb_read_frames -of csv=p=0 "$OUTPUT")"
  [[ "$FRAMES" == "100" ]] || { echo "ERROR: scan switch: expected 100 frames, got ${FRAMES}" >&2; exit 1; }
  QUALITY_LOG="${RUN_DIR}/scan-switch-async${asynchronous}-ssim.log"
  "$FFMPEG_LOCAL_BIN" -hide_banner -v info -i "$INPUT" -i "$OUTPUT" \
    -lavfi '[0:v]setpts=N/(25*TB),format=yuv420p[ref];[1:v]setpts=N/(25*TB),format=yuv420p[out];[ref][out]ssim=shortest=1' \
    -an -f null - >"$QUALITY_LOG" 2>&1
  python3 - "$QUALITY_LOG" <<'PY'
from pathlib import Path
import re
import sys

log = Path(sys.argv[1])
match = re.search(r"SSIM .*All:([0-9.]+)", log.read_text())
assert match and float(match[1]) > 0.95, f"scan switch pixel/order mismatch: {log}"
PY
  echo "OK: progressive -> tff -> bff -> progressive, async=${asynchronous}: 100 frames; pixel comparison passed"
done
