# Integration tests (VideoToolbox Remote)

This tree holds VideoToolbox Remote integration tests and benchmarks.

- `mock_vtremoted/`: portable Python mock server to exercise protocol framing and message flow. It responds to HELLO/CONFIGURE/FRAME/FLUSH, emits dummy Annex B packets, and exits after FLUSH (see its README for usage).
- `run_mock_roundtrip.sh`: spins up the Python mock and runs `h264_videotoolbox_remote` against it using a built ffmpeg binary (defaults to `ffmpeg/ffmpeg` in the repo root).
- `run_complex_chain_test.sh`: exercises a complex filter chain via the mock server to validate framing + options under load.
- `check_pts_dts.sh`: ffprobe-based validator that fails if video packets have `pts < dts`, non-monotonic DTS, missing keyframes, or (optionally) if the average keyframe interval deviates from an expected GOP.
- `check_frame_packet_count.sh`: validates that decoded frame count equals packet count (guards against warmup/extra packets).
- `check_bitrate.sh`: validates average bitrate within a tolerance window (guards against broken rate-control).
- `bench_vtremote.sh`: local vs remote encode benchmark across multiple sizes + framerates (skips local codec if unavailable). Prefers `vtremoted/.build/release/vtremoted` when present.
- `run_vtremoted_roundtrip.sh`: launches `vtremoted` on loopback, runs short H.264 + HEVC `*_videotoolbox_remote` encodes, validates PTS/DTS via `check_pts_dts.sh`, and decodes the result with `ffmpeg -xerror` to catch bad bytestream/packet formatting.
- `run_vtremoted_decode.sh`: generates short local H.264/HEVC inputs and validates remote decode with `h264_videotoolbox_remote` / `hevc_videotoolbox_remote`.
- `run_transcode_test.sh`: simultaneous remote decode + encode pipeline (sanity + stability).
- `run_speed_decode_async.sh`: sync vs async remote decode speed test.
- `run_speed_decode_matrix.sh`: matrix runner over async/sync, reorder depth, and wire compression (outputs CSV).
- `run_all.sh`: convenience runner for the standard integration suite (with optional speed/bench toggles).
- `vtremoted_common.sh`: shared vtremoted start/stop helpers used by integration scripts.

Most scripts default to the repo-built binaries:
- `FFMPEG_BIN` / `FFMPEG` default to `ffmpeg/ffmpeg`
- `FFPROBE_BIN` / `FFPROBE` default to `ffmpeg/ffprobe`
- `VTREMOTED` default to `vtremoted/.build/debug/vtremoted`

Override those env vars as needed to point at local/system builds.

For performance tests and benchmarks, use the release daemon:

```bash
export VTREMOTED="$PWD/vtremoted/.build/release/vtremoted"
```

Async decode defaults:
- `VTREMOTE_DECODE_ASYNC=1` (default on)
- `VTREMOTE_DECODE_REORDER_DEPTH=2`

Bench defaults:
- `VTREMOTE_BENCH_BITRATE=10M`
- `VTREMOTE_BENCH_CBR=1` (adds `-maxrate`/`-bufsize` for apples-to-apples)
- `FFMPEG_LOCAL` defaults to the repo `ffmpeg/ffmpeg` for local encodes (set `FFMPEG_LOCAL=ffmpeg` to use your system build).

FFmpeg build note: enable the local + remote codecs during configure on macOS, e.g.
`./configure --enable-videotoolbox --enable-videotoolbox-remote`
and keep `--enable-network` on.
