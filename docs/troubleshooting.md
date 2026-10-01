---
title: Troubleshooting
description: "Diagnose and fix common VideoToolbox Remote issues: connection failures, encoder throughput limits, pixel format mismatches, and network performance tuning."
---

# Troubleshooting

Common issues and their solutions.

## Connection Issues

### Unable to connect to server
**Symptom**: `Connection refused` or timeout.
**Checks**:
1.  **Reachability**: Can you ping the Mac's IP from the client?
2.  **Firewall**: Ensure the macOS firewall allows incoming TCP connections to `vtremoted` (port 5555).
3.  **Port**: Verify `vtremoted` is running and listening on `0.0.0.0` (not just `localhost`).

### Auth Failure
**Symptom**: Server closes connection immediately with an error.
**Solution**: Ensure the `token` on the client matches the server's `--token`.

## Performance Issues

### Low Throughput / Dropped Frames
**Symptom**: Encoding speed is below real-time or choppy.
**Solutions**:
- **Network**: Use wired LAN (1GbE+). Wi-Fi is often too unstable for raw frame streaming.
- **Optimization**:
    - Increase in-flight frames: `-vt_remote_inflight 32`
    - Or let it adapt: `-vt_remote_inflight auto`
    - Use Transcode mode (`-vt_remote_transcode`) to reduce network load.
- **Compression**: Ensure wire compression is enabled. FFmpeg/OBS default to **LZ4**; the VA-API driver defaults to `auto`. Override FFmpeg with `-vt_remote_wire_compression lz4|zstd|none`, or use `auto` to pick based on resolution/FPS.

### High Latency
**Symptom**: Delay in live streaming.
**Solution**: Use `-realtime 1` on the client to tell the server to prioritize latency over throughput.

## Build & Installation

### "Codec not found"
**Cause**: FFmpeg build used does not include the remote codecs.
**Solution**:
- Ensure you are running the `ffmpeg` binary from `ffmpeg/`.
- Reconfigure with `--enable-videotoolbox-remote`.

### Linux build fails in FFmpeg x86 assembly
**Symptom**: The build fails in an FFmpeg x86 assembly file, or the error mentions `nasm`, `yasm`, or an unsupported x86 instruction.
**Checks**:
1. Confirm you are building on 64-bit Linux:
   ```bash
   uname -m
   ```
   Supported Linux release artifacts target `x86_64`, not 32-bit `i686`.
2. Install current assemblers:
   ```bash
   nasm -v
   yasm --version
   ```
3. Clean and rebuild after installing them:
   ```bash
   make clean-ffmpeg
   make build-ffmpeg
   ```
4. If the failure persists, confirm it is isolated to x86 assembly with the compatibility fallback:
   ```bash
   make clean-ffmpeg
   make build-ffmpeg FFMPEG_DISABLE_X86ASM=1
   ```

`FFMPEG_DISABLE_X86ASM=1` appends `--disable-x86asm`. It can reduce FFmpeg performance, so use it as a diagnostic or compatibility fallback rather than the default build.

### macOS Build Fails
**Error**: `videotoolbox requested, but not all dependencies are satisfied`.
**Solution**:
- Ensure Xcode command line tools are active: `xcode-select -p`.
- Build with SDK path explicitly:
  ```bash
  SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" make build-ffmpeg
  ```

### Verify a running macOS server after upgrade
**Symptom**: Multiple `vtremoted` processes are running, or a LaunchAgent and LaunchDaemon point at different binaries.
**Solution**:
1. Check the packaged binary:
   ```bash
   vtremoted --version
   ```
2. Check launchd state:
   ```bash
   launchctl print "gui/$(id -u)/com.davelindon.vtremoted"
   ```
   For a system LaunchDaemon, use:
   ```bash
   sudo launchctl print system/com.davelindon.vtremoted
   ```
3. Check listeners and process paths:
   ```bash
   pgrep -fl vtremoted
   lsof -nP -iTCP:5555 -sTCP:LISTEN
   ```
4. If using the Makefile install path, rebuild, reinstall, restart, and verify with:
   ```bash
   make install-vtremoted-restart VTREMOTED_LISTEN=<MAC_PRIVATE_IP>:5555
   ```

## Encoding/Decoding

### Remote transcode decoder fails on interlaced H.264

