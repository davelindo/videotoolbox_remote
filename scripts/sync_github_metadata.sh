#!/usr/bin/env bash
set -euo pipefail

repo="${1:-${REPO_SLUG:-davelindo/videotoolbox_remote}}"
description="Remote VideoToolbox for FFmpeg: use a Mac or Apple Silicon system over LAN as an IP-based H.264/HEVC encode/decode/transcoding accelerator."
homepage="${HOMEPAGE_URL:-https://davelindo.github.io/videotoolbox_remote/}"
topics=(
  videotoolbox
  ffmpeg
  transcoding
  hardware-acceleration
  apple-silicon
  macos
  video-encoding
  hevc
  h264
)

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI not found" >&2
  exit 1
fi

args=(repo edit "${repo}" --description "${description}" --homepage "${homepage}")
for topic in "${topics[@]}"; do
  args+=(--add-topic "${topic}")
done

gh "${args[@]}"
gh api "repos/${repo}" --jq '{description: .description, homepage: .homepage, topics: .topics}'
