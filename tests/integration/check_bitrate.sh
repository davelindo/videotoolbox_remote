#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <output_file> <target_bps> [tolerance_fraction]" >&2
  echo "example: $0 /tmp/out.mp4 1000000 0.35" >&2
  echo "env: FFPROBE overrides ffprobe path (default ../ffmpeg/ffprobe)" >&2
  exit 1
fi

OUT="$1"
TARGET_BPS="$2"
TOL="${3:-0.25}"

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

DUR=$("$FFPROBE_BIN" -v error -show_entries format=duration -of default=nk=1:nw=1 "$OUT")
if [[ -z "$DUR" || "$DUR" == "N/A" ]]; then
  echo "failed to read duration from ffprobe" >&2
  exit 1
fi

BYTES=$(wc -c < "$OUT" | tr -d ' ')
if [[ -z "$BYTES" ]]; then
  echo "failed to read size for $OUT" >&2
  exit 1
fi

ACTUAL_BPS=$(python3 - <<PY
dur = float("$DUR")
bytes_ = int("$BYTES")
print(int(bytes_ * 8 / dur)) if dur > 0 else print(0)
PY
)

LOW=$(python3 - <<PY
target = float("$TARGET_BPS")
tol = float("$TOL")
print(int(target * (1.0 - tol)))
PY
)

HIGH=$(python3 - <<PY
target = float("$TARGET_BPS")
tol = float("$TOL")
print(int(target * (1.0 + tol)))
PY
)

if (( ACTUAL_BPS < LOW || ACTUAL_BPS > HIGH )); then
  echo "bitrate out of range: actual=${ACTUAL_BPS}bps expected=${TARGET_BPS}bps tol=${TOL}" >&2
  exit 1
fi
