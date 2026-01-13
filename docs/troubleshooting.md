# Troubleshooting

This is a checklist for the most common “it doesn’t work” cases.

---

## 1) Connection failures

### Symptoms
- FFmpeg errors like “connection refused” / “timed out”
- The transcode hangs immediately

### Checklist
- Is `vtremoted` running?
- Is it listening on the interface you think it is?
  - If you used `127.0.0.1`, it will NOT be reachable from other machines.
- Is the port open in macOS firewall?
- Can you reach it from the client?
  - Try `nc -vz macmini.local 5555` (or equivalent)

---

## 2) Token/auth failures

### Symptoms
- Connect succeeds, then immediate disconnect
- Server logs show auth failures

### Checklist
- Make sure client `-vt_remote_token` matches server `--token`
- Remove token flags on both sides to confirm basic connectivity, then re-enable

---

## 3) Performance is terrible

### Typical causes
- Wi‑Fi instead of wired LAN
- 1GbE link saturated by high-res/high-fps raw frames
- CPU bottlenecks on client due to heavy filters

### Fixes
- Use wired ethernet
- Keep LZ4 wire compression enabled (default)
- Reduce resolution/fps, or avoid expensive filters
- If doing 4K, strongly consider >1GbE networking

---

## 4) “Codec not found” / “Unknown encoder”

### Checklist
- You must use the FFmpeg build from `ffmpeg/` (or ensure patches are applied).
- Confirm build flags included the remote encoders/decoders:
  - `--enable-encoder=h264_videotoolbox_remote` etc.
- Confirm LZ4 was enabled:
  - `--enable-liblz4`

---

## 5) How to get useful logs

- Run server in foreground with a higher log level:
  `vtremoted --log-level 1 ...`
- Run FFmpeg with more logging:
  - `-loglevel verbose` or `-loglevel debug`
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

## Decode/encode errors

- Ensure you are using the matching remote codec:
  `h264_videotoolbox_remote` or `hevc_videotoolbox_remote`.
- Run with higher log level (`--log-level 2`) on the server.
