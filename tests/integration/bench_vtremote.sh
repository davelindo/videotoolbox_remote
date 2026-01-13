#!/usr/bin/env bash
set -euo pipefail

# Lightweight perf benchmark for local vs remote VideoToolbox encoding.
# Runs short lavfi sources and reports elapsed time + average bitrate.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG:-${ROOT}/ffmpeg/ffmpeg}"
FFPROBE_BIN="${FFPROBE:-${ROOT}/ffmpeg/ffprobe}"
VTREMOTED_BIN="${VTREMOTED:-${ROOT}/vtremoted/.build/debug/vtremoted}"

PORT="${VTREMOTE_PORT:-5555}"
TOKEN="${VTREMOTE_TOKEN:-}"
WIRE_COMP="${VTREMOTE_WIRE_COMPRESSION:-}"

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg not found at $FFMPEG_BIN (override with FFMPEG)" >&2; exit 1
fi
if [[ ! -x "$FFPROBE_BIN" ]]; then
  echo "ffprobe not found at $FFPROBE_BIN (override with FFPROBE)" >&2; exit 1
fi
if [[ ! -x "$VTREMOTED_BIN" ]]; then
  echo "vtremoted not found at $VTREMOTED_BIN (build it or set VTREMOTED)" >&2; exit 1
fi

start_vtremoted() {
  if [[ -n "$TOKEN" ]]; then
    "$VTREMOTED_BIN" --listen 127.0.0.1:${PORT} --token "$TOKEN" > /tmp/vtremoted_bench.log 2>&1 &
  else
    "$VTREMOTED_BIN" --listen 127.0.0.1:${PORT} > /tmp/vtremoted_bench.log 2>&1 &
  fi
  VTREMOTED_PID=$!
  sleep 0.3
}

stop_vtremoted() {
  if [[ -n "${VTREMOTED_PID:-}" ]]; then
    kill "$VTREMOTED_PID" 2>/dev/null || true
  fi
}

trap stop_vtremoted EXIT
start_vtremoted

