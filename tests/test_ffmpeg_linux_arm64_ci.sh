#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

# Keep this wiring test dependency-free so it also runs in the changes job.
python3 - "${1:-${repo_root}/.github/workflows/ci.yml}" "${2:-${repo_root}/.github/workflows/promote-ffmpeg-sync.yml}" <<'PY'
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

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

# Promotion must require success from the new platform before creating a tag.
# Execute the actual job-conclusion gate with a fake read-only gh response.
promotion = Path(sys.argv[2]).read_text()
gate = re.search(r"          required_jobs=\(\n(.*?)          echo \"target_tag=", promotion, re.S)
assert gate, "missing sync-promotion CI job gate"
command = "\n".join(line[10:] for line in gate.group(0).splitlines()[:-1])
required_jobs = re.findall(r'^            "([^"\n]+)"$', gate.group(1), re.M)
assert "FFmpeg (linux-arm64)" in required_jobs, "sync promotion must wait for successful arm64 CI"
for conclusion in ["success", "skipped", "failure", "missing"]:
    jobs = "\n".join(
        f"{name}\t{conclusion if name == 'FFmpeg (linux-arm64)' else 'success'}"
        for name in required_jobs
        if not (name == "FFmpeg (linux-arm64)" and conclusion == "missing")
    )
    result = subprocess.run(
        ["bash", "-e", "-c", 'gh() { printf \'%s\\n\' "$MOCK_JOBS_OUTPUT"; }\n' + command],
        env={**os.environ, "REPOSITORY": "test/repo", "CI_RUN_ID": "1", "MOCK_JOBS_OUTPUT": jobs},
        capture_output=True,
        text=True,
        check=False,
    )
    assert (result.returncode == 0) == (conclusion == "success"), f"incorrect arm64 promotion gate for {conclusion}"

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
# Exercise the real packaging/flattening shell steps with small binary fixtures.
# This validates archive names, contents and both checksum publication paths
# without pretending these fixtures are a compiled Linux client.
def shell_step(block, name):
    match = re.search(r"- name: " + re.escape(name) + r"\n        run: \|\n((?:          .*\n)+)", block)
    assert match, f"missing shell step: {name}"
    return "\n".join(line[10:] for line in match.group(1).splitlines())

label = "linux-arm64"
package_command = shell_step(arm, "Package ffmpeg (Linux)").replace("${{ env.FFMPEG_BUILD_LABEL }}", label)
with tempfile.TemporaryDirectory(prefix="vtremote-arm64-package-") as tmp:
    root = Path(tmp)
    (root / "ffmpeg").mkdir()
    for name in ["ffmpeg", "ffprobe", "ffplay"]:
        (root / "ffmpeg" / name).write_bytes(f"fixture: {name}\n".encode())
    subprocess.run(["bash", "-e", "-c", package_command], cwd=root, check=True)
    archive_name = f"ffmpeg-{label}.tar.gz"
    checksum_name = archive_name + ".sha256"
    digest = hashlib.sha256((root / archive_name).read_bytes()).hexdigest()
    assert (root / checksum_name).read_text().split() == [digest, archive_name], "invalid arm64 archive checksum"
    with tarfile.open(root / archive_name) as archive:
        for name in ["ffmpeg", "ffprobe", "ffplay"]:
            assert archive.extractfile(f"./{name}").read() == (root / "ffmpeg" / name).read_bytes(), f"missing packaged {name}"
    upload = re.search(r"- name: Upload ffmpeg artifact\n(.*)", arm, re.S).group(1)
    require(upload, "ffmpeg-${{ env.FFMPEG_BUILD_LABEL }}.tar.gz\n")
    require(upload, "ffmpeg-${{ env.FFMPEG_BUILD_LABEL }}.tar.gz.sha256")
    artifacts = root / "release_assets" / f"ffmpeg-{label}"
    artifacts.mkdir(parents=True)
    for name in [archive_name, checksum_name]:
        shutil.copyfile(root / name, artifacts / name)
    subprocess.run(["bash", "-e", "-c", shell_step(publish, "Flatten artifacts")], cwd=root, capture_output=True, check=True)
    flat = root / "release_flat"
    assert (flat / archive_name).is_file() and (flat / checksum_name).is_file(), "arm64 files missing from flattened release assets"
    assert (flat / "SHA256SUMS.txt").read_text().split() == [digest, archive_name], "aggregate release checksums omit arm64"

assert "vaapi-driver" not in arm, "arm64 job must only build the FFmpeg client"
require(workflow, "bash tests/test_ffmpeg_linux_arm64_ci.sh")
print("ok: Linux arm64 CI platform, event, validation and release wiring")
PY
