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
- Keep LZ4 wire compression enabled (default).
- Avoid heavy client-side filters if CPU bound.

## “Codec not found” / “Unknown encoder”

- Use the FFmpeg build from `ffmpeg/` (or ensure patches are applied).
- Build with the remote codecs enabled:
  - `--enable-videotoolbox-remote`
- Confirm LZ4 was enabled:
  - `--enable-liblz4`

## Decode/encode errors

- Ensure you are using the matching remote codec:
  `h264_videotoolbox_remote` or `hevc_videotoolbox_remote`.
- Run with higher log level on the server:
  `--log-level 2`
