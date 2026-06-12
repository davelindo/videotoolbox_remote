#!/usr/bin/env bash
set -euo pipefail

tag="${1:?usage: bash scripts/generate_release_notes.sh <tag> [output-file]}"
output="${2:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "${repo_root}"

repo_slug="${REPO_SLUG:-${GITHUB_REPOSITORY:-davelindo/videotoolbox_remote}}"
doc_ref="${DOC_REF:-main}"
nightly_asset_commit="${NIGHTLY_ASSET_COMMIT:-}"
nightly_head_commit="${NIGHTLY_HEAD_COMMIT:-}"
nightly_head_tag="${NIGHTLY_HEAD_TAG:-nightly-main}"
nightly_assets_stale="${NIGHTLY_ASSETS_STALE:-false}"

readme_url="https://github.com/${repo_slug}/blob/${doc_ref}/README.md"
getting_started_url="https://github.com/${repo_slug}/blob/${doc_ref}/docs/getting-started.md"
troubleshooting_url="https://github.com/${repo_slug}/blob/${doc_ref}/docs/troubleshooting.md"
security_url="https://github.com/${repo_slug}/blob/${doc_ref}/docs/security.md"
architecture_url="https://github.com/${repo_slug}/blob/${doc_ref}/docs/architecture.md"
benchmarks_url="https://github.com/${repo_slug}/blob/${doc_ref}/docs/benchmarks.md"
changelog_url="https://github.com/${repo_slug}/blob/${doc_ref}/CHANGELOG.md"

short_commit() {
  local commit="$1"
  if [[ -z "${commit}" ]]; then
    return 0
  fi
  printf '%s' "${commit:0:12}"
}

commit_link() {
  local commit="$1"
  if [[ -z "${commit}" ]]; then
    return 0
  fi
  local short
  short="$(short_commit "${commit}")"
  printf '[`%s`](https://github.com/%s/commit/%s)' "${short}" "${repo_slug}" "${commit}"
}

extract_changelog_section() {
  local wanted_tag="$1"

  awk -v tag="${wanted_tag}" '
    $0 ~ "^## \\[" tag "\\]" { in_section=1; next }
    in_section && $0 ~ "^## \\[" { exit }
    in_section { print }
  ' CHANGELOG.md
}

emit_nightly_changes_section() {
  if [[ "${nightly_assets_stale}" == "true" && -n "${nightly_asset_commit}" && -n "${nightly_head_commit}" ]]; then
    cat <<EOF

## What changed in this build?

No artifact-affecting changes were detected since the last nightly build.

- Attached binaries were last rebuilt from $(commit_link "${nightly_asset_commit}").
- Latest \`main\` commit observed by automation is $(commit_link "${nightly_head_commit}") via the \`${nightly_head_tag}\` tag.
- The \`nightly\` release tag remains pinned to the last built commit so its source archives stay aligned with the published binaries.
EOF
  elif [[ -n "${nightly_asset_commit}" ]]; then
    cat <<EOF

## What changed in this build?

This nightly was rebuilt from $(commit_link "${nightly_asset_commit}"). For release-by-release summaries, see the [changelog](${changelog_url}).
EOF
  else
    cat <<EOF

## What changed in this build?

This nightly tracks the latest changes on \`main\`. For release-by-release summaries, see the [changelog](${changelog_url}).
EOF
  fi
}

emit_body() {
  cat <<EOF
Remote VideoToolbox for FFmpeg: use a Mac or Apple Silicon system over LAN as an IP-based H.264/HEVC encode/decode/transcoding accelerator.

## 1-minute quickstart

1. On the Mac server, download \`vtremoted-macos-arm64.tar.gz\` (Apple Silicon) or \`vtremoted-macos-x86_64.tar.gz\` (Intel Mac).
2. On the client, download the FFmpeg build for your platform: \`ffmpeg-linux-x86_64.tar.gz\`, \`ffmpeg-macos-arm64.tar.gz\`, \`ffmpeg-macos-x86_64.tar.gz\`, or \`ffmpeg-windows-x86_64.tar.gz\`.
3. Start \`vtremoted\` on the Mac:

\`\`\`bash
tar -xzf vtremoted-macos-arm64.tar.gz
./vtremoted/vtremoted --listen 0.0.0.0:5555 --log-level 1
\`\`\`

4. Run a remote encode from the client:

\`\`\`bash
mkdir -p ffmpeg-client
tar -xzf ffmpeg-linux-x86_64.tar.gz -C ffmpeg-client
./ffmpeg-client/ffmpeg -i input.mkv \\
  -c:v h264_videotoolbox_remote \\
  -vt_remote_host <MAC_IP>:5555 \\
  -b:v 6000k \\
  output.mkv
\`\`\`

## Which asset do I need?

- \`vtremoted-macos-arm64.tar.gz\`: macOS server binary for Apple Silicon Macs.
- \`vtremoted-macos-x86_64.tar.gz\`: macOS server binary for Intel Macs.
- \`ffmpeg-linux-x86_64.tar.gz\`: FFmpeg client build for Linux.
- \`ffmpeg-macos-arm64.tar.gz\`: FFmpeg client build for Apple Silicon Macs.
- \`ffmpeg-macos-x86_64.tar.gz\`: FFmpeg client build for Intel Macs.
- \`ffmpeg-windows-x86_64.tar.gz\`: FFmpeg client build for Windows.
- \`SHA256SUMS.txt\`: checksums for all release tarballs.

## Build and upgrade notes

- v0.4.1-capable clients and servers negotiate the expanded media surface explicitly: hardware-frame ingest/output, HEVC \`bgra\`/\`ayuv\`/\`p210le\`, frame and packet side-data forwarding, and \`vtremote_transcode\` HDR signaling.
- Linux FFmpeg artifacts are built for \`x86_64\`. If a source build fails in FFmpeg x86 assembly, first install current \`nasm\` and \`yasm\`; as a compatibility fallback, rebuild with \`make build-ffmpeg FFMPEG_DISABLE_X86ASM=1\`.
- To verify a macOS server upgrade, run \`vtremoted --version\`, \`pgrep -fl vtremoted\`, and \`lsof -nP -iTCP:5555 -sTCP:LISTEN\` on the Mac.
- Release tarballs are smoke-tested after packaging to confirm the vtremote FFmpeg encoders, decoders, and \`vtremote_transcode\` bitstream filter are present.
EOF

  if [[ "${tag}" == "nightly" ]]; then
    emit_nightly_changes_section
  else
    local changelog_section
    changelog_section="$(extract_changelog_section "${tag}")"

    if [[ -n "${changelog_section}" ]]; then
      cat <<EOF

## What changed in this release?
${changelog_section}
EOF
    else
      cat <<EOF

## What changed in this release?

See the [changelog](${changelog_url}) for the summary for \`${tag}\`.
EOF
    fi
  fi

  cat <<EOF

## Learn more

- [README](${readme_url})
- [Getting started](${getting_started_url})
- [Benchmarks](${benchmarks_url})
- [Troubleshooting](${troubleshooting_url})
- [Security](${security_url})
- [Architecture](${architecture_url})
EOF
}

if [[ -n "${output}" ]]; then
  mkdir -p "$(dirname "${output}")"
  emit_body > "${output}"
else
  emit_body
fi
