#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
classifier="$repo_root/scripts/classify_ci_ref.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
cd "$tmpdir"
git init -q -b main
git config user.name 'Test User'
git config user.email 'test@users.noreply.github.com'
git config commit.gpgsign false
git config tag.gpgsign false
git config core.hooksPath "$tmpdir/hooks"
git commit -q --allow-empty -m 'ordinary change'
base="$(git rev-parse HEAD)"

check() {
  local event=$1 ref=$2 sha=$3 expected=$4 output
  output="$(GITHUB_EVENT_NAME="$event" GITHUB_REF="$ref" GITHUB_SHA="$sha" bash "$classifier")"
  if [[ "$output" != "$expected" ]]; then
    printf 'Unexpected classification for %s %s:\n%s\n' "$event" "$ref" "$output" >&2
    exit 1
  fi
}

ordinary=$'semver_tag=false\nrelease_candidate=false\ntagged_sync=false'
tag=$'semver_tag=true\nrelease_candidate=false\ntagged_sync=false'
candidate=$'semver_tag=false\nrelease_candidate=true\ntagged_sync=false'
promoted=$'semver_tag=false\nrelease_candidate=false\ntagged_sync=true'

check push refs/heads/main "$base" "$ordinary"
check push refs/tags/v1.2.3 "$base" "$tag"
check push refs/tags/nightly "$base" "$ordinary"
check push refs/heads/automation/ffmpeg-sync/v1.2.3-123 "$base" "$candidate"

git commit -q --allow-empty -m 'ffmpeg-sync: update subtree to 123456789abc for v1.2.3' \
  -m "FFmpeg-Sync-Run-ID: 123
FFmpeg-Sync-Tag: v1.2.3
FFmpeg-Sync-Base-SHA: $base"
sync="$(git rev-parse HEAD)"
check push refs/heads/main "$sync" "$ordinary"
git tag -a v1.2.3 "$base" -m 'wrong target'
check push refs/heads/main "$sync" "$ordinary"
git tag -d v1.2.3 >/dev/null
git tag -a v1.2.3 "$sync" -m 'release'
check push refs/heads/main "$sync" "$promoted"
check push refs/tags/v1.2.3 "$sync" "$tag"
check pull_request refs/pull/1/merge "$sync" "$ordinary"
check workflow_dispatch refs/heads/main "$sync" "$ordinary"
check schedule refs/heads/main "$sync" "$ordinary"
git tag -d v1.2.3 >/dev/null
git tag v1.2.3 "$sync"
check push refs/heads/main "$sync" "$promoted"
git commit -q --allow-empty -m 'ordinary tagged change'
ordinary_sha="$(git rev-parse HEAD)"
git tag v1.2.4 "$ordinary_sha"
check push refs/heads/main "$ordinary_sha" "$ordinary"

echo 'ok: tagged sync main pushes defer to release CI; other events retain validation'
