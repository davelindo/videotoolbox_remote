---
title: Architecture
---

# VideoToolbox Remote Architecture

**Updated:** 2026-01-30

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

## Build expectations
- FFmpeg client: add `--enable-videotoolbox-remote` plus `liblz4/libzstd`. On macOS, `make build-ffmpeg` enables both local and remote codecs via the Xcode SDK.
- Server: SwiftPM/Xcode on macOS; flags for listen addr/port, optional token, max_sessions, log level. Requires system `liblz4`.

## Milestone alignment
- **M0**: protocol lib (`vtremote_proto.*`) + portable mock server; validate client scaffolding without VideoToolbox.
- **M1**: `h264_videotoolbox_remote` + real `vtremoted` H.264 (Annex B), full FFmpeg pipeline.
- **M2**: HEVC path + DTS correctness for B-frames.
- **M3**: stability/perf (keepalive, inflight tuning, optional wire compression).

## Performance defaults

Defaults applied when the client does not override settings:

| Property | Default | Purpose |
|----------|---------|---------|
| `ExpectedFrameRate` | from client | Helps VT optimize encode pipeline |
| `PrioritizeEncodingSpeedOverQuality` | unset | Uses VideoToolbox default unless explicitly set |
| `RealTime` | `false` (forced when unset) | Maximize throughput over latency |
| `MaximizePowerEfficiency` | `false` (forced when unset) | Maximize speed over power |
| `MaxFrameDelayCount` | from `-bf` when set | Enable/limit frame reordering |

When `-realtime 1` is passed, `RealTime` is set true; other properties are only
applied if explicitly set by the client.

Client-side pipelining:
- Default `inflight` of 16 frames to hide network latency
- Non-blocking packet drain to keep pipeline full
- Zstd wire compression (~30-40% smaller than LZ4)

Remote decode defaults to **async** with a reorder depth of **2**. The reorder buffer
sorts by PTS and clamps only when PTS would regress.

## Not in scope (MVP)
- TLS/mTLS, HandBrake integration, HDR metadata passthrough, multi-server discovery.
