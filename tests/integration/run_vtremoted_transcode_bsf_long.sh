#!/usr/bin/env bash
set -euo pipefail

# Long-run integration test for the vtremote_transcode bitstream filter against a real vtremoted.
#
# This is meant to catch timestamp/ordering bugs that only surface after many frames. It:
# 1) Generates a long CFR H.264 source (libx264) with B-frames.
# 2) Transcodes it remotely via vtremote_transcode to HEVC (or H.264) using vtremoted.
# 3) Validates:
#    - strict monotonic DTS (muxer requirement)
#    - packet count preserved (no silent drops)
#    - duration + reported FPS sane (guards against timestamp corruption)
#    - decode clean with -xerror (bitstream correctness)
#
# By default this runs for 10 minutes; keep it out of run_all unless explicitly enabled.
#
# Env:
#   VTREMOTE_LONG_DURATION_S       seconds (default 600)
#   VTREMOTE_LONG_RATE             fps (default 24)
#   VTREMOTE_LONG_SIZE             WxH (default 640x360)
#   VTREMOTE_LONG_GOP              frames (default 48)
#   VTREMOTE_LONG_BFRAMES          frames (default 3)
#   VTREMOTE_LONG_IN_BITRATE       ffmpeg bitrate string for input (default 1200k)
#   VTREMOTE_LONG_OUT_BITRATE_BPS  integer bps for remote output (default 1200000)
#   VTREMOTE_LONG_OUT_CODEC        h264|hevc (default hevc)
#   VTREMOTE_KEEP_OUTPUT           keep tmp dir on success (default 0)
#
# Remote server selection:
#   VTREMOTE_USE_EXISTING=1 VTREMOTE_HOST=192.168.5.55 VTREMOTE_PORT=5555
#   (otherwise we start VTREMOTED locally on loopback)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG_BIN:-${FFMPEG:-${ROOT}/ffmpeg/ffmpeg}}"
FFPROBE_BIN="${FFPROBE_BIN:-${FFPROBE:-${ROOT}/ffmpeg/ffprobe}}"
VTREMOTED_BIN="${VTREMOTED:-${ROOT}/vtremoted/.build/debug/vtremoted}"
source "${ROOT}/tests/integration/vtremoted_common.sh"

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ffmpeg not found at $FFMPEG_BIN (override with FFMPEG_BIN/FFMPEG)" >&2
  exit 1
fi
if [[ ! -x "$FFPROBE_BIN" ]]; then
  echo "ffprobe not found at $FFPROBE_BIN (override with FFPROBE_BIN/FFPROBE)" >&2
  exit 1
fi

USE_EXISTING="${VTREMOTE_USE_EXISTING:-}"
TOKEN="${VTREMOTE_TOKEN:-}"

LONG_DURATION_S="${VTREMOTE_LONG_DURATION_S:-600}"
LONG_RATE="${VTREMOTE_LONG_RATE:-24}"
LONG_SIZE="${VTREMOTE_LONG_SIZE:-640x360}"
LONG_GOP="${VTREMOTE_LONG_GOP:-48}"
LONG_BFRAMES="${VTREMOTE_LONG_BFRAMES:-3}"
IN_BITRATE="${VTREMOTE_LONG_IN_BITRATE:-1200k}"
OUT_BITRATE_BPS="${VTREMOTE_LONG_OUT_BITRATE_BPS:-1200000}"
OUT_CODEC="${VTREMOTE_LONG_OUT_CODEC:-hevc}"
KEEP_OUTPUT="${VTREMOTE_KEEP_OUTPUT:-0}"

RUN_DIR="$(mktemp -d /tmp/vtremote_long_transcode.XXXXXX)"
IN_H264="${RUN_DIR}/input_h264.mkv"
OUT_FILE="${RUN_DIR}/out_${OUT_CODEC}.mkv"
SERVER_PID=""

cleanup() {
  local exit_code=$?
  vtremote_stop_server
  if [[ "$KEEP_OUTPUT" != "0" || "$exit_code" != "0" ]]; then
    echo "KEEP: outputs preserved (exit_code=${exit_code}):"
    echo "  ${RUN_DIR}"
    echo "  ${IN_H264}"
    echo "  ${OUT_FILE}"
  else
    rm -rf "$RUN_DIR"
  fi
}
trap cleanup EXIT

