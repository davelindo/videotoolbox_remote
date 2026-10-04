# Integration tests (VideoToolbox Remote)

This tree holds VideoToolbox Remote integration tests and benchmarks.

- `run_transport_regressions.py`: complete-message daemon deadlines, session-slot release, normal/BUSY version identity and encoder DONE/error handling. Use `--skip-daemon` on Windows/Linux.
- `socket_timeouts.c`: runtime getsockopt/receive/blocked-send checks for the shared FFmpeg timeout helper, including Winsock milliseconds. Windows CI compiles and runs it.
- `run_decode_duplex.py`: public decoder API regression for simultaneous large uploads/downloads and explicit truncation/timeout errors.
- `run_session_reset.sh`: hardware H.264/HEVC same-context decoder/BSF reuse, including reset with output pending and exact decoded plane checks.
- `check_decode_parity.py`: compares raw decode SHA-256 frame hashes, timestamps and color metadata against a preserved daemon baseline, across none/LZ4/Zstd transport.
- `bench_sustained.py`: reusable natural-video, sustained and concurrent comparisons; see the command and metric definitions below.
- `performance.py`: current five-pipeline Intel/software/local-Mac/remote-Mac comparison; see [Performance comparison](#performance-comparison).
- `bench_inflight.py`: fixed/automatic depth comparisons with controlled response delay and changing processing capacity. Its packets are protocol fixtures, not decodable media.
- `run_obs_pipeline.py`: bounded worker API throughput/cancellation experiment, excluded from the plugin build pending a supported OBS drain API. Its explicit drain is not evidence of correct normal OBS recording shutdown.
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
- `VTREMOTE_OBS_RECORDINGS=1 bash tests/integration/run_obs_plugin_integration.sh`: additionally uses a disposable loopback hardware daemon and a local libobs test output backed by libavformat. Records H.264/NV12 and HEVC/P010 through normal output start/stop, verifies container signaling, extradata, software decode and all 60 submitted frames, and retains recordings/logs under the printed temporary directory. Requires built FFmpeg libraries and libobs. It has no streaming/service configuration.
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
- `run_mock_transcode_cli_options.py`: verifies CLI `host:port`, stream-specific options, and exact authentication tokens through automatic transcode BSF construction.
- `run_vtremoted_interlaced.sh`: checks synthetic progressive and both field orders of interlaced H.264 in MP4 and MPEG-TS, local `bwdif` with remote encode, and progressive/interlaced sequence changes with frame counts and pixel comparisons in both decode modes. Requires macOS, `vtremoted`, and a local FFmpeg with `libx264` and `ssim`.
- `run_vtremoted_paff.py`: downloads four SHA-256-pinned FFmpeg FATE fixtures, checks separate fields, mixed PAFF and fields already paired in a packet, and verifies output frame/packet counts, ordered PTS, independent decode and SSIM against software decode. Runs synchronous and asynchronous decode with one input credit. Requires macOS and a local FFmpeg with `dts2pts` and `ssim`; `--fixtures DIR` reuses downloaded samples.
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

For a sustained comparison on macOS, preserve the baseline binaries first, then run:

```bash
python3 tests/integration/bench_sustained.py \
  --input /path/to/natural-main10.mp4 --output /tmp/vtr-comparison \
  --baseline-daemon /path/to/baseline/vtremoted \
  --modes encode,decode,transcode --sessions 1,2,4 \
  --frames 1800 --warmup-frames 120 --min-seconds 30 --repeats 3 \
  --fixture-source 'fixture provenance' --wire lz4
```

The command owns fresh loopback daemons. It repeats compressed input packets into finite local fixtures, avoiding seek/reconnect work inside measured runs. Session modes cycle through the requested list; use `--modes decode` for decode-only comparisons and `--depths 0,8,16,32,64` for encoder depth cases. `--baseline-ffmpeg` can compare client binaries too. The output directory must be new.

`metadata.json`, `runs.jsonl`, and `summary.json` capture source/binary/fixture identity, settings, fps, CPU time, peak RSS, wire bytes, exact counts and independent decode validation of encoded output. Summary distributions include variation. Latencies run from server input submission through completed output send; logarithmic histogram counts merge across sessions and repeats for p50/p95/p99 (up to 4.5% bucket quantization above the one-microsecond floor). Old baseline binaries without histograms retain their per-session percentiles but have no merged percentile estimate. Summed process RSS peaks are an upper bound, not a simultaneous measurement. Raw-fps Jain fairness is meaningful for equal workloads; mixed modes have different costs.

Warm-up throughput estimates each session's frame count for the requested minimum duration. Check `all_sustained`; increase `--frames` if any run is shorter. Correctness failures stop the run independently of speed. Raw decode timing runs validate counts; use the API/plane tests and a separate pixel comparison when changing decode memory paths. No hardware regression threshold is chosen before measuring variance. This runner currently measures loopback; the existing `bench_vtremote.sh` supports an explicitly designated remote server, without the new aggregate resource capture.

## Performance comparison

The [Performance page](https://davelindo.github.io/videotoolbox_remote/performance.html) uses `performance.py`. It compares Intel iGPU VA-API, CPU `fast` and `medium` presets, native VideoToolbox and packet transcoding through remote VideoToolbox. Both VideoToolbox paths run on the same designated Mac; the remote client runs on the designated Linux host. The coordinator only dispatches SSH jobs and collects results.

Prerequisites:

- Linux: Python 3.11+, `/usr/bin/ffmpeg` with `libx264` for fixture preparation; Intel iHD driver and access to `/dev/dri/renderD128`. Native measurement uses a separate build with `libx264`, `libx265`, VA-API and `libvmaf`; older Ubuntu FFmpeg can exhaust its VA-API filter frame pool.
- Mac: Python at `/opt/homebrew/bin/python3`, FFmpeg and ffprobe at `/opt/homebrew/bin/`, with VideoToolbox, `scale_vt` and `libvmaf` enabled.
- Coordinator: Python 3.11+, SSH key access to both hosts and the repository checkout. Install the checksum-verified release Linux FFmpeg/ffprobe and Mac daemon on their respective hosts; the release client includes `libvmaf` for validation.
- A direct private LAN route from the Linux host to the Mac, with an unused benchmark port (default 5569). Existing daemons are not reused or stopped.

Keep a common working directory outside every Git checkout, for example `/tmp/vtremote-performance`, on all three machines. Install Linux release binaries in its `bin/` directory and the Mac release daemon at `vtremoted/vtremoted`. Copy `performance.py` to the working directory on both hosts. The suite deliberately requires those tool locations so the pipeline definitions stay consistent.

On Linux, unpack the matching release's vendored `ffmpeg/` source under `native-src/`. With development libraries and NASM installed, build the shared Intel/CPU baseline there:

```bash
cd /tmp/vtremote-performance/native-src
./configure --disable-autodetect --disable-doc --disable-debug --disable-ffplay \
  --disable-bsf=vtremote_transcode \
  --enable-gpl --enable-libx264 --enable-libx265 --enable-vaapi --enable-libvmaf
make -j4 ffmpeg ffprobe
mkdir ../native-bin
cp ffmpeg ffprobe ../native-bin/
```

On Linux, download the [official Big Buck Bunny archive](https://download.blender.org/demo/movies/BBB/bbb_sunflower_1080p_30fps_normal.mp4.zip) into `downloads/bbb_sunflower_1080p_30fps_normal.mp4.zip` under the working directory. Prepare the three 60-second inputs there:

```bash
python3 /tmp/vtremote-performance/performance.py \
  --workdir /tmp/vtremote-performance prepare
```

Copy the entire generated `fixtures/` directory to the same location on the Mac. The suite verifies identical input hashes before starting. It uses the movie's seconds 60–120, a moving `testsrc2` signal and static `smptebars`, prepared as 1080p30 H.264 High 8-bit video.

Supply SSH destinations and the Mac's private LAN address locally; **never put real hostnames, usernames, addresses or private paths in tracked files or PR metadata**. Replace the placeholders in your private terminal session:

```bash
python3 tests/integration/performance.py \
  --workdir /tmp/vtremote-performance --server <private-mac-address> \
  suite --linux-host <linux-ssh-destination> --mac-host <mac-ssh-destination> \
  --release v0.9.14 --output /tmp/vtremote-performance/current
```

Start with a short preflight by adding `--fixtures big-buck-bunny --sizes 1280x720 --frames 60 --warmup-frames 30 --repeats 1` and choosing a separate, new output directory. Preflight results cannot be published. The complete default run measures 60 cases: three inputs, two codecs, two output sizes and five pipelines. Each case gets a warm-up and three measured repeats; order rotates and jobs run sequentially. VMAF samples every fifth frame and SSIM covers all frames on the first measured repeat. Validation checks frame/packet counts, profile, pixel format, dimensions, monotonic DTS and independent software decoding.

Raw `metadata.json`, `runs.jsonl`, `summary.json`, worker captures and logs contain private infrastructure details. Keep them outside Git. The runner refuses capture directories inside a Git checkout. For publication, this command prints only allowed measurements, generic labels, tool versions and SHA-256 hashes:

```bash
python3 tests/integration/performance.py \
  --workdir /tmp/vtremote-performance public-results \
  --input /tmp/vtremote-performance/current/summary.json
```

Review that output before updating `docs/_data/performance.json`. The exporter rejects incomplete, failed or short comparisons and excludes inventory, commands, paths and addresses. Run `python3 tests/test_performance.py` before committing. The page reports delivered bitrate alongside quality and throughput; client CPU time excludes the remote daemon. Intel RAPL captures are private diagnostics, not whole-system power measurements.

## Integration script options

These options apply to the integration and `bench_vtremote.sh` scripts above, rather than the five-pipeline performance runner.

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
- `VTREMOTE_RUN_INTERLACED=1` runs the synthetic interlaced H.264 checks.
- `VTREMOTE_RUN_PAFF=1` runs the field-packet conformance checks; this downloads about 8 MB on first run. `FFMPEG_LOCAL_BIN` and `FFPROBE_LOCAL_BIN` select the local reference tools.

FFmpeg build note: enable the local + remote codecs during configure on macOS, e.g.
`./configure --enable-videotoolbox --enable-videotoolbox-remote`
and keep `--enable-network` on.

Shell compatibility note: integration scripts should remain compatible with the
system Bash 3.2 shipped on macOS. Under `set -u`, optional arrays must use
guarded expansion such as `${TOKEN_ARGS[@]+"${TOKEN_ARGS[@]}"}`
instead of unguarded `"${TOKEN_ARGS[@]}"`.
