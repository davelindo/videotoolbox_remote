---
title: VideoToolbox Remote
description: "Remote VideoToolbox for FFmpeg: use a Mac or Apple Silicon system over LAN as a hardware H.264/HEVC encode, decode, and transcoding server for Linux, Windows, and macOS clients."
---

<div class="hero">
  <div class="hero-badge">
    <span class="badge-dot"></span>
    v0.7.11 &middot; Stable protocol v1
  </div>
  <h1>Remote VideoToolbox for FFmpeg</h1>
  <p>
    Turn a Mac on your LAN into a hardware H.264/HEVC encode, decode, and transcoding server.
    Drop-in FFmpeg codecs for Linux, Windows, and macOS clients.
  </p>
  <div class="cta-row">
    <a class="btn primary" href="getting-started.html">Get Started</a>
    <a class="btn" href="https://github.com/davelindo/videotoolbox_remote/releases/latest">Download Binaries</a>
    <a class="btn" href="protocol.html">Protocol Spec</a>
  </div>
</div>

<div class="stats-strip">
  <div class="stat">
    <div class="stat-value">230 fps</div>
    <div class="stat-label">1080p H.264 encode</div>
  </div>
  <div class="stat">
    <div class="stat-value">210 fps</div>
    <div class="stat-label">1080p HEVC encode</div>
  </div>
  <div class="stat">
    <div class="stat-value">~60 fps</div>
    <div class="stat-label">4K HEVC encode</div>
  </div>
  <div class="stat">
    <div class="stat-value">100%</div>
    <div class="stat-label">Output parity vs local</div>
  </div>
</div>

## The Problem

Apple's VideoToolbox is a fast hardware encoder for H.264 and HEVC on Apple Silicon, but it only runs on macOS. If your FFmpeg workflow lives on a Linux server, Windows workstation, NAS, or homelab box, you are usually choosing between slow software encoding, a separate GPU path, or moving the whole pipeline to a Mac.

VideoToolbox Remote exposes a Mac on your LAN as a remote VideoToolbox endpoint for FFmpeg. Keep inputs, filters, audio, subtitles, and muxing local. Offload only the H.264/HEVC work that benefits from the Mac's media hardware.

## How It Works

A lightweight server (`vtremoted`) runs on macOS and wraps the VideoToolbox API. On the client side, custom FFmpeg codecs connect over TCP and appear as normal `-c:v` choices:

```bash
ffmpeg -i input.mkv \
  -c:v h264_videotoolbox_remote \
  -vt_remote_host 192.168.1.50:5555 \
  -b:v 6000k \
  output.mkv
```

The rest of FFmpeg stays familiar. Filters, multi-stream muxing, audio codecs, subtitles, and local I/O continue to run on the client.

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
<p>Send packets in, get packets out. The server handles the video decode-to-encode path; FFmpeg I/O, filters outside vtremote transcode options, audio, subtitles, and muxing stay on the client.</p>
</div>
</div>

## Built for LAN Performance

- **Wire compression**: LZ4 or Zstd compression on raw frame payloads reduces bandwidth by 40-70% with negligible CPU overhead.
- **Adaptive buffering**: Non-blocking send queues and configurable in-flight depth keep the encoder pipeline saturated.
- **1080p at 200+ fps** (H.264 ~230 fps, HEVC ~210 fps) on Apple Silicon. 4K at ~60 fps. Actual throughput depends on content, bitrate, and network.
- **Parity with local VideoToolbox**: When configured identically, remote output matches local encoding behavior.

See [benchmarks](benchmarks.html) for hardware, network, and reproduction details.

## Documentation

<div class="doc-grid">
<a class="doc-card" href="getting-started.html"><div class="doc-card-title">Getting Started</div><div class="doc-card-desc">Installation, setup, and first encode.</div></a>
<a class="doc-card" href="benchmarks.html"><div class="doc-card-title">Benchmarks</div><div class="doc-card-desc">Performance numbers, caveats, and reproduction commands.</div></a>
<a class="doc-card" href="architecture.html"><div class="doc-card-title">Architecture</div><div class="doc-card-desc">System design, data flow, and component overview.</div></a>
<a class="doc-card" href="protocol.html"><div class="doc-card-title">Protocol</div><div class="doc-card-desc">Wire specification (v1, stable).</div></a>
<a class="doc-card" href="obs-plugin.html"><div class="doc-card-title">OBS Plugin</div><div class="doc-card-desc">Experimental OBS Studio integration.</div></a>
<a class="doc-card" href="security.html"><div class="doc-card-title">Security</div><div class="doc-card-desc">SSH tunnels, VPN, and token authentication.</div></a>
<a class="doc-card" href="troubleshooting.html"><div class="doc-card-title">Troubleshooting</div><div class="doc-card-desc">Common issues and performance tuning.</div></a>
<a class="doc-card" href="development.html"><div class="doc-card-title">Development</div><div class="doc-card-desc">Building from source and running tests.</div></a>
</div>

<div class="cta-row" style="margin-top: 56px;">
  <a class="btn primary" href="https://github.com/davelindo/videotoolbox_remote/releases/latest">Download Latest Release</a>
  <a class="btn" href="https://github.com/davelindo/videotoolbox_remote">View on GitHub</a>
</div>
