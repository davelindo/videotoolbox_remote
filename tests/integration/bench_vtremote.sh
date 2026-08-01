#!/usr/bin/env bash
set -euo pipefail

# Lightweight perf benchmark for local vs remote VideoToolbox encoding.
# Runs short lavfi sources and reports elapsed time + average bitrate.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG:-${ROOT}/ffmpeg/ffmpeg}"
FFMPEG_LOCAL_BIN="${FFMPEG_LOCAL:-$FFMPEG_BIN}"
FFPROBE_BIN="${FFPROBE:-${ROOT}/ffmpeg/ffprobe}"
if [[ -n "${VTREMOTED:-}" ]]; then
  VTREMOTED_BIN="$VTREMOTED"
else
  if [[ -x "${ROOT}/vtremoted/.build/release/vtremoted" ]]; then
    VTREMOTED_BIN="${ROOT}/vtremoted/.build/release/vtremoted"
  else
    VTREMOTED_BIN="${ROOT}/vtremoted/.build/debug/vtremoted"
  fi
fi
source "${ROOT}/tests/integration/vtremoted_common.sh"

PORT="${VTREMOTE_PORT:-5555}"
HOST="${VTREMOTE_HOST:-127.0.0.1}"
TOKEN="${VTREMOTE_TOKEN:-}"
WIRE_COMP="${VTREMOTE_WIRE_COMPRESSION:-}"
DECODE_ASYNC="${VTREMOTE_DECODE_ASYNC:-0}"
REORDER_DEPTH="${VTREMOTE_DECODE_REORDER_DEPTH:-2}"
BENCH_BITRATE="${VTREMOTE_BENCH_BITRATE:-10M}"
BENCH_MAXRATE="${VTREMOTE_BENCH_MAXRATE:-$BENCH_BITRATE}"
BENCH_BUFSIZE="${VTREMOTE_BENCH_BUFSIZE:-20M}"
BENCH_CBR="${VTREMOTE_BENCH_CBR:-1}"
BENCH_TOL_PCT="${VTREMOTE_BENCH_TOL_PCT:-0.15}"
BENCH_STRICT="${VTREMOTE_BENCH_STRICT:-0}"
BENCH_TRANSCODE="${VTREMOTE_BENCH_TRANSCODE:-1}"
BENCH_TRANSCODE_OUT_CODEC="${VTREMOTE_BENCH_TRANSCODE_OUT_CODEC:-hevc}"
BENCH_TRANSCODE_PIX_FMT="${VTREMOTE_BENCH_TRANSCODE_PIX_FMT:-1}"
BENCH_ONLY_TRANSCODE="${VTREMOTE_BENCH_ONLY_TRANSCODE:-0}"

RATE_ARGS=()
if [[ "$BENCH_CBR" != "0" ]]; then
  RATE_ARGS=( -maxrate "$BENCH_MAXRATE" -bufsize "$BENCH_BUFSIZE" )
fi

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg not found at $FFMPEG_BIN (override with FFMPEG)" >&2; exit 1
fi
if [[ ! -x "$FFMPEG_LOCAL_BIN" ]]; then
  echo "local ffmpeg not found at $FFMPEG_LOCAL_BIN (override with FFMPEG_LOCAL)" >&2; exit 1
fi
if [[ ! -x "$FFPROBE_BIN" ]]; then
  echo "ffprobe not found at $FFPROBE_BIN (override with FFPROBE)" >&2; exit 1
fi
if [[ ! -x "$VTREMOTED_BIN" ]]; then
  echo "vtremoted not found at $VTREMOTED_BIN (build it or set VTREMOTED)" >&2; exit 1
fi

TARGET_BPS=$(python3 - <<PY
import re
s = "${BENCH_BITRATE}"
try:
    if s.lower().endswith("k"):
        v = float(s[:-1]) * 1e3
    elif s.lower().endswith("m"):
        v = float(s[:-1]) * 1e6
    elif s.lower().endswith("g"):
        v = float(s[:-1]) * 1e9
    else:
        v = float(s)
    print(int(v))
except Exception:
    print(0)
PY
)

MAXRATE_BPS=$(python3 - <<PY
import re
s = "${BENCH_MAXRATE}"
try:
    if s.lower().endswith("k"):
        v = float(s[:-1]) * 1e3
    elif s.lower().endswith("m"):
        v = float(s[:-1]) * 1e6
    elif s.lower().endswith("g"):
        v = float(s[:-1]) * 1e9
    else:
        v = float(s)
    print(int(v))
except Exception:
    print(0)
PY
)

