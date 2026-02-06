#!/usr/bin/env bash
set -eEuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VTREMOTED="${VTREMOTED:-${ROOT}/vtremoted/.build/debug/vtremoted}"
FFMPEG_REMOTE="${FFMPEG:-${ROOT}/ffmpeg/ffmpeg}"
FFMPEG_LOCAL="${FFMPEG_LOCAL:-$(command -v ffmpeg || true)}"
source "${ROOT}/tests/integration/vtremoted_common.sh"

PORT="${VTREMOTE_PORT:-}"
WIRE_COMP="${VTREMOTE_WIRE_COMPRESSION:-}"
DECODE_ASYNC="${VTREMOTE_DECODE_ASYNC:-1}"
REORDER_DEPTH="${VTREMOTE_DECODE_REORDER_DEPTH:-2}"
DURATION="${VTREMOTE_SPEED_DURATION:-20}"
SIZE="${VTREMOTE_SPEED_SIZE:-1920x1080}"
RATE="${VTREMOTE_SPEED_RATE:-30}"
PRINT_LOGS="${VTREMOTE_SPEED_PRINT_LOGS:-0}"

IN="/tmp/vtremote_speed_h264.mp4"
LOCAL_LOG="/tmp/vtremote_speed_local.log"
REMOTE_LOG_ASYNC="/tmp/vtremote_speed_remote_async.log"
REMOTE_LOG_SYNC="/tmp/vtremote_speed_remote_sync.log"
VT_LOG="/tmp/vtremoted_speed.log"
IN_LOG="/tmp/vtremote_speed_input.log"

rm -f "$LOCAL_LOG" "$REMOTE_LOG_ASYNC" "$REMOTE_LOG_SYNC" "$VT_LOG" "$IN" "$IN_LOG"

print_logs() {
  for f in "$IN_LOG" "$LOCAL_LOG" "$REMOTE_LOG_ASYNC" "$REMOTE_LOG_SYNC" "$VT_LOG"; do
    if [[ -s "$f" ]]; then
      echo "---- $f ----"
      tail -n 200 "$f"
    fi
  done
}

on_error() {
  echo "ERROR: speed test failed"
  print_logs
}
trap on_error ERR

if [[ ! -x "$VTREMOTED" ]]; then
  echo "vtremoted not found at $VTREMOTED (build it first)"
  exit 1
fi
if [[ ! -x "$FFMPEG_REMOTE" ]]; then
  echo "ffmpeg not found at $FFMPEG_REMOTE (build ffmpeg first)"
  exit 1
fi
if [[ -z "$FFMPEG_LOCAL" ]]; then
  # Prefer an ffmpeg in PATH, but fall back to the repo build if none exists.
  FFMPEG_LOCAL="$FFMPEG_REMOTE"
fi
if [[ ! -x "$FFMPEG_LOCAL" ]]; then
  echo "FFMPEG_LOCAL not executable at $FFMPEG_LOCAL"
  exit 1
fi

if command -v rg >/dev/null 2>&1; then
  if ! "$FFMPEG_REMOTE" -h decoder=h264_videotoolbox_remote 2>/dev/null | rg -q "vt_remote_decode_async"; then
    echo "ffmpeg remote decoder options do not include vt_remote_decode_async; rebuild ffmpeg."
    exit 1
  fi
else
  if ! "$FFMPEG_REMOTE" -h decoder=h264_videotoolbox_remote 2>/dev/null | grep -q "vt_remote_decode_async"; then
    echo "ffmpeg remote decoder options do not include vt_remote_decode_async; rebuild ffmpeg."
    exit 1
  fi
fi

have_encoder() {
  local bin="$1"
  local enc="$2"
  if command -v rg >/dev/null 2>&1; then
    "$bin" -encoders 2>/dev/null | rg -q "\\b${enc}\\b"
  else
    "$bin" -encoders 2>/dev/null | grep -q "\\b${enc}\\b"
  fi
}

pick_h264_encoder() {
  local bin="$1"
  if have_encoder "$bin" "libopenh264"; then
    echo "libopenh264"
  elif have_encoder "$bin" "libx264"; then
    echo "libx264"
  elif have_encoder "$bin" "h264_videotoolbox"; then
    echo "h264_videotoolbox"
  else
    echo ""
  fi
}

