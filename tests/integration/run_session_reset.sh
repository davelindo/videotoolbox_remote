#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
RUN_DIR="$(mktemp -d /tmp/vtremote-session-reset.XXXXXX)"
source tests/integration/vtremoted_common.sh
VTREMOTED="${VTREMOTED:-$ROOT/vtremoted/.build/debug/vtremoted}"
FFMPEG="${FFMPEG:-$ROOT/ffmpeg/ffmpeg}"
cleanup() { vtremote_stop_server; }
trap cleanup EXIT
make -f tests/integration/api-regressions.mk "API_BUILD_DIR=$RUN_DIR"
vtremote_start_server "$RUN_DIR/server.log"
for codec in h264 hevc; do
  pix_fmt=nv12
  if [[ "$codec" == hevc ]]; then pix_fmt=p010le; fi
  "$FFMPEG" -v error -xerror -f lavfi -i testsrc2=size=320x180:rate=30 -frames:v 24 \
    -c:v "${codec}_videotoolbox" -pix_fmt "$pix_fmt" -bf 0 "$RUN_DIR/$codec.mp4"
  for mode in decode transcode; do
    "$RUN_DIR/session_reset" "$mode" "$RUN_DIR/$codec.mp4" "$VTREMOTE_HOST:$VTREMOTE_PORT"
  done
done
echo "PASS session reset; artifacts: $RUN_DIR"
