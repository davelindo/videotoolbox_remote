#!/usr/bin/env bash
set -euo pipefail

# Match git subtree's search: the first record wins, even if older records
# would be valid. A repository merge must never masquerade as an upstream root.
record="$(git log "${1:-HEAD}" --grep='^git-subtree-dir: ffmpeg/*$' --format=%H -n1)"
if [[ -z "${record}" ]]; then
  echo "ERROR: no FFmpeg subtree record found" >&2
  exit 1
fi
parents="$(git show -s --format=%P "${record}")"
if [[ "${parents}" == *' '* ]]; then
  echo "ERROR: FFmpeg subtree record ${record} is a merge commit; tracking trailers belong on the upstream squash commit" >&2
  exit 1
fi
split="$(git show -s --format=%B "${record}" | sed -n 's/^git-subtree-split: //p')"
if [[ ! "${split}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: FFmpeg subtree record ${record} has no unique valid split" >&2
  exit 1
fi
if ! git cat-file -e "${record}:configure" 2>/dev/null ||
   [[ "$(git cat-file -t "${record}:libavcodec" 2>/dev/null || true)" != tree ]]; then
  echo "ERROR: FFmpeg subtree record ${record} does not contain an upstream FFmpeg root" >&2
  exit 1
fi
printf '%s\n' "${record}"