H264_ENCODER="$(pick_h264_encoder "$FFMPEG_LOCAL")"
if [[ -z "$H264_ENCODER" ]]; then
  echo "Local ffmpeg lacks an H.264 encoder (need one of libopenh264/libx264/h264_videotoolbox)." >&2
  echo "Install one or set FFMPEG_LOCAL to a build that provides one." >&2
  exit 1
fi

ENC_ARGS=()
PIX_FMT="yuv420p"
case "$H264_ENCODER" in
  libx264)
    ENC_ARGS=( -preset ultrafast -tune zerolatency )
    ;;
  h264_videotoolbox)
    # Some environments require software fallback (e.g. GitHub runners / VMs).
    ENC_ARGS=( -allow_sw 1 )
    PIX_FMT="nv12"
    ;;
  *)
    ;;
esac
echo "Using local input encoder: ${H264_ENCODER}"

echo "STEP: generate input ${SIZE}@${RATE} (${DURATION}s)"
"$FFMPEG_LOCAL" -v error -f lavfi -i "testsrc2=size=${SIZE}:rate=${RATE}:duration=${DURATION}" \
  -pix_fmt "$PIX_FMT" -c:v "$H264_ENCODER" "${ENC_ARGS[@]+"${ENC_ARGS[@]}"}" -b:v 4M -g 60 -y "$IN" >"$IN_LOG" 2>&1

build_remote_args() {
  remote_args=( -vt_remote_host "127.0.0.1:${PORT}" )
  if [[ -n "$WIRE_COMP" ]]; then
    remote_args+=( -vt_remote_wire_compression "$WIRE_COMP" )
  fi
}

VTREMOTED="$VTREMOTED"
VTREMOTE_PORT="$PORT"
if [[ -n "${VTREMOTE_USE_EXISTING:-}" ]]; then
  echo "STEP: using existing vtremoted on 127.0.0.1:${VTREMOTE_PORT:-5555}"
else
  echo "STEP: start vtremoted on 127.0.0.1:${VTREMOTE_PORT:-<auto>}"
fi
vtremote_start_server "$VT_LOG"
PID="${VTREMOTE_SERVER_PID:-}"
PORT="$VTREMOTE_PORT"
trap 'kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true' EXIT
build_remote_args

vt_decode_failed() {
  if command -v rg >/dev/null 2>&1; then
    rg -q "VTDecompressionSessionCreate failed" "$VT_LOG"
  else
    grep -q "VTDecompressionSessionCreate failed" "$VT_LOG"
  fi
}

restart_vtremoted() {
  vtremote_restart_server "$VT_LOG"
  PID="${VTREMOTE_SERVER_PID:-}"
  PORT="$VTREMOTE_PORT"
  build_remote_args
}

local_decoder="h264"
if command -v rg >/dev/null 2>&1; then
  if "$FFMPEG_REMOTE" -decoders 2>/dev/null | rg -q "h264_videotoolbox"; then
    local_decoder="h264_videotoolbox"
  fi
else
  if "$FFMPEG_REMOTE" -decoders 2>/dev/null | grep -q "h264_videotoolbox"; then
    local_decoder="h264_videotoolbox"
  fi
fi

run_timed() {
  local label="$1"; shift
  local log_file="$1"; shift
  local fail_hard="${RUN_FAIL_HARD:-1}"
  local start_ns end_ns elapsed_s
  start_ns=$(python3 - <<'PY'
import time; print(int(time.time() * 1e9))
PY
)
  set +e
  "$@" >"$log_file" 2>&1
  local rc=$?
  set -e
  end_ns=$(python3 - <<'PY'
import time; print(int(time.time() * 1e9))
PY
)
  elapsed_s=$(python3 - <<PY
print("{:.3f}".format((${end_ns}-${start_ns})/1e9))
PY
)
  if [[ $rc -ne 0 ]]; then
    echo "FAIL ${label} elapsed_s=${elapsed_s} rc=${rc}"
    echo "---- $log_file ----"
    tail -n 200 "$log_file"
    if [[ "$fail_hard" != "0" ]]; then
      exit "$rc"
    fi
    return "$rc"
  fi
  echo "RESULT ${label} elapsed_s=${elapsed_s}"
  return 0
}

