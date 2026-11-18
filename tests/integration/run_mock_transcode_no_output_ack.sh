#!/usr/bin/env bash
set -euo pipefail

# Regression coverage for vtremote_transcode input-credit ACKs. The mock accepts
# transcode PACKET input, sends PACKET_ACK, but deliberately emits no output
# PACKETs before FLUSH/DONE. With vt_remote_inflight=1 this would wedge if input
# credit still depended on output packet cardinality. A second run verifies
# that EOF can flush a full legacy in-flight window without ACKs.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG_BIN:-${ROOT}/ffmpeg/ffmpeg}"
source "${ROOT}/tests/integration/mock_vtremoted_common.sh"

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

RUN_DIR="$(mktemp -d /tmp/mock_vtremoted_transcode_no_output_ack.XXXXXX)"
run_case() {
  local name="$1" frames="$2"
  shift 2
  local server_log="${RUN_DIR}/${name}-server.log"
  local ffmpeg_log="${RUN_DIR}/${name}-ffmpeg.log"
  local ready_file="${RUN_DIR}/${name}.ready"

  python3 "${ROOT}/tests/integration/mock_vtremoted/mock_vtremoted.py" \
    --listen "127.0.0.1:0" --ready-file "$ready_file" \
    --packet-reply none --once "$@" >"$server_log" 2>&1 &
  SERVER_PID=$!
  trap 'vtremote_stop_mock "$SERVER_PID"' EXIT
  local server_addr
  server_addr="$(vtremote_wait_mock_ready "$SERVER_PID" "$ready_file" "$server_log")"

  python3 - "$FFMPEG_BIN" "$server_addr" "$ENCODER" "$PIX_FMT" "$ffmpeg_log" "$frames" "${ENC_ARGS[@]}" <<'PYRUN'
import subprocess
import sys

ffmpeg_bin, server_addr, encoder, pix_fmt, log_path, frames, *enc_args = sys.argv[1:]
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
    "-frames:v", frames,
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

  if grep -E "Timed out waiting for vtremote_transcode input credit|Connection timed out|Operation timed out" "$ffmpeg_log" >/dev/null; then
    echo "ERROR: vtremote_transcode reported an input-credit timeout ($name)" >&2
    tail -n 80 "$ffmpeg_log" >&2
    exit 1
  fi
  echo "OK: vtremote_transcode $name completed"
}

run_case packet-ack 5
run_case legacy-eof 1 --capabilities h264,hevc,pixfmt.nv12,pixfmt.p010
echo "Logs at $RUN_DIR"
