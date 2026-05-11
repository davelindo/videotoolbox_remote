#!/usr/bin/env bash
set -euo pipefail

# Mock-backed capability negotiation coverage. The first case proves a normal
# advertised pixel format succeeds; the second proves a 0.4.1-only format fails
# during configure when the server omits the required capability.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG_BIN:-${ROOT}/ffmpeg/ffmpeg}"

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg binary not found at $FFMPEG_BIN" >&2
  exit 1
fi

free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

run_mock() {
  local port="$1"
  local caps="$2"
  local log="$3"
  python3 "${ROOT}/tests/integration/mock_vtremoted/mock_vtremoted.py" \
    --listen "127.0.0.1:${port}" \
    --strict-config-options \
    --capabilities "$caps" \
    --once >"$log" 2>&1 &
  SERVER_PID=$!
}

BASE_CAPS="h264,hevc,pixfmt.nv12,pixfmt.p010,side_data.v2"

PORT="$(free_port)"
SERVER_LOG="/tmp/mock_vtremote_caps_success.log"
SERVER_PID=""
run_mock "$PORT" "$BASE_CAPS" "$SERVER_LOG"
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
sleep 0.2

"$FFMPEG_BIN" -hide_banner -v warning -xerror \
  -f lavfi -i testsrc2=size=160x90:rate=5 -frames:v 3 -pix_fmt nv12 \
  -c:v h264_videotoolbox_remote \
  -vt_remote_host "127.0.0.1:${PORT}" \
  -vt_remote_wire_compression lz4 \
  -b:v 500k -g 10 \
  -f null - >/tmp/mock_vtremote_caps_success_ffmpeg.log 2>&1
wait "$SERVER_PID"
trap - EXIT

PORT="$(free_port)"
SERVER_LOG="/tmp/mock_vtremote_caps_missing.log"
SERVER_PID=""
run_mock "$PORT" "$BASE_CAPS" "$SERVER_LOG"
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
sleep 0.2

set +e
python3 - "$FFMPEG_BIN" "127.0.0.1:${PORT}" >/tmp/mock_vtremote_caps_missing_ffmpeg.log 2>&1 <<'PY'
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
trap - EXIT

if ! grep -Eq "missing capability pixfmt.bgra|required capability for bgra" \
  /tmp/mock_vtremote_caps_missing_ffmpeg.log "$SERVER_LOG"; then
  echo "ERROR: missing-capability failure did not name pixfmt.bgra" >&2
  cat /tmp/mock_vtremote_caps_missing_ffmpeg.log >&2
  cat "$SERVER_LOG" >&2
  exit 1
fi

echo "OK: mock protocol capability negotiation cases passed"
