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
- **`tests/`**: Integration tests and benchmarks.
- **`docs/`**: Protocol and architecture documentation.

## Build Instructions

### macOS (Server & Client)

The easiest way to build everything on a Mac:

```bash
make build
```
This produces:
- `vtremoted/.build/release/vtremoted`
- `ffmpeg/ffmpeg` (with local and remote VideoToolbox codecs enabled)

### Linux / Windows (Client Only)

1.  **Configure**:
    ```bash
    cd ffmpeg
    ./configure --enable-videotoolbox-remote --enable-liblz4 --enable-libzstd \
      --enable-libvmaf --enable-libaom --enable-libdav1d --enable-libsvtav1
    ```
2.  **Build**:
    ```bash
    make -j$(nproc)
    ```

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
```

What they do:
- `make sync-github-metadata` updates the repo description, homepage, and topics.
- `make release-notes TAG=...` regenerates and applies the onboarding-style release body for one GitHub release.
- `make release-notes-all` backfills all existing GitHub releases with the generated notes format.
- `bash scripts/generate_release_notes.sh <tag>` previews the generated release body locally without editing GitHub.
