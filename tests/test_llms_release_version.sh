#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

latest_changelog_tag="$(
  awk '
    /^## \[v[0-9]+\.[0-9]+\.[0-9]+\]/ {
      tag=$2
      gsub(/^\[/, "", tag)
      gsub(/\]$/, "", tag)
      print tag
      exit
    }
  ' CHANGELOG.md
)"

llms_version="$(
  awk -F': ' '
    /^\*\*Version\*\*: / {
      print $2
      exit
    }
  ' docs/llms.txt
)"

config_version="$(
  awk -F': ' '
    /^current_release: / {
      value=$2
      gsub(/^["'\'']|["'\'']$/, "", value)
      print value
      exit
    }
  ' docs/_config.yml
)"

if [[ -z "${latest_changelog_tag}" ]]; then
  echo "ERROR: could not find latest semver release in CHANGELOG.md" >&2
  exit 1
fi

if [[ -z "${llms_version}" ]]; then
  echo "ERROR: could not find **Version** in docs/llms.txt" >&2
  exit 1
fi

if [[ -z "${config_version}" ]]; then
  echo "ERROR: could not find current_release in docs/_config.yml" >&2
  exit 1
fi

if [[ "${llms_version}" != "${latest_changelog_tag}" ]]; then
  echo "ERROR: docs/llms.txt version (${llms_version}) does not match latest CHANGELOG.md release (${latest_changelog_tag})" >&2
  exit 1
fi

if [[ "${config_version}" != "${latest_changelog_tag}" ]]; then
  echo "ERROR: docs/_config.yml current_release (${config_version}) does not match latest CHANGELOG.md release (${latest_changelog_tag})" >&2
  exit 1
fi

echo "docs release metadata matches ${latest_changelog_tag}"
