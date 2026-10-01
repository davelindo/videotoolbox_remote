#!/usr/bin/env bash
set -euo pipefail

# Ensure vtremote does not clamp PTS to DTS.
#
# The mock server can reply to FRAME with PACKET timestamps where DTS > PTS.
# This is valid (e.g. B-frames / reordering). We assert FFmpeg preserves this
# relationship instead of forcing PTS >= DTS.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG_BIN:-${ROOT}/ffmpeg/ffmpeg}"
source "${ROOT}/tests/integration/mock_vtremoted_common.sh"
SERVER_TOKEN=${SERVER_TOKEN:-}
SERVER_ADDR=${SERVER_ADDR:-127.0.0.1:0}

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg binary not found at $FFMPEG_BIN" >&2
  exit 1
fi

RUN_DIR="$(mktemp -d /tmp/mock_vtremoted_pts_dts.XXXXXX)"
SERVER_LOG="${RUN_DIR}/server.log"
FFMPEG_LOG="${RUN_DIR}/ffmpeg.log"
READY_FILE="${RUN_DIR}/server.ready"
TOKEN_ARGS=()

python3 "${ROOT}/tests/integration/mock_vtremoted/mock_vtremoted.py" \
  --listen "$SERVER_ADDR" --ready-file "$READY_FILE" --token "$SERVER_TOKEN" \
  --packet-dts-offset 1 --once >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
trap 'vtremote_stop_mock "$SERVER_PID"' EXIT
SERVER_ADDR="$(vtremote_wait_mock_ready "$SERVER_PID" "$READY_FILE" "$SERVER_LOG")"
if [[ -n "$SERVER_TOKEN" ]]; then
  TOKEN_ARGS=( -vt_remote_token "$SERVER_TOKEN" )
fi

"$FFMPEG_BIN" -hide_banner -loglevel verbose -debug_ts \
  -f lavfi -i testsrc2=size=64x64:rate=5 -t 1 -pix_fmt nv12 \
  -c:v h264_videotoolbox_remote -vt_remote_host "$SERVER_ADDR" \
  -vt_remote_wire_compression none ${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"} \
  -f null - > /dev/null 2>"$FFMPEG_LOG"

python3 - <<PY
import re, sys

log_path = "$FFMPEG_LOG"
pat = re.compile(r"encoder -> .*\\bpkt_pts:(-?\\d+)\\b.*\\bpkt_dts:(-?\\d+)\\b")

seen = 0
seen_pts_lt_dts = 0
lines = []

with open(log_path, "r", errors="ignore") as f:
    for line in f:
        m = pat.search(line)
        if not m:
            continue
        seen += 1
        pts = int(m.group(1))
        dts = int(m.group(2))
        lines.append((pts, dts, line.strip()))
        if pts < dts:
            seen_pts_lt_dts = 1
            break

if seen == 0:
    print("ERROR: did not observe any encoded packet timestamps in ffmpeg log", file=sys.stderr)
    sys.exit(1)

if not seen_pts_lt_dts:
    print("ERROR: expected at least one packet with pts < dts; timestamps may have been clamped", file=sys.stderr)
    for pts, dts, line in lines[-10:]:
        print("  " + line, file=sys.stderr)
    sys.exit(1)
PY

echo "OK: pts<dts preserved; logs at ${SERVER_LOG} and ${FFMPEG_LOG}"
