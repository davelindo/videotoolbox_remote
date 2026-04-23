#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
release_script="${repo_root}/scripts/next_patch_release.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

cd "${tmpdir}"
git init -q -b main
git config user.name "Codex"
git config user.email "codex@example.com"

printf 'base\n' > README.md
git add README.md
git commit -q -m "base"

git tag nightly
git tag vfoo
git tag v0.3.03
git tag v0.2.10
git tag v0.3.1
git tag v0.3.2

actual="$(bash "${release_script}")"
expected="v0.3.3"

if [[ "${actual}" != "${expected}" ]]; then
  echo "expected ${expected}, got ${actual}" >&2
  exit 1
fi

git tag v1.2.9

actual="$(bash "${release_script}")"
expected="v1.2.10"

if [[ "${actual}" != "${expected}" ]]; then
  echo "expected ${expected}, got ${actual}" >&2
  exit 1
fi

tmpdir_no_tags="$(mktemp -d)"
trap 'rm -rf "${tmpdir}" "${tmpdir_no_tags}"' EXIT

cd "${tmpdir_no_tags}"
git init -q -b main
git config user.name "Codex"
git config user.email "codex@example.com"

printf 'base\n' > README.md
git add README.md
git commit -q -m "base"
git tag nightly
git tag vfoo

if bash "${release_script}" >/tmp/next_patch_no_tags.out 2>/tmp/next_patch_no_tags.err; then
  echo "expected next patch script to reject repositories without semantic version tags" >&2
  exit 1
fi

echo "ok"
