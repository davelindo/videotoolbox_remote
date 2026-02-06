# vtremoted (macOS server)

`vtremoted` is the macOS daemon that runs VideoToolbox encode/decode on behalf of a remote FFmpeg client.

## Build

```bash
brew install lz4 zstd pkg-config
swift build -c release
```

## Run (foreground)

```bash
# Default is loopback-only (safe). For LAN clients, bind explicitly:
.build/release/vtremoted --listen 0.0.0.0:5555 --log-level 1
```

## Run (as a service)

```bash
./install_launchd.sh --bin /usr/local/bin/vtremoted --listen 0.0.0.0:5555
```

## Transcode mode

The server also supports packet-in/packet-out transcode sessions (decode + encode on the Mac).
From the client, add `-vt_remote_transcode` to a normal VideoToolbox encode command and provide
`-vt_remote_host`. Optional scaling/format conversion is applied on the server.

## Command-line options

| Option | Default | Description |
|--------|---------|-------------|
| `--listen` | `127.0.0.1:5555` | Address and port to listen on |
| `--token` | (none) | Require clients to authenticate with this token (avoid in production; leaks into process listings) |
| `--token-file` | (none) | Read token from a file (recommended) |
| `--token-env` | (none) | Read token from an environment variable |
| `--max-sessions` | `4` | Maximum concurrent encode/decode sessions |
| `--handshake-timeout` | `10` | Seconds allowed for HELLO/CONFIGURE |
| `--idle-timeout` | `60` | Seconds allowed between messages before disconnect |
| `--max-message-bytes` | `268435456` | Hard cap on any single message body (prevents OOM) |
| `--log-level` | `1` | Verbosity: 0=error, 1=info, 2=debug |
| `--once` | (flag) | Exit after handling one client (for testing) |

## Performance

The server automatically applies optimal VideoToolbox settings for batch encoding:

- **PrioritizeEncodingSpeedOverQuality**: enabled by default
- **RealTime**: disabled by default (maximizes throughput)
- **MaximizePowerEfficiency**: disabled by default (maximizes speed)
- **MaxFrameDelayCount**: set to 8 for parallel encoding
- **ExpectedFrameRate**: set from client's framerate

These defaults are optimal for offline transcoding. For realtime/streaming use cases, 
the client can pass `-realtime 1` to disable speed prioritization.

## Security notes

* Do not expose this directly to the public internet.
* Prefer token auth (`--token-file`) and/or SSH tunneling.
