#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 ffmpeg|vtremoted ARTIFACT.tar.gz

Unpacks a packaged release artifact and verifies the expected executable and
feature surface are present. This intentionally tests the tarball contents,
not the build directory.
EOF
}

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 1
fi

kind="$1"
artifact="$2"

if [[ ! -f "$artifact" ]]; then
  echo "artifact not found: $artifact" >&2
  exit 1
fi

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/vtremote-artifact-smoke.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

tar_args=(-xzf "$artifact" -C "$tmpdir")
if tar --help 2>&1 | grep -q -- '--no-same-owner'; then
  tar_args=(--no-same-owner --no-same-permissions "${tar_args[@]}")
fi
tar "${tar_args[@]}"

grep_feature() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  if ! grep -Eq "$pattern" "$file"; then
    echo "missing $label in $artifact" >&2
    cat "$file" >&2
    exit 1
  fi
}

case "$kind" in
  ffmpeg)
    ffmpeg_bin=""
    if [[ -x "$tmpdir/ffmpeg" ]]; then
      ffmpeg_bin="$tmpdir/ffmpeg"
    elif [[ -x "$tmpdir/ffmpeg.exe" ]]; then
      ffmpeg_bin="$tmpdir/ffmpeg.exe"
    else
      echo "ffmpeg executable not found in $artifact" >&2
      find "$tmpdir" -maxdepth 2 -type f -print >&2
      exit 1
    fi

    "$ffmpeg_bin" -hide_banner -version >/dev/null
    "$ffmpeg_bin" -hide_banner -filters >"$tmpdir/filters.txt"
    "$ffmpeg_bin" -hide_banner -encoders >"$tmpdir/encoders.txt"
    "$ffmpeg_bin" -hide_banner -decoders >"$tmpdir/decoders.txt"
    "$ffmpeg_bin" -hide_banner -bsfs >"$tmpdir/bsfs.txt"

    grep_feature "psnr filter" '(^|[[:space:]])psnr([[:space:]]|$)' "$tmpdir/filters.txt"
    grep_feature "ssim filter" '(^|[[:space:]])ssim([[:space:]]|$)' "$tmpdir/filters.txt"
    grep_feature "libvmaf filter" '(^|[[:space:]])libvmaf([[:space:]]|$)' "$tmpdir/filters.txt"
    grep_feature "h264_videotoolbox_remote encoder" '(^|[[:space:]])h264_videotoolbox_remote([[:space:]]|$)' "$tmpdir/encoders.txt"
    grep_feature "hevc_videotoolbox_remote encoder" '(^|[[:space:]])hevc_videotoolbox_remote([[:space:]]|$)' "$tmpdir/encoders.txt"
    grep_feature "h264_videotoolbox_remote decoder" '(^|[[:space:]])h264_videotoolbox_remote([[:space:]]|$)' "$tmpdir/decoders.txt"
    grep_feature "hevc_videotoolbox_remote decoder" '(^|[[:space:]])hevc_videotoolbox_remote([[:space:]]|$)' "$tmpdir/decoders.txt"
    grep_feature "vtremote_transcode bsf" '(^|[[:space:]])vtremote_transcode([[:space:]]|$)' "$tmpdir/bsfs.txt"
    ;;

  vtremoted)
    vtremoted_bin="$tmpdir/vtremoted/vtremoted"
    if [[ ! -x "$vtremoted_bin" ]]; then
      echo "vtremoted executable not found in $artifact" >&2
      find "$tmpdir" -maxdepth 3 -type f -print >&2
      exit 1
    fi

    "$vtremoted_bin" --version | grep -Eq '^vtremoted [0-9]+\.[0-9]+\.[0-9]+'
    "$vtremoted_bin" --help | grep -q -- '--listen HOST:PORT'
    ;;

  *)
    usage >&2
    exit 1
    ;;
esac

echo "OK: $kind artifact smoke passed for $artifact"
