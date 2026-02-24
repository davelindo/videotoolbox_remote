#!/usr/bin/env bash
set -euo pipefail

# Compare local VideoToolbox encoder option surface vs remote encoders.
# Remote-only transport options (vt_remote_*) are ignored.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG_BIN:-${ROOT}/ffmpeg/ffmpeg}"

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "ERROR: ffmpeg binary not found/executable: $FFMPEG_BIN"
  exit 1
fi

encoder_exists() {
  local enc="$1"
  "$FFMPEG_BIN" -hide_banner -h "encoder=${enc}" >/dev/null 2>&1
}

extract_opts() {
  local enc="$1"
  "$FFMPEG_BIN" -hide_banner -h "encoder=${enc}" 2>/dev/null \
    | awk '/^  -/{print $1}' \
    | sed 's/^-//' \
    | sort -u
}

compare_pair() {
  local local_enc="$1"
  local remote_enc="$2"
  local local_file="$3"
  local remote_file="$4"

  extract_opts "$local_enc" >"$local_file"
  extract_opts "$remote_enc" >"$remote_file"

  local local_only
  local remote_only
  local_only="$(comm -23 "$local_file" "$remote_file" || true)"
  remote_only="$(comm -13 "$local_file" "$remote_file" | grep -Ev '^vt_remote_' || true)"

  if [[ -n "$local_only" || -n "$remote_only" ]]; then
    echo "FAIL: option parity mismatch: ${local_enc} vs ${remote_enc}"
    if [[ -n "$local_only" ]]; then
      echo "  Missing on remote:"
      while IFS= read -r opt; do
        [[ -n "$opt" ]] && echo "    - $opt"
      done <<<"$local_only"
    fi
    if [[ -n "$remote_only" ]]; then
      echo "  Unexpected remote-only (non transport) options:"
      while IFS= read -r opt; do
        [[ -n "$opt" ]] && echo "    - $opt"
      done <<<"$remote_only"
    fi
    return 1
  fi

  echo "OK: option parity ${local_enc} == ${remote_enc} (excluding vt_remote_*)"
  return 0
}

tmpdir="$(mktemp -d /tmp/vtremote_opt_parity.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

pairs=(
  "h264_videotoolbox h264_videotoolbox_remote"
  "hevc_videotoolbox hevc_videotoolbox_remote"
)

checked=0
failures=0

for pair in "${pairs[@]}"; do
  local_enc="${pair%% *}"
  remote_enc="${pair##* }"

  if ! encoder_exists "$remote_enc"; then
    echo "ERROR: remote encoder unavailable: $remote_enc"
    failures=$((failures + 1))
    continue
  fi

  if ! encoder_exists "$local_enc"; then
    echo "SKIP: local encoder unavailable on this host: $local_enc"
    continue
  fi

  checked=$((checked + 1))
  if ! compare_pair "$local_enc" "$remote_enc" \
    "$tmpdir/${local_enc}.opts" "$tmpdir/${remote_enc}.opts"; then
    failures=$((failures + 1))
  fi
done

if [[ "$checked" -eq 0 ]]; then
  echo "SKIP: no local VideoToolbox encoders available; parity check not applicable."
  exit 0
fi

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi

echo "OK: option surface parity checks passed"
