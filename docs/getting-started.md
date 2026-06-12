---
title: Getting Started
description: "Install the vtremoted macOS server and FFmpeg client binaries, then use remote VideoToolbox over LAN for H.264/HEVC encode, decode, or transcode jobs."
---

# Getting Started

VideoToolbox Remote turns a Mac into a networked FFmpeg accelerator. Use this guide if you want a Linux, Windows, or macOS FFmpeg client to use remote VideoToolbox over LAN for H.264/HEVC encode, decode, or full transcode jobs.

> [!TIP]
> Want the fastest first run? Download the prebuilt `vtremoted-*` and `ffmpeg-*` tarballs from the [latest release](https://github.com/davelindo/videotoolbox_remote/releases/latest), then use the same launch and FFmpeg commands shown below.

Follow these steps to set up the macOS server and a matching FFmpeg client.

## Prerequisites

- **Server**: A Mac with Apple Silicon or a T2 Security Chip running macOS 13 or newer, including macOS 27.
- **Client**: Linux, Windows, or macOS. Prebuilt Linux artifacts target `x86_64`; 32-bit `i686` builds are not part of the supported release matrix.
- **Network**: Wired LAN is strongly recommended (1GbE minimum, 2.5GbE+ for 4K).

## Step 1: Prepare the Mac (Server)

For the fastest first run, download `vtremoted-macos-arm64.tar.gz` or `vtremoted-macos-x86_64.tar.gz` from the [latest release](https://github.com/davelindo/videotoolbox_remote/releases/latest), unpack it, and use the release-tarball command in step 4.

1.  **Clone the repository**:
    ```bash
    git clone https://github.com/davelindo/videotoolbox_remote.git
    cd videotoolbox_remote
    ```

2.  **Install dependencies**:
    ```bash
    brew install lz4 zstd pkg-config
    ```

    `vtremoted` loads `lz4` and `zstd` at runtime instead of requiring them to start. Default FFmpeg/OBS clients request LZ4 wire compression, so keep `lz4` installed for normal sessions and `zstd` installed if clients use Zstd.

3.  **Build the server**:
    ```bash
    make build-vtremoted
    ```

    The default macOS deployment target is `13.0`, even when building on macOS 27 or with a newer SDK. Override `MACOSX_DEPLOYMENT_TARGET` only when you intentionally want a newer minimum OS.

4.  **Run the server**:

    From a release tarball:
    ```bash
    # Trusted private LAN only. Never expose this port directly to the internet.
    ./vtremoted/vtremoted --listen <MAC_PRIVATE_IP>:5555 --log-level 1
    ```

    From a source build:
    ```bash
    # Trusted private LAN only. Never expose this port directly to the internet.
    vtremoted/.build/release/vtremoted --listen <MAC_PRIVATE_IP>:5555 --log-level 1
    ```

    > [!TIP]
    > To install as a background service, run:
    > `make install-vtremoted-restart VTREMOTED_LISTEN=<MAC_PRIVATE_IP>:5555`

5.  **Verify the server**:
    ```bash
    vtremoted/.build/release/vtremoted --version
    pgrep -fl vtremoted
    lsof -nP -iTCP:5555 -sTCP:LISTEN
    ```

## Step 2: Build FFmpeg (Client)

For the fastest first run, download the matching `ffmpeg-*` client tarball for your client OS from the [latest release](https://github.com/davelindo/videotoolbox_remote/releases/latest).

On your Linux or Windows machine (or the same Mac if testing locally):

1.  **Install build dependencies**:
    - Ensure `liblz4`, `libzstd`, `libvmaf`, and `pkg-config` are installed. `liblz4` is needed for the default LZ4 wire-compression mode; `libzstd` is needed only when requesting Zstd wire compression.
    - For AV1 and common codecs, install `libaom`, `libdav1d`, `libsvtav1`, `x264`, `x265`, `libvpx`, `opus`, `vorbis`, and `lame` development packages as well.

2.  **Clone and build**:
    ```bash
    git clone https://github.com/davelindo/videotoolbox_remote.git
    cd videotoolbox_remote
    make build-ffmpeg
    ```

    If a Linux `x86_64` source build fails inside FFmpeg x86 assembly, first install current `nasm` and `yasm`. To confirm the failure is assembler-specific, rebuild with:
    ```bash
    make clean-ffmpeg
    make build-ffmpeg FFMPEG_DISABLE_X86ASM=1
    ```

## Step 3: Usage Examples

### Remote Encode
Send raw frames to the Mac for encoding.

```bash
ffmpeg -i input.mkv \
  -c:v h264_videotoolbox_remote \
  -vt_remote_host <MAC_IP>:5555 \
  -b:v 6000k -g 240 \
  -c:a copy -c:s copy \
  output.mkv
```

### Remote Transcode
Send compressed packets to the Mac. The Mac handles the video decode-to-encode path, while FFmpeg I/O, filters outside vtremote transcode options, audio, subtitles, and muxing stay on the client.

```bash
ffmpeg -i input.mkv \
  -map 0 \
  -c copy \
  -vt_remote_transcode:v:0 \
  -vt_remote_host <MAC_IP> \
  -vt_remote_port 5555 \
  -vt_remote_out_codec:v:0 hevc \
  -b:v:0 6000k \
  output.mkv
```

## Optional: OBS Plugin Smoke Test (Experimental)

To validate the OBS plugin protocol client path:

```bash
make test-obs-plugin
```

This runs a mock-backed smoke test for connect/configure/frame/packet flow.

## Important Notes

- **Compression**: Wire compression defaults to **LZ4** for all remote modes. Override with `-vt_remote_wire_compression lz4|zstd|none`, or use `auto` to choose based on resolution/FPS.
- **Security**: Token auth is strongly recommended whenever binding beyond loopback. Tokens do not encrypt traffic, so use SSH tunnels or a VPN on untrusted networks. See [Security](security.md) for details.
- **Optimization**: The server automatically optimizes VideoToolbox settings for batch encoding throughput.
