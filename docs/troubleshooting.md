---
title: Troubleshooting
---

# Troubleshooting

## Connection issues

- Verify the host/port is reachable from the client machine.
- Ensure macOS firewall allows inbound connections to `vtremoted`.
- If using tokens, ensure client/server tokens match.

## Performance issues

- Prefer wired LAN; raw frames are large.
- Wire compression uses **Zstd** by default (~30-40% smaller than LZ4).
- Avoid heavy client-side filters if CPU bound.
- For maximum throughput, ensure the server has these defaults (automatic):
  - `RealTime=false` (batch encoding)
  - `PrioritizeEncodingSpeedOverQuality=true`
  - `MaximizePowerEfficiency=false`
- Increase in-flight frames if you have spare bandwidth:
  ```bash
  -vt_remote_inflight 32
  ```

## "Codec not found" / "Unknown encoder"

- Use the FFmpeg build from `ffmpeg/` (or ensure patches are applied).
- Build with the remote codecs enabled:
  - `--enable-videotoolbox-remote`
- Confirm Zstd/LZ4 was enabled:
  - `--enable-libzstd --enable-liblz4`

## Decode/encode errors

- Ensure you are using the matching remote codec:
  `h264_videotoolbox_remote` or `hevc_videotoolbox_remote`.
- Run with higher log level on the server:
  `--log-level 2`

## Slow HEVC 10-bit encoding

HEVC 10-bit (P010) encoding is more compute-intensive than 8-bit H.264. 
The hardware encoder itself has limits. Typical performance:

- M1/M2 Mac: ~45-50fps for 1080p HEVC 10-bit
- Higher resolutions will be slower

If you see `max_inflight` staying low (e.g., 5), the server-side encoder 
is the bottleneck, not the network.
