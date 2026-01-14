#!/usr/bin/env bash
set -euo pipefail

# Profile vtremoted under heavy load using 'sample'.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG:-${ROOT}/ffmpeg/ffmpeg}"
VTREMOTED_BIN="${VTREMOTED:-${ROOT}/vtremoted/.build/release/vtremoted}"
PORT="${VTREMOTE_PORT:-5555}"

if [[ ! -x "$VTREMOTED_BIN" ]]; then
    # Fallback to debug build if release not found
    VTREMOTED_BIN="${ROOT}/vtremoted/.build/debug/vtremoted"
fi

echo "Starting vtremoted on port ${PORT}..."
"$VTREMOTED_BIN" --listen "127.0.0.1:${PORT}" > /tmp/vtremoted_profile.log 2>&1 &
VTREMOTED_PID=$!
echo "vtremoted PID: ${VTREMOTED_PID}"

cleanup() {
    echo "Stopping vtremoted..."
    kill "$VTREMOTED_PID" 2>/dev/null || true
}
trap cleanup EXIT

sleep 1

echo "Starting load: 4K60 encoding (10 seconds)..."
# Run 4k60 encode for 10 seconds to generate load
"$FFMPEG_BIN" -v warning -f lavfi -i "testsrc2=size=3840x2160:rate=60:duration=10" \
    -pix_fmt nv12 -c:v h264_videotoolbox_remote \
    -vt_remote_host "127.0.0.1:${PORT}" \
    -b:v 20M -f null /dev/null > /tmp/vtremoted_ffmpeg.log 2>&1 &
LOAD_PID=$!

sleep 2
echo "Sampling vtremoted for 5 seconds..."
sample "$VTREMOTED_PID" 5 10 -file "${ROOT}/tests/integration/vtremoted.sample.txt"

wait "$LOAD_PID"
echo "Load finished."

echo "Profile saved to ${ROOT}/tests/integration/vtremoted.sample.txt"
head -n 20 "${ROOT}/tests/integration/vtremoted.sample.txt"
echo "..."
