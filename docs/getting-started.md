---
title: Getting Started
---

# Getting Started

Follow these steps to set up the macOS server and build the FFmpeg client.

## Prerequisites

- **Server**: A Mac with Apple Silicon (M1/M2/M3) or T2 Security Chip running macOS.
- **Client**: Linux, Windows, or macOS.
- **Network**: Wired LAN is strongly recommended (1GbE minimum, 2.5GbE+ for 4K).

## Step 1: Prepare the Mac (Server)

1.  **Clone the repository**:
    ```bash
    git clone https://github.com/davelindo/videotoolbox_remote.git
    cd videotoolbox_remote
    ```

2.  **Install dependencies**:
    ```bash
    brew install lz4 zstd pkg-config
    ```

3.  **Build the server**:
    ```bash
    make build-vtremoted
    ```

4.  **Run the server**:
    ```bash
    vtremoted/.build/release/vtremoted --listen 0.0.0.0:5555 --log-level 1
    ```

    > [!TIP]
    > To install as a background service, run:
    > `./install_launchd.sh --bin /usr/local/bin/vtremoted --listen 0.0.0.0:5555`

## Step 2: Build FFmpeg (Client)

On your Linux or Windows machine (or the same Mac if testing locally):

1.  **Install build dependencies**:
    - Ensure `libzstd`, `liblz4`, and `pkg-config` are installed.

2.  **Clone and build**:
    ```bash
    git clone https://github.com/davelindo/videotoolbox_remote.git
    cd videotoolbox_remote
    cd ffmpeg
    ./configure --enable-videotoolbox-remote --enable-liblz4 --enable-libzstd
    make -j$(nproc)
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
Send compressed packets to the Mac. The Mac decodes, processes, and re-encodes them.

```bash
ffmpeg -i input.mkv \
  -c:v hevc_videotoolbox_remote \
  -vt_remote_transcode \
  -vt_remote_host <MAC_IP>:5555 \
  -b:v 6000k \
  output.mkv
```

## Important Notes

- **Compression**: Wire compression defaults to **LZ4** for all remote modes. Override with `-vt_remote_wire_compression lz4|zstd|none`, or use `auto` to choose based on resolution/FPS.
- **Security**: Token auth is optional. See [Security](security.md) for details.
- **Optimization**: The server automatically optimizes VideoToolbox settings for batch encoding throughput.
