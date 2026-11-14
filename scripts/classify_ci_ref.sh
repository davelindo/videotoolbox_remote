#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
event="${GITHUB_EVENT_NAME:?}"
ref="${GITHUB_REF:?}"
sha="${GITHUB_SHA:?}"
semver_tag=false
release_candidate=false
tagged_sync=false

if [[ "$ref" == refs/tags/* ]] && bash "$script_dir/is_semver_tag.sh" "${ref#refs/tags/}"; then
  semver_tag=true
fi
if [[ "$ref" == refs/heads/automation/ffmpeg-sync/* ]]; then
  release_candidate=true
fi

# Promotion atomically pushes main and its release tag after candidate CI.
# The tag runs the full release matrix; the identical main push needs no copy.
if [[ "$event" == push && "$ref" == refs/heads/main ]]; then
  if metadata="$(bash "$script_dir/parse_ffmpeg_sync_commit.sh" "$sha" 2>/dev/null)"; then
    target_tag="$(printf '%s\n' "$metadata" | sed -n 's/^target_tag=//p')"
    tagged_sha="$(git rev-parse -q --verify "refs/tags/${target_tag}^{commit}" 2>/dev/null || true)"
    if [[ "$tagged_sha" == "$sha" ]]; then
      tagged_sync=true
    fi
  fi
fi

printf 'semver_tag=%s\n' "$semver_tag"
printf 'release_candidate=%s\n' "$release_candidate"
printf 'tagged_sync=%s\n' "$tagged_sync"
