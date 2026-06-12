---
title: Benchmarks
description: "VideoToolbox Remote benchmark results for remote H.264/HEVC encoding, with hardware, network, and reproduction caveats."
---

# Benchmarks

These numbers are intended as a practical baseline for FFmpeg users evaluating whether a Mac hardware transcoding server is worth adding to a LAN workflow. Actual throughput depends on source content, bitrate, encoder options, client CPU, network, and whether the session sends raw frames or compressed packets.

## Current Baseline

| Mode | Resolution | Codec | Observed throughput |
| --- | --- | --- | --- |
| Remote encode | 1080p | H.264 | ~230 fps |
| Remote encode | 1080p | HEVC | ~210 fps |
| Remote encode | 4K DCI (4096x2160) | H.264 | ~62 fps |
| Remote encode | 4K DCI (4096x2160) | HEVC | ~59 fps |

The baseline above comes from Apple Silicon loopback-style testing and should be treated as an upper-bound reference, not a network guarantee. Wired LAN is strongly recommended: 1GbE minimum, 2.5GbE+ for 4K.

## What Affects Results

- **Network mode**: Remote encode sends raw frames and benefits from LZ4/Zstd wire compression. Remote transcode sends compressed packets and can use far less bandwidth.
- **Codec and format**: HEVC Main10, HDR signaling, hardware-frame paths, and pixel format conversion can change throughput.
- **Encoder options**: Bitrate, GOP, realtime mode, quality settings, and VideoToolbox capability negotiation all matter.
- **Client work**: Input demux, filters, audio, subtitles, and muxing still happen on the FFmpeg client unless using packet-in/packet-out transcode mode.

## Reproduce Locally

Start a server on the Mac:

```bash
# Trusted private LAN only. Never expose this port directly to the internet.
vtremoted/.build/release/vtremoted --listen <MAC_PRIVATE_IP>:5555 --log-level 1
```

Run the benchmark script from the client checkout:

```bash
VTREMOTE_HOST=<mac-host> VTREMOTE_PORT=5555 VTREMOTE_USE_EXISTING=1 \
VTREMOTED=/bin/true tests/integration/bench_vtremote.sh
```

For release binaries, replace the local `ffmpeg/ffmpeg` path used by the script with the unpacked release client if needed.

```bash
FFMPEG=/path/to/ffmpeg FFPROBE=/path/to/ffprobe \
VTREMOTE_HOST=<mac-host> VTREMOTE_PORT=5555 VTREMOTE_USE_EXISTING=1 \
VTREMOTED=/bin/true tests/integration/bench_vtremote.sh
```

## Interpreting Results

Compare remote encode, remote transcode, and local software or GPU paths on the same source file. For weak clients or slower networks, `-vt_remote_transcode` can be the better mode because the client sends compressed packets to the Mac and receives compressed packets back.

For security and deployment recommendations, see [Security](security.html). For connection and throughput troubleshooting, see [Troubleshooting](troubleshooting.html).
