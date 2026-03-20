---
title: VideoToolbox Remote
---

<div class="hero">
  <h1>VideoToolbox Remote</h1>
  <p>
    <strong>Remote VideoToolbox for FFmpeg.</strong><br>
    Use a Mac or Apple Silicon system over LAN as an IP-based H.264/HEVC encode/decode/transcoding accelerator.
  </p>
  <div class="cta-row">
    <a class="btn primary" href="getting-started.html">Get Started</a>
    <a class="btn" href="https://github.com/davelindo/videotoolbox_remote/releases/latest">Latest Release</a>
    <a class="btn" href="protocol.html">Protocol Spec</a>
  </div>
</div>

## Use a Mac as a Transcoding Server

VideoToolbox Remote is a networked FFmpeg accelerator for workflows that already live on Linux, Windows, or another Mac. It lets you keep FFmpeg local for inputs, filters, audio, and muxing while a remote Mac provides VideoToolbox hardware acceleration over the network.

If you have a Mac Mini, Mac Studio, or spare Apple Silicon system on the LAN, this is the direct way to use that machine as a remote VideoToolbox endpoint instead of moving the rest of your pipeline onto macOS.

Prefer binaries over a source build? Start with the server and client tarballs from the [latest GitHub release](https://github.com/davelindo/videotoolbox_remote/releases/latest).

## How It Works

It creates a lightweight, high-performance tunnel for video frames:

- **Client (Linux/Windows)**: Runs standard FFmpeg. Handles I/O, filters, and audio.
- **Server (macOS)**: Receives raw frames, encodes via `VideoToolbox`, and returns specific packets.

Integration is native. It appears as just another codec in FFmpeg:

```bash
ffmpeg -i input.mkv \
  -c:v h264_videotoolbox_remote \
  -vt_remote_host 192.168.1.50:5555 \
  -b:v 6000k \
  output.mkv
```

## Features

- **Efficient Transport**: Framed TCP streams with Zstd/LZ4 compression.
- **Drop-in Compatibility**: Works with standard FFmpeg filters and containers.
- **Native VideoToolbox**: Uses Apple’s hardware pipeline; results match local settings when configured identically.

## Documentation

- [Getting Started](getting-started.html): Installation and setup.
- [OBS Plugin](obs-plugin.html): Experimental OBS plugin build/test notes.
- [Architecture](architecture.html): System design and data flow.
- [Protocol](protocol.html): Wire specification.
- [Troubleshooting](troubleshooting.html): Common resolutions.
- [Security](security.html): Secure deployment guide.
