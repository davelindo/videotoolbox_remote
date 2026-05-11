# Integration tests (VideoToolbox Remote)

This tree holds VideoToolbox Remote integration tests and benchmarks.

- `mock_vtremoted/`: portable Python mock server to exercise protocol framing and message flow. It responds to HELLO/CONFIGURE/FRAME/FLUSH, can return caller-supplied HEVC fixtures, and exits after FLUSH (see its README for usage).
- `run_mock_roundtrip.sh`: spins up the Python mock and runs `h264_videotoolbox_remote` against it using a built ffmpeg binary (defaults to `ffmpeg/ffmpeg` in the repo root).
- `run_mock_wire_compression.sh`: runs dedicated LZ4 and Zstd mock cases so compressed frame-payload validation is explicit instead of coupled to framing smoke tests.
- `run_mock_protocol_capabilities.sh`: verifies successful capability negotiation and clear configure-time failure when a required 0.4.1 capability is missing.
- `run_mock_side_data_roundtrip.sh`: validates optional PACKET side-data records round-trip through the protocol mock.
- `run_mock_hevc_pixfmt_negotiation.sh`: verifies mock negotiation for HEVC `bgra`, `ayuv`, and `p210le` input formats.
- `run_mock_decode.sh`: spins up the Python mock and runs the `h264_videotoolbox_remote` *decoder* against it (forces `-vt_remote_wire_compression none` since the mock does not compress).
- `run_mock_transcode_hvc1_hdr_signaling.sh`: spins up the Python mock with HEVC Main10 HDR fixtures and asserts both the explicit-override and source-preservation `vtremote_transcode` paths keep `hvc1`, HDR color signaling, and MP4 `nclx` container metadata on HLS/fMP4 output.
- `run_obs_plugin_client_mock.sh`: compiles the OBS plugin client (`obs-plugin/src/vtremoted-client.cpp`) with a local OBS logging stub and runs protocol smoke cases against the Python mock server for `none`, `lz4`, `zstd`, and oversized inbound responses.
- `run_obs_plugin_integration.sh`: builds the actual OBS plugin module against `libobs`, loads it through the OBS module API, creates a real `obs_encoder_t` + `video_t`, and drives the encoder lifecycle against the Python mock server. Skips cleanly when `libobs` dev headers/libs are unavailable.
- `run_complex_chain_test.sh`: exercises a complex filter chain via the mock server to validate framing + options under load.
- `check_pts_dts.sh`: ffprobe-based validator that fails on **non-monotonic DTS** (muxer requirement) and missing keyframes. Note: `pts < dts` is valid when B-frames are used.
- `check_frame_packet_count.sh`: validates that decoded frame count equals packet count (guards against warmup/extra packets).
- `check_bitrate.sh`: validates average bitrate within a tolerance window (guards against broken rate-control).
- `bench_vtremote.sh`: local vs remote encode benchmark across multiple sizes + framerates (skips local codec if unavailable), plus an optional transcode section. Prefers `vtremoted/.build/release/vtremoted` when present.
- `run_vtremoted_roundtrip.sh`: launches `vtremoted` on loopback, runs short H.264 + HEVC `*_videotoolbox_remote` encodes, validates PTS/DTS via `check_pts_dts.sh`, and decodes the result with `ffmpeg -xerror` to catch bad bytestream/packet formatting.
- `run_vtremoted_hevc_pixfmt_parity.sh`: launches `vtremoted` on loopback and verifies remote HEVC accepts `bgra`, `ayuv`, and `p210le` inputs, then decodes each output with `ffmpeg -xerror`.
- `run_vtremoted_hwframe_ingest.sh`: launches `vtremoted` on loopback and verifies H.264/HEVC remote encoders accept `AV_PIX_FMT_VIDEOTOOLBOX` frames from FFmpeg's VideoToolbox `hwupload` path.
- `run_vtremoted_transcode_hardware_ingest.sh`: launches `vtremoted` on loopback and verifies a local VideoToolbox hardware-decode pipeline can feed hardware frames into a remote HEVC encode.
- `run_vtremoted_hwframe_decode.sh`: launches `vtremoted` on loopback and verifies H.264/HEVC remote decoders can return local `AV_PIX_FMT_VIDEOTOOLBOX` frames that survive `hwdownload`.
- `run_vtremoted_hdr_side_data.sh`: launches `vtremoted` on loopback and verifies remote HEVC Main10 output keeps HDR color signaling (`hvc1`, BT.2020, PQ, limited range) and decodes cleanly.
- `run_vtremoted_decode.sh`: generates short local H.264/HEVC inputs and validates remote decode with `h264_videotoolbox_remote` / `hevc_videotoolbox_remote`.
- `run_transcode_test.sh`: simultaneous remote decode + encode pipeline (sanity + stability).
- `run_option_surface_parity.sh`: compares local (`*_videotoolbox`) vs remote (`*_videotoolbox_remote`) encoder option surfaces for H.264/HEVC and fails on drift (ignoring `vt_remote_*` transport-only options).
- `run_vtremoted_transcode_bsf_long.sh`: long-run vtremote_transcode bitstream filter test (optional; 10 minutes by default) to catch timestamp/ordering bugs that only appear after many frames.
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
- `VTREMOTE_BENCH_TRANSCODE=1` (enable transcode section)
- `VTREMOTE_BENCH_ONLY_TRANSCODE=1` (skip encode/decode benches)
- `VTREMOTE_BENCH_TRANSCODE_OUT_CODEC=hevc`
- `VTREMOTE_BENCH_TRANSCODE_PIX_FMT=1` (1=nv12, 2=p010)
- `FFMPEG_LOCAL` defaults to the repo `ffmpeg/ffmpeg` for local encodes (set `FFMPEG_LOCAL=ffmpeg` to use your system build).

Run-all toggles:
- `VTREMOTE_RUN_OBS_PLUGIN=1` runs the OBS plugin client protocol smoke test.
- `VTREMOTE_RUN_OPTION_PARITY=1` runs local-vs-remote encoder option parity checks.

FFmpeg build note: enable the local + remote codecs during configure on macOS, e.g.
`./configure --enable-videotoolbox --enable-videotoolbox-remote`
and keep `--enable-network` on.

Shell compatibility note: integration scripts should remain compatible with the
system Bash 3.2 shipped on macOS. Under `set -u`, optional arrays must use
guarded expansion such as `${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"}`
instead of unguarded `"${TOKEN_ARGS[@]}"`.
