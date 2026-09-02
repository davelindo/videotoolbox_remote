---
title: Linux VA-API Driver and Plex
description: "Install the VTRemote H.264/HEVC VA-API encoder on Linux and validate Plex remote decode, scale, and encode."
---

# Linux VA-API Driver and Plex

The `vtremote-vaapi-linux-x86_64.tar.gz` release asset lets a stock Linux
VA-API application send H.264 or HEVC encoding to `vtremoted`. It supports
H.264 Baseline/Main/High, HEVC Main, and HEVC Main 10 with NV12/P010 input.

The general-purpose VA-API driver is encode-only. Decode, scaling, deinterlace,
subtitle burn-in, and tone mapping must happen before VA-API upload. B-frames
and external DMA-BUF surfaces are not supported.

## Install

Install your distribution's liblz4 and libzstd runtime packages, unpack the
release asset, and run:

```bash
sudo ./vtremote-vaapi/install-binary.sh
sudo modprobe vgem
export LIBVA_DRIVERS_PATH=/opt/vtremote-vaapi/lib/dri
export LIBVA_DRIVER_NAME=vtremote
export VTREMOTE_HOST=<MAC_PRIVATE_IP>:5555
export VTREMOTE_WIRE_COMPRESSION=auto
/opt/vtremote-vaapi/bin/vtremote-probe --host "$VTREMOTE_HOST" --codec h264
```

`VTREMOTE_HOST` is required. Wire compression accepts `auto`, `none`, `lz4`,
or `zstd`. Automatic mode chooses Zstandard for raw traffic below 200 Mbit/s
and LZ4 for higher-throughput streams.

## Plex

The repository provides a Dockerfile pinned to an official amd64 `pms-docker`
bootstrap image digest, plus a Compose merge example under
`vaapi-driver/docker/`. Its narrow Plex Transcoder wrapper recognizes Plex's
ordinary H.264/HEVC VA-API scale graph and replaces that video chain with the
`vtremote_transcode` packet filter. Compressed input packets go to the Mac;
decoded or scaled frames never cross the network or consume Linux CPU.

This Plex path does not use the VA-API driver and needs no render node. Linux
continues to demux, process audio and subtitles, and mux the returned video.
Unknown graphs pass through unchanged to Plex's native Transcoder.

Validate the bundled Plex Transcoder and VA-API stack without claiming the
server or creating a library:

```bash
PLEX_CONTAINER=plex \
  vaapi-driver/scripts/plex-transcoder-remote-smoke.sh
```

This deterministic check creates a small H.264 source, invokes Plex's bundled
Transcoder with a Plex-shaped VA-API command, and verifies the remotely decoded,
scaled, and encoded result. It requires no Plex token, library, or Plex Pass.

Separately, enable hardware acceleration and hardware encoding in a claimed
Plex Pass server. Plex requests its normal hardware pipeline and the wrapper
converts the supported graph to remote decode, scale, and encode.
Validate it through a real playback request:

```bash
PLEX_URL=http://127.0.0.1:32400 \
PLEX_TOKEN=... \
PLEX_RATING_KEY=12345 \
PLEX_CONTAINER=plex \
  vaapi-driver/scripts/plex-playback-smoke.sh
```

The optional claimed-server check requests an HLS playback transcode from PMS,
downloads and decodes a media segment, and requires a new wrapper audit entry.
It proves PMS selected the remote packet filter and returned playable media;
the unclaimed-server check proves the underlying Transcoder integration.

For build, environment, SDK, and architecture details, see
[`vaapi-driver/README.md`](../vaapi-driver/README.md).
