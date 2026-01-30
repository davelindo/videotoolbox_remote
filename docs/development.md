---
title: Development
---

# Development

Notes for contributors working on the client codecs, protocol, or daemon.

## Repo layout

- `vtremoted/` — Swift macOS daemon exposing VideoToolbox over TCP
- `ffmpeg/` — FFmpeg fork containing the remote codec implementations
- `tests/` — integration tests + benchmarks
- `docs/` — protocol + architecture docs

## Build (macOS)

```bash
make build
```

This builds:
- `vtremoted/.build/release/vtremoted`
- `ffmpeg/ffmpeg` with both local and remote VideoToolbox codecs enabled

## Build (FFmpeg client on Linux/Windows)

```bash
cd ffmpeg
./configure --enable-videotoolbox-remote --enable-liblz4 --enable-libzstd
make -j
```

If your toolchain doesn't support response files for `ar`, add:
`--disable-response-files`.

## Tests and benchmarks

Integration scripts live in `tests/integration/`:

- `run_all.sh` — standard integration suite
- `run_vtremoted_roundtrip.sh` — H.264/HEVC roundtrip with PTS/DTS checks
- `run_vtremoted_decode.sh` — remote decode validation
- `run_transcode_test.sh` — simultaneous decode + encode pipeline
- `run_speed_decode_async.sh` — sync vs async decode speed
- `run_speed_decode_matrix.sh` — async/sync + depth + compression matrix
- `bench_vtremote.sh` — local vs remote encode benchmark

For performance tests, use a release server:

```bash
export VTREMOTED="$PWD/vtremoted/.build/release/vtremoted"
```
