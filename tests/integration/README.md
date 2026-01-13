# Integration tests (VideoToolbox Remote)

This tree holds pre-VideoToolbox integration scaffolding.

- `mock_vtremoted/`: portable Python mock server to exercise protocol framing and message flow. It responds to HELLO/CONFIGURE/FRAME/FLUSH, emits dummy Annex B packets, and exits after FLUSH (see its README for usage).
- `run_mock_roundtrip.sh`: convenience script to spin up the Python mock and run `h264_videotoolbox_remote` against it using a built ffmpeg binary (expects `../ffmpeg/ffmpeg` by default).
- `check_pts_dts.sh`: ffprobe-based validator that fails if video packets have `pts < dts`, non-monotonic DTS, missing keyframes, or (optionally) if the average keyframe interval deviates from an expected GOP.
- `check_frame_packet_count.sh`: validates that decoded frame count equals packet count (guards against warmup/extra packets).
- `check_bitrate.sh`: validates average bitrate within a tolerance window (guards against broken rate-control).
- `bench_vtremote.sh`: lightweight local vs remote performance sweep for H.264 (720p30/1080p30/1080p60) and HEVC (1080p30).
- `run_vtremoted_roundtrip.sh`: launches `vtremoted` on loopback, runs short H.264 + HEVC `*_videotoolbox_remote` encodes, validates PTS/DTS via `check_pts_dts.sh`, and decodes the result with `ffmpeg -xerror` to catch bad bytestream/packet formatting.
- `run_vtremoted_decode.sh`: generates short local H.264/HEVC inputs and validates remote decode with `h264_videotoolbox_remote` / `hevc_videotoolbox_remote`.

Once real encoders/server land, add scripts here to:
1. Start `vtremoted` on macOS.
2. Run FFmpeg with `*_videotoolbox_remote` encoders from another machine (lavfi `testsrc2` preferred).
3. Validate with `ffprobe` (duration, stream parameters, seekability).

FFmpeg build note: enable the remote codecs during configure, e.g.
`./configure --enable-videotoolbox-remote`
and keep `--enable-network` on.
