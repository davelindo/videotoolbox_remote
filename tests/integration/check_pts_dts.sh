#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <output_file> [expected_gop_frames]" >&2
  echo "env: FFPROBE overrides ffprobe path (default ../ffmpeg/ffprobe)" >&2
  exit 1
fi

OUT="$1"
EXPECTED_GOP="${2:-0}"
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

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

"$FFPROBE_BIN" -v error -select_streams v:0 \
  -show_entries packet=pts_time,dts_time,flags \
  -of csv=p=0 "$OUT" > "$TMP"

awk -F, -v gop="$EXPECTED_GOP" '
BEGIN { err=0; have_lastdts=0; lastdts=0; lastk=-1; gaps=0; totalGap=0 }
{
  pts=$1; dts=$2; flags=$3;

  # ffprobe prints "N/A" when a timestamp is not set.
  pts_na = (pts == "N/A" || pts == "");
  dts_na = (dts == "N/A" || dts == "");
  if (!pts_na) pts_v = pts + 0;
  if (!dts_na) dts_v = dts + 0;

  # DTS must not be greater than PTS when both are known; ffmpeg muxer logs
  # "Invalid DTS: ... PTS: ..." and rewrites timestamps when dts > pts.
  if (!pts_na && !dts_na && dts_v > pts_v + 1e-6) {
    err++;
    printf("invalid dts>pts at packet %d: dts=%s pts=%s\n", NR, dts, pts) > "/dev/stderr"
  }

  # Check for strict monotonicity (dts must be > lastdts, not just >=) once DTS exists.
  # Some streams legitimately omit DTS for early packets.
  if (!dts_na) {
    if (have_lastdts && dts_v < lastdts + 1e-6) {
      err++;
      printf("non-monotonic dts at packet %d: %s <= %s\n", NR, dts, lastdts) > "/dev/stderr"
    }
    lastdts = dts_v;
    have_lastdts = 1;
  }

  iskey = index(flags, "K") ? 1 : 0;
  if (iskey) {
    if (lastk >= 0) { gap = NR - lastk; gaps++; totalGap += gap; }
    lastk = NR;
  }
}
END {
  if (lastk < 0) { printf("no keyframes found\n") > "/dev/stderr"; exit 1 }
  if (err > 0) exit 1
  if (gop > 0 && gaps > 0) {
    avg = totalGap / gaps;
    if (avg < gop*0.8 || avg > gop*1.2) {
      printf("average keyframe interval %.2f deviates from expected %d\n", avg, gop) > "/dev/stderr";
      exit 1;
    }
  }
}
' "$TMP"
