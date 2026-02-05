---
title: Architecture
---

# Architecture

**Updated:** 2026-01-30

## System Context

VideoToolbox Remote bridges a standard FFmpeg client to a dedicated macOS compression server.

```mermaid
flowchart LR
    User["Human User"] --> Client["FFmpeg Client"]
    Client -->|"TCP (B-Frames/Annex B)"| Server["vtremoted (macOS)"]
    Server -->|CVPixelBuffer| VT["VideoToolbox API"]
    VT -->|"Hardware Encode"| HW["Apple Silicon / T2"]
```

## 1. Components

### Client (FFmpeg)
- **Encoders**: `h264_videotoolbox_remote`, `hevc_videotoolbox_remote`
- **Bitstream Filter**: `vtremote_transcode` (packet-in/out transcode mode)
- **Responsibilities**: Demuxing, filtering, audio/subtitles, TCP session lifecycle, rate-control policy.

### Server (`vtremoted`, macOS)
- **Daemon**: Listens on TCP 5555.
- **Session**: Manages one `VTCompressionSession` or `VTDecompressionSession` per connection.
- **Pipeline**:
    1.  Receives **NV12/P010** planes.
    2.  Wraps in `CVPixelBuffer`.
    3.  Encodes via Hardware.
    4.  Converts output NALs to **Annex B**.
    5.  Returns packets with PTS/DTS.

## 2. Data Flow (Encode)

1.  **Handshake**: Message `HELLO` exchange.
2.  **Config**: Client sends `CONFIGURE`, Server creates `VTCompressionSession`.
3.  **Stream**:
    - **In**: `FRAME` (Pixels)
    - **Out**: `PACKET` (H.264/HEVC)
4.  **Teardown**: Client sends `FLUSH`, then closes.

## 3. Data Flow (Decode)

1.  **Handshake**: Message `HELLO` exchange.
2.  **Config**: Client sends `CONFIGURE`, Server creates `VTDecompressionSession`.
3.  **Stream**:
    - **In**: `PACKET` (Annex B)
    - **Out**: `FRAME` (NV12/P010)
4.  **Teardown**: Client sends `FLUSH`, then closes.

## 4. Data Flow (Transcode)

1.  **Handshake**: Message `HELLO` exchange.
2.  **Config**: Client sends `CONFIGURE` with `mode=transcode`.
3.  **Stream**:
    - **In**: `PACKET` (Annex B)
    - **Out**: `PACKET` (Annex B)
4.  **Teardown**: Client sends `FLUSH`, then closes.

## 5. Repository Layout

- **`ffmpeg/`**: Forked codebase with `libavcodec/vtremote*`.
- **`vtremoted/`**: SwiftPM server implementation.
- **`tests/`**: Integration tests and Python mock server.
- **`docs/`**: Protocol and Architecture documentation.

## 6. Performance Defaults

Defaults applied when the client does not override settings:

| Property | Default | Purpose |
|----------|---------|---------|
| `ExpectedFrameRate` | from client | Helps VT optimize encode pipeline |
| `PrioritizeEncodingSpeedOverQuality` | unset | Uses VideoToolbox default unless explicitly set |
| `RealTime` | `false` | Maximize throughput over latency |
| `MaximizePowerEfficiency` | `false` | Maximize speed over power |
| `MaxFrameDelayCount` | from `-bf` | Enable/limit frame reordering |

> [!NOTE]
> Remote decode defaults to **async** with a reorder depth of **2**. The reorder buffer sorts by PTS and clamps only when PTS would regress.
