---
title: Troubleshooting
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
    - Use Transcode mode (`-vt_remote_transcode`) to reduce network load.
- **Compression**: Ensure wire compression is enabled. Default is **LZ4**. Override with `-vt_remote_wire_compression lz4|zstd|none`.

### High Latency
**Symptom**: Delay in live streaming.
**Solution**: Use `-realtime 1` on the client to tell the server to prioritize latency over throughput.

## Build & Installation

### "Codec not found"
**Cause**: FFmpeg build used does not include the remote codecs.
**Solution**:
- Ensure you are running the `ffmpeg` binary from `ffmpeg/`.
- Reconfigure with `--enable-videotoolbox-remote`.

### macOS Build Fails
**Error**: `videotoolbox requested, but not all dependencies are satisfied`.
**Solution**:
- Ensure Xcode command line tools are active: `xcode-select -p`.
- Build with SDK path explicitly:
  ```bash
  SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" make build-ffmpeg
  ```

## Encoding/Decoding

### Slow HEVC 10-bit Encoding
**Context**: 10-bit HEVC is compute-intensive.
**Expectation**: M1/M2 Macs typically hit ~45-50fps for 1080p 10-bit. Higher resolutions will be slower.
**Diagnosis**: If `max_inflight` stays low (e.g., < 5), the bottleneck is the Mac's hardware encoder, not the network.
