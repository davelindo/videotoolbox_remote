---
title: Development
---

# Development

Notes for contributors working on the client codecs, protocol, or daemon.

## Repository Layout

- **`vtremoted/`**: Swift macOS daemon exposing VideoToolbox over TCP.
- **`ffmpeg/`**: FFmpeg fork containing the remote codec implementations.
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
    ./configure --enable-videotoolbox-remote --enable-liblz4 --enable-libzstd
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
