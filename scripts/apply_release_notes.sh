#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: bash scripts/apply_release_notes.sh <tag|--all> [owner/repo]" >&2
  exit 1
fi

target="$1"
repo="${2:-${REPO_SLUG:-${GITHUB_REPOSITORY:-davelindo/videotoolbox_remote}}}"

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI not found" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "${repo_root}"

apply_tag() {
  local tag="$1"
  local note_file
  note_file="$(mktemp)"
  bash scripts/generate_release_notes.sh "${tag}" "${note_file}"
  gh release edit "${tag}" -R "${repo}" --notes-file "${note_file}"
  rm -f "${note_file}"
}

if [[ "${target}" == "--all" ]]; then
  while IFS= read -r tag; do
    if [[ -n "${tag}" ]]; then
      apply_tag "${tag}"
    fi
  done < <(gh api "repos/${repo}/releases" --paginate --jq '.[].tag_name')
else
  apply_tag "${target}"
fi
