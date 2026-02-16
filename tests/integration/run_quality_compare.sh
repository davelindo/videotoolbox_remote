#!/usr/bin/env bash
set -eEuo pipefail

# Quality comparison: Realtime vs High-Quality encoding
# Compares PSNR/SSIM metrics at the same bitrate

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VTREMOTED="${VTREMOTED:-${ROOT}/vtremoted/.build/release/vtremoted}"
FFMPEG_REMOTE="${FFMPEG:-${ROOT}/ffmpeg/ffmpeg}"
FFMPEG_LOCAL="${FFMPEG_LOCAL:-}"
source "${ROOT}/tests/integration/vtremoted_common.sh"

PORT="${VTREMOTE_PORT:-}"
WIRE_COMP="${VTREMOTE_WIRE_COMPRESSION:-none}"
DURATION="${VTREMOTE_QUALITY_DURATION:-5}"
SIZE="${VTREMOTE_QUALITY_SIZE:-1920x1080}"
RATE="${VTREMOTE_QUALITY_RATE:-30}"
BITRATE="${VTREMOTE_QUALITY_BITRATE:-8M}"
INPUT_FILE="${VTREMOTE_QUALITY_INPUT:-}"

WORK_DIR="/tmp/vtremote_quality_compare"
VT_LOG="/tmp/vtremoted_quality.log"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
rm -f "$VT_LOG"

