#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
classifier="${repo_root}/scripts/classify_nightly_changes.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

git_init() {
    git init -q -b main
    git config user.name "Codex"
    git config user.email "codex@example.com"
}

write_base_tree() {
    mkdir -p ffmpeg vtremoted tests/integration docs .github/workflows
    printf 'base\n' > ffmpeg/configure
    printf 'base\n' > vtremoted/Package.swift
    printf 'base\n' > tests/integration/run_mock_roundtrip.sh
    printf 'base\n' > docs/index.md
    printf 'base\n' > README.md
    printf 'base\n' > Makefile
    printf 'name: CI\n' > .github/workflows/ci.yml
}

assert_output() {
    local output="$1"
    local key="$2"
    local expected="$3"
    local actual

    actual="$(printf '%s\n' "${output}" | sed -n "s/^${key}=//p")"
    if [[ "${actual}" != "${expected}" ]]; then
        echo "Assertion failed for ${key}: expected '${expected}', got '${actual}'" >&2
        exit 1
    fi
}

run_case() {
    local branch_name="$1"
    local path="$2"
    local content="$3"
    shift 3

    git checkout -q main
    git checkout -q -B "${branch_name}"
    mkdir -p "$(dirname "${path}")"
    printf '%s\n' "${content}" > "${path}"
    git add "${path}"
    git commit -q -m "${branch_name}"

    local output
    output="$(bash "${classifier}" nightly HEAD)"

    while (($#)); do
        assert_output "${output}" "$1" "$2"
        shift 2
    done
}

cd "${tmpdir}"
git_init
write_base_tree
git add .
git commit -q -m "base"
git tag nightly

missing_output="$(bash "${classifier}" nightly-missing HEAD)"
assert_output "${missing_output}" "nightly_exists" "false"
assert_output "${missing_output}" "publishable" "true"

run_case "docs-only" "docs/index.md" "docs change" \
    "nightly_exists" "true" \
    "docs" "true" \
    "publishable" "false"

run_case "makefile-only" "Makefile" "build logic change" \
    "nightly_exists" "true" \
    "ffmpeg" "true" \
    "vtremoted" "true" \
    "obs_plugin" "true" \
    "publishable" "true"

run_case "ffmpeg-only" "ffmpeg/configure" "ffmpeg change" \
    "nightly_exists" "true" \
    "ffmpeg" "true" \
    "publishable" "true"

run_case "vtremoted-only" "vtremoted/Package.swift" "vtremoted change" \
    "nightly_exists" "true" \
    "vtremoted" "true" \
    "publishable" "true"

echo "ok"
