# VideoToolbox Remote

![Build Status](https://img.shields.io/badge/build-passing-brightgreen) ![License](https://img.shields.io/badge/license-LGPLv2.1%2B-blue) ![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey)

**Remote VideoToolbox for FFmpeg: use a Mac or Apple Silicon system over LAN as an IP-based H.264/HEVC encode/decode/transcoding accelerator.**

VideoToolbox Remote is a networked FFmpeg accelerator that lets you use a Mac as a transcoding server. An FFmpeg client on Linux, Windows, or macOS can offload H.264/HEVC encode, decode, or full transcode jobs to VideoToolbox running on a remote Apple Silicon or T2 Mac over LAN.

Think of it as remote VideoToolbox over IP: FFmpeg stays local for I/O, filters, and muxing, while the Mac contributes hardware acceleration for video encoding, decoding, or packet-in/packet-out transcoding.

## Quick start from Releases

If you want to try it before building from source, start with the prebuilt binaries in the [latest release](https://github.com/davelindo/videotoolbox_remote/releases/latest).

1. Download `vtremoted-macos-arm64.tar.gz` or `vtremoted-macos-x86_64.tar.gz` for the Mac that will run the server.
2. Download the matching FFmpeg client tarball for Linux, macOS, or Windows from the same release page.
3. Start the server on the Mac:

```bash
tar -xzf vtremoted-macos-arm64.tar.gz
./vtremoted/vtremoted --listen 0.0.0.0:5555 --log-level 1
```

4. Run a remote encode from the client:

```bash
mkdir -p ffmpeg-client
tar -xzf ffmpeg-linux-x86_64.tar.gz -C ffmpeg-client
./ffmpeg-client/ffmpeg -i input.mkv \
  -c:v h264_videotoolbox_remote \
  -vt_remote_host <MAC_IP>:5555 \
  -b:v 6000k \
  output.mkv
```

## How it works

The system consists of:
- **Server (`vtremoted`)**: A lightweight Swift daemon running on macOS that wraps the VideoToolbox API.
- **Client**: A modified FFmpeg with custom `h264_videotoolbox_remote` and `hevc_videotoolbox_remote` codecs.
- **OBS Plugin (`obs-plugin/`)**: Experimental OBS encoder plugin using the same vtremoted protocol client.

## How users can get started

### Prerequisites

- **Server**: A Mac with Apple Silicon (M1/M2/M3) or T2 Security Chip running macOS.
- **Client**: Linux, Windows, or macOS.
- **Network**: Wired LAN (1GbE minimum, 2.5GbE+ recommended for 4K).

### Build from source

#### 1. Build the Server (macOS)

```bash
cd vtremoted
swift build -c release
# Binary created at: .build/release/vtremoted
```

#### 2. Build the Client (Linux/Windows/macOS)

The standard build enables **VMAF**, **SSIM/PSNR**, and common codec libraries (including AV1).
You will need the corresponding development headers installed (see `docs/development.md` for platform notes).

```bash
make build-ffmpeg
```

*(On macOS, you can use `make build` in the root directory to build both server and client.)*

### Usage Examples

Start the server on your Mac:
```bash
# Default is loopback-only (safe). For LAN clients, bind explicitly:
./vtremoted --listen 0.0.0.0:5555 --log-level 1
```

#### Remote Encode (Client -> Server)
Encode a video on the client using the remote Mac:
```bash
ffmpeg -i input.mkv \
  -c:v h264_videotoolbox_remote \
  -vt_remote_host <MAC_IP>:5555 \
  -b:v 6000k \
  output.mkv
```

#### Remote Transcode (Packet In -> Packet Out)
Ideal for weak clients. Decoding, scaling, and encoding happen on the server:
```bash
ffmpeg -i input.mkv \
  -c:v hevc_videotoolbox_remote \
  -vt_remote_transcode \
  -vt_remote_host <MAC_IP>:5555 \
  output.mkv
```

## Parity Status

Current coverage:
- Encoder option-surface parity checks for `h264/hevc_videotoolbox` vs `h264/hevc_videotoolbox_remote` (excluding `vt_remote_*` transport options) via `tests/integration/run_option_surface_parity.sh`.
- Remote encoder software-frame upload parity for common 4:2:0 paths:
  - H.264: `nv12`, `yuv420p`
  - HEVC: `nv12`, `yuv420p`, `p010le`, `yuv420p10le`, `yuv420p10be`

Backlog:
- Extend encoder pixel-format parity beyond 4:2:0 for HEVC inputs supported by local VideoToolbox (`bgra`, `ayuv`, `p210`).
- Add remote encoder hardware-frame ingest parity for `AV_PIX_FMT_VIDEOTOOLBOX` inputs (avoid mandatory `hwdownload,format=...` pre-step).
- Expand remote side-data forwarding beyond A53 CC where local VideoToolbox behavior supports additional side data.
- Evaluate optional remote-decoder hardware-frame output mode (`AV_PIX_FMT_VIDEOTOOLBOX`) for hw-frame pipelines.

## Why the project is useful

- **Hardware Acceleration Everywhere**: Enable hardware encoding on Linux/Windows machines that lack capable GPUs by using a networked Mac.
- **High Performance**: Optimized for low-latency LAN environments (1GbE+ recommended).
- **Flexibility**: Supports three modes to fit different network/CPU constraints:
    - **Remote Encode**: Send raw frames to Mac, get compressed packets back.
    - **Remote Decode**: Send compressed packets to Mac, get raw frames back.
    - **Remote Transcode**: Send compressed packets, decode+process+encode on Mac, receive compressed packets (saves bandwidth and client CPU).
- **Standard FFmpeg Integration**: Works like any other FFmpeg codec, fitting seamlessly into existing pipelines.

## Where users can get help

- **Architecture**: [docs/architecture.md](docs/architecture.md) - System design and data flow.
- **OBS Plugin**: [docs/obs-plugin.md](docs/obs-plugin.md) - Experimental plugin build/testing notes.
- **Protocol**: [docs/protocol.md](docs/protocol.md) - Wire protocol specification.
- **Troubleshooting**: [docs/troubleshooting.md](docs/troubleshooting.md) - Common issues and fixes.
- **Security**: [docs/security.md](docs/security.md) - Recommended secure deployment.

## Who maintains and contributes

We welcome contributions! Please see [docs/development.md](docs/development.md) for build instructions, testing/benchmarking scripts, and development notes.

**License**: This project follows FFmpeg-style licensing (LGPL v2.1+ with optional GPL parts). See [LICENSE.md](LICENSE.md) and [ffmpeg/LICENSE.md](ffmpeg/LICENSE.md).
