#!/usr/bin/env bash
set -eEuo pipefail

# Realtime encode latency benchmark.
# Generates a live-like stream using -re (realtime input) and measures encoder latency.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VTREMOTED="${VTREMOTED:-${ROOT}/vtremoted/.build/release/vtremoted}"
FFMPEG_REMOTE="${FFMPEG:-${ROOT}/ffmpeg/ffmpeg}"
FFMPEG_LOCAL="${FFMPEG_LOCAL:-}"
source "${ROOT}/tests/integration/vtremoted_common.sh"

PORT="${VTREMOTE_PORT:-}"
WIRE_COMP="${VTREMOTE_WIRE_COMPRESSION:-none}"
DURATION="${VTREMOTE_REALTIME_DURATION:-10}"
SIZE="${VTREMOTE_REALTIME_SIZE:-1920x1080}"
RATE="${VTREMOTE_REALTIME_RATE:-30}"
BITRATE="${VTREMOTE_REALTIME_BITRATE:-8M}"
PRINT_LOGS="${VTREMOTE_REALTIME_PRINT_LOGS:-0}"
LOW_DELAY="${VTREMOTE_REALTIME_LOW_DELAY:-1}"

VT_LOG="/tmp/vtremoted_realtime.log"
FFMPEG_LOG="/tmp/vtremote_realtime_ffmpeg.log"

rm -f "$VT_LOG" "$FFMPEG_LOG"

print_logs() {
  for f in "$VT_LOG" "$FFMPEG_LOG"; do
    if [[ -s "$f" ]]; then
      echo "---- $f ----"
      tail -n 200 "$f"
    fi
  done
}

on_error() {
  echo "ERROR: realtime encode test failed"
  print_logs
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

# Check for encoder support
have_encoder() {
  local bin="$1"
  local enc="$2"
  "$bin" -encoders 2>/dev/null | grep -w "$enc" >/dev/null
}

# Pick local ffmpeg for input generation
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

# Start vtremoted
echo "STEP: start vtremoted on 127.0.0.1:${PORT:-<auto>}"
vtremote_start_server "$VT_LOG"
PID="${VTREMOTE_SERVER_PID:-}"
PORT="$VTREMOTE_PORT"
trap 'kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true' EXIT

# Build remote encoder args
remote_args=(
  -vt_remote_host "127.0.0.1:${PORT}"
  -vt_remote_wire_compression "$WIRE_COMP"
)

# Low-delay encoding flags
LOW_DELAY_FLAGS=()
if [[ "$LOW_DELAY" != "0" ]]; then
  LOW_DELAY_FLAGS=(-flags +low_delay)
fi

echo "STEP: realtime encode ${SIZE}@${RATE} for ${DURATION}s (bitrate=${BITRATE}, wc=${WIRE_COMP})"

# Use -re for realtime simulation
# Generate testsrc2 and encode via remote encoder
"$FFMPEG_REMOTE" -v warning -xerror \
  -re \
  -f lavfi -i "testsrc2=size=${SIZE}:rate=${RATE}:duration=${DURATION}" \
  -pix_fmt nv12 \
  "${remote_args[@]}" \
  -c:v h264_videotoolbox_remote \
  -b:v "$BITRATE" \
  -g "$RATE" \
  "${LOW_DELAY_FLAGS[@]+"${LOW_DELAY_FLAGS[@]}"}" \
  -f null - >"$FFMPEG_LOG" 2>&1

echo "STEP: extract latency stats from vtremoted log"

# Parse the SUMMARY line from vtremoted log
if grep -q "SUMMARY mode=encode" "$VT_LOG"; then
  summary_line=$(grep "SUMMARY mode=encode" "$VT_LOG" | tail -n 1)
  echo "RESULT: $summary_line"
  
  # Extract avg and max encode times
  avg_ms=$(echo "$summary_line" | sed -n 's/.*avg_encode_ms=\([0-9.]*\).*/\1/p')
  max_ms=$(echo "$summary_line" | sed -n 's/.*max_encode_ms=\([0-9.]*\).*/\1/p')
  
  echo ""
  echo "========================================="
  echo "LATENCY RESULTS"
  echo "========================================="
  echo "Average encode latency: ${avg_ms:-N/A} ms"
  echo "Maximum encode latency: ${max_ms:-N/A} ms"
  echo "========================================="
  
  # Check thresholds
  if [[ -n "$avg_ms" ]]; then
    # Use bc for float comparison
    threshold_ok=$(echo "$avg_ms < 50" | bc -l 2>/dev/null || echo "1")
    if [[ "$threshold_ok" == "1" ]]; then
      echo "✓ Average latency is within acceptable range (<50ms)"
    else
      echo "⚠ Average latency exceeds 50ms - optimization needed"
    fi
  fi
else
  echo "WARN: No SUMMARY line found in vtremoted log"
  echo "---- $VT_LOG ----"
  cat "$VT_LOG"
fi

if [[ "$PRINT_LOGS" != "0" ]]; then
  print_logs
fi

echo ""
echo "OK: realtime encode test complete"
