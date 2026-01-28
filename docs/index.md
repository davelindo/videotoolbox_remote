---
title: VideoToolbox Remote
---

<div class="hero">
  <h1>VideoToolbox Remote</h1>
  <p>
    <strong>Turn your Mac into a dedicated FFmpeg accelerator.</strong><br>
    Seamlessly offload H.264/HEVC encoding & decoding to networked Apple Silicon.
  </p>
  <div class="cta-row">
    <a class="btn primary" href="getting-started.html">Get Started</a>
    <a class="btn" href="protocol.html">Protocol Spec</a>
  </div>
</div>

## Why VideoToolbox Remote?
You have a powerful Mac Mini or Studio, but your production workflow runs on Linux or Windows. **VideoToolbox Remote** bridges the gap, allowing you to utilize Apple's efficient hardware acceleration without complex desktop sharing or file transfers.

## How It Works
It creates a lightweight, high-performance tunnel for video frames:

*   **Client (Linux/Windows)**: Runs standard FFmpeg. Handles IO, filters, and audio.
*   **Server (macOS)**: Receives raw frames, encodes via `VideoToolbox`, and returns specific packets.

Integration is native. It appears as just another codec in FFmpeg:

```bash
ffmpeg -i input.mkv \
  -c:v h264_videotoolbox_remote \
  -vt_remote_host 192.168.1.50:5555 \
  -b:v 6000k \
  output.mkv
```

## Features
*   **Zero-Copy Networking**: Optimized TCP streams with Zstd compression.
*   **Drop-in Compatibility**: Works with standard FFmpeg filters and containers.
*   **Native Quality**: Identical encoding results to a local Mac.

## Documentation
*   [Getting Started](getting-started.html) - Installation and setup.
*   [Architecture](architecture.html) - System design and data flow.
*   [Protocol](protocol.html) - Wire specification.
*   [Troubleshooting](troubleshooting.html) - Common resolutions.
