#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
semver_script="${repo_root}/scripts/is_semver_tag.sh"

for tag in v0.3.3 v1.0.0 v10.20.30; do
  if ! bash "${semver_script}" "${tag}"; then
    echo "expected ${tag} to be accepted" >&2
    exit 1
  fi
done

for tag in nightly nightly-main vfoo v0.3 v0.3.3-rc1 v01.3.3 v0.03.3 v0.3.03; do
  if bash "${semver_script}" "${tag}"; then
    echo "expected ${tag} to be rejected" >&2
    exit 1
  fi
done

echo "ok"
