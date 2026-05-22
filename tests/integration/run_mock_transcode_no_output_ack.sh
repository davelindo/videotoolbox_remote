#!/usr/bin/env bash
set -euo pipefail

# Regression coverage for vtremote_transcode input-credit ACKs. The mock accepts
# transcode PACKET input, sends PACKET_ACK, but deliberately emits no output
# PACKETs before FLUSH/DONE. With vt_remote_inflight=1 this would wedge if input
# credit still depended on output packet cardinality.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG_BIN:-${ROOT}/ffmpeg/ffmpeg}"

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg binary not found at $FFMPEG_BIN" >&2
  exit 1
fi

bin_strings="$(strings "$FFMPEG_BIN" 2>/dev/null || true)"
if ! grep -F "packet_ack.v1" <<<"$bin_strings" >/dev/null; then
  echo "SKIP: $FFMPEG_BIN was built before vtremote packet_ack.v1 support; rebuild ffmpeg to run this regression"
  exit 0
fi

have_encoder() {
  local enc="$1"
  local encoders
  # Capture first instead of piping to grep -q; with pipefail, early grep exits can
  # otherwise surface as ffmpeg SIGPIPE probe failures.
  if ! encoders="$("$FFMPEG_BIN" -encoders 2>/dev/null)"; then
    return 2
  fi
  grep -w "$enc" <<<"$encoders" >/dev/null
}

ENCODER=""
PIX_FMT="yuv420p"
ENC_ARGS=()
if have_encoder "libopenh264"; then
  ENCODER="libopenh264"
elif have_encoder "libx264"; then
  ENCODER="libx264"
  ENC_ARGS=( -preset ultrafast -tune zerolatency )
elif have_encoder "h264_videotoolbox"; then
  ENCODER="h264_videotoolbox"
  PIX_FMT="nv12"
  ENC_ARGS=( -allow_sw 1 -color_range:v limited )
else
  echo "ERROR: no local H.264 encoder available (need libopenh264/libx264/h264_videotoolbox)" >&2
  exit 1
fi

PORT=$(python3 - <<'PYPORT'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PYPORT
)
SERVER_ADDR="127.0.0.1:${PORT}"
SERVER_LOG=/tmp/mock_vtremoted_transcode_no_output_ack.log
FFMPEG_LOG=/tmp/mock_vtremoted_transcode_no_output_ack_ffmpeg.log

python3 "${ROOT}/tests/integration/mock_vtremoted/mock_vtremoted.py" \
  --listen "$SERVER_ADDR" \
  --packet-reply none \
  --once >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
sleep 0.2

python3 - "$FFMPEG_BIN" "$SERVER_ADDR" "$ENCODER" "$PIX_FMT" "$FFMPEG_LOG" "${ENC_ARGS[@]}" <<'PYRUN'
import subprocess
import sys

ffmpeg_bin, server_addr, encoder, pix_fmt, log_path, *enc_args = sys.argv[1:]
host, port = server_addr.rsplit(":", 1)
bsf = (
    "vtremote_transcode="
    f"vt_remote_host={host}:vt_remote_port={port}:"
    "vt_remote_inflight=1:vt_remote_timeout_ms=5000"
)
cmd = [
    ffmpeg_bin,
    "-hide_banner",
    "-loglevel", "verbose",
    "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=5",
    "-t", "1",
    "-pix_fmt", pix_fmt,
    "-c:v", encoder,
    *enc_args,
    "-bf", "0",
    "-g", "10",
    "-bsf:v", bsf,
    "-f", "null",
    "-",
]
with open(log_path, "w", encoding="utf-8", errors="replace") as log:
    try:
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=log, check=True, timeout=20)
    except subprocess.TimeoutExpired as exc:
        raise SystemExit(f"ffmpeg timed out; vtremote_transcode input credit may be wedged: {exc}") from exc
PYRUN

wait "$SERVER_PID"
trap - EXIT

if grep -E "Timed out waiting for vtremote_transcode input credit|Connection timed out" "$FFMPEG_LOG" >/dev/null; then
  echo "ERROR: vtremote_transcode reported an input-credit timeout" >&2
  tail -n 80 "$FFMPEG_LOG" >&2
  exit 1
fi

echo "OK: vtremote_transcode no-output PACKET_ACK credit passed; logs at ${SERVER_LOG} and ${FFMPEG_LOG}"
