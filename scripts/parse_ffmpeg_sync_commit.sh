#!/usr/bin/env bash
set -euo pipefail

commit_ref="${1:-HEAD}"
subject="$(git show -s --format=%s "${commit_ref}")"

if [[ ! "${subject}" =~ ^ffmpeg-sync:\ update\ subtree\ to\ ([0-9a-f]{12})\ for\ (v[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  echo "ERROR: unexpected ffmpeg sync commit subject: ${subject}" >&2
  exit 1
fi

upstream_commit="${BASH_REMATCH[1]}"
target_tag="${BASH_REMATCH[2]}"
body="$(git show -s --format=%B "${commit_ref}")"
sync_run_id="$(printf '%s\n' "${body}" | sed -n 's/^FFmpeg-Sync-Run-ID: //p' | tail -n1)"
sync_tag="$(printf '%s\n' "${body}" | sed -n 's/^FFmpeg-Sync-Tag: //p' | tail -n1)"
base_sha="$(printf '%s\n' "${body}" | sed -n 's/^FFmpeg-Sync-Base-SHA: //p' | tail -n1)"

if [[ ! "${sync_run_id}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: missing or invalid FFmpeg-Sync-Run-ID trailer" >&2
  exit 1
fi

if [[ "${sync_tag}" != "${target_tag}" ]]; then
  echo "ERROR: FFmpeg-Sync-Tag trailer mismatch: expected ${target_tag}, got ${sync_tag:-<missing>}" >&2
  exit 1
fi

if [[ ! "${base_sha}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: missing or invalid FFmpeg-Sync-Base-SHA trailer" >&2
  exit 1
fi

cat <<EOF
upstream_commit=${upstream_commit}
target_tag=${target_tag}
sync_run_id=${sync_run_id}
base_sha=${base_sha}
EOF
