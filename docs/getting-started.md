# Getting started

This guide aims for “I have a Mac + another machine, and I want remote H.264/HEVC working.”

## What you need

- A **Mac** that will run `vtremoted` (Apple Silicon recommended).
- A **client machine** where you will run FFmpeg (Linux/Windows/macOS).
- A **fast network** between them (wired LAN strongly recommended).
- Build tools:
  - On macOS: Swift toolchain / Xcode CLT, Homebrew
  - On client: a toolchain that can build FFmpeg + `liblz4`

---

## Step 1 — Prepare the Mac (server)

### Install dependencies

```bash
brew install lz4 pkg-config
```

### Build vtremoted

```bash
cd vtremoted
swift build -c release
```

### Run it (first-time setup)

```bash
.build/release/vtremoted --listen 0.0.0.0:5555 --log-level 1
```

Leave it running for now.

> Tip: If you want to restrict access to your LAN only, bind to your LAN interface instead of `0.0.0.0`.

### macOS firewall

Ensure macOS allows incoming connections on your chosen port.

---

## Step 2 — Build the FFmpeg client (other machine)

### Install liblz4 + pkg-config

How you install this depends on the OS.

Examples:

* Debian/Ubuntu: `sudo apt-get install liblz4-dev pkg-config`
* Fedora: `sudo dnf install lz4-devel pkgconf-pkg-config`
* macOS: `brew install lz4 pkg-config`

### Configure & build the included FFmpeg fork

```bash
cd ffmpeg

./configure ... --enable-liblz4 \
  --enable-encoder=h264_videotoolbox_remote --enable-encoder=hevc_videotoolbox_remote \
  --enable-decoder=h264_videotoolbox_remote --enable-decoder=hevc_videotoolbox_remote

make -j
```

### Verify the codec exists

```bash
./ffmpeg -encoders | grep videotoolbox_remote
./ffmpeg -decoders | grep videotoolbox_remote
```

---

## Step 3 — Run a test transcode

Replace `macmini.local:5555` with your server’s hostname/IP and port:

```bash
./ffmpeg -i input.mkv \
  -c:v h264_videotoolbox_remote -vt_remote_host macmini.local:5555 \
  -b:v 6000k -g 240 \
  -c:a copy -c:s copy \
  output.mkv
```

If that works, you’re done.

---

## Optional — Run vtremoted as a service (launchd)

This is the “I want it running after reboots” option:

```bash
./install_launchd.sh --bin /usr/local/bin/vtremoted --listen 0.0.0.0:5555
```

If you later change ports or tokens, update the service and restart it.

---

## Next steps

* Tune flags: `configuration.md`
* Lock it down: `security.md`
* When something breaks: `troubleshooting.md`
---
title: Getting Started
---

# Getting Started

This guide walks you through a minimal local/remote setup.

## 1) Build and run `vtremoted` (macOS)

```bash
brew install lz4 pkg-config
cd vtremoted
swift build -c release
.build/release/vtremoted --listen 0.0.0.0:5555 --log-level 1
```

Optionally install as a service:

```bash
./install_launchd.sh --bin /usr/local/bin/vtremoted --listen 0.0.0.0:5555
```

## 2) Build FFmpeg client (Linux/Windows/macOS)

```bash
cd ffmpeg
./configure ... --enable-liblz4 \
  --enable-encoder=h264_videotoolbox_remote --enable-encoder=hevc_videotoolbox_remote \
  --enable-decoder=h264_videotoolbox_remote --enable-decoder=hevc_videotoolbox_remote
make -j
```

## 3) Encode remotely

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
