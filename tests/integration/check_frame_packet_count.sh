#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <output_file>" >&2
  echo "env: FFPROBE overrides ffprobe path (default ../ffmpeg/ffprobe)" >&2
  exit 1
fi

OUT="$1"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFPROBE_BIN="${FFPROBE:-${REPO_ROOT}/ffmpeg/ffprobe}"

if [[ ! -x "$FFPROBE_BIN" ]]; then
  if command -v ffprobe >/dev/null 2>&1; then
    FFPROBE_BIN="$(command -v ffprobe)"
  else
    echo "ffprobe not found/executable at $FFPROBE_BIN (override with FFPROBE)" >&2
    exit 1
  fi
fi

python3 - <<PY
import json, subprocess, sys

ffprobe = "$FFPROBE_BIN"
out = "$OUT"

cmd = [
    ffprobe, "-v", "error", "-select_streams", "v:0",
    "-count_packets",
    "-show_entries", "stream=nb_read_packets,nb_frames,avg_frame_rate,duration",
    "-of", "json", out,
]
try:
    data = json.loads(subprocess.check_output(cmd))
except Exception as e:
    print(f"failed to read frame/packet counts from ffprobe: {e}", file=sys.stderr)
    sys.exit(1)

streams = data.get("streams") or []
if not streams:
    print("no video stream found", file=sys.stderr)
    sys.exit(1)

s = streams[0]
nb_packets = s.get("nb_read_packets")
nb_frames = s.get("nb_frames")
duration = s.get("duration")
avg = s.get("avg_frame_rate")

def to_int(val):
    try:
        return int(val)
    except Exception:
        return None

def to_float(val):
    try:
        return float(val)
    except Exception:
        return None

def parse_rate(r):
    if not r or r == "0/0":
        return None
    if "/" in r:
        num, den = r.split("/", 1)
        try:
            num = float(num); den = float(den)
            return num / den if den != 0 else None
        except Exception:
            return None
    try:
        return float(r)
    except Exception:
        return None

packets = to_int(nb_packets)
frames = to_int(nb_frames)
if packets is None:
    print("failed to read packet count from ffprobe", file=sys.stderr)
    sys.exit(1)

if frames is None or frames <= 0:
    dur = to_float(duration)
    fps = parse_rate(avg)
    if dur is None or fps is None:
        print("failed to derive expected frame count", file=sys.stderr)
        sys.exit(1)
    frames = int(round(dur * fps))

if frames != packets:
    print(f"frame/packet mismatch: frames={frames} packets={packets}", file=sys.stderr)
    sys.exit(1)
PY
