---
title: Benchmarks
description: "VideoToolbox Remote benchmark results for remote H.264/HEVC encoding, with hardware, network, and reproduction caveats."
---

# Benchmarks

These numbers are intended as a practical baseline for FFmpeg users evaluating whether a Mac hardware transcoding server is worth adding to a LAN workflow. Actual throughput depends on source content, bitrate, encoder options, client CPU, network, and whether the session sends raw frames or compressed packets.

## v0.7.0 Validated Baseline

The primary v0.7.0 validation used a Linux client and an M2 Air VideoToolbox server connected at 2.5 GbE. Measured TCP capacity was approximately 1.93 Gb/s client-to-server and 2.35 Gb/s server-to-client. Encode comparisons use three alternating local/remote repeats, except the tuned HEVC 4K speed result from a two-repeat fixed-depth sweep. Decode and transcode comparisons use two repeats.

### Encode

| Codec and mode | Resolution | Local VideoToolbox | Remote VideoToolbox | Remote/local |
| --- | --- | ---: | ---: | ---: |
| H.264 default | 1920x1080 | 182.3 fps | 182.7 fps | 100.3% |
| H.264 default | 3840x2160 | 48.4 fps | 48.3 fps | 99.8% |
| HEVC Main10 default | 1920x1080 | 189.7 fps | 190.7 fps | 100.5% |
| HEVC Main10 default | 3840x2160 | 51.3 fps | 51.1 fps | 99.6% |
| HEVC Main10 `prio_speed=1` | 1920x1080 | 316.5 fps | 313.0 fps | 98.9% |
| HEVC Main10 `prio_speed=1` | 3840x2160 | 90.1 fps | 89.0 fps | 98.8% |

All corrected encode cases preserved exact input-frame/output-packet counts. A fixed `-vt_remote_inflight 32` performed best for the high-throughput HEVC 4K speed case. Encode wire traffic remained below approximately 600 Mb/s with LZ4, leaving substantial headroom on the tested link.

### Decode and Transcode

| Mode | Codec and resolution | Local VideoToolbox | Remote VideoToolbox | Remote/local |
| --- | --- | ---: | ---: | ---: |
| Raw decode | H.264 3840x2160 | 169.2 fps | 177.5 fps | 104.9% |
| Raw decode | HEVC Main 3840x2160 | 171.3 fps | 218.1 fps | 127.3% |
| Raw decode | HEVC Main10 3840x2160 | 398.7 fps | 117.3 fps | 29.4% |
| Packet transcode | HEVC Main10 3840x2160 | 83.5 fps | 83.6 fps | 100.2% |

Raw Main10 decode returned approximately 1.8 Gb/s after LZ4 and was limited by P010 copying/compression and network transport. The equivalent packet-in/packet-out Main10 transcode used approximately 14 Mb/s in each direction and matched local throughput with exact 1,800-packet input/output counts.

### Loopback Upper Bound

Apple Silicon loopback testing remains useful as an upper-bound reference: approximately 230 fps H.264 and 210 fps HEVC at 1080p, and 62 fps H.264 and 59 fps HEVC at 4K DCI (4096x2160). Wired LAN is strongly recommended: 1 GbE minimum and 2.5 GbE or faster for 4K.

These results use deterministic synthetic sources and short benchmark windows. Natural-video content, concurrent traffic, thermals, codec settings, and client-side filtering can materially change throughput.

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

Compare remote encode, remote transcode, and local software or GPU paths on the same source file. For weak clients, slower networks, or HEVC Main10 pipelines that do not need raw client-side frames, prefer `-vt_remote_transcode` because the client sends compressed packets to the Mac and receives compressed packets back. For maximum-throughput HEVC encoding on a low-latency 2.5 GbE LAN, start with `-vt_remote_inflight 32` and validate latency and throughput against the actual workload.

For security and deployment recommendations, see [Security](security.html). For connection and throughput troubleshooting, see [Troubleshooting](troubleshooting.html).
