---
title: Architecture
---

# VideoToolbox Remote Architecture

**Updated:** 2026-01-14

## System Context

```mermaid
flowchart LR
    User["Human User"] --> Client["FFmpeg Client"]
    Client -->|"TCP (B-Frames/Annex B)"| Server["vtremoted (macOS)"]
    Server -->|CVPixelBuffer| VT["VideoToolbox API"]
    VT -->|"Hardware Encode"| HW["Apple Silicon / T2"]
```

## 1. Components

### Client (FFmpeg)
*   **Encoders**: `h264_videotoolbox_remote`, `hevc_videotoolbox_remote`.
*   **Responsibilities**: Demuxing, filtering, audio/subtitles, TCP session lifecycle, rate-control policy.

### Server (`vtremoted`, macOS)
*   **Daemon**: Listens on TCP 5555.
*   **Session**: Manages one `VTCompressionSession` or `VTDecompressionSession` per connection.
*   **Pipeline**:
    1.  Receives **NV12/P010** planes.
    2.  Wraps in `CVPixelBuffer`.
    3.  Encodes via Hardware.
    4.  Converts output NALs to **Annex B**.
    5.  Returns packets with PTS/DTS.

## 2. Data Flow (Encode)

1.  **Handshake**: Message `HELLO` exchange.
2.  **Config**: Client sends `CONFIGURE`, Server creates `VTCompressionSession`.
3.  **Stream**:
    *   **In**: `FRAME` (Pixels)
    *   **Out**: `PACKET` (H.264/HEVC)
4.  **Teardown**: Client sends `FLUSH`, then closes.

## 3. Repository Layout
- **`ffmpeg/`**: Forked codebase with `libavcodec/vtremote*`.
- **`vtremoted/`**: SwiftPM server implementation.
- **`tests/`**: Integration tests and Python mock server.
- **`docs/`**: Protocol and Architecture documentation.

## Build expectations (to be documented in README)
- FFmpeg: minimal configure additions for `*_videotoolbox_remote` encoders; no macOS frameworks required on client.
  Example:
  ```
  ./configure ... --enable-liblz4 \
    --enable-videotoolbox-remote
  ```
- Server: SwiftPM or Xcode on macOS; flags for listen addr/port, optional token, max_sessions, log level. Requires system `liblz4`.

## Milestone alignment
- **M0**: protocol lib (`vtremote_proto.*`) + portable mock server; validate client scaffolding without VideoToolbox.
- **M1**: `h264_videotoolbox_remote` + real `vtremoted` H.264 (Annex B), full FFmpeg pipeline.
- **M2**: HEVC path + DTS correctness for B-frames.
- **M3**: stability/perf (keepalive, inflight tuning, optional wire compression).

## Performance optimizations

The server automatically applies optimal VideoToolbox settings for batch encoding:

| Property | Default | Purpose |
|----------|---------|---------|
| `ExpectedFrameRate` | from client | Helps VT optimize encode pipeline |
| `PrioritizeEncodingSpeedOverQuality` | `true` | Favor speed for batch encoding |
| `RealTime` | `false` | Maximize throughput over latency |
| `MaximizePowerEfficiency` | `false` | Maximize speed over power |
| `MaxFrameDelayCount` | `8` | Allow parallel frame encoding |

These are automatically disabled when `-realtime 1` is passed by the client.

Client-side pipelining:
- Default `inflight` of 16 frames to hide network latency
- Non-blocking packet drain to keep pipeline full
- Zstd wire compression (~30-40% smaller than LZ4)

## Not in scope (MVP)
- TLS/mTLS, HandBrake integration, HDR metadata passthrough, multi-server discovery.
