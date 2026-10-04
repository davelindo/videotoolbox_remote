#!/usr/bin/env bash
set -euo pipefail

repo="${1:-${REPO_SLUG:-davelindo/videotoolbox_remote}}"
description="High-quality, low-power H.264/HEVC transcoding over LAN. Keep Plex on Linux and use a Mac's VideoToolbox hardware for FFmpeg, VA-API and OBS encoding."
homepage="${HOMEPAGE_URL:-https://davelindo.github.io/videotoolbox_remote/}"
topics=(
  videotoolbox
  ffmpeg
  transcoding
  video-transcoding
  hardware-acceleration
  hardware-encoding
  apple-silicon
  macos
  media-server
  self-hosted
  homelab
  video-processing
  video-encoding
  hevc
  h264
  h265
  lan
  plex
  vaapi
  obs-studio
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
