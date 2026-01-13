# vtremoted

SwiftPM daemon that implements the VideoToolbox Remote protocol v1 and performs real VideoToolbox H.264/HEVC encode + decode (Annex B on wire).

## Build

```bash
cd vtremoted
brew install lz4 pkg-config
swift build -c debug
```

## Run

```bash
.build/debug/vtremoted --listen 0.0.0.0:5555 --log-level 1
```

Use `--once` to exit after a single session (good for tests).
Log level: 0=errors, 1=info (default), 2=debug.
Wire compression is enabled by default (lz4). Disable with `-vt_remote_wire_compression none`.
Token auth is optional; add `--token YOURTOKEN` to enforce.

### Launchd (recommended)

```bash
./install_launchd.sh --bin /usr/local/bin/vtremoted --listen 0.0.0.0:5555
```

Debug helpers:
- `VTREMOTED_DUMP_FIRST=1` writes the first encoded packet to `/tmp/vtremoted_firstpkt.bin`
- `VTREMOTED_DUMP_EXTRA=1` writes codec extradata (avcC/hvcC) to `/tmp/vtremoted_extradata.bin`

Notes:
- Protocol v1, Annex B packets; extradata is avcC.
- NV12 frames required in MVP; frame reordering disabled for monotonic DTS.
