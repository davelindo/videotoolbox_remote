---
title: Getting started
description: "Install remote VideoToolbox binaries for macOS, Linux and Windows. Run your first low-power H.264/HEVC encode or packet transcode with FFmpeg."
---

# Getting started

Use a Mac's media hardware from your Linux, Windows or macOS FFmpeg client. For a Plex server, go directly to the [Plex guide](plex.html); stock libva applications use the [VA-API guide](vaapi-driver.html).

## Requirements

- A Mac with Apple Silicon or supported T2 hardware, running macOS 13 or newer, including macOS 27.
- A Linux, Windows or macOS client with a matching release or source build.
- A reachable private endpoint. Wired LAN is recommended; raw 4K/10-bit frames benefit from 2.5GbE or faster. Packet transcoding uses much less bandwidth.

## Install the release binaries

Download the archives and checksum files from the [latest release]({{ site.latest_release_url }}). Verify the downloaded tarball against `SHA256SUMS.txt` with `shasum -a 256` on macOS or `sha256sum` on Linux.

| Machine | Archive |
| --- | --- |
| Apple Silicon Mac server | `vtremoted-macos-arm64.tar.gz` |
| Intel Mac server | `vtremoted-macos-x86_64.tar.gz` |
| Linux x86_64 client | `ffmpeg-linux-x86_64.tar.gz` |
| Linux arm64 client | `ffmpeg-linux-arm64.tar.gz` — read the [runtime requirements](#linux-arm64-release-runtime) |
| macOS client | `ffmpeg-macos-arm64.tar.gz` or `ffmpeg-macos-x86_64.tar.gz` |
| Windows x86_64 client | `ffmpeg-windows-x86_64.tar.gz` |

On the Apple Silicon Mac:

```bash
tar -xzf vtremoted-macos-arm64.tar.gz
brew install lz4 zstd
./vtremoted/vtremoted --version
./vtremoted/vtremoted --listen 192.168.1.20:5555 --log-level 1
```

Replace `192.168.1.20` with your Mac's private address. Intel users unpack the x86_64 archive. The daemon defaults to `127.0.0.1:5555`; other machines cannot connect until you choose a reachable listen address or use a tunnel.

LZ4/Zstd are optional runtime libraries for the daemon. FFmpeg and OBS request LZ4 by default; install LZ4 for that mode, and Zstd for clients using Zstd or automatic selection. You can explicitly choose `-vt_remote_wire_compression none` for an FFmpeg session without wire compression.

On a Linux x86_64 client:

```bash
mkdir -p ffmpeg-client
tar -xzf ffmpeg-linux-x86_64.tar.gz -C ffmpeg-client
./ffmpeg-client/ffmpeg -hide_banner -encoders
```

Unpack the corresponding archive on other client platforms. Use its `ffmpeg` binary for the following examples (`ffmpeg.exe` on Windows).

## Your first remote encode

```bash
./ffmpeg-client/ffmpeg -i input.mkv \
  -c:v h264_videotoolbox_remote \
  -vt_remote_host 192.168.1.20:5555 \
  -b:v 6M -g 240 -c:a copy -c:s copy \
  output.mkv
```

FFmpeg decodes and filters locally, sends raw video frames to the Mac, then muxes the returned H.264 packets. Audio and subtitles are copied in this example. Select `hevc_videotoolbox_remote` for HEVC; use supported 10-bit formats and `-profile:v main10` for HEVC Main 10.

## Packet transcoding for batch jobs

For H.264/HEVC input, keep decoded frames on the Mac and send compressed packets in both directions:

```bash
./ffmpeg-client/ffmpeg -i input.mkv -map 0 -c copy \
  -vt_remote_transcode:v:0 \
  -vt_remote_host 192.168.1.20 -vt_remote_port 5555 \
  -vt_remote_out_codec:v:0 hevc -b:v:0 6M \
  output.mkv
```

The first video stream is transcoded; other mapped streams are copied. The Mac performs video decode, optional configured resize/pixel-format conversion and encode. Client-side audio, subtitles, files and muxing stay local. Arbitrary video filters are not part of this server path; use the remote encoder after local filtering for those jobs.

For a directory of MKV files, run jobs sequentially to begin:

```bash
mkdir -p converted
for input in ./*.mkv; do
  [ -f "$input" ] || continue
  ./ffmpeg-client/ffmpeg -n -i "$input" -map 0 -c copy \
    -vt_remote_transcode:v:0 \
    -vt_remote_host 192.168.1.20 -vt_remote_port 5555 \
    -vt_remote_out_codec:v:0 hevc -b:v:0 6M \
    "converted/${input##*/}" || break
done
```

Review bitrate, output format and visual quality on representative files before a whole-library conversion. A fast preset and higher concurrency can change throughput, quality and power; choose them from measurements on your own hardware.

## Share the endpoint securely

For token authentication, store a secret in a file readable only by the daemon user and start the server with:

```bash
./vtremoted/vtremoted --listen 192.168.1.20:5555 \
  --token-file /path/to/vtremote-token --log-level 1
```

Add `-vt_remote_token YOUR_TOKEN` to FFmpeg commands, or `VTREMOTE_TOKEN` to the VA-API/Plex environment. Tokens do not encrypt media or credentials. Use an [SSH tunnel or VPN](security.html) on untrusted networks; keep port 5555 private.

## Linux arm64 release runtime

The arm64/aarch64 archive contains `ffmpeg`, `ffprobe` and `ffplay`. It is dynamically linked, built on Ubuntu 24.04, and needs glibc 2.39+ with matching codec, compression, font and SDL2 libraries. These include x264, x265, libvpx, dav1d, libaom, Opus, Vorbis, LAME, LZ4, Zstd, libass and libvmaf. CI installs libvmaf 3.0.0 under `/usr/local`; that shared library must be available on the client. SVT-AV1 4.0.1 is linked statically.

Debian 12 and Raspberry Pi OS Bookworm have an older glibc. Build on your target distribution or use a compatible Ubuntu 24.04 arm64 environment with the required libraries. A newer glibc alone does not supply every dependency. Inspect missing libraries with:

```bash
ldd ffmpeg-client/ffmpeg
ldd ffmpeg-client/ffprobe
ldd ffmpeg-client/ffplay
```

This asset is an FFmpeg client only. VA-API and Plex integrations remain Linux x86_64; no i686 release is published.

## Build from source

Clone the repository on each machine that needs a build:

```bash
git clone https://github.com/davelindo/videotoolbox_remote.git
cd videotoolbox_remote
```

On macOS, install Xcode command line tools and the runtime compression libraries, then build the daemon:

```bash
brew install lz4 zstd pkg-config
make build-vtremoted
vtremoted/.build/release/vtremoted --listen 192.168.1.20:5555 --log-level 1
```

The default deployment target is macOS 13.0. To install as a background service from the checkout:

```bash
make install-vtremoted-restart VTREMOTED_LISTEN=192.168.1.20:5555
```

For FFmpeg, install development packages for LZ4, Zstd, libvmaf and the codec libraries enabled by the build, plus `pkg-config` and a compiler. Both compression development libraries are required by the standard build. See [development](development.html) for configuration and platform notes, then run:

```bash
make build-ffmpeg
```

The built client is `ffmpeg/ffmpeg`. If a Linux x86 assembly build fails, install current `nasm` and `yasm`; the [assembler diagnostic](troubleshooting.html#linux-build-fails-in-ffmpeg-x86-assembly) can isolate toolchain errors.

## Next steps

- [Plex](plex.html): keep Plex on Linux and use a Mac as the external video engine.
- [VA-API](vaapi-driver.html): use stock Linux applications through the encode-only driver.
- [OBS](obs-plugin.html): build the experimental remote live encoder.
- [Performance](performance.html): compare video quality, throughput and resource use.
- [Troubleshooting](troubleshooting.html): connection, codec and performance checks.
