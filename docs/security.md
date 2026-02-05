---
title: Security
---

# Security

> [!CAUTION]
> **No Encryption By Default**
> The VideoToolbox Remote protocol runs over plain TCP. Traffic is **NOT** encrypted.
> Do **NOT** expose the daemon port (default 5555) directly to the public internet.

## Token Authentication

The server supports a simple token-based authentication mechanism.

- **Server**: Start with `--token <secret>`
- **Client**: Run with `-vt_remote_token <secret>`

> [!WARNING]
> This token prevents unauthorized access but does **not** protect against eavesdropping or man-in-the-middle attacks.

## Recommended Secure Setup

If you must run this over an untrusted network (e.g., across the internet), use a secure tunnel.

### Option 1: SSH Tunnel (Recommended)

1.  **Bind to localhost**: Start the server bound only to loopback.
    ```bash
    vtremoted --listen 127.0.0.1:5555
    ```

2.  **Create Tunnel**: From the client, create an encrypted tunnel.
    ```bash
    ssh -L 5555:localhost:5555 user@mac-server
    ```

3.  **Connect**: Point FFmpeg to localhost.
    ```bash
    ffmpeg ... -vt_remote_host 127.0.0.1:5555 ...
    ```

### Option 2: VPN / Tailscale

Run both client and server on a private Tailscale network (or WireGuard/OpenVPN). Use the VPN IP addresses for connection. This provides encryption transparently.