VTREMOTED="$VTREMOTED_BIN"
VTREMOTE_PORT="$PORT"
trap 'vtremote_stop_server' EXIT
vtremote_start_server /tmp/vtremoted_bench.log
VTREMOTED_PID="${VTREMOTE_SERVER_PID:-}"
PORT="$VTREMOTE_PORT"

matches_output() {
  local pattern="$1"
  # Do not use -q: an early matcher exit triggers SIGPIPE under pipefail.
  if command -v rg >/dev/null 2>&1; then
    rg "$pattern" >/dev/null
  else
    grep "$pattern" >/dev/null
  fi
}

have_encoder() {
  local bin="$1"
  local enc="$2"
  "$bin" -encoders 2>/dev/null | matches_output "\\b${enc}\\b"
}

have_bsf() {
  local bin="$1"
  local bsf="$2"
  "$bin" -bsfs 2>/dev/null | matches_output "\b${bsf}\b"
}

HAVE_LOCAL_H264=0
HAVE_LOCAL_HEVC=0
if have_encoder "$FFMPEG_LOCAL_BIN" "h264_videotoolbox"; then
  HAVE_LOCAL_H264=1
else
  echo "WARN: local ffmpeg lacks h264_videotoolbox encoder; skipping local H.264 bench" >&2
fi
if have_encoder "$FFMPEG_LOCAL_BIN" "hevc_videotoolbox"; then
  HAVE_LOCAL_HEVC=1
else
  echo "WARN: local ffmpeg lacks hevc_videotoolbox encoder; skipping local HEVC bench" >&2
fi

encoder_supports_option() {
  local bin="$1"
  local enc="$2"
  local opt="$3"
  "$bin" -h encoder="$enc" 2>/dev/null | matches_output "\\b${opt}\\b"
}

supports_fps_mode() {
  local bin="$1"
  "$bin" -h full 2>/dev/null | matches_output "\\bfps_mode\\b"
}

FPS_ARGS_FFMPEG_BIN=( -vsync cfr )
FPS_ARGS_FFMPEG_LOCAL=( -vsync cfr )
if supports_fps_mode "$FFMPEG_BIN"; then
  FPS_ARGS_FFMPEG_BIN=( -fps_mode cfr )
fi
if [[ "$FFMPEG_LOCAL_BIN" == "$FFMPEG_BIN" ]]; then
  FPS_ARGS_FFMPEG_LOCAL=( "${FPS_ARGS_FFMPEG_BIN[@]}" )
elif supports_fps_mode "$FFMPEG_LOCAL_BIN"; then
  FPS_ARGS_FFMPEG_LOCAL=( -fps_mode cfr )
fi

CBR_ARGS_H264=()
CBR_ARGS_HEVC=()
if [[ "$BENCH_CBR" != "0" ]]; then
  local_cbr_h264=0
  local_cbr_hevc=0
  remote_cbr_h264=0
  remote_cbr_hevc=0
  if [[ "$HAVE_LOCAL_H264" -eq 1 ]] && encoder_supports_option "$FFMPEG_LOCAL_BIN" "h264_videotoolbox" "constant_bit_rate"; then
    local_cbr_h264=1
  fi
  if [[ "$HAVE_LOCAL_HEVC" -eq 1 ]] && encoder_supports_option "$FFMPEG_LOCAL_BIN" "hevc_videotoolbox" "constant_bit_rate"; then
    local_cbr_hevc=1
  fi
  if encoder_supports_option "$FFMPEG_BIN" "h264_videotoolbox_remote" "constant_bit_rate"; then
    remote_cbr_h264=1
  fi
  if encoder_supports_option "$FFMPEG_BIN" "hevc_videotoolbox_remote" "constant_bit_rate"; then
    remote_cbr_hevc=1
  fi

  if [[ "$local_cbr_h264" -eq 1 && "$remote_cbr_h264" -eq 1 ]]; then
    CBR_ARGS_H264=( -constant_bit_rate 1 )
  else
    echo "WARN: constant_bit_rate not supported for H.264 on this setup; results may be VBR" >&2
  fi
  if [[ "$local_cbr_hevc" -eq 1 && "$remote_cbr_hevc" -eq 1 ]]; then
    CBR_ARGS_HEVC=( -constant_bit_rate 1 )
  else
    echo "WARN: constant_bit_rate not supported for HEVC on this setup; results may be VBR" >&2
  fi
fi

