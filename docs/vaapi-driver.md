---
title: Linux VA-API driver
description: "Use a Mac's VideoToolbox encoder from stock Linux FFmpeg through an encode-only H.264/HEVC VA-API driver. Installation, VGEM render nodes and Main 10 setup."
---

# Linux VA-API driver

Use stock Linux FFmpeg's `h264_vaapi` and `hevc_vaapi` encoders while the actual encode runs on a Mac over LAN. The driver is Linux x86_64 and encode-only: decode, filters and raw-frame upload stay on the application host.

For a GPU-less Plex host, use the separate [Plex packet integration](plex.html). It offloads decode, resize and encode without a Linux render node; it does not route video through this driver.

## Supported operations

| Capability | Driver support |
| --- | --- |
| H.264 encode | Constrained Baseline, Main, High |
| HEVC encode | Main and Main 10 |
| Software-uploaded surfaces | NV12 and P010 |
| Rate control | CBR, VBR, CQP |
| Decode / VPP / scale / deinterlace / tone mapping | Local application responsibility |
| B-frames / external DMA-BUF surfaces | Unsupported |

The target Mac must support the requested codec and format. Driver profile support does not guarantee every Mac supports every mode.

## Install the binary release

Start the [Mac daemon](getting-started.html#install-the-release-binaries), then download `vtremote-vaapi-linux-x86_64.tar.gz` and its checksum from the [latest release]({{ site.latest_release_url }}).

Install your distribution's LZ4 and Zstd runtime packages. The artifact has a GLIBC 2.17 baseline; stock FFmpeg also needs a compatible libva runtime. Unpack and install:

```bash
tar -xzf vtremote-vaapi-linux-x86_64.tar.gz
sudo ./vtremote-vaapi/install-binary.sh
export LIBVA_DRIVERS_PATH=/opt/vtremote-vaapi/lib/dri
export LIBVA_DRIVER_NAME=vtremote
export VTREMOTE_HOST=192.168.1.20:5555
export VTREMOTE_WIRE_COMPRESSION=auto
# If the Mac daemon requires a token:
# export VTREMOTE_TOKEN=YOUR_TOKEN
/opt/vtremote-vaapi/bin/vtremote-probe --host "$VTREMOTE_HOST" --codec h264
```

The installer uses `/opt/vtremote-vaapi` and refuses to overwrite an existing installation. See the [binary installation instructions]({{ site.repository_url }}/blob/main/vaapi-driver/packaging/BINARY-INSTALL.md) for upgrades, dependencies and checksums.

## Choose a render node

Libva still needs a DRM render node to initialize, even though encoding happens on the remote Mac. Use an accessible physical render node or, where the kernel provides it, a VGEM node:

```bash
sudo modprobe vgem
ls -l /dev/dri/renderD*
```

VGEM availability depends on the host kernel; some NAS kernels omit it. Choose the actual node and grant the application user appropriate render-group/device access. `renderD128` below is an example, not a guaranteed VGEM assignment. The repository's [render-node helper]({{ site.repository_url }}/blob/main/vaapi-driver/scripts/show-render-nodes.sh) lists available nodes.

## Encode with stock FFmpeg

H.264 with local software decode and NV12 upload:

```bash
ffmpeg -init_hw_device vaapi=remote:/dev/dri/renderD128 \
  -filter_hw_device remote -i input.mkv \
  -vf format=nv12,hwupload \
  -c:v h264_vaapi -bf 0 -b:v 6M -c:a copy \
  output.mkv
```

HEVC Main 10 with P010 upload:

```bash
ffmpeg -init_hw_device vaapi=remote:/dev/dri/renderD128 \
  -filter_hw_device remote -i input.mkv \
  -vf format=p010le,hwupload \
  -c:v hevc_vaapi -profile:v main10 -bf 0 -b:v 6M -c:a copy \
  output-main10.mkv
```

Keep scale, deinterlace or tone mapping before `hwupload`. The driver has no VPP pipeline and accepts software-uploaded surfaces rather than another GPU's DMA-BUF frames. Raw-frame transport can become the limiting factor at high resolutions; see [benchmarks](benchmarks.html).

## Connection settings

| Variable | Meaning / default |
| --- | --- |
| `VTREMOTE_HOST` | Required `host:port` endpoint |
| `VTREMOTE_TOKEN` | Optional daemon authentication token |
| `VTREMOTE_WIRE_COMPRESSION` | `auto` (default), `none`, `lz4`, `zstd` |
| `VTREMOTE_TIMEOUT_MS` | Operation timeout, default `10000` |
| `VTREMOTE_LOG` | Diagnostic logging, default `0` |

Automatic compression chooses Zstd below 200 Mbit/s of estimated raw traffic and LZ4 above that threshold. Compression savings depend on content. The daemon must have the corresponding runtime library installed. Network traffic is plain TCP; see [security](security.html).

`vgem_drv_video.so` provides a discovery alias. Use `LIBVA_DRIVER_NAME=vtremote` explicitly where possible. Keep any application-specific discovery aliases in an isolated driver directory; do not replace system iHD drivers.

## Build, SDK and tests

Run `make test-vaapi-driver` on Linux for driver checks with stock FFmpeg and the repository mock server. The [driver README]({{ site.repository_url }}/blob/main/vaapi-driver/README.md) contains source-build dependencies and Docker instructions.

The package also includes an experimental static C SDK (`libvtremote_client.a`, headers and pkg-config metadata). It exposes connection, configure, frame/packet and flush operations with bounded in-flight work. Its ABI changed in v0.9.0; rebuild applications against the matching release. See the [SDK reference]({{ site.repository_url }}/blob/main/vaapi-driver/README.md#experimental-c-sdk).

For Plex deployment and real playback verification, continue with the [Plex guide](plex.html).
