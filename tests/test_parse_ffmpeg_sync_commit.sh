#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
parse_script="${repo_root}/scripts/parse_ffmpeg_sync_commit.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

cd "${tmpdir}"
git init -q -b main
git config user.name "Codex"
git config user.email "codex@example.com"

printf 'base\n' > README.md
git add README.md
git commit -q -m "base"

cat > message.txt <<'EOF'
ffmpeg-sync: update subtree to 123456789abc for v0.3.3

Squashed 'ffmpeg/' changes from deadbeef00..123456789abc

git-subtree-dir: ffmpeg
git-subtree-split: 123456789abcdef0123456789abcdef012345678

FFmpeg-Sync-Run-ID: 12345
FFmpeg-Sync-Tag: v0.3.3
FFmpeg-Sync-Base-SHA: 1111111111111111111111111111111111111111
EOF

printf 'sync\n' >> README.md
git add README.md
git commit -q -F message.txt

output="$(bash "${parse_script}" HEAD)"
printf '%s\n' "${output}" | grep -F 'upstream_commit=123456789abc' >/dev/null
printf '%s\n' "${output}" | grep -F 'target_tag=v0.3.3' >/dev/null
printf '%s\n' "${output}" | grep -F 'sync_run_id=12345' >/dev/null
printf '%s\n' "${output}" | grep -F 'base_sha=1111111111111111111111111111111111111111' >/dev/null

expect_parse_failure() {
  local message_file="$1"
  local expected_error="$2"
  local stdout_file="${tmpdir}/parse_ffmpeg_sync.out"
  local stderr_file="${tmpdir}/parse_ffmpeg_sync.err"

  printf 'bad\n' >> README.md
  git add README.md
  git commit -q -F "${message_file}"

  if bash "${parse_script}" HEAD >"${stdout_file}" 2>"${stderr_file}"; then
    echo "expected parser failure for ${message_file}" >&2
    exit 1
  fi

  if ! grep -F "${expected_error}" "${stderr_file}" >/dev/null; then
    echo "expected parser error containing '${expected_error}'" >&2
    cat "${stderr_file}" >&2
    exit 1
  fi
}

cat > bad_subject.txt <<'EOF'
ffmpeg-sync: update subtree to 123456789abc for v0.3.3-rc1

FFmpeg-Sync-Run-ID: 12345
FFmpeg-Sync-Tag: v0.3.3-rc1
FFmpeg-Sync-Base-SHA: 1111111111111111111111111111111111111111
EOF
expect_parse_failure bad_subject.txt "unexpected ffmpeg sync commit subject"

cat > bad_run_id.txt <<'EOF'
ffmpeg-sync: update subtree to 123456789abc for v0.3.3

FFmpeg-Sync-Run-ID: abc
FFmpeg-Sync-Tag: v0.3.3
FFmpeg-Sync-Base-SHA: 1111111111111111111111111111111111111111
EOF
expect_parse_failure bad_run_id.txt "missing or invalid FFmpeg-Sync-Run-ID"

cat > bad_tag.txt <<'EOF'
ffmpeg-sync: update subtree to 123456789abc for v0.3.3

FFmpeg-Sync-Run-ID: 12345
FFmpeg-Sync-Tag: v0.3.4
FFmpeg-Sync-Base-SHA: 1111111111111111111111111111111111111111
EOF
expect_parse_failure bad_tag.txt "FFmpeg-Sync-Tag trailer mismatch"

cat > bad_base.txt <<'EOF'
ffmpeg-sync: update subtree to 123456789abc for v0.3.3

FFmpeg-Sync-Run-ID: 12345
FFmpeg-Sync-Tag: v0.3.3
FFmpeg-Sync-Base-SHA: 1111
EOF
expect_parse_failure bad_base.txt "missing or invalid FFmpeg-Sync-Base-SHA"

echo "ok"