echo "Generating input (${LONG_DURATION_S}s @ ${LONG_RATE}fps, ${LONG_SIZE})..."
"$FFMPEG_BIN" -hide_banner -v error -y \
  -f lavfi -i "testsrc2=size=${LONG_SIZE}:rate=${LONG_RATE}:duration=${LONG_DURATION_S}" \
  -pix_fmt yuv420p \
  -c:v libx264 -preset veryfast -b:v "$IN_BITRATE" -maxrate "$IN_BITRATE" -bufsize "$IN_BITRATE" \
  -g "$LONG_GOP" -bf "$LONG_BFRAMES" \
  -x264-params "scenecut=0" \
  -an -sn -dn "$IN_H264"

if [[ -z "$USE_EXISTING" ]]; then
  if [[ ! -x "$VTREMOTED_BIN" ]]; then
    echo "vtremoted not found at $VTREMOTED_BIN (build it or set VTREMOTED)" >&2
    exit 1
  fi
  VTREMOTED="$VTREMOTED_BIN"
  VTREMOTE_TOKEN="$TOKEN"
  echo "Starting vtremoted on 127.0.0.1:${VTREMOTE_PORT:-<auto>}..."
  vtremote_start_server /tmp/vtremoted_long_transcode.log
  SERVER_PID="${VTREMOTE_SERVER_PID:-}"
  echo "Using vtremoted on ${VTREMOTE_HOST}:${VTREMOTE_PORT} (pid=${SERVER_PID})"
else
  # Use VTREMOTE_HOST/VTREMOTE_PORT as the remote daemon location.
  VTREMOTE_HOST="${VTREMOTE_HOST:-127.0.0.1}"
  VTREMOTE_PORT="${VTREMOTE_PORT:-5555}"
  echo "Using existing vtremoted on ${VTREMOTE_HOST}:${VTREMOTE_PORT}"
fi

# Note: BSF options use ':' as the key/value separator. Don't embed ':port' inside vt_remote_host or
# FFmpeg will try to parse the port number as the next option name.
BSF_ARGS="vtremote_transcode=vt_remote_host=${VTREMOTE_HOST}:vt_remote_port=${VTREMOTE_PORT}:vt_remote_out_codec=${OUT_CODEC}:vt_remote_bitrate=${OUT_BITRATE_BPS}:vt_remote_gop=${LONG_GOP}:vt_remote_max_b_frames=${LONG_BFRAMES}:vt_remote_inflight=16:vt_remote_timeout_ms=10000"
if [[ -n "$TOKEN" ]]; then
  BSF_ARGS="${BSF_ARGS}:vt_remote_token=${TOKEN}"
fi

echo "Transcoding via vtremote_transcode (out=${OUT_CODEC})..."
"$FFMPEG_BIN" -hide_banner -v warning -y \
  -i "$IN_H264" -map 0:v:0 -c:v copy \
  -bsf:v "$BSF_ARGS" \
  -an -sn -dn "$OUT_FILE" >/tmp/vtremote_long_transcode_ffmpeg.log 2>&1

echo "Checking transcode log for timestamp warnings..."
if grep -qiE "Invalid DTS:|Non-monotonic DTS|non monotonically increasing dts" /tmp/vtremote_long_transcode_ffmpeg.log; then
  echo "ERROR: ffmpeg reported timestamp problems during muxing; see /tmp/vtremote_long_transcode_ffmpeg.log" >&2
  grep -niE "Invalid DTS:|Non-monotonic DTS|non monotonically increasing dts" /tmp/vtremote_long_transcode_ffmpeg.log | head -n 50 >&2 || true
  exit 1
fi

echo "Checking DTS monotonicity..."
"$ROOT/tests/integration/check_pts_dts.sh" "$OUT_FILE" "$LONG_GOP"

echo "Checking decoded frame timestamp deltas (presentation order)..."
python3 - <<PY
import subprocess

ffprobe = "$FFPROBE_BIN"
path = "$OUT_FILE"
rate_s = "$LONG_RATE"
dur_s = float("$LONG_DURATION_S")

def parse_rate(s: str) -> float:
    s = s.strip()
    if "/" in s:
        num, den = s.split("/", 1)
        return float(num) / float(den)
    return float(s)

rate = parse_rate(rate_s)
frame_dur = 1.0 / rate if rate > 0 else 0.0
if frame_dur <= 0:
    raise SystemExit("invalid rate")

start = min(max(0.0, dur_s * 0.5), max(0.0, dur_s - 2.0))
interval = f"{start}%+2"

cmd = [
    ffprobe, "-v", "error", "-select_streams", "v:0",
    "-read_intervals", interval,
    "-show_frames",
    "-show_entries", "frame=best_effort_timestamp_time",
    "-of", "csv=p=0",
    path,
]
txt = subprocess.check_output(cmd, text=True)
times = []
for line in txt.splitlines():
    line = line.strip()
    if not line or line == "N/A":
        continue
    times.append(float(line))

