# vtremoted (macOS server)

`vtremoted` is the macOS daemon that runs VideoToolbox encode/decode on behalf of a remote FFmpeg client.

## Build

```bash
brew install lz4 zstd pkg-config
swift build -c release
```

## Run (foreground)

```bash
.build/release/vtremoted --listen 0.0.0.0:5555 --log-level 1
```

## Run (as a service)

```bash
./install_launchd.sh --bin /usr/local/bin/vtremoted --listen 0.0.0.0:5555
```

## Command-line options

| Option | Default | Description |
|--------|---------|-------------|
| `--listen` | `0.0.0.0:5555` | Address and port to listen on |
| `--token` | (none) | Require clients to authenticate with this token |
| `--max-sessions` | `4` | Maximum concurrent encode/decode sessions |
| `--log-level` | `0` | Verbosity: 0=info, 1=debug, 2=trace |
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
* Prefer token auth (`--token`) and/or SSH tunneling.