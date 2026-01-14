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
BEGIN { err=0; lastdts=-1; lastk=-1; gaps=0; totalGap=0 }
{
  pts=$1; dts=$2; flags=$3;
  if (dts > pts + 1e-6) { err++; printf("pts<dts at packet %d: pts=%s dts=%s\n", NR, pts, dts) > "/dev/stderr" }
  # Check for strict monotonicity (dts must be > lastdts, not just >=)
  # FFmpeg warns "Non-monotonic DTS" when dts <= previous dts
  if (lastdts >= 0 && dts < lastdts + 1e-6) { err++; printf("non-monotonic dts at packet %d: %s <= %s\n", NR, dts, lastdts) > "/dev/stderr" }
  lastdts = dts;
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