if len(times) < 10:
    raise RuntimeError(f"not enough decoded frames for delta check (got {len(times)})")

deltas = [b - a for a, b in zip(times, times[1:])]
min_d = min(deltas)
max_d = max(deltas)
small = sum(1 for d in deltas if d < 0.0015)
huge = sum(1 for d in deltas if d > frame_dur * 1.75)

if small or huge:
    raise RuntimeError(
        f"bad frame timestamp deltas around t~{start:.1f}s: "
        f"min={min_d:.6f} max={max_d:.6f} small<{0.0015}s={small} huge>{frame_dur*1.75:.6f}s={huge}"
    )

print(f"frame_delta_ok sample_start_s={start:.1f} frames={len(times)} min_delta={min_d:.6f} max_delta={max_d:.6f}")
PY

echo "Checking packet count + duration + reported fps..."
python3 - <<PY
import json, subprocess, sys

ffprobe = "$FFPROBE_BIN"
in_path = "$IN_H264"
out_path = "$OUT_FILE"
rate_expected = float("$LONG_RATE")

def probe(path: str):
    cmd = [
        ffprobe, "-v", "error", "-select_streams", "v:0",
        "-count_packets",
        "-show_entries", "stream=nb_read_packets,avg_frame_rate,r_frame_rate,time_base,start_time,duration",
        "-show_entries", "format=duration",
        "-of", "json", path,
    ]
    data = json.loads(subprocess.check_output(cmd))
    streams = data.get("streams") or []
    if not streams:
        raise RuntimeError(f"no video stream: {path}")
    s = streams[0]
    fmt = data.get("format") or {}
    def f(x):
        try: return float(x)
        except Exception: return None
    def i(x):
        try: return int(x)
        except Exception: return None
    def rate(r):
        if not r or r == "0/0": return None
        if "/" in r:
            num, den = r.split("/", 1)
            try:
                num = float(num); den = float(den)
                return num / den if den else None
            except Exception:
                return None
        return f(r)
    return {
        "packets": i(s.get("nb_read_packets")),
        "avg_fps": rate(s.get("avg_frame_rate")),
        "r_fps": rate(s.get("r_frame_rate")),
        "fmt_dur": f(fmt.get("duration")),
    }

pin = probe(in_path)
pout = probe(out_path)

if pin["packets"] is None or pout["packets"] is None:
    raise RuntimeError(f"missing packet counts: in={pin} out={pout}")
if pout["packets"] != pin["packets"]:
    raise RuntimeError(f"packet count changed: in={pin['packets']} out={pout['packets']}")

def near(a, b, tol):
    return a is not None and b is not None and abs(a - b) <= tol

dur_in = pin["fmt_dur"]
dur_out = pout["fmt_dur"]
if dur_in is not None and dur_out is not None:
    # Matroska duration is float; allow small container rounding drift.
    if abs(dur_in - dur_out) > 0.25:
        raise RuntimeError(f"duration mismatch: in={dur_in:.3f}s out={dur_out:.3f}s")

avg = pout["avg_fps"]
rfps = pout["r_fps"]
if avg is not None and abs(avg - rate_expected) > 0.1:
    raise RuntimeError(f"avg_frame_rate looks wrong: {avg} (expected ~{rate_expected})")
if rfps is not None and abs(rfps - rate_expected) > 0.1:
    raise RuntimeError(f"r_frame_rate looks wrong: {rfps} (expected ~{rate_expected})")

print(f"in_packets={pin['packets']} out_packets={pout['packets']} out_avg_fps={avg} out_r_fps={rfps} in_dur={dur_in} out_dur={dur_out}")
PY

echo "Verifying decode clean with -xerror..."
VERIFY_LOG="${RUN_DIR}/verify_decode.stderr"
if ! "$FFMPEG_BIN" -hide_banner -v error -xerror -err_detect explode -i "$OUT_FILE" -f null - >/dev/null 2>"$VERIFY_LOG"; then
  echo "ERROR: verification decode failed" >&2
  cat "$VERIFY_LOG" >&2 || true
  exit 1
fi
if [[ -s "$VERIFY_LOG" ]]; then
  echo "ERROR: verification produced decoder errors:" >&2
  cat "$VERIFY_LOG" >&2 || true
  exit 1
fi

echo "OK: long vtremote_transcode test passed; logs at /tmp/vtremote_long_transcode_ffmpeg.log"