run_case() {
  local label="$1"
  local size="$2"
  local rate="$3"
  local out="$4"
  local encoder="$5"
  local pix_fmt="${6:-nv12}"
  local start_ns end_ns elapsed_s
  start_ns=$(python3 - <<'PY'
import time; print(int(time.time() * 1e9))
PY
)
  if (( $# > 6 )); then
    "$FFMPEG_BIN" -v warning -f lavfi -i "testsrc2=size=${size}:rate=${rate}:duration=5" \
      -pix_fmt "$pix_fmt" -an -sn \
      -c:v "$encoder" -b:v 10M -g 120 "${@:7}" \
      -y "$out" >/tmp/vtremote_bench_ffmpeg.log 2>&1
  else
    "$FFMPEG_BIN" -v warning -f lavfi -i "testsrc2=size=${size}:rate=${rate}:duration=5" \
      -pix_fmt "$pix_fmt" -an -sn \
      -c:v "$encoder" -b:v 10M -g 120 \
      -y "$out" >/tmp/vtremote_bench_ffmpeg.log 2>&1
  fi
  end_ns=$(python3 - <<'PY'
import time; print(int(time.time() * 1e9))
PY
)
  elapsed_s=$(python3 - <<PY
print("{:.3f}".format((${end_ns}-${start_ns})/1e9))
PY
)
  local dur bytes bps
  dur=$("$FFPROBE_BIN" -v error -show_entries format=duration -of default=nk=1:nw=1 "$out")
  bytes=$(wc -c < "$out" | tr -d ' ')
  bps=$(python3 - <<PY
dur = float("$dur")
bytes_ = int("$bytes")
print(int(bytes_ * 8 / dur)) if dur > 0 else print(0)
PY
)
  printf "%-12s %-28s elapsed=%ss avg_bps=%s size=%sB\n" "$label" "$encoder" "$elapsed_s" "$bps" "$bytes"
}

run_remote_case() {
  local label="$1"
  local size="$2"
  local rate="$3"
  local out="$4"
  local encoder="$5"
  local pix_fmt="$6"
  shift 6
  local args=( "$@" )
  if [[ -n "$TOKEN" ]]; then
    args+=( -vt_remote_token "$TOKEN" )
  fi
  if [[ -n "$WIRE_COMP" ]]; then
    args+=( -vt_remote_wire_compression "$WIRE_COMP" )
  fi
  run_case "$label" "$size" "$rate" "$out" "$encoder" "$pix_fmt" "${args[@]}"
}

run_remote_decode_case() {
  local label="$1"
  local in_file="$2"
  local decoder="$3"
  local args=()
  if [[ -n "$TOKEN" ]]; then
    args+=( -vt_remote_token "$TOKEN" )
  fi
  if [[ -n "$WIRE_COMP" ]]; then
    args+=( -vt_remote_wire_compression "$WIRE_COMP" )
  fi
  "$FFMPEG_BIN" -v warning -xerror \
    -vt_remote_host "127.0.0.1:${PORT}" "${args[@]}" \
    -c:v "$decoder" -i "$in_file" -f null - >/tmp/vtremote_bench_ffmpeg.log 2>&1
  echo "decode ${label} ${decoder} ok"
}

echo "Benchmarking local vs remote encode (5s each, LZ4 on wire if enabled)..."

sizes=(
  "720p 1280x720"
  "1080p 1920x1080"
  "1440p 2560x1440"
  "2k 2048x1080"
)
rates=(30 60 120)

for entry in "${sizes[@]}"; do
  label="${entry%% *}"
  size="${entry##* }"
  for rate in "${rates[@]}"; do
    run_case "${label}${rate}"  "$size"  "$rate" "/tmp/vt_local_h264_${label}${rate}.mp4" "h264_videotoolbox" nv12
    run_remote_case "${label}${rate}"  "$size"  "$rate" "/tmp/vt_remote_h264_${label}${rate}.mp4" "h264_videotoolbox_remote" nv12 -vt_remote_host "127.0.0.1:${PORT}"
  done
done

# 4K (DCI 4096x2160) only at 60fps
run_case "4k60" "4096x2160" "60" "/tmp/vt_local_h264_4k60.mp4" "h264_videotoolbox" nv12
run_remote_case "4k60" "4096x2160" "60" "/tmp/vt_remote_h264_4k60.mp4" "h264_videotoolbox_remote" nv12 -vt_remote_host "127.0.0.1:${PORT}"

for entry in "${sizes[@]}"; do
  label="${entry%% *}"
  size="${entry##* }"
  for rate in "${rates[@]}"; do
    run_case "${label}${rate}"  "$size"  "$rate" "/tmp/vt_local_hevc_${label}${rate}.mp4" "hevc_videotoolbox" p010le
    run_remote_case "${label}${rate}"  "$size"  "$rate" "/tmp/vt_remote_hevc_${label}${rate}.mp4" "hevc_videotoolbox_remote" p010le -vt_remote_host "127.0.0.1:${PORT}"
  done
done

run_case "4k60" "4096x2160" "60" "/tmp/vt_local_hevc_4k60.mp4" "hevc_videotoolbox" p010le
run_remote_case "4k60" "4096x2160" "60" "/tmp/vt_remote_hevc_4k60.mp4" "hevc_videotoolbox_remote" p010le -vt_remote_host "127.0.0.1:${PORT}"

if [[ "${VTREMOTE_BENCH_DECODE:-1}" != "0" ]]; then
  echo "Benchmarking remote decode (uses local encoded inputs)..."
  for entry in "${sizes[@]}"; do
    label="${entry%% *}"
    for rate in "${rates[@]}"; do
      run_remote_decode_case "${label}${rate}" "/tmp/vt_local_h264_${label}${rate}.mp4" "h264_videotoolbox_remote"
    done
  done
  run_remote_decode_case "4k60" "/tmp/vt_local_h264_4k60.mp4" "h264_videotoolbox_remote"

  for entry in "${sizes[@]}"; do
    label="${entry%% *}"
    for rate in "${rates[@]}"; do
      run_remote_decode_case "${label}${rate}" "/tmp/vt_local_hevc_${label}${rate}.mp4" "hevc_videotoolbox_remote"
    done
  done
  run_remote_decode_case "4k60" "/tmp/vt_local_hevc_4k60.mp4" "hevc_videotoolbox_remote"
fi

echo "Note: capture CPU usage separately (e.g., Activity Monitor or 'ps -o %cpu -p <pid>')."