echo "STEP: local decode baseline (${local_decoder})"
run_timed "local_decode_${local_decoder}" "$LOCAL_LOG" \
  "$FFMPEG_REMOTE" -v warning -xerror -c:v "$local_decoder" -i "$IN" -f null -

echo "STEP: remote decode (sync)"
if ! RUN_FAIL_HARD=0 run_timed "remote_decode_sync" "$REMOTE_LOG_SYNC" \
  "$FFMPEG_REMOTE" -v warning -xerror "${remote_args[@]}" \
    -c:v h264_videotoolbox_remote -i "$IN" -f null -; then
  rc=$?
  if vt_decode_failed; then
    echo "WARN: VTDecompressionSessionCreate failed; retrying remote sync decode..."
    restart_vtremoted
    RUN_FAIL_HARD=1 run_timed "remote_decode_sync" "$REMOTE_LOG_SYNC" \
      "$FFMPEG_REMOTE" -v warning -xerror "${remote_args[@]}" \
        -c:v h264_videotoolbox_remote -i "$IN" -f null -
  else
    exit "$rc"
  fi
fi

if [[ "$DECODE_ASYNC" != "0" ]]; then
  remote_args_async=( "${remote_args[@]}" -vt_remote_decode_async 1 -vt_remote_decode_reorder_depth "$REORDER_DEPTH" )
  echo "STEP: remote decode (async=${DECODE_ASYNC} depth=${REORDER_DEPTH})"
  if ! RUN_FAIL_HARD=0 run_timed "remote_decode_async" "$REMOTE_LOG_ASYNC" \
    "$FFMPEG_REMOTE" -v warning -xerror "${remote_args_async[@]}" \
      -c:v h264_videotoolbox_remote -i "$IN" -f null -; then
    rc=$?
    if vt_decode_failed; then
      echo "WARN: VTDecompressionSessionCreate failed; retrying remote async decode..."
      restart_vtremoted
      remote_args_async=( "${remote_args[@]}" -vt_remote_decode_async 1 -vt_remote_decode_reorder_depth "$REORDER_DEPTH" )
      RUN_FAIL_HARD=1 run_timed "remote_decode_async" "$REMOTE_LOG_ASYNC" \
        "$FFMPEG_REMOTE" -v warning -xerror "${remote_args_async[@]}" \
          -c:v h264_videotoolbox_remote -i "$IN" -f null -
    else
      exit "$rc"
    fi
  fi
fi

check_log() {
  local name="$1"; local file="$2";
  if [[ ! -s "$file" ]]; then
    return 0
  fi
  if command -v rg >/dev/null 2>&1; then
    if rg -n "(?i)(warn|error|invalid|non[- ]monotonic)" "$file" >/dev/null 2>&1; then
      echo "WARN/ERROR in ${name} log: $file"
      rg -n "(?i)(warn|error|invalid|non[- ]monotonic)" "$file"
      exit 2
    fi
  else
    if grep -E -n -i "(warn|error|invalid|non[- ]monotonic)" "$file" >/dev/null 2>&1; then
      echo "WARN/ERROR in ${name} log: $file"
      grep -E -n -i "(warn|error|invalid|non[- ]monotonic)" "$file"
      exit 2
    fi
  fi
}

check_log "local ffmpeg" "$LOCAL_LOG"
check_log "remote ffmpeg sync" "$REMOTE_LOG_SYNC"
if [[ "$DECODE_ASYNC" != "0" ]]; then
  check_log "remote ffmpeg async" "$REMOTE_LOG_ASYNC"
fi
check_log "vtremoted" "$VT_LOG"

if [[ "$PRINT_LOGS" != "0" ]]; then
  echo "---- $LOCAL_LOG ----"
  cat "$LOCAL_LOG"
  echo "---- $REMOTE_LOG_SYNC ----"
  cat "$REMOTE_LOG_SYNC"
  if [[ "$DECODE_ASYNC" != "0" ]]; then
    echo "---- $REMOTE_LOG_ASYNC ----"
    cat "$REMOTE_LOG_ASYNC"
  fi
fi

echo "OK: no warnings/errors in decode logs"