run_case() {
  local label="$1"
  local size="$2"
  local rate="$3"
  local out="$4"
  local encoder="$5"
  local pix_fmt="${6:-nv12}"
  local bin="${7:-$FFMPEG_BIN}"
  shift 7 || true
  local extra_args=( "$@" )
  local fps_args=( "${FPS_ARGS_FFMPEG_BIN[@]}" )
  if [[ "$bin" == "$FFMPEG_LOCAL_BIN" ]]; then
    fps_args=( "${FPS_ARGS_FFMPEG_LOCAL[@]}" )
  fi
  local start_ns end_ns elapsed_s
  start_ns=$(python3 - <<'PY'
import time; print(int(time.time() * 1e9))
PY
)
  local log="/tmp/vtremote_bench_${label}_${encoder}.log"
  if ! "$bin" -v warning -f lavfi -i "testsrc2=size=${size}:rate=${rate}:duration=5" \
    -r "$rate" "${fps_args[@]+"${fps_args[@]}"}" -pix_fmt "$pix_fmt" -an -sn \
    -c:v "$encoder" -b:v "$BENCH_BITRATE" -g 120 \
    "${RATE_ARGS[@]+"${RATE_ARGS[@]}"}" \
    "${extra_args[@]+"${extra_args[@]}"}" \
    -y "$out" >"$log" 2>&1; then
    echo "FAIL ${label} ${encoder} (log: $log)" >&2
    tail -n 200 "$log" >&2
    exit 1
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
  rc_note=""
  if [[ "$TARGET_BPS" -gt 0 ]]; then
    pct=$(python3 - <<PY
target = float("${TARGET_BPS}")
bps = float("${bps}")
print(abs(bps - target) / target)
PY
)
    mismatch=$(python3 - <<PY
import math
print(1 if float("${pct}") > float("${BENCH_TOL_PCT}") else 0)
PY
)
    if [[ "$mismatch" -eq 1 ]]; then
      rc_note=" rc_mismatch"
      if [[ "$BENCH_STRICT" != "0" ]]; then
        echo "FAIL rate control: ${label} ${encoder} bps=${bps} target=${TARGET_BPS} tol=${BENCH_TOL_PCT}" >&2
        exit 2
      fi
    fi
  fi
  printf "%-12s %-28s elapsed=%ss avg_bps=%s size=%sB%s\n" "$label" "$encoder" "$elapsed_s" "$bps" "$bytes" "$rc_note"
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
  run_case "$label" "$size" "$rate" "$out" "$encoder" "$pix_fmt" "$FFMPEG_BIN" "${args[@]+"${args[@]}"}"
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
  if [[ "$DECODE_ASYNC" != "0" ]]; then
    args+=( -vt_remote_decode_async 1 -vt_remote_decode_reorder_depth "$REORDER_DEPTH" )
  fi
  local log="/tmp/vtremote_bench_decode_${label}_${decoder}.log"
  if ! "$FFMPEG_BIN" -v warning -xerror \
    -vt_remote_host "${HOST}:${PORT}" ${args[@]+"${args[@]}"} \
    -c:v "$decoder" -i "$in_file" -f null - >"$log" 2>&1; then
    echo "FAIL decode ${label} ${decoder} (log: $log)" >&2
    tail -n 200 "$log" >&2
    exit 1
  fi
  echo "decode ${label} ${decoder} ok"
}

