#!/usr/bin/env bash
set -euo pipefail

latest_tag="$(git tag --list 'v*' --sort=-version:refname | while IFS= read -r tag; do
  if bash "$(dirname "${BASH_SOURCE[0]}")/is_semver_tag.sh" "${tag}"; then
    printf '%s\n' "${tag}"
    break
  fi
done)"

if [[ -z "${latest_tag}" ]]; then
  echo "ERROR: no semantic version tag found" >&2
  exit 1
fi

if [[ ! "${latest_tag}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "ERROR: latest semantic version tag has unexpected format: ${latest_tag}" >&2
  exit 1
fi

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"

printf 'v%s.%s.%s\n' "${major}" "${minor}" "$((10#${patch} + 1))"
