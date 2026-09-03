---
title: Development
description: "Build VideoToolbox Remote from source: Swift server compilation, FFmpeg configuration with vtremote codecs, and running the integration test suite."
---

# Development

Notes for contributors working on the client codecs, protocol, or daemon.

## Repository Layout

- **`vtremoted/`**: Swift macOS daemon exposing VideoToolbox over TCP.
- **`ffmpeg/`**: FFmpeg fork containing the remote codec implementations.
- **`obs-plugin/`**: OBS plugin prototype using the same remote protocol.
- **`vaapi-driver/`**: Linux VA-API encode driver, static C SDK, packaging, and Plex smoke tooling.
- **`tests/`**: Integration tests and benchmarks.
- **`docs/`**: Protocol and architecture documentation.

## Build Instructions

### macOS (Server & Client)

The easiest way to build everything on a Mac:

```bash
make build
```

Release builds default to `MACOSX_DEPLOYMENT_TARGET=13.0`. Keep that default when building on macOS 27 or newer SDKs unless a release intentionally raises the minimum supported macOS version.

This produces:
- `vtremoted/.build/release/vtremoted`
- `ffmpeg/ffmpeg` (with local and remote VideoToolbox codecs enabled)

The `vtremoted` binary must not hard-link Homebrew `liblz4` or `libzstd`; those libraries are runtime-only optional dependencies for LZ4/Zstd wire compression. The release smoke test checks both the macOS 13.0 minimum OS and the absence of absolute Homebrew dylib load commands.

### Linux / Windows (Client Only)

Linux CI and release artifacts target `x86_64`. The project does not publish or test 32-bit `i686` Linux builds.

The VA-API driver job runs in Ubuntu 20.04 and builds the pinned libva 2.22 /
VA-API 1.22 headers from source. This preserves the GLIBC 2.17 release-artifact
baseline. Locally on Linux, run `make test-vaapi-driver`. The test suite uses
the shared repository mock and stock FFmpeg's VA-API encoders.

1.  **Install assembler and library dependencies**:
    ```bash
    nasm -v
    yasm --version
    ```
    Install current `nasm` and `yasm` before building. FFmpeg's x86 assembly can fail early with older or missing assemblers.

2.  **Configure**:
    ```bash
    cd ffmpeg
    ./configure --enable-videotoolbox-remote --enable-liblz4 --enable-libzstd \
      --enable-libvmaf --enable-libaom --enable-libdav1d --enable-libsvtav1
    ```
3.  **Build**:
    ```bash
    make -j$(nproc)
    ```

The repository Makefile wraps the same build with project defaults:

```bash
make build-ffmpeg
```

If a Linux `x86_64` source build fails in FFmpeg x86 assembly after installing current assemblers, use the diagnostic compatibility fallback:

```bash
make clean-ffmpeg
make build-ffmpeg FFMPEG_DISABLE_X86ASM=1
```

This appends `--disable-x86asm`. It is slower and should not be the default path, but it confirms whether the failure is limited to the assembler/toolchain surface.

## Testing & Benchmarks

Integration scripts are located in `tests/integration/`.

### Setup
Export the path to your server binary:
```bash
export VTREMOTED="$PWD/vtremoted/.build/release/vtremoted"
```

### Key Scripts
- **`run_all.sh`**: Standard integration suite.
- **`bench_vtremote.sh`**: Perform encoding/transcoding benchmarks.
- **`run_vtremoted_roundtrip.sh`**: Verify H.264/HEVC roundtrip correctness.
- **`run_mock_wire_compression.sh`**: Validate LZ4 and Zstd compressed frame payloads against the Python mock server.
- **`run_mock_protocol_capabilities.sh`**: Validate 0.4.1 configure-time capability negotiation and clear rejection of unsupported surfaces.
- **`run_mock_side_data_roundtrip.sh`**: Validate exact protocol side-data round-trips against the Python mock server.
- **`run_mock_hevc_pixfmt_negotiation.sh`**: Validate HEVC `bgra`, `ayuv`, and `p210le` negotiation against the Python mock server.
- **`run_vtremoted_hardware_ingest.sh`**: Verify remote encoders accept local VideoToolbox hardware frames.
- **`run_vtremoted_transcode_hardware_ingest.sh`**: Verify a local VideoToolbox hardware-decode pipeline can feed remote HEVC encode.
- **`run_vtremoted_decode_hardware_output.sh`**: Verify remote decoders can return VideoToolbox-backed frames when requested.
- **`run_vtremoted_hevc_pixfmts.sh`**: Verify real `vtremoted` accepts HEVC `bgra`, `ayuv`, and `p210le` inputs.
- **`run_vtremoted_hdr_side_data.sh`**: Verify real `vtremoted` preserves HEVC HDR color signaling.
- **`run_obs_plugin_client_mock.sh`**: OBS plugin protocol smoke test against the Python mock server.

### Running a Benchmark
To reproduce the performance numbers:
```bash
VTREMOTE_HOST=<mac-host> VTREMOTE_PORT=5555 VTREMOTE_USE_EXISTING=1 \
VTREMOTED=/bin/true tests/integration/bench_vtremote.sh
```

### Adaptive options

```bash
-vt_remote_wire_compression auto   # pick LZ4 vs Zstd based on resolution/FPS
-vt_remote_inflight auto           # adjust inflight over time
```

## GitHub Metadata and Release Notes

The repository includes small `gh`-based helpers for keeping the public GitHub surfaces in sync.

Prerequisite:

```bash
gh auth status
```

Key commands:

```bash
make sync-github-metadata
make release-notes TAG=v0.3.1
make release-notes-all
bash scripts/generate_release_notes.sh v0.3.1
bash tests/test_llms_release_version.sh
```

What they do:
- `make sync-github-metadata` updates the repo description, homepage, and topics.
- `make release-notes TAG=...` regenerates and applies the onboarding-style release body for one GitHub release.
- `make release-notes-all` backfills all existing GitHub releases with the generated notes format.
- `bash scripts/generate_release_notes.sh <tag>` previews the generated release body locally without editing GitHub.
- `bash tests/test_llms_release_version.sh` verifies `docs/llms.txt` matches the latest changelog release.

Release checklist:

- Update `CHANGELOG.md`.
- Update `docs/llms.txt` and `docs/_config.yml` when the public release changes.
- Confirm the README, landing page CTA, and release notes still point to the latest release and getting-started flow.
- Run `make sync-github-metadata` if description, homepage, or topics changed.

## Artifact Smoke Checks

CI smoke-tests packaged tarballs after creating them. To reproduce locally:

```bash
bash scripts/smoke_release_artifact.sh ffmpeg ffmpeg-linux-x86_64.tar.gz
bash scripts/smoke_release_artifact.sh vtremoted vtremoted-macos-arm64.tar.gz
```

The FFmpeg smoke check unpacks the tarball and verifies the remote encoders, remote decoders, `vtremote_transcode`, and quality filters are present. The `vtremoted` smoke check verifies `--version` and `--help` without binding a socket.
