---
title: VideoToolbox Remote
description: "Use any Mac on your LAN as a hardware H.264/HEVC transcoding server for FFmpeg. Drop-in VideoToolbox acceleration for Linux and Windows — no pipeline changes required."
---

<div class="hero">
  <h1>Hardware-Accelerated Video Encoding Over Your Network</h1>
  <p>
    Turn any Mac on your LAN into a dedicated H.264/HEVC transcoding server.<br>
    Drop-in FFmpeg codec. No pipeline changes. Linux, Windows, and macOS clients.
  </p>
  <div class="cta-row">
    <a class="btn primary" href="getting-started.html">Get Started</a>
    <a class="btn" href="https://github.com/davelindo/videotoolbox_remote/releases/latest">Download Binaries</a>
    <a class="btn" href="protocol.html">Protocol Spec</a>
  </div>
</div>

## The Problem

Apple's VideoToolbox is the fastest hardware encoder for H.264 and HEVC on Apple Silicon — but it only runs on macOS. If your workflow lives on Linux or Windows, you're stuck choosing between slow software encoding, expensive GPU acceleration, or moving your entire pipeline to a Mac.

VideoToolbox Remote eliminates that trade-off. It exposes any Mac on your LAN as a remote hardware encoding endpoint that FFmpeg talks to natively. Keep your inputs, filters, audio, and muxing local. Send only the video frames that need encoding.

## How It Works

A lightweight server (`vtremoted`) runs on macOS and wraps the VideoToolbox API. On the client side, custom FFmpeg codecs connect over TCP and appear as standard encoders:

```bash
ffmpeg -i input.mkv \
  -c:v h264_videotoolbox_remote \
  -vt_remote_host 192.168.1.50:5555 \
  -b:v 6000k \
  output.mkv
```

That's it. Every FFmpeg feature — filters, multi-stream muxing, audio codecs, hardware decode — works unchanged. The remote codec is just another `-c:v` option.

## Three Modes, One Protocol

<div class="feature-grid">
<div class="feature">
<h3>Remote Encode</h3>
<p>Send raw NV12/P010 frames to the server, receive compressed H.264/HEVC packets. Ideal when you have raw video and need hardware compression.</p>
</div>
<div class="feature">
<h3>Remote Decode</h3>
<p>Send compressed packets, receive raw frames. Offload decode-heavy workloads to Apple Silicon's dedicated media engine.</p>
</div>
<div class="feature">
<h3>Remote Transcode</h3>
<p>Send packets in, get packets out. The server handles the full decode-encode pipeline. Minimizes network bandwidth — only compressed data crosses the wire.</p>
</div>
</div>

## Built for LAN Performance

- **Wire compression**: LZ4 or Zstd compression on raw frame payloads reduces bandwidth by 40-70% with negligible CPU overhead.
- **Adaptive buffering**: Non-blocking send queues and configurable in-flight depth keep the encoder pipeline saturated.
- **1080p HEVC at 45-50 fps** on M-series silicon. Higher resolutions scale with Apple's media engine capabilities.
- **Parity with local VideoToolbox**: When configured identically, remote output matches local encoding behavior.

## Documentation

- [Getting Started](getting-started.html) — Installation, setup, and first encode.
- [Architecture](architecture.html) — System design, data flow, and component overview.
- [Protocol](protocol.html) — Wire specification (v1, stable).
- [OBS Plugin](obs-plugin.html) — Experimental OBS Studio integration.
- [Security](security.html) — SSH tunnels, VPN, and token authentication.
- [Troubleshooting](troubleshooting.html) — Common issues and performance tuning.
- [Development](development.html) — Building from source and running tests.

<div class="cta-row" style="margin-top: 48px;">
  <a class="btn primary" href="https://github.com/davelindo/videotoolbox_remote/releases/latest">Download Latest Release</a>
  <a class="btn" href="https://github.com/davelindo/videotoolbox_remote">View on GitHub</a>
</div>