cleanup() {
  if [[ -n "${PID:-}" ]]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

on_error() {
  echo "ERROR: quality comparison failed"
  if [[ -s "$VT_LOG" ]]; then
    echo "---- vtremoted log ----"
    tail -n 50 "$VT_LOG"
  fi
}
trap on_error ERR

if [[ ! -x "$VTREMOTED" ]]; then
  echo "vtremoted not found at $VTREMOTED (build it first: make build-vtremoted)"
  exit 1
fi
if [[ ! -x "$FFMPEG_REMOTE" ]]; then
  echo "ffmpeg not found at $FFMPEG_REMOTE (build ffmpeg first: make build-ffmpeg)"
  exit 1
fi

# Pick local ffmpeg
pick_local_ffmpeg() {
  local candidates=()
  if [[ -n "$FFMPEG_LOCAL" ]]; then
    candidates+=("$FFMPEG_LOCAL")
  else
    if command -v ffmpeg >/dev/null 2>&1; then
      candidates+=("$(command -v ffmpeg)")
    fi
  fi
  if [[ -x /usr/bin/ffmpeg ]]; then
    candidates+=("/usr/bin/ffmpeg")
  fi
  candidates+=("$FFMPEG_REMOTE")

  for c in "${candidates[@]}"; do
    if [[ -x "$c" ]]; then
      FFMPEG_LOCAL="$c"
      return 0
    fi
  done
  return 1
}

if ! pick_local_ffmpeg; then
  echo "No ffmpeg found for input generation." >&2
  exit 1
fi
echo "Using local ffmpeg: ${FFMPEG_LOCAL}"

# Generate or use provided input
RAW_REF="${WORK_DIR}/reference.y4m"
if [[ -n "$INPUT_FILE" && -f "$INPUT_FILE" ]]; then
  echo "STEP: decode input file to raw reference"
  "$FFMPEG_LOCAL" -v warning -i "$INPUT_FILE" -t "$DURATION" -pix_fmt yuv420p "$RAW_REF"
else
  echo "STEP: generate test source (${SIZE}@${RATE} for ${DURATION}s)"
  "$FFMPEG_LOCAL" -v warning -f lavfi -i "testsrc2=size=${SIZE}:rate=${RATE}:duration=${DURATION}" \
    -pix_fmt yuv420p "$RAW_REF"
fi

# Start vtremoted
echo "STEP: start vtremoted"
vtremote_start_server "$VT_LOG"
PID="${VTREMOTE_SERVER_PID:-}"
PORT="$VTREMOTE_PORT"

remote_args=(
  -vt_remote_host "127.0.0.1:${PORT}"
  -vt_remote_wire_compression "$WIRE_COMP"
)

# Files
REALTIME_OUT="${WORK_DIR}/realtime.mp4"
HQ_OUT="${WORK_DIR}/hq.mp4"
REALTIME_LOG="${WORK_DIR}/realtime.log"
HQ_LOG="${WORK_DIR}/hq.log"
PSNR_RT="${WORK_DIR}/psnr_rt.log"
PSNR_HQ="${WORK_DIR}/psnr_hq.log"
SSIM_RT="${WORK_DIR}/ssim_rt.log"
SSIM_HQ="${WORK_DIR}/ssim_hq.log"

echo ""
echo "========================================="
echo "ENCODING: Realtime Mode"
echo "========================================="
# Realtime encoding: low latency, no B-frames
"$FFMPEG_REMOTE" -v warning -xerror \
  -i "$RAW_REF" \
  -pix_fmt nv12 \
  "${remote_args[@]}" \
  -c:v h264_videotoolbox_remote \
  -b:v "$BITRATE" \
  -g "$RATE" \
  -realtime true \
  -prio_speed true \
  -bf 0 \
  -flags +low_delay \
  -y "$REALTIME_OUT" 2>"$REALTIME_LOG"


# Extract latency from vtremoted log
rt_latency=""
if grep -q "SUMMARY mode=encode" "$VT_LOG"; then
  rt_line=$(grep "SUMMARY mode=encode" "$VT_LOG" | tail -n 1)
  rt_latency=$(echo "$rt_line" | sed -n 's/.*avg_encode_ms=\([0-9.]*\).*/\1/p')
fi

# Restart vtremoted for clean stats
vtremote_stop_server
rm -f "$VT_LOG"
vtremote_start_server "$VT_LOG"
PID="${VTREMOTE_SERVER_PID:-}"
PORT="$VTREMOTE_PORT"
remote_args=(
  -vt_remote_host "127.0.0.1:${PORT}"
  -vt_remote_wire_compression "$WIRE_COMP"
)

echo ""
echo "========================================="
echo "ENCODING: High-Quality Mode"
echo "========================================="
# High quality encoding: B-frames, no realtime priority
"$FFMPEG_REMOTE" -v warning -xerror \
  -i "$RAW_REF" \
  -pix_fmt nv12 \
  "${remote_args[@]}" \
  -c:v h264_videotoolbox_remote \
  -b:v "$BITRATE" \
  -g "$RATE" \
  -realtime false \
  -prio_speed false \
  -bf 2 \
  -y "$HQ_OUT" 2>"$HQ_LOG"

# Extract latency
hq_latency=""
if grep -q "SUMMARY mode=encode" "$VT_LOG"; then
  hq_line=$(grep "SUMMARY mode=encode" "$VT_LOG" | tail -n 1)
  hq_latency=$(echo "$hq_line" | sed -n 's/.*avg_encode_ms=\([0-9.]*\).*/\1/p')
fi

echo ""
echo "========================================="
echo "QUALITY ANALYSIS"
echo "========================================="

# Calculate PSNR and SSIM for realtime
echo "Analyzing realtime encode..."
"$FFMPEG_LOCAL" -v error -i "$RAW_REF" -i "$REALTIME_OUT" \
  -lavfi "[0:v][1:v]psnr=stats_file=${PSNR_RT}" -f null - 2>&1 | tee "${WORK_DIR}/psnr_rt_out.txt"
"$FFMPEG_LOCAL" -v error -i "$RAW_REF" -i "$REALTIME_OUT" \
  -lavfi "[0:v][1:v]ssim=stats_file=${SSIM_RT}" -f null - 2>&1 | tee "${WORK_DIR}/ssim_rt_out.txt"

# Calculate PSNR and SSIM for high quality
echo "Analyzing high-quality encode..."
"$FFMPEG_LOCAL" -v error -i "$RAW_REF" -i "$HQ_OUT" \
  -lavfi "[0:v][1:v]psnr=stats_file=${PSNR_HQ}" -f null - 2>&1 | tee "${WORK_DIR}/psnr_hq_out.txt"
"$FFMPEG_LOCAL" -v error -i "$RAW_REF" -i "$HQ_OUT" \
  -lavfi "[0:v][1:v]ssim=stats_file=${SSIM_HQ}" -f null - 2>&1 | tee "${WORK_DIR}/ssim_hq_out.txt"

# Parse results
parse_psnr() {
  local file="$1"
  if [[ -f "$file" ]]; then
    grep -oE 'average:[0-9.]+' "$file" | tail -1 | cut -d: -f2 || echo "N/A"
  else
    echo "N/A"
  fi
}

parse_ssim() {
  local file="$1"
  if [[ -f "$file" ]]; then
    grep -oE 'All:[0-9.]+' "$file" | tail -1 | cut -d: -f2 || echo "N/A"
  else
    echo "N/A"
  fi
}

# Try to get from output files first (ffmpeg prints summary to stderr)
rt_psnr=$(grep -oE 'PSNR.*average:[0-9.]+' "${WORK_DIR}/psnr_rt_out.txt" 2>/dev/null | grep -oE '[0-9.]+$' || parse_psnr "$PSNR_RT")
hq_psnr=$(grep -oE 'PSNR.*average:[0-9.]+' "${WORK_DIR}/psnr_hq_out.txt" 2>/dev/null | grep -oE '[0-9.]+$' || parse_psnr "$PSNR_HQ")
rt_ssim=$(grep -oE 'SSIM.*All:[0-9.]+' "${WORK_DIR}/ssim_rt_out.txt" 2>/dev/null | grep -oE '[0-9.]+$' || parse_ssim "$SSIM_RT")
hq_ssim=$(grep -oE 'SSIM.*All:[0-9.]+' "${WORK_DIR}/ssim_hq_out.txt" 2>/dev/null | grep -oE '[0-9.]+$' || parse_ssim "$SSIM_HQ")

# File sizes
rt_size=$(stat -f%z "$REALTIME_OUT" 2>/dev/null || stat -c%s "$REALTIME_OUT" 2>/dev/null || echo "0")
hq_size=$(stat -f%z "$HQ_OUT" 2>/dev/null || stat -c%s "$HQ_OUT" 2>/dev/null || echo "0")
rt_size_mb=$(echo "scale=2; $rt_size / 1048576" | bc)
hq_size_mb=$(echo "scale=2; $hq_size / 1048576" | bc)

echo ""
echo "========================================="
echo "QUALITY COMPARISON RESULTS"
echo "Target bitrate: ${BITRATE}"
echo "========================================="
printf "| %-14s | %-10s | %-8s | %-10s | %-8s |\n" "Mode" "PSNR (dB)" "SSIM" "Latency" "Size"
printf "|----------------|------------|----------|------------|----------|\n"
printf "| %-14s | %-10s | %-8s | %-10s | %-8s |\n" "Realtime" "${rt_psnr:-N/A}" "${rt_ssim:-N/A}" "${rt_latency:-N/A}ms" "${rt_size_mb}MB"
printf "| %-14s | %-10s | %-8s | %-10s | %-8s |\n" "High-Quality" "${hq_psnr:-N/A}" "${hq_ssim:-N/A}" "${hq_latency:-N/A}ms" "${hq_size_mb}MB"
echo "========================================="
echo ""

# Quality difference
if [[ -n "$rt_psnr" && -n "$hq_psnr" && "$rt_psnr" != "N/A" && "$hq_psnr" != "N/A" ]]; then
  psnr_diff=$(echo "$hq_psnr - $rt_psnr" | bc -l 2>/dev/null || echo "")
  if [[ -n "$psnr_diff" ]]; then
    echo "PSNR difference: +${psnr_diff} dB (higher = better quality)"
  fi
fi

if [[ -n "$rt_latency" && -n "$hq_latency" ]]; then
  latency_diff=$(echo "$hq_latency - $rt_latency" | bc -l 2>/dev/null || echo "")
  if [[ -n "$latency_diff" ]]; then
    echo "Latency difference: +${latency_diff} ms for high-quality"
  fi
fi

echo ""
echo "Output files saved to: ${WORK_DIR}/"
echo "  - realtime.mp4"
echo "  - hq.mp4"
echo ""
echo "OK: quality comparison complete"
