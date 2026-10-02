#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

# Keep this wiring test dependency-free so it also runs in the changes job.
python3 - "${1:-${repo_root}/.github/workflows/ci.yml}" <<'PY'
import os
from pathlib import Path
import re
import subprocess
import sys

workflow = Path(sys.argv[1]).read_text()

def job(name):
    match = re.search(r"^  " + re.escape(name) + r":\n(.*?)(?=^  [\w-]+:\n|\Z)", workflow, re.M | re.S)
    assert match, f"missing CI job: {name}"
    return match.group(1)

def require(text, value):
    assert value in text, f"missing required CI wiring: {value}"

arm = job("ffmpeg-build-linux-arm64")
x86 = job("ffmpeg-build-linux")
hosted = job("ffmpeg-build")
publish = job("publish-assets")
require(arm, "runs-on: ubuntu-24.04-arm")
require(arm, "FFMPEG_BUILD_LABEL: linux-arm64")
require(x86, "runs-on: videotoolbox-remote-runner")
require(x86, "github.event.pull_request.user.login")
assert "github.event.pull_request.user.login" not in arm, "hosted arm64 PRs must not require the self-hosted author allowlist"

# The new platform must run for the same PR, tag, nightly and sync events as
# the existing hosted FFmpeg platforms.
condition = lambda block: re.search(r"^    if: (.+)$", block, re.M).group(1)
assert condition(arm) == condition(hosted), "arm64 event gating differs from hosted FFmpeg builds"
needs = re.search(r"^    needs: \[([^\]]+)\]$", publish, re.M).group(1)
assert "ffmpeg-build-linux-arm64" in [item.strip() for item in needs.split(",")], "release publication must wait for arm64 artifacts"

# Exercise the runner check, including mislabelled or wrong-OS runners.
check = re.search(r"- name: Check runner platform\n        run: \|\n((?:          .+\n)+)", arm)
assert check, "arm64 job must reject incorrect runner platforms"
command = "\n".join(line[10:] for line in check.group(1).splitlines())
for runner_os, runner_arch, succeeds in [("Linux", "ARM64", True), ("Linux", "X64", False), ("macOS", "ARM64", False)]:
    result = subprocess.run(["bash", "-e", "-c", command], env={**os.environ, "RUNNER_OS": runner_os, "RUNNER_ARCH": runner_arch}, check=False)
    assert (result.returncode == 0) == succeeds, f"incorrect platform check for {runner_os}/{runner_arch}"

for value in [
    "make build-ffmpeg",
    "Build libvmaf (Linux)",
    "Build SVT-AV1 (Linux)",
    "-DBUILD_SHARED_LIBS=OFF",
    "h264_videotoolbox_remote",
    "hevc_videotoolbox_remote",
    "vtremote_transcode",
    "python3 tests/integration/run_transport_regressions.py --skip-daemon",
    "bash tests/integration/run_mock_roundtrip.sh",
    "bash tests/integration/run_mock_decode.sh",
    "bash scripts/smoke_release_artifact.sh ffmpeg ffmpeg-${{ env.FFMPEG_BUILD_LABEL }}.tar.gz",
    "name: ffmpeg-${{ env.FFMPEG_BUILD_LABEL }}",
    "ffmpeg-${{ env.FFMPEG_BUILD_LABEL }}.tar.gz.sha256",
    "uses: actions/upload-artifact@v4",
    "persist-credentials: false",
]:
    require(arm, value)
assert "vaapi-driver" not in arm, "arm64 job must only build the FFmpeg client"
require(workflow, "bash tests/test_ffmpeg_linux_arm64_ci.sh")
print("ok: Linux arm64 CI platform, event, validation and release wiring")
PY
