---
title: Linux VA-API Driver and Plex
description: "Install and validate the VTRemote H.264/HEVC encode-only VA-API driver on Linux, including Plex playback transcoding with vgem."
---

# Linux VA-API Driver and Plex

The `vtremote-vaapi-linux-x86_64.tar.gz` release asset lets a stock Linux
VA-API application send H.264 or HEVC encoding to `vtremoted`. It supports
H.264 Baseline/Main/High, HEVC Main, and HEVC Main 10 with NV12/P010 input.

This is an encode-only path. Decode, scaling, deinterlace, subtitle burn-in,
and tone mapping must happen in software before VA-API upload. B-frames and
external DMA-BUF surfaces are not supported.

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

The repository provides a Dockerfile pinned to official Plex Media Server
`1.43.3.10896-cb3ebc72d` and its amd64 digest, plus a Compose merge example under
`vaapi-driver/docker/`. The host must pass an accessible render node into the
container; vgem is sufficient when no physical GPU is present.

Validate the bundled Plex Transcoder and VA-API stack without claiming the
server or creating a library:

```bash
PLEX_CONTAINER=plex \
RENDER_DEVICE=/dev/dri/renderD128 \
  vaapi-driver/scripts/plex-transcoder-vaapi-smoke.sh
```

This deterministic check encodes generated NV12 and P010 frames as H.264,
HEVC Main, and HEVC Main 10 through the remote VideoToolbox server. It requires
no Plex token, downloaded decoder, or Plex Pass entitlement.

Separately, enable hardware encoding in a claimed Plex Pass server while
keeping decode and video processing on software. Validate PMS hardware-policy
selection through a real playback request:

```bash
PLEX_URL=http://127.0.0.1:32400 \
PLEX_TOKEN=... \
PLEX_RATING_KEY=12345 \
PLEX_CONTAINER=plex \
  vaapi-driver/scripts/plex-playback-smoke.sh
```

The optional claimed-server check requests an HLS playback transcode from PMS,
downloads a media segment, and requires a new driver connection in the Plex
logs. It proves PMS selected hardware encoding; the unclaimed-server check
proves the Plex Transcoder/VA-API integration itself.

For build, environment, SDK, and architecture details, see
[`vaapi-driver/README.md`](../vaapi-driver/README.md).
