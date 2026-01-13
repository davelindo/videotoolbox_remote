---
title: VideoToolbox Remote
---

<div class="wrap hero">
  <div>
    <div class="eyebrow">Hardware encode/decode, offloaded</div>
    <h1>Use a Mac as your VideoToolbox accelerator—remotely.</h1>
    <p>
      VideoToolbox Remote offloads H.264/HEVC encode + decode to a macOS daemon while
      keeping demux, filters, audio/subs, and mux on your FFmpeg client. It feels like
      a local codec with a network hop.
    </p>
    <div class="cta-row">
      <a class="btn primary" href="getting-started.html">Get Started</a>
      <a class="btn" href="protocol.html">Protocol Spec</a>
    </div>
  </div>
  <div class="hero-card">
    <div class="eyebrow">One line to use</div>
    <pre><code>ffmpeg -i input.mkv \
  -c:v h264_videotoolbox_remote \
  -vt_remote_host macmini.local:5555 \
  -b:v 6000k -g 240 \
  -c:a copy -c:s copy \
  output.mkv</code></pre>
  </div>
</div>

<div class="wrap">
  <h2 class="section-title">Why this exists</h2>
  <div class="grid">
    <div class="card">
      <h3>Keep your pipeline local</h3>
      <p>Only the encode/decode step goes remote. Filters, audio, and mux stay on the client.</p>
    </div>
    <div class="card">
      <h3>Leverage spare Macs</h3>
      <p>Use Apple Silicon hardware encode/decode from Linux/Windows or headless servers.</p>
    </div>
    <div class="card">
      <h3>Protocol is simple</h3>
      <p>TCP, framed messages, Annex B packets on the wire. Easy to reimplement elsewhere.</p>
    </div>
  </div>

  <h2 class="section-title">How it works</h2>
  <div class="split">
    <div class="card">
      <h3>Encode path</h3>
      <p>Raw NV12/P010 frames → TCP → vtremoted → Annex B packets → mux locally.</p>
    </div>
    <div class="card">
      <h3>Decode path</h3>
      <p>Annex B packets → TCP → vtremoted → raw NV12/P010 frames → filters/encode locally.</p>
    </div>
  </div>

  <h2 class="section-title">Docs</h2>
  <div class="grid">
    <a class="card" href="getting-started.html"><h3>Getting Started</h3><p>Build, run, and verify in minutes.</p></a>
    <a class="card" href="architecture.html"><h3>Architecture</h3><p>System boundaries, data flow, invariants.</p></a>
    <a class="card" href="protocol.html"><h3>Protocol</h3><p>Authoritative v1 spec.</p></a>
    <a class="card" href="development.html"><h3>Development</h3><p>Build/test notes for contributors.</p></a>
    <a class="card" href="security.html"><h3>Security</h3><p>Token auth, LAN guidance, hardening.</p></a>
    <a class="card" href="troubleshooting.html"><h3>Troubleshooting</h3><p>Common failure modes and fixes.</p></a>
  </div>
</div>
