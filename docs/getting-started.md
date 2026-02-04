---
title: Getting Started
---

# Getting Started

Follow these steps to set up the macOS server and build the FFmpeg client.

## Step 1 — Prepare the Mac (server)

Install dependencies and build:

```bash
git clone https://github.com/davelindo/videotoolbox_remote.git
cd videotoolbox_remote
brew install lz4 zstd pkg-config
make build-vtremoted
```

Run it:

```bash
vtremoted/.build/release/vtremoted --listen 0.0.0.0:5555 --log-level 1
```

Optionally install as a service:

```bash
./install_launchd.sh --bin /usr/local/bin/vtremoted --listen 0.0.0.0:5555
```

## Step 2 — Build FFmpeg client (other machine)

Install `libzstd` + `liblz4` + `pkg-config` for your OS, then:

```bash
git clone https://github.com/davelindo/videotoolbox_remote.git
cd videotoolbox_remote
make build-ffmpeg
```


## Step 3 — Encode remotely

```bash
ffmpeg -i input.mkv \
  -c:v h264_videotoolbox_remote -vt_remote_host macmini.local:5555 \
  -b:v 6000k -g 240 \
  -c:a copy -c:s copy \
  output.mkv
```

## Step 4 — Transcode remotely (packet in/out)

Use the normal VideoToolbox flags and add `-vt_remote_transcode`:

```bash
ffmpeg -i input.mkv \
  -c:v hevc_videotoolbox -vt_remote_transcode -vt_remote_host macmini.local:5555 \
  -b:v 6000k -g 240 \
  -c:a copy -c:s copy \
  output.mkv
```

Optional scale/format on the server:

```bash
ffmpeg -i input.mkv \
  -c:v hevc_videotoolbox -vt_remote_transcode -vt_remote_host macmini.local:5555 \
  -s 1280x720 -pix_fmt nv12 -vt_remote_scale_mode aspect \
  -b:v 6000k -g 240 \
  output.mkv
```

## Notes

- Wire compression uses **Zstd** by default (~30-40% smaller than LZ4).
- Token auth is optional; add `-vt_remote_token` on the client and `--token` on the server to enforce.
- The server automatically optimizes VideoToolbox settings for batch encoding throughput.
- `-vt_remote_host` does not change local `*_videotoolbox` behavior by itself; use a remote codec or `-vt_remote_transcode`.
