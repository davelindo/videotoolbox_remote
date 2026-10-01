#!/usr/bin/env bash
set -euo pipefail

# Mock-backed capability negotiation coverage. The first case proves a normal
# advertised pixel format succeeds; the second proves a 0.4.1-only format fails
# during configure when the server omits the required capability.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG_BIN:-${ROOT}/ffmpeg/ffmpeg}"
source "${ROOT}/tests/integration/mock_vtremoted_common.sh"

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg binary not found at $FFMPEG_BIN" >&2
  exit 1
fi

RUN_DIR="$(mktemp -d /tmp/mock_vtremote_caps.XXXXXX)"
SERVER_PID=""
trap 'vtremote_stop_mock "$SERVER_PID"' EXIT

run_mock() {
  local caps="$1"
  local log="$2"
  local ready_file="${log}.ready"
  python3 "${ROOT}/tests/integration/mock_vtremoted/mock_vtremoted.py" \
    --listen "127.0.0.1:0" --ready-file "$ready_file" \
    --strict-config-options \
    --capabilities "$caps" \
    --once >"$log" 2>&1 &
  SERVER_PID=$!
  SERVER_ADDR="$(vtremote_wait_mock_ready "$SERVER_PID" "$ready_file" "$log")"
}

BASE_CAPS="h264,hevc,pixfmt.nv12,pixfmt.p010,side_data.v2"

SERVER_LOG="${RUN_DIR}/success.log"
run_mock "$BASE_CAPS" "$SERVER_LOG"

"$FFMPEG_BIN" -hide_banner -v warning -xerror \
  -f lavfi -i testsrc2=size=160x90:rate=5 -frames:v 3 -pix_fmt nv12 \
  -c:v h264_videotoolbox_remote \
  -vt_remote_host "$SERVER_ADDR" \
  -vt_remote_wire_compression lz4 \
  -b:v 500k -g 10 \
  -f null - >"${RUN_DIR}/success_ffmpeg.log" 2>&1
wait "$SERVER_PID"
SERVER_PID=""

SERVER_LOG="${RUN_DIR}/missing.log"
run_mock "$BASE_CAPS" "$SERVER_LOG"

set +e
python3 - "$FFMPEG_BIN" "$SERVER_ADDR" >"${RUN_DIR}/missing_ffmpeg.log" 2>&1 <<'PY'
import subprocess
import sys

ffmpeg, host = sys.argv[1], sys.argv[2]
cmd = [
    ffmpeg, "-hide_banner", "-v", "warning",
    "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=5",
    "-frames:v", "3",
    "-vf", "format=bgra",
    "-c:v", "hevc_videotoolbox_remote",
    "-vt_remote_host", host,
    "-vt_remote_wire_compression", "lz4",
    "-b:v", "500k", "-g", "10",
    "-f", "null", "-",
]
completed = subprocess.run(cmd)
sys.exit(0 if completed.returncode == 0 else 1)
PY
missing_status=$?
set -e
if [[ "$missing_status" -eq 0 ]]; then
  echo "ERROR: HEVC BGRA encode unexpectedly succeeded without pixfmt.bgra capability" >&2
  cat "$SERVER_LOG" >&2
  exit 1
fi
wait "$SERVER_PID" || true
SERVER_PID=""

if ! grep -Eq "missing capability pixfmt.bgra|required capability for bgra" \
  "${RUN_DIR}/missing_ffmpeg.log" "$SERVER_LOG"; then
  echo "ERROR: missing-capability failure did not name pixfmt.bgra" >&2
  cat "${RUN_DIR}/missing_ffmpeg.log" >&2
  cat "$SERVER_LOG" >&2
  exit 1
fi

echo "OK: mock protocol capability negotiation cases passed"
