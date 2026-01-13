# Security

## Important: token auth ≠ encryption

This project supports an optional shared token, but traffic is still plain TCP.
Do not expose `vtremoted` directly to the public internet.

---

## Recommended baseline (LAN-only)

- Run `vtremoted` on a private LAN
- Enable token auth:
  - server: `--token YOUR_TOKEN`
  - client: `-vt_remote_token YOUR_TOKEN`
- Restrict inbound access using macOS firewall (or a router firewall)

---

## Safer setup: SSH tunnel

If you need to run this across networks, tunnel it.

### On the Mac (server)
Bind to localhost so it is not reachable over the LAN:

```bash
vtremoted --listen 127.0.0.1:5555 --token YOUR_TOKEN
```

### On the client

Create a tunnel:

```bash
ssh -L 5555:127.0.0.1:5555 youruser@your-mac-hostname
```

Then point FFmpeg at localhost:

```bash
ffmpeg ... -vt_remote_host 127.0.0.1:5555 -vt_remote_token YOUR_TOKEN ...
```

This gives you encryption + authentication through SSH.

---

## Safer setup: VPN

If you already have a VPN between machines, you can:

* bind `vtremoted` to the VPN interface IP
* firewall it so it’s only reachable from the VPN network
---
title: Security
---

# Security

This project uses plain TCP. Token auth is optional and is **not** encryption.

Recommendations:

- Do not expose the daemon port directly to the public internet.
- Prefer LAN-only usage.
- If you need encryption, tunnel with SSH or run through a VPN.
- Use `--token` on the server and `-vt_remote_token` on the client on shared networks.
