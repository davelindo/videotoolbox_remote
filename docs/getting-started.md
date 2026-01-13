---
title: Getting Started
---

# Getting Started

This guide aims for “I have a Mac + another machine, and I want remote H.264/HEVC working.”

## Step 1 — Prepare the Mac (server)

Install dependencies and build:

```bash
brew install lz4 pkg-config
cd vtremoted
swift build -c release
```

Run it:

```bash
.build/release/vtremoted --listen 0.0.0.0:5555 --log-level 1
```

Optionally install as a service:

```bash
./install_launchd.sh --bin /usr/local/bin/vtremoted --listen 0.0.0.0:5555
```

## Step 2 — Build FFmpeg client (other machine)

Install `liblz4` + `pkg-config` for your OS, then:

```bash
cd ffmpeg
./configure ... --enable-liblz4 \
  --enable-videotoolbox-remote
make -j
```

Verify the codecs:

```bash
./ffmpeg -encoders | grep videotoolbox_remote
./ffmpeg -decoders | grep videotoolbox_remote
```

## Step 3 — Encode remotely

```bash
ffmpeg -i input.mkv \
  -c:v h264_videotoolbox_remote -vt_remote_host macmini.local:5555 \
  -b:v 6000k -g 240 \
  -c:a copy -c:s copy \
  output.mkv
```

## Notes

- Wire compression (LZ4) is enabled by default.
- Token auth is optional; add `-vt_remote_token` on the client and `--token` on the server to enforce.
