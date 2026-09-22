#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check_script="${script_dir}/../scripts/check_ffmpeg_subtree.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

upstream="${tmpdir}/upstream"
repo="${tmpdir}/repo"

# git subtree traverses by commit date. Keep this fast fixture's history ordered
# without sleeps or commits accidentally dated after a subsequent sync.
test_epoch=1600000000
tick() {
  test_epoch=$((test_epoch + 1))
  export GIT_AUTHOR_DATE="${test_epoch} +0000"
  export GIT_COMMITTER_DATE="${test_epoch} +0000"
}
tick
git init -q -b master "${upstream}"
git -C "${upstream}" config user.name "Test User"
git -C "${upstream}" config user.email "test@example.com"
mkdir "${upstream}/libavcodec"
printf 'configure\n' > "${upstream}/configure"
printf 'one\n' > "${upstream}/libavcodec/codec.c"
git -C "${upstream}" add configure libavcodec/codec.c
git -C "${upstream}" commit -q -m "initial upstream"

git init -q -b main "${repo}"
git -C "${repo}" config user.name "Test User"
git -C "${repo}" config user.email "test@example.com"
printf 'base\n' > "${repo}/README.md"
git -C "${repo}" add README.md
tick
git -C "${repo}" commit -q -m "base"
tick
git -C "${repo}" subtree add --prefix=ffmpeg "${upstream}" master --squash >/dev/null
(cd "${repo}" && bash "${check_script}") >/dev/null

printf 'remote codec\n' > "${repo}/ffmpeg/libavcodec/vtremote.c"
printf 'remote feature\n' >> "${repo}/ffmpeg/configure"
git -C "${repo}" add ffmpeg
tick
git -C "${repo}" commit -q -m "add local codec and configure option"

printf 'two\n' > "${upstream}/libavcodec/codec.c"
git -C "${upstream}" add libavcodec/codec.c
tick
git -C "${upstream}" commit -q -m "update upstream"
upstream_head="$(git -C "${upstream}" rev-parse HEAD)"

base_sha="$(git -C "${repo}" rev-parse HEAD)"
tick
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
printf '%s\n' "${changed_paths}" | grep -F 'ffmpeg/libavcodec/codec.c' >/dev/null
test "$(cd "${repo}" && bash "${check_script}")" = "${second_parent}"

# Reproduce the manual-resolution mistake: copying the upstream trailers onto
# the repository merge makes git subtree select the entire repository as its base.
tick
git -C "${repo}" commit --amend -q -m "incorrect sync metadata" -m "${subtree_body}"
if (cd "${repo}" && bash "${check_script}") >"${tmpdir}/check.out" 2>"${tmpdir}/check.err"; then
  echo "accepted a repository merge as an upstream subtree record" >&2
  exit 1
fi
grep -F 'is a merge commit' "${tmpdir}/check.err" >/dev/null

# Restore a pristine upstream anchor without rewriting any published history or
# changing the repository tree.
tick
anchor="$(git -C "${repo}" commit-tree \
  "${second_parent}^{tree}" -p "${second_parent}" \
  -m 'Restore pristine FFmpeg subtree base' \
  -m "$(printf 'git-subtree-dir: ffmpeg\ngit-subtree-split: %s' "${upstream_head}")")"
before_repair="$(git -C "${repo}" rev-parse HEAD)"
tick
git -C "${repo}" merge --no-ff -s ours -m 'Repair FFmpeg subtree tracking' "${anchor}" >/dev/null
git -C "${repo}" diff --exit-code "${before_repair}" HEAD
test "$(cd "${repo}" && bash "${check_script}")" = "${anchor}"

# Two subsequent syncs must retain both local-only files and edits to upstream
# files, while still importing new upstream changes and advancing the base.
for content in three four; do
  printf '%s\n' "${content}" > "${upstream}/libavcodec/codec.c"
  tick
  git -C "${upstream}" commit -qam "update upstream to ${content}"
  upstream_head="$(git -C "${upstream}" rev-parse HEAD)"
  tick
  git -C "${repo}" subtree pull --prefix=ffmpeg "${upstream}" "${upstream_head}" --squash >/dev/null
  test "$(cat "${repo}/ffmpeg/libavcodec/codec.c")" = "${content}"
  test "$(cat "${repo}/ffmpeg/libavcodec/vtremote.c")" = 'remote codec'
  grep -Fx 'remote feature' "${repo}/ffmpeg/configure" >/dev/null
  test "$(cd "${repo}" && bash "${check_script}")" = "$(git -C "${repo}" rev-parse HEAD^2)"
done

echo "ok"
