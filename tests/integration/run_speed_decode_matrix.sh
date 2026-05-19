#!/usr/bin/env bash
set -eEuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VTREMOTED="${VTREMOTED:-${ROOT}/vtremoted/.build/debug/vtremoted}"
FFMPEG_REMOTE="${FFMPEG:-${ROOT}/ffmpeg/ffmpeg}"
FFMPEG_LOCAL="${FFMPEG_LOCAL:-$(command -v ffmpeg || true)}"
source "${ROOT}/tests/integration/vtremoted_common.sh"

PORT="${VTREMOTE_PORT:-}"
SIZE="${VTREMOTE_SPEED_SIZE:-1920x1080}"
RATE="${VTREMOTE_SPEED_RATE:-30}"
DURATION="${VTREMOTE_SPEED_DURATION:-20}"
WIRE_LIST="${VTREMOTE_MATRIX_WIRE_LIST:-2}"
ASYNC_LIST="${VTREMOTE_MATRIX_ASYNC_LIST:-0 1}"
DEPTH_LIST="${VTREMOTE_MATRIX_DEPTH_LIST:-0 2 8}"
FAIL_FAST="${VTREMOTE_MATRIX_FAIL_FAST:-0}"
RESTART_EACH="${VTREMOTE_MATRIX_RESTART_EACH:-0}"
IN_FILE="${VTREMOTE_MATRIX_INPUT:-}"

RUN_DIR="${VTREMOTE_MATRIX_OUT_DIR:-$(mktemp -d /tmp/vtremote_speed_matrix.XXXXXX)}"
RESULTS="${RUN_DIR}/results.csv"
VT_LOG="${RUN_DIR}/vtremoted.log"
LOCAL_LOG="${RUN_DIR}/local.log"
IN_LOG="${RUN_DIR}/input.log"

mkdir -p "$RUN_DIR"

on_error() {
  echo "ERROR: speed matrix failed; logs in $RUN_DIR"
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
  echo "FFMPEG_LOCAL not set and no ffmpeg in PATH"
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

if [[ -z "$IN_FILE" ]]; then
  if command -v rg >/dev/null 2>&1; then
    if ! "$FFMPEG_LOCAL" -encoders 2>/dev/null | rg -q "libopenh264"; then
      echo "Local ffmpeg lacks libopenh264 encoder. Install one or set VTREMOTE_MATRIX_INPUT to a file."
      exit 1
    fi
  else
    if ! "$FFMPEG_LOCAL" -encoders 2>/dev/null | grep -q "libopenh264"; then
      echo "Local ffmpeg lacks libopenh264 encoder. Install one or set VTREMOTE_MATRIX_INPUT to a file."
      exit 1
    fi
  fi
  IN_FILE="${RUN_DIR}/input_${SIZE}_${RATE}_${DURATION}s.mp4"
  echo "STEP: generate input ${SIZE}@${RATE} (${DURATION}s)"
  "$FFMPEG_LOCAL" -v error \
    -f lavfi -i "testsrc2=size=${SIZE}:rate=${RATE}:duration=${DURATION}" \
    -pix_fmt yuv420p -c:v libopenh264 -b:v 4M -g 60 -y "$IN_FILE" \
    >"$IN_LOG" 2>&1
else
  echo "STEP: using input $IN_FILE"
fi

VTREMOTED="$VTREMOTED"
VTREMOTE_PORT="$PORT"
echo "STEP: start vtremoted on 127.0.0.1:${VTREMOTE_PORT:-<auto>}"
vtremote_start_server "$VT_LOG"
PID="${VTREMOTE_SERVER_PID:-}"
PORT="$VTREMOTE_PORT"
trap 'kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true' EXIT

local_decoder="h264"
if vtremote_ffmpeg_has_decoder "$FFMPEG_REMOTE" "h264_videotoolbox"; then
  local_decoder="h264_videotoolbox"
else
  decoder_probe_rc=$?
  if [[ "$decoder_probe_rc" -eq 2 ]]; then
    echo "Failed to query decoders from $FFMPEG_REMOTE" >&2
    exit 1
  fi
fi

run_timed() {
  local label="$1"; shift
  local log_file="$1"; shift
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
  echo "$elapsed_s,$rc"
}

echo "label,async,depth,wire,elapsed_s,rc" > "$RESULTS"

echo "STEP: local decode baseline (${local_decoder})"
baseline=$(run_timed "local_decode_${local_decoder}" "$LOCAL_LOG" \
  "$FFMPEG_REMOTE" -v warning -xerror -c:v "$local_decoder" -i "$IN_FILE" -f null -)
echo "local,0,-,-,${baseline}" >> "$RESULTS"
echo "RESULT local_decode_${local_decoder} elapsed_s=${baseline%,*}"

for wire in $WIRE_LIST; do
  wire_label="${wire:-default}"
  for async in $ASYNC_LIST; do
    if [[ "$async" == "0" ]]; then
      depth_list="-"
    else
      depth_list="$DEPTH_LIST"
    fi
    for depth in $depth_list; do
      if [[ "$RESTART_EACH" != "0" ]]; then
        vtremote_restart_server "$VT_LOG"
        PID="${VTREMOTE_SERVER_PID:-}"
        PORT="$VTREMOTE_PORT"
      fi
      remote_args=( -vt_remote_host "127.0.0.1:${PORT}" )
      if [[ -n "$wire" ]]; then
        remote_args+=( -vt_remote_wire_compression "$wire" )
      fi
      if [[ "$async" != "0" ]]; then
        remote_args+=( -vt_remote_decode_async 1 -vt_remote_decode_reorder_depth "$depth" )
      fi
      label="remote_async${async}_depth${depth}_wire${wire_label}"
      log_file="${RUN_DIR}/${label}.log"
      result=$(run_timed "$label" "$log_file" \
        "$FFMPEG_REMOTE" -v warning -xerror "${remote_args[@]}" \
          -c:v h264_videotoolbox_remote -i "$IN_FILE" -f null -)
      elapsed="${result%,*}"
      rc="${result#*,}"
      echo "${label},${async},${depth},${wire_label},${elapsed},${rc}" >> "$RESULTS"
      if [[ "$rc" -ne 0 ]]; then
        echo "FAIL ${label} elapsed_s=${elapsed} rc=${rc} (log: $log_file)"
        if [[ "$FAIL_FAST" != "0" ]]; then
          exit "$rc"
        fi
      else
        echo "RESULT ${label} elapsed_s=${elapsed}"
      fi
    done
  done
done

echo "OK: results at $RESULTS"
python3 - <<PY
import csv
path = "${RESULTS}"
with open(path, newline="") as f:
    rows = list(csv.DictReader(f))
rows = [r for r in rows if r["label"] != "local" and r["rc"] == "0"]
rows.sort(key=lambda r: float(r["elapsed_s"]))
print("FASTEST:")
for r in rows[:5]:
    print(f"  {r['label']} elapsed_s={r['elapsed_s']}")
PY