run_remote_transcode_case() {
  local label="$1"
  local in_file="$2"
  local out_file="$3"
  local out_codec="$4"
  local pix_fmt="$5"
  local out_enc="hevc_videotoolbox"
  if ! have_encoder "$FFMPEG_BIN" "$out_enc"; then
    out_enc="hevc_videotoolbox_remote"
  fi
  if [[ "$out_codec" == "h264" ]]; then
    out_enc="h264_videotoolbox"
    if ! have_encoder "$FFMPEG_BIN" "$out_enc"; then
      out_enc="h264_videotoolbox_remote"
    fi
  fi
  local pix_fmt_str=""
  if [[ "$pix_fmt" == "1" ]]; then
    pix_fmt_str="nv12"
  elif [[ "$pix_fmt" == "2" ]]; then
    pix_fmt_str="p010le"
  fi
  local args=( -vt_remote_transcode -vt_remote_host "${HOST}" -vt_remote_port "${PORT}" \
    -c:v "$out_enc" -g 120 -b:v "$BENCH_BITRATE" )
  if [[ -n "$pix_fmt_str" ]]; then
    args+=( -pix_fmt "$pix_fmt_str" )
  fi
  if [[ -n "$TOKEN" ]]; then
    args+=( -vt_remote_token "$TOKEN" )
  fi
  if [[ "$BENCH_CBR" != "0" ]]; then
    args+=( -maxrate "$BENCH_MAXRATE" -bufsize "$BENCH_BUFSIZE" -constant_bit_rate 1 )
  fi
  if [[ "$DECODE_ASYNC" != "0" ]]; then
    args+=( -vt_remote_decode_async 1 -vt_remote_decode_reorder_depth "$REORDER_DEPTH" )
  fi
  local start_ns end_ns elapsed_s
  start_ns=$(python3 - <<'PY'
import time; print(int(time.time() * 1e9))
PY
)
  local log="/tmp/vtremote_bench_transcode_${label}_${out_codec}.log"
  if ! "$FFMPEG_BIN" -v warning -i "$in_file" -an -sn -c:v copy \
    "${args[@]}" -y "$out_file" >"$log" 2>&1; then
    echo "FAIL transcode ${label} ${out_codec} (log: $log)" >&2
    tail -n 200 "$log" >&2
    exit 1
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
  dur=$("$FFPROBE_BIN" -v error -show_entries format=duration -of default=nk=1:nw=1 "$out_file")
  bytes=$(wc -c < "$out_file" | tr -d ' ')
  bps=$(python3 - <<PY
dur = float("$dur")
bytes_ = int("$bytes")
print(int(bytes_ * 8 / dur)) if dur > 0 else print(0)
PY
)
  printf "%-12s %-28s elapsed=%ss avg_bps=%s size=%sB\n" "$label" "transcode_${out_codec}" "$elapsed_s" "$bps" "$bytes"
}

if [[ "$BENCH_ONLY_TRANSCODE" == "0" ]]; then
  echo "Benchmarking local vs remote encode (5s each, LZ4 on wire if enabled)..."
  echo "local ffmpeg:  $FFMPEG_LOCAL_BIN"
  echo "remote ffmpeg: $FFMPEG_BIN"
  if [[ "${#CBR_ARGS_H264[@]}" -gt 0 ]]; then
    echo "H.264: constant_bit_rate=1"
  else
    echo "H.264: constant_bit_rate=0"
  fi
  if [[ "${#CBR_ARGS_HEVC[@]}" -gt 0 ]]; then
    echo "HEVC: constant_bit_rate=1"
  else
    echo "HEVC: constant_bit_rate=0"
  fi
fi

sizes=(
  "720p 1280x720"
  "1080p 1920x1080"
  "1440p 2560x1440"
  "2k 2048x1080"
)
rates=(30 60 120)

if [[ "$BENCH_ONLY_TRANSCODE" == "0" ]]; then
for entry in "${sizes[@]}"; do
  label="${entry%% *}"
  size="${entry##* }"
  for rate in "${rates[@]}"; do
    if [[ "$HAVE_LOCAL_H264" -eq 1 ]]; then
      run_case "${label}${rate}"  "$size"  "$rate" "/tmp/vt_local_h264_${label}${rate}.mp4" "h264_videotoolbox" nv12 "$FFMPEG_LOCAL_BIN" \
        "${CBR_ARGS_H264[@]+"${CBR_ARGS_H264[@]}"}"
    fi
    run_remote_case "${label}${rate}"  "$size"  "$rate" "/tmp/vt_remote_h264_${label}${rate}.mp4" "h264_videotoolbox_remote" nv12 \
      "${CBR_ARGS_H264[@]+"${CBR_ARGS_H264[@]}"}" -vt_remote_host "${HOST}:${PORT}"
  done
done

# 4K (DCI 4096x2160) only at 60fps
if [[ "$HAVE_LOCAL_H264" -eq 1 ]]; then
  run_case "4k60" "4096x2160" "60" "/tmp/vt_local_h264_4k60.mp4" "h264_videotoolbox" nv12 "$FFMPEG_LOCAL_BIN" \
    "${CBR_ARGS_H264[@]+"${CBR_ARGS_H264[@]}"}"
fi
run_remote_case "4k60" "4096x2160" "60" "/tmp/vt_remote_h264_4k60.mp4" "h264_videotoolbox_remote" nv12 \
  "${CBR_ARGS_H264[@]+"${CBR_ARGS_H264[@]}"}" -vt_remote_host "${HOST}:${PORT}"

