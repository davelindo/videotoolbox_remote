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

## Security notes

* Do not expose this directly to the public internet.
* Prefer token auth (`--token`) and/or SSH tunneling.