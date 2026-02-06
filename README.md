# VideoToolbox Remote

![Build Status](https://img.shields.io/badge/build-passing-brightgreen) ![License](https://img.shields.io/badge/license-LGPLv2.1%2B-blue) ![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey)

**Remote VideoToolbox encode/decode for FFmpeg.**

## What the project does

VideoToolbox Remote offloads hardware-accelerated H.264 and HEVC encoding/decoding from an FFmpeg client to a remote macOS daemon. This allows you to leverage the dedicated media engines (Apple Silicon or T2) on a Mac for video processing tasks initiated from Linux, Windows, or other macOS machines.

The system consists of:
- **Server (`vtremoted`)**: A lightweight Swift daemon running on macOS that wraps the VideoToolbox API.
- **Client**: A modified FFmpeg with custom `h264_videotoolbox_remote` and `hevc_videotoolbox_remote` codecs.

## How users can get started

### Prerequisites

- **Server**: A Mac with Apple Silicon (M1/M2/M3) or T2 Security Chip running macOS.
- **Client**: Linux, Windows, or macOS.
- **Network**: Wired LAN (1GbE minimum, 2.5GbE+ recommended for 4K).

### Installation

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
- **Protocol**: [docs/protocol.md](docs/protocol.md) - Wire protocol specification.
- **Troubleshooting**: [docs/troubleshooting.md](docs/troubleshooting.md) - Common issues and fixes.
- **Security**: [docs/security.md](docs/security.md) - Recommended secure deployment.

## Who maintains and contributes

We welcome contributions! Please see [docs/development.md](docs/development.md) for build instructions, testing/benchmarking scripts, and development notes.

**License**: This project follows FFmpeg-style licensing (LGPL v2.1+ with optional GPL parts). See [LICENSE.md](LICENSE.md) and [ffmpeg/LICENSE.md](ffmpeg/LICENSE.md).
