---
title: Remote encoding for any PC
description: "Capture video on a PC and use a Mac for encoding. Send NV12 or P010 frames from cameras, desktop capture and applications over Thunderbolt or fast Ethernet."
---

# Capture here. Encode on your Mac.

Keep capture and your main application on the PC. Send its frames to a Mac's dedicated media hardware for H.264 or HEVC encoding. This works for desktop capture, cameras, recording systems, kiosks, mini PCs, SBCs and video applications that want encoding off the source machine.

The source application sends **NV12 or P010 frames → Mac encoder → H.264 or HEVC packets**. It receives the encoded packets for recording or broadcast and continues to handle audio and output delivery. There is no intermediate video encode on the source PC.

FFmpeg clients run on Linux, Windows and macOS. Start with the [installation guide](getting-started.html), then choose the input your capture application supplies.

## Feed raw NV12 frames

For a 1080p60 NV12 capture or frame producer:

```bash
ffmpeg -f rawvideo -pixel_format nv12 -video_size 1920x1080 -framerate 60 \
  -i capture.nv12 -an \
  -c:v h264_videotoolbox_remote -vt_remote_host "${MAC_HOST}:5555" \
  -vt_remote_wire_compression none -vt_remote_inflight 32 \
  -b:v 8M -g 120 -bf 0 output.mkv
```

Set `MAC_HOST` to the Mac endpoint. Use `pipe:0` instead of `capture.nv12` when your producer writes raw frames to standard input. Set the format, dimensions and frame rate to the frames it supplies. The application can mux or stream the returned packets using its normal output path.

For a Linux capture device that supplies NV12:

```bash
ffmpeg -f v4l2 -input_format nv12 -video_size 1920x1080 -framerate 60 \
  -i /dev/video0 -an \
  -c:v h264_videotoolbox_remote -vt_remote_host "${MAC_HOST}:5555" \
  -vt_remote_wire_compression none -vt_remote_inflight 32 \
  -b:v 8M -g 120 -bf 0 output.mkv
```

## Send 10-bit frames

P010 carries 10-bit 4:2:0 video in 16-bit samples. Use `p010le` and HEVC Main 10:

```bash
ffmpeg -f rawvideo -pixel_format p010le -video_size 3840x2160 -framerate 30 \
  -i capture.p010 -an \
  -c:v hevc_videotoolbox_remote -vt_remote_host "${MAC_HOST}:5555" \
  -vt_remote_wire_compression none -vt_remote_inflight 32 \
  -pix_fmt p010le -profile:v main10 -b:v 20M -g 60 -bf 0 output.mkv
```

## Choose wire compression for the link

On Thunderbolt networking or fast Ethernet, **None** sends raw frames directly and saves the source CPU from compressing them. **LZ4** reduces frame traffic; it is the default in FFmpeg and OBS. The format and frame rate determine the raw payload:

| Video | NV12 | P010 |
| --- | ---: | ---: |
| 1080p60 | 1.49 Gb/s | 2.99 Gb/s |
| 4K30 | 2.99 Gb/s | 5.97 Gb/s |
| 4K60 | 5.97 Gb/s | 11.94 Gb/s |

These are frame payload rates before network headers. NV12 uses 1.5 bytes per pixel; P010 uses 3. Thunderbolt networking presents an IP interface: use the Mac's address on that link as the endpoint.

## Filter locally, encode remotely

An existing video input can use remote decode, local filters and remote encode. The two directions can use different compression settings. In the measured 4K filter workflow, **LZ4 for decoded frames returning to Linux and no compression for uploads to the encoder** delivered the highest throughput:

```bash
ffmpeg -c:v h264_videotoolbox_remote \
  -vt_remote_host "${MAC_HOST}:5555" -vt_remote_wire_compression lz4 \
  -i input.mkv -map 0:v:0 -an -vf hflip -fps_mode passthrough \
  -c:v hevc_videotoolbox_remote \
  -vt_remote_host "${MAC_HOST}:5555" -vt_remote_wire_compression none \
  -vt_remote_inflight 32 -pix_fmt nv12 -b:v 20M -g 60 -bf 0 output.mkv
```

For jobs whose video operations run entirely on the Mac, [packet transcoding](getting-started.html#packet-transcoding-for-batch-jobs) sends compressed packets in both directions.

## Use your existing application

- **OBS Studio:** choose a [remote encoder](obs-plugin.html), keep composition, audio and streaming in OBS, and select **Wire Compression → None** for a fast link. H.264 uses NV12; HEVC also supports P010.
- **Stock Linux VA-API applications:** the [VA-API driver](vaapi-driver.html) supplies a remote hardware encoder through the application's existing VA-API output.
- **Custom applications:** the [C SDK]({{ site.repository_url }}/blob/main/vaapi-driver/README.md#experimental-c-sdk) accepts frame uploads and returns encoded packets.

{% include transport-performance.md %}
