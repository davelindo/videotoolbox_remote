#!/usr/bin/env bash
set -euo pipefail

# Simple decode framing test using the Python mock server and h264_videotoolbox_remote decoder.
# Requirements:
# - python3 available
# - ffmpeg binary built in ../ffmpeg/ffmpeg with h264_videotoolbox_remote enabled
#
# Note: the mock server does not implement wire compression; force `none`.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG_BIN:-${ROOT}/ffmpeg/ffmpeg}"
source "${ROOT}/tests/integration/mock_vtremoted_common.sh"
FFMPEG_LOCAL_BIN="${FFMPEG_LOCAL:-ffmpeg}"
SERVER_TOKEN=${SERVER_TOKEN:-}
SERVER_ADDR=${SERVER_ADDR:-127.0.0.1:0}
SERVER_PID=""

TOKEN_ARGS=()

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg binary not found at $FFMPEG_BIN" >&2
  exit 1
fi

RUN_DIR="$(mktemp -d /tmp/vtremote_mock_decode.XXXXXX)"
INPUT_FILE="${RUN_DIR}/input.mp4"
SERVER_LOG="${RUN_DIR}/server.log"
FFMPEG_LOG="${RUN_DIR}/ffmpeg.log"
GEN_LOG="${RUN_DIR}/generate.log"
READY_FILE="${RUN_DIR}/server.ready"
cleanup() {
  vtremote_stop_mock "$SERVER_PID"
  rm -f "$INPUT_FILE"
}
trap cleanup EXIT

echo "Generating input file..."
candidate_bins=()
if command -v "$FFMPEG_LOCAL_BIN" >/dev/null 2>&1; then
  candidate_bins+=( "$(command -v "$FFMPEG_LOCAL_BIN")" )
fi
if [[ -x /usr/bin/ffmpeg ]]; then
  candidate_bins+=( "/usr/bin/ffmpeg" )
fi
# Always include the repo build as a fallback.
candidate_bins+=( "$FFMPEG_BIN" )

have_encoder() {
  local bin="$1"
  local enc="$2"
  # Don't use grep -q here: it can exit early, causing ffmpeg to hit SIGPIPE.
  # With `set -o pipefail`, that would make the probe look like a failure.
  "$bin" -encoders 2>/dev/null | grep -w "$enc" >/dev/null
}

encode_input() {
  local bin="$1"
  shift
  local enc="$1"
  shift
  local pix_fmt="$1"
  shift
  "$bin" -v warning -f lavfi -i testsrc2=size=320x180:rate=5 -t 1 -pix_fmt "$pix_fmt" \
    -c:v "$enc" "$@" -an -sn -y "$INPUT_FILE" >"$GEN_LOG" 2>&1
}

ok=0
chosen_bin=""
chosen_enc=""
for bin in "${candidate_bins[@]}"; do
  for enc in libopenh264 libx264 h264_videotoolbox; do
    if ! have_encoder "$bin" "$enc"; then
      continue
    fi
    extra=()
    pix_fmt="yuv420p"
    if [[ "$enc" == "libx264" ]]; then
      extra=( -preset ultrafast -tune zerolatency )
    elif [[ "$enc" == "h264_videotoolbox" ]]; then
      pix_fmt="nv12"
      extra=( -allow_sw 1 -color_range:v limited )
    fi
    if encode_input "$bin" "$enc" "$pix_fmt" "${extra[@]+"${extra[@]}"}"; then
      ok=1
      chosen_bin="$bin"
      chosen_enc="$enc"
      break
    fi
  done
  if [[ "$ok" -eq 1 ]]; then
    break
  fi
done
if [[ "$ok" -ne 1 ]]; then
  echo "ERROR: failed to generate H.264 input (need one of libopenh264/libx264/h264_videotoolbox)" >&2
  tail -n 200 "$GEN_LOG" 2>/dev/null || true
  exit 1
fi
echo "Using local input generator: ${chosen_bin} (${chosen_enc})"

echo "Starting mock server..."
python3 "${ROOT}/tests/integration/mock_vtremoted/mock_vtremoted.py" \
  --listen "$SERVER_ADDR" --ready-file "$READY_FILE" --token "$SERVER_TOKEN" \
  --once >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
SERVER_ADDR="$(vtremote_wait_mock_ready "$SERVER_PID" "$READY_FILE" "$SERVER_LOG")"

if [[ -n "$SERVER_TOKEN" ]]; then
  TOKEN_ARGS=( -vt_remote_token "$SERVER_TOKEN" )
fi

echo "Running remote decode against mock server..."
"$FFMPEG_BIN" -v error -xerror \
  -vt_remote_host "$SERVER_ADDR" \
  -vt_remote_wire_compression none \
  -vt_remote_decode_async 0 \
  ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  -c:v h264_videotoolbox_remote -i "$INPUT_FILE" \
  -f null - >"$FFMPEG_LOG" 2>&1

echo "OK: vtremote decode framing exercised; logs at ${RUN_DIR}"