If `-vt_remote_transcode` reports `decoder callback produced no frame`, retain
the numeric decoder status, full server log, `vtremoted --version`, macOS
version, and a short failing source sample. The message alone does not establish
that all interlaced H.264 is unsupported. The server logs whether the decoder
reports hardware use, plus callback flags and timestamps on failure. An
`unknown(status=...)` hardware property is inconclusive.

The synthetic regression checks progressive and MBAFF H.264, both field orders,
and both MP4 and MPEG-TS:

```bash
bash tests/integration/run_vtremoted_interlaced.sh
```

MBAFF does not cover separately coded PAFF fields. The transcode filter joins
complementary H.264 fields before submitting a complete picture to VideoToolbox.
It preserves packets already containing both fields and frame-coded pictures
within mixed PAFF streams. A missing or mismatched complementary field produces
an explicit input error rather than encoding a field as a full frame. Test that
path with the pinned public FFmpeg conformance samples:

```bash
python3 tests/integration/run_vtremoted_paff.py --fixtures /tmp/vtremote-paff-fixtures
```

This downloads four hash-checked fixtures and checks frame counts, timestamps,
independent decoding and pixel similarity with synchronous and asynchronous
decode. The local reference FFmpeg needs `dts2pts` and `ssim`. Raw H.264 samples
need picture-order PTS before remuxing: assigning decode-order timestamps can
misorder B-frames and invalidate a comparison.

The daemon also refreshes the decoder when H.264 sequence parameters change.
It drains delayed frames before replacing the session, which lets a stream
switch between progressive and interlaced coding without feeding the new
sequence to the previous decoder. Compatible PPS updates keep reference state.
The synthetic regression includes a progressive → top-first → bottom-first →
progressive transition and verifies all 100 output frames against software decode.

These changes do not establish the cause of issue #24's `-12350` status. A
damaged public PAFF capture reproduces that status even after keyframe remuxing;
software decode also reports reference and macroblock errors for that capture.
Retain the reporter's source and macOS version to distinguish a codec limitation,
damaged input, and parameter changes. Use `-xerror` in reproductions and inspect
the server log and decoded frame count: FFmpeg can otherwise return zero after
a transcode filter error.

For a source that the server's VideoToolbox decoder cannot handle, use local
software decode and deinterlace, then send frames to the remote encoder:

```bash
ffmpeg -i interlaced.ts -map 0:v:0 -map '0:a:0?' -c:a copy \
  -vf bwdif=mode=send_frame -pix_fmt nv12 -c:v h264_videotoolbox_remote \
  -vt_remote_host mac-host:5555 -b:v 8M -g:v 50 \
  -f mpegts out.ts
```

This path uses client CPU for decode and deinterlace and sends raw frames over
the network. `send_frame` preserves the input frame rate. Remote transcode has
no automatic software decode or deinterlace fallback.

### VA-API driver does not load

Confirm that `VTREMOTE_HOST` is set, a render node is accessible to the process,
and the isolated driver path is active:

```bash
export LIBVA_DRIVERS_PATH=/opt/vtremote-vaapi/lib/dri
export LIBVA_DRIVER_NAME=vtremote
/opt/vtremote-vaapi/bin/vtremote-probe --host "$VTREMOTE_HOST" --codec h264
```

With no physical GPU, stock VA-API applications can use a `vgem` render node.
The Plex packet-transcode image does not use libva and needs no render node.

### Plex transcode still uses substantial Linux CPU

Confirm that the input is H.264 or HEVC and that Plex emitted the supported
software-scale/format/hardware-upload graph. A successful remote handshake
appends `remote-decode-scale-encode` to `VTREMOTE_PLEX_AUDIT_FILE`. If the
marker does not appear, the wrapper deliberately passed the command through
unchanged.
This also happens when Plex's bundled `libavcodec` fingerprint or full
`avcodec_version()` is not on the tested allowlist, when the command contains
an encoder constraint that cannot be translated exactly, or when it contains
multiple video inputs or outputs.
Tone mapping, deinterlace, subtitle burn-in, unsupported graphs, audio
transcoding, and container I/O can still consume Linux CPU.

### Slow HEVC 10-bit Encoding
**Context**: 10-bit HEVC is compute-intensive. Expect ~200 fps at 1080p and ~60 fps at 4K on Apple Silicon (loopback). Over a real network, throughput depends on bandwidth and latency.
**Diagnosis**: If `max_inflight` stays low (e.g., < 5), the bottleneck is the Mac's hardware encoder, not the network.
