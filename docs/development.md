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
- `bench_vtremote.sh` — local vs remote encode benchmark + optional transcode bench

For performance tests, use a release server:

```bash
export VTREMOTED="$PWD/vtremoted/.build/release/vtremoted"
```

Transcode bench toggles:

```bash
VTREMOTE_BENCH_TRANSCODE=1   # enable/disable transcode section
VTREMOTE_BENCH_ONLY_TRANSCODE=1
```

## Real-world testing notes

We benchmarked a Linux client against an Apple Silicon (M2) macOS server over a 2.5GbE LAN. Summary:

- 1080p60 remote encode is near‑parity with local VideoToolbox on the Mac.
- 4k60 encode falls below realtime on this link.
- For raw‑frame encode, `lz4` outperforms `zstd`; `none` performs poorly on this link.
- Transcode throughput is similar or slightly lower than encode‑only (expected), but keeps compressed packets on the wire.

### CPU sampling evidence (weak‑CPU clients)

To quantify client CPU savings, we measured 1080p60, 10s runs (10M, GOP 120, LZ4):

- **Remote encode (raw frames)**: ~145% client CPU
- **Remote transcode (packet in/out)**: ~6–7% client CPU

This shows transcode mode dramatically reduces client CPU, which is the primary win for weak CPUs.

To reproduce on your setup:

```bash
VTREMOTE_HOST=<mac-host> VTREMOTE_PORT=5555 VTREMOTE_USE_EXISTING=1 \
VTREMOTED=/bin/true tests/integration/bench_vtremote.sh
```
