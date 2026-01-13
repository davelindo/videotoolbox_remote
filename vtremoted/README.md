---

# vtremoted (VideoToolbox Remote Daemon)

`vtremoted` is a lightweight macOS server daemon that exposes Apple's VideoToolbox hardware acceleration to remote clients over a custom TCP protocol. It is designed primarily to act as a remote encoder backend for **FFmpeg** running on Linux or Windows machines, offloading H.264 and HEVC encoding to a Mac.

## Features

* **Hardware Encoding:** Supports H.264 (AVC) and HEVC (H.265) via `VTCompressionSession`.
* **Hardware Decoding:** Supports decoding via `VTDecompressionSession`.
* **Performance:**
* Utilizes **Annex B** format for on-wire bitstream parity.
* Supports **LZ4 compression** for raw frame data transfer (NV12/P010) to minimize bandwidth usage.


* **Pixel Formats:** Supports 8-bit (NV12) and 10-bit (P010) formats.
* **Configuration:** Full control over bitrate, GOP size, profile, level, entropy mode (CABAC/CAVLC), and rate control limits.
* **Apple Silicon Support:** Optimized specifically for Apple Silicon (detects architecture for low-latency rate control compatibility).

## Requirements

* **macOS**: Required to access the VideoToolbox framework.
* **lz4**: The `liblz4` library is required for wire compression.
* **Swift**: Code is written in Swift and utilizes C-interop for LZ4.

## Building

The application links against the system `liblz4` using SwiftPM (via pkg-config).

1. **Install dependencies** (via Homebrew):
```bash
brew install lz4 pkg-config
```

2. **Compile**:
```bash
cd vtremoted
swift build -c debug
```

## Lint / format (optional)

If you have the tools installed:

```bash
make format
make lint
```

## Usage

Start the daemon on the macOS host:

```bash
./vtremoted [flags]

```

### Launchd (recommended)

Install as a launchd service (user-level by default):

```bash
./install_launchd.sh --bin /usr/local/bin/vtremoted --listen 0.0.0.0:5555
```

System-wide install (requires sudo):

```bash
./install_launchd.sh --system --bin /usr/local/bin/vtremoted --listen 0.0.0.0:5555
```

Uninstall:

```bash
./install_launchd.sh --uninstall
```

### Command Line Arguments

| Flag | Description | Default |
| --- | --- | --- |
| `--listen <host:port>` | The address and port to bind to. | `0.0.0.0:5555` |
| `--token <string>` | A simple pre-shared token for authentication. | (Empty) |
| `--log-level <0-2>` | Logging verbosity (0=Error, 1=Info, 2=Debug). | `1` (Info) |
| `--once` | Handle a single client session and then exit. | `false` |

### Environment Variables

For debugging purposes, the following environment variables can be set:

* `VTREMOTED_DUMP_EXTRA`: If set, writes extracted codec extradata (SPS/PPS/VPS) to `/tmp/vtremoted_extradata.bin`.
* `VTREMOTED_DUMP_FIRST`: If set, writes the first encoded packet to `/tmp/vtremoted_firstpkt.bin`.

## Protocol Overview

`vtremoted` uses a custom binary protocol (Version 1, Magic `VTR1`).

1. **Transport:** Single TCP connection per session.
2. **Handshake:** Client sends `HELLO` with token and capabilities; Server responds with `HELLO_ACK`.
3. **Config:** Client sends `CONFIGURE` (resolution, codec, bitrate, flags); Server sets up the Compression/Decompression Session.
4. **Streaming:**
* **Encode Mode:** Client sends raw `FRAME` data (potentially LZ4 compressed). Server returns encoded `PACKET` data (Annex B NAL units).
* **Decode Mode:** Client sends encoded `PACKET` data. Server returns raw `FRAME` data.



## Integration with FFmpeg

This daemon is intended to be paired with a modified FFmpeg client using the `h264_videotoolbox_remote` or `hevc_videotoolbox_remote` encoders.

**Example Client Command:**

```bash
ffmpeg -i input.mkv \
  -c:v h264_videotoolbox_remote \
  -vt_remote_host <MAC_IP>:5555 \
  -vt_remote_token MYTOKEN \
  -b:v 6000k \
  output.mp4

```

## Architecture Notes

* **Concurrency:** The server handles multiple clients via `DispatchQueue.global().async`, though specific concurrency limits are enforced by the protocol handshake logic.
* **Warmup:** In encode mode, the server performs a "warmup" encode of a black frame to initialize the hardware pipeline before processing client frames.
* **Compression:** If `wire_compression` is negotiated as `1` (LZ4), the server expects the client to send LZ4 compressed pixel buffers and will return decompressed frames (in decode mode) or accept compressed frames (in encode mode).

## License

Internal / Proprietary.
