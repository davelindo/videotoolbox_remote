#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 5 ]]; then
  echo "usage: bash scripts/update_changelog_for_ffmpeg_sync.sh <tag> <old-sha> <new-sha> [date] [changelog-file]" >&2
  exit 1
fi

tag="$1"
old_sha="$2"
new_sha="$3"
release_date="${4:-$(date -u +%F)}"
changelog_file="${5:-CHANGELOG.md}"
upstream_ref="${FFMPEG_UPSTREAM_REF:-${UPSTREAM_REF:-master}}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! bash "${script_dir}/is_semver_tag.sh" "${tag}"; then
  echo "ERROR: invalid release tag: ${tag}" >&2
  exit 1
fi

if [[ ! "${old_sha}" =~ ^[0-9a-f]{12,40}$ || ! "${new_sha}" =~ ^[0-9a-f]{12,40}$ ]]; then
  echo "ERROR: old and new FFmpeg SHAs must be 12-40 lowercase hex characters" >&2
  exit 1
fi

if [[ ! "${release_date}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "ERROR: release date must use YYYY-MM-DD format" >&2
  exit 1
fi

short_sha() {
  local sha="$1"
  printf '%s' "${sha:0:12}"
}

if [[ ! -f "${changelog_file}" ]]; then
  echo "ERROR: changelog not found: ${changelog_file}" >&2
  exit 1
fi

section_file="$(mktemp)"
tmp_file="$(mktemp)"
trap 'rm -f "${section_file}" "${tmp_file}"' EXIT

cat > "${section_file}" <<EOF
## [${tag}] - ${release_date}

### Changed
- Rebased the vendored \`ffmpeg/\` subtree to upstream \`${upstream_ref}\` snapshot \`$(short_sha "${new_sha}")\` (from \`$(short_sha "${old_sha}")\`).
EOF

awk -v tag="${tag}" -v section_file="${section_file}" '
function emit_section() {
  while ((getline line < section_file) > 0) {
    print line
  }
  close(section_file)
}

BEGIN {
  inserted = 0
  replacing = 0
  preserved_top = 0
  target_heading = "## [" tag "]"
}

{
  if (index($0, target_heading) == 1) {
    replacing = 1
    next
  }

  if (replacing) {
    if ($0 ~ /^## \[/) {
      replacing = 0
    } else {
      next
    }
  }

  if (!inserted && !preserved_top && $0 ~ /^## \[Unreleased\]/) {
    preserved_top = 1
    print
    next
  }

  if (!inserted && preserved_top && $0 ~ /^## \[/) {
    emit_section()
    print ""
    inserted = 1
  }

  if (!inserted && !preserved_top && $0 ~ /^## \[/) {
    emit_section()
    print ""
    inserted = 1
  }

  print
}

END {
  if (!inserted) {
    if (NR > 0) {
      print ""
    }
    emit_section()
  }
}
' "${changelog_file}" > "${tmp_file}"

mv "${tmp_file}" "${changelog_file}"