for entry in "${sizes[@]}"; do
  label="${entry%% *}"
  size="${entry##* }"
  for rate in "${rates[@]}"; do
    if [[ "$HAVE_LOCAL_HEVC" -eq 1 ]]; then
      run_case "${label}${rate}"  "$size"  "$rate" "/tmp/vt_local_hevc_${label}${rate}.mp4" "hevc_videotoolbox" p010le "$FFMPEG_LOCAL_BIN" \
        "${CBR_ARGS_HEVC[@]+"${CBR_ARGS_HEVC[@]}"}"
    fi
    run_remote_case "${label}${rate}"  "$size"  "$rate" "/tmp/vt_remote_hevc_${label}${rate}.mp4" "hevc_videotoolbox_remote" p010le \
      "${CBR_ARGS_HEVC[@]+"${CBR_ARGS_HEVC[@]}"}" -vt_remote_host "${HOST}:${PORT}"
  done
done

if [[ "$HAVE_LOCAL_HEVC" -eq 1 ]]; then
  run_case "4k60" "4096x2160" "60" "/tmp/vt_local_hevc_4k60.mp4" "hevc_videotoolbox" p010le "$FFMPEG_LOCAL_BIN" \
    "${CBR_ARGS_HEVC[@]+"${CBR_ARGS_HEVC[@]}"}"
fi
run_remote_case "4k60" "4096x2160" "60" "/tmp/vt_remote_hevc_4k60.mp4" "hevc_videotoolbox_remote" p010le \
  "${CBR_ARGS_HEVC[@]+"${CBR_ARGS_HEVC[@]}"}" -vt_remote_host "${HOST}:${PORT}"
fi

if [[ "$BENCH_TRANSCODE" != "0" ]]; then
  if have_bsf "$FFMPEG_BIN" "vtremote_transcode"; then
    if [[ "$BENCH_ONLY_TRANSCODE" != "0" ]]; then
      echo "Benchmarking remote transcode only (packet in -> packet out)..."
    else
      echo "Benchmarking remote transcode (packet in -> packet out)..."
    fi
    for entry in "${sizes[@]}"; do
      label="${entry%% *}"
      for rate in "${rates[@]}"; do
        in_file="/tmp/vt_local_h264_${label}${rate}.mp4"
        if [[ ! -f "$in_file" ]]; then
          in_file="/tmp/vt_remote_h264_${label}${rate}.mp4"
        fi
        if [[ -f "$in_file" ]]; then
          run_remote_transcode_case "${label}${rate}" "$in_file" "/tmp/vt_remote_transcode_${label}${rate}.mp4" "$BENCH_TRANSCODE_OUT_CODEC" "$BENCH_TRANSCODE_PIX_FMT"
        else
          echo "WARN: transcode input missing for ${label}${rate}; skipping" >&2
        fi
      done
    done
    in_file="/tmp/vt_local_h264_4k60.mp4"
    if [[ ! -f "$in_file" ]]; then
      in_file="/tmp/vt_remote_h264_4k60.mp4"
    fi
    if [[ -f "$in_file" ]]; then
      run_remote_transcode_case "4k60" "$in_file" "/tmp/vt_remote_transcode_4k60.mp4" "$BENCH_TRANSCODE_OUT_CODEC" "$BENCH_TRANSCODE_PIX_FMT"
    else
      echo "WARN: transcode input missing for 4k60; skipping" >&2
    fi
  else
    echo "WARN: vtremote_transcode bsf not available; skipping transcode bench" >&2
  fi
fi

if [[ "$BENCH_ONLY_TRANSCODE" == "0" && "${VTREMOTE_BENCH_DECODE:-1}" != "0" ]]; then
  echo "Benchmarking remote decode (uses local encoded inputs)..."
  if [[ "$HAVE_LOCAL_H264" -eq 1 ]]; then
    for entry in "${sizes[@]}"; do
      label="${entry%% *}"
      for rate in "${rates[@]}"; do
        run_remote_decode_case "${label}${rate}" "/tmp/vt_local_h264_${label}${rate}.mp4" "h264_videotoolbox_remote"
      done
    done
    run_remote_decode_case "4k60" "/tmp/vt_local_h264_4k60.mp4" "h264_videotoolbox_remote"
  fi

  if [[ "$HAVE_LOCAL_HEVC" -eq 1 ]]; then
    for entry in "${sizes[@]}"; do
      label="${entry%% *}"
      for rate in "${rates[@]}"; do
        run_remote_decode_case "${label}${rate}" "/tmp/vt_local_hevc_${label}${rate}.mp4" "hevc_videotoolbox_remote"
      done
    done
    run_remote_decode_case "4k60" "/tmp/vt_local_hevc_4k60.mp4" "hevc_videotoolbox_remote"
  fi
fi

echo "Note: capture CPU usage separately (e.g., Activity Monitor or 'ps -o %cpu -p <pid>')."
