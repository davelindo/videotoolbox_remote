# VTRemote VA-API driver

This Linux VA-API encode driver sends raw NV12 or P010 frames to `vtremoted`
on macOS and returns the H.264 or HEVC access units produced by VideoToolbox.
It is intended for applications such as Plex that already know how to use a
VA-API encoder.

Supported profiles are H.264 Constrained Baseline, Main, and High, plus HEVC
Main and Main 10. Decode, VA-API video processing, B-frames, and external
DMA-BUF surfaces are not implemented. Software decode, filtering, and upload
to the driver are supported.

## Build and test

The build requires a C11 compiler, CMake, pkg-config, libva 2.22 headers
(VA-API 1.22), liblz4, libzstd, pthreads, and Python 3 for repository E2E tests.

```bash
cd vaapi-driver # omit this line inside the standalone source archive
cmake -S . -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DVTREMOTE_VERSION="${VERSION:-dev}"
cmake --build build --parallel
(cd build && ctest --output-on-failure)
```

On Linux, the E2E suite exercises the module directly and through stock
FFmpeg's `h264_vaapi` and `hevc_vaapi` encoders with uncompressed, LZ4, and
Zstandard frame transport. HEVC Main 10 uses P010.

## Install

```bash
sudo vaapi-driver/scripts/install.sh --prefix /opt/vtremote-vaapi
sudo modprobe vgem
```

Then set:

```bash
export LIBVA_DRIVERS_PATH=/opt/vtremote-vaapi/lib/dri
export LIBVA_DRIVER_NAME=vtremote
export VTREMOTE_HOST=192.168.1.20:5555
export VTREMOTE_WIRE_COMPRESSION=auto
# export VTREMOTE_TOKEN='replace-me'
```

`VTREMOTE_HOST` is required. `VTREMOTE_WIRE_COMPRESSION` accepts `auto`,
`none`, `lz4`, or `zstd`; `auto` selects Zstandard below 200 Mbit/s of raw
frame traffic and LZ4 otherwise. Probe the daemon before starting an
application:

```bash
/opt/vtremote-vaapi/bin/vtremote-probe --host "$VTREMOTE_HOST" --codec h264
```

The installed `vgem_drv_video.so` alias lets libva discover the driver from a
vgem render node. The optional `iHD_drv_video.so` alias is installed only in
the isolated driver directory for Plex processes that explicitly select iHD.
Never place that alias in the system DRI directory.

## Runtime settings

| Variable | Default | Purpose |
|---|---:|---|
| `VTREMOTE_HOST` | required | `host:port` of `vtremoted` |
| `VTREMOTE_TOKEN` | empty | Shared authentication token |
| `VTREMOTE_WIRE_COMPRESSION` | `auto` | `auto`, `none`, `lz4`, or `zstd` |
| `VTREMOTE_TIMEOUT_MS` | `10000` | Network operation timeout |
| `VTREMOTE_BITRATE` | `8000000` | Initial bitrate before VA parameters arrive |
| `VTREMOTE_MAXRATE` | bitrate | Initial maximum bitrate |
| `VTREMOTE_GOP` | `60` | Initial keyframe interval |
| `VTREMOTE_FPS_NUM` / `VTREMOTE_FPS_DEN` | `30` / `1` | Initial frame rate |
| `VTREMOTE_REALTIME` | `1` | Request real-time VideoToolbox operation |
| `VTREMOTE_LOG` | `0` | Enable driver diagnostics |

VA sequence and miscellaneous parameter buffers override bitrate, GOP, and
frame rate before the remote session starts. Changing them after the first
frame is rejected because protocol v1 does not define mid-session reconfigure.
A network failure is terminal for that VA context.

## Experimental C SDK

The release bundle includes `libvtremote_client.a`, public headers, and
`vtremote-client.pc`. This client API is experimental and can change between
repository releases; the wire protocol remains the published v1 contract.

See [Plex integration](docs/PLEX.md), including its unclaimed-server
Plex Transcoder smoke test, and
[architecture](docs/ARCHITECTURE.md) for operational details.
