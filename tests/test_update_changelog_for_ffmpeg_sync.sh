#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
update_script="${repo_root}/scripts/update_changelog_for_ffmpeg_sync.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

changelog_file="${tmpdir}/CHANGELOG.md"

assert_file_equals() {
  local expected_file="$1"
  local actual_file="$2"

  if ! diff -u "${expected_file}" "${actual_file}"; then
    echo "file did not match expected output: ${actual_file}" >&2
    exit 1
  fi
}

cat > "${changelog_file}" <<'EOF'
# Changelog

All notable changes to this project are documented in this file.

The format follows Keep a Changelog principles, using repository release tags (`v*`) in reverse chronological order.
The non-version `nightly` tag is intentionally excluded.

## [v0.3.2] - 2026-04-23

### Changed
- Existing release entry.
EOF

bash "${update_script}" v0.3.3 08f56d4898eafcaddc19b3aac9263e066e82f0c0 123456789abc 2026-04-24 "${changelog_file}"

cat > "${tmpdir}/expected_no_unreleased.md" <<'EOF'
# Changelog

All notable changes to this project are documented in this file.

The format follows Keep a Changelog principles, using repository release tags (`v*`) in reverse chronological order.
The non-version `nightly` tag is intentionally excluded.

## [v0.3.3] - 2026-04-24

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `123456789abc` (from `08f56d4898ea`).

## [v0.3.2] - 2026-04-23

### Changed
- Existing release entry.
EOF

assert_file_equals "${tmpdir}/expected_no_unreleased.md" "${changelog_file}"

bash "${update_script}" v0.3.3 08f56d4898eafcaddc19b3aac9263e066e82f0c0 abcdef012345 2026-04-24 "${changelog_file}"

count="$(rg -c '^## \[v0\.3\.3\]' "${changelog_file}")"
if [[ "${count}" != "1" ]]; then
  echo "expected changelog to contain exactly one v0.3.3 section, found ${count}" >&2
  exit 1
fi

rg -n 'snapshot `abcdef012345` \(from `08f56d4898ea`\)' "${changelog_file}" >/dev/null

cat > "${changelog_file}" <<'EOF'
# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Changed
- Pending work.

## [v0.3.2] - 2026-04-23

### Changed
- Existing release entry.
EOF

bash "${update_script}" v0.3.3 08f56d4898eafcaddc19b3aac9263e066e82f0c0 fedcba987654 2026-04-24 "${changelog_file}"

cat > "${tmpdir}/expected_unreleased.md" <<'EOF'
# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Changed
- Pending work.

## [v0.3.3] - 2026-04-24

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `fedcba987654` (from `08f56d4898ea`).

## [v0.3.2] - 2026-04-23

### Changed
- Existing release entry.
EOF

assert_file_equals "${tmpdir}/expected_unreleased.md" "${changelog_file}"

bash "${update_script}" v0.3.3 08f56d4898eafcaddc19b3aac9263e066e82f0c0 a1b2c3d4e5f6 2026-04-24 "${changelog_file}"

count="$(rg -c '^## \[v0\.3\.3\]' "${changelog_file}")"
if [[ "${count}" != "1" ]]; then
  echo "expected changelog to contain exactly one v0.3.3 section after unreleased rewrite, found ${count}" >&2
  exit 1
fi

rg -n 'snapshot `a1b2c3d4e5f6` \(from `08f56d4898ea`\)' "${changelog_file}" >/dev/null

if bash "${update_script}" v0.3.3-rc1 08f56d4898eafcaddc19b3aac9263e066e82f0c0 a1b2c3d4e5f6 2026-04-24 "${changelog_file}" >/tmp/changelog_bad.out 2>/tmp/changelog_bad.err; then
  echo "expected changelog updater to reject non-semver tag" >&2
  exit 1
fi

if bash "${update_script}" v0.3.3 badsha a1b2c3d4e5f6 2026-04-24 "${changelog_file}" >/tmp/changelog_bad_sha.out 2>/tmp/changelog_bad_sha.err; then
  echo "expected changelog updater to reject malformed SHA" >&2
  exit 1
fi

echo "ok"
