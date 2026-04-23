#!/usr/bin/env bash
set -euo pipefail

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

upstream="${tmpdir}/upstream"
repo="${tmpdir}/repo"

git init -q -b master "${upstream}"
git -C "${upstream}" config user.name "Codex"
git -C "${upstream}" config user.email "codex@example.com"
printf 'one\n' > "${upstream}/codec.c"
git -C "${upstream}" add codec.c
git -C "${upstream}" commit -q -m "initial upstream"

git init -q -b main "${repo}"
git -C "${repo}" config user.name "Codex"
git -C "${repo}" config user.email "codex@example.com"
printf 'base\n' > "${repo}/README.md"
git -C "${repo}" add README.md
git -C "${repo}" commit -q -m "base"
git -C "${repo}" subtree add --prefix=ffmpeg "${upstream}" master --squash >/dev/null

printf 'two\n' > "${upstream}/codec.c"
git -C "${upstream}" add codec.c
git -C "${upstream}" commit -q -m "update upstream"
upstream_head="$(git -C "${upstream}" rev-parse HEAD)"

base_sha="$(git -C "${repo}" rev-parse HEAD)"
git -C "${repo}" subtree pull --prefix=ffmpeg "${upstream}" "${upstream_head}" --squash >/dev/null
head_sha="$(git -C "${repo}" rev-parse HEAD)"

read -r first_parent second_parent extra_parent <<< "$(git -C "${repo}" show -s --format=%P "${head_sha}")"
if [[ "${first_parent}" != "${base_sha}" || -z "${second_parent}" || -n "${extra_parent}" ]]; then
  echo "expected subtree pull to create a two-parent merge with the previous HEAD first" >&2
  exit 1
fi

subtree_body="$(git -C "${repo}" show -s --format=%B "${second_parent}")"
printf '%s\n' "${subtree_body}" | grep -F 'git-subtree-dir: ffmpeg' >/dev/null
printf '%s\n' "${subtree_body}" | grep -F "git-subtree-split: ${upstream_head}" >/dev/null

changed_paths="$(git -C "${repo}" diff --name-only "${base_sha}..${head_sha}")"
printf '%s\n' "${changed_paths}" | grep -F 'ffmpeg/codec.c' >/dev/null

echo "ok"
