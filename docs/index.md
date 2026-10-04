---
title: Remote Plex & FFmpeg transcoding
description: "Keep Plex on Linux. Use a Mac's efficient VideoToolbox hardware for high-quality H.264/HEVC transcodes over LAN, FFmpeg batch jobs, VA-API and experimental OBS."
home: true
---

<section class="hero" aria-labelledby="hero-title">
  <div>
    <div class="eyebrow">Low-power video for your Linux homelab</div>
    <h1 id="hero-title">Let your Mac<br>handle the<br><span>transcodes.</span></h1>
    <p class="lead">Keep Plex on your Linux server. Offload high-quality H.264 and HEVC transcodes to a Mac's efficient media hardware over LAN.</p>
    <div class="actions">
      <a class="button primary" href="getting-started.html">Set up remote transcoding</a>
      <a class="button" href="{{ site.latest_release_url }}">Download {{ site.current_release }} ↗</a>
    </div>
    <p class="hero-note">Open source · Apple Silicon &amp; supported Intel Macs</p>
  </div>
  <div class="engine" aria-label="Plex remote transcode data flow">
    <div class="engine-title"><span>Plex · packet transcode</span><span>TCP / LAN</span></div>
    <div class="engine-node"><strong>Your Linux server</strong><p>Plex · media storage · audio · delivery</p></div>
    <div class="engine-flow">Compressed H.264 / HEVC input <span aria-hidden="true">↓</span></div>
    <div class="engine-node mac"><strong>Mac + VideoToolbox</strong><p>Hardware decode → resize → hardware encode</p></div>
    <div class="engine-flow">Encoded video packets <span aria-hidden="true">↑</span></div>
    <div class="engine-node"><strong>Your Plex playback</strong><p>Linux serves the resulting stream</p></div>
    <p class="engine-caption">Your media library stays on Linux. The Mac processes video and sends it back for playback.</p>
  </div>
</section>
<div class="compatibility"><strong>{{ site.current_release }}</strong><span>macOS 13+ server</span><span>Linux · Windows · macOS FFmpeg</span><span>Stable protocol v1</span></div>

<section class="landing-section" aria-labelledby="benefits-title">
  <div class="section-label">Why remote VideoToolbox</div>
  <h2 id="benefits-title">Keep Plex running on the server you have.</h2>
  <div class="benefits">
    <div><h3>Free your server's CPU for hosting.</h3><p>Your Linux host keeps Plex, storage and stream delivery. The Mac handles supported video decode, resizing and encoding, so a GPU-less server can host Plex transcodes.</p><a class="text-link" href="plex.html">See the Plex setup →</a></div>
    <div><h3>Put efficient media hardware to work.</h3><p>A Mac mini can process playback transcodes and batch queues for your homelab. VideoToolbox uses dedicated media hardware designed for efficient video processing.</p><a class="text-link" href="performance.html#power-and-quality">Understand power use →</a></div>
    <div><h3>Control the quality of your output.</h3><p>Keep 10-bit HEVC output when your workflow needs it. Set bitrate, profile and color metadata, then compare throughput and video quality in the Performance guide.</p><a class="text-link" href="performance.html">Compare measured performance →</a></div>
  </div>
</section>

<section class="landing-section" aria-labelledby="usecases-title">
  <div class="section-label">Choose your workflow</div>
  <h2 id="usecases-title">Use the Mac for Plex, batch jobs or live video.</h2>
  <div class="usecase"><span class="usecase-number">01</span><div><h3>Host Plex on a GPU-less Linux server.</h3><span class="tag">Plex Docker · Linux x86_64</span></div><div><p>Keep your media library and Plex installation on your server or NAS. Send supported video transcodes to the Mac and serve the finished stream from Linux. The integration checks Plex compatibility before offloading.</p><a class="text-link" href="plex.html">Set up Plex offload →</a></div></div>
  <div class="usecase"><span class="usecase-number">02</span><div><h3>Run batch conversions on Mac hardware.</h3><span class="tag">FFmpeg · Linux / Windows / macOS</span></div><div><p>Queue H.264 or HEVC conversions from the machine that holds your files. The Mac's dedicated media engine handles video processing. Packet transcoding sends compressed video in both directions to keep network traffic low.</p><a class="text-link" href="getting-started.html#packet-transcoding-for-batch-jobs">Run your first batch transcode →</a></div></div>
  <div class="usecase"><span class="usecase-number">03</span><div><h3>Give OBS a separate video encoder.</h3><span class="tag">Experimental · H.264 / HEVC</span></div><div><p>Keep scene composition and stream output on your OBS machine. Send video frames to the Mac for VideoToolbox encoding through the plugin's H.264 or HEVC encoder. Validate your recording and streaming workflow before relying on it.</p><a class="text-link" href="obs-plugin.html">Try the experimental OBS encoder →</a></div></div>
  <div class="usecase"><span class="usecase-number">04</span><div><h3>Use stock FFmpeg's VA-API encoders.</h3><span class="tag">Encode-only · Linux x86_64</span></div><div><p>Use <code>h264_vaapi</code> or <code>hevc_vaapi</code> on Linux with the Mac handling the encode. The driver fits the existing VA-API interface. Video decode and filters stay local, and libva needs a render node.</p><a class="text-link" href="vaapi-driver.html">Connect VA-API to the Mac →</a></div></div>
</section>

<section class="landing-section" aria-labelledby="setup-title">
  <div class="section-label">How to connect your machines</div><h2 id="setup-title">Start the Mac. Connect your workflow.</h2>
  <div class="modes"><div><h3>1. Start the Mac server</h3><p>Download the macOS server and matching client release. Run <code>vtremoted</code> on the Mac's private LAN address and configure authentication for shared access.</p></div><div><h3>2. Choose your integration</h3><p>Set up the Plex container, select a remote FFmpeg codec, or configure the VA-API driver. Each guide shows what to install on the client.</p></div><div><h3>3. Verify a real transcode</h3><p>Run a short job and check the Mac's session logs and the output. For Plex, confirm hardware transcoding and actual playback before adding more streams.</p></div></div>
</section>

<section class="landing-section quickstart" aria-labelledby="quickstart-title">
  <div><div class="section-label">Try it with FFmpeg</div><h2 id="quickstart-title">Send your next encode to the Mac.</h2><p>Once the server and matching FFmpeg client are installed, select <code>h264_videotoolbox_remote</code> and point it at your Mac.</p><p>This example keeps decoding on the client. Choose packet transcoding to move supported video decode and resize to the Mac too.</p><a class="text-link" href="getting-started.html">Follow the installation guide →</a></div>
  <div class="terminal"><div class="terminal-label">FFmpeg client · Mac endpoint 192.168.1.20</div><pre><code>ffmpeg -i input.mkv \
  -c:v h264_videotoolbox_remote \
  -vt_remote_host 192.168.1.20:5555 \
  -b:v 6M -c:a copy -c:s copy \
  output.mkv</code></pre></div>
</section>

<section class="landing-section" aria-labelledby="guides-title">
  <div class="section-label">Setup guides and reference</div><h2 id="guides-title">Find the guide for your setup.</h2>
  <div class="guide-grid">
    <a href="getting-started.html"><strong>Getting started →</strong><span>Binaries, source builds and first transcodes.</span></a>
    <a href="plex.html"><strong>Plex →</strong><span>Linux host, Mac engine and playback checks.</span></a>
    <a href="vaapi-driver.html"><strong>Linux VA-API →</strong><span>Driver installation, render nodes and scope.</span></a>
    <a href="obs-plugin.html"><strong>OBS Studio →</strong><span>Experimental remote encoder setup.</span></a>
    <a href="performance.html"><strong>Performance →</strong><span>Current video workflows, quality and throughput.</span></a>
    <a href="architecture.html"><strong>Architecture →</strong><span>Components and video data flow.</span></a>
    <a href="security.html"><strong>Security →</strong><span>Tokens, SSH tunnels and network isolation.</span></a>
    <a href="troubleshooting.html"><strong>Troubleshooting →</strong><span>Connection, compatibility and performance.</span></a>
    <a href="development.html"><strong>Development →</strong><span>Tests, protocol and release workflow.</span></a>
  </div>
</section>

<section class="landing-section" aria-labelledby="questions-title">
  <div class="section-label">Before you set up</div><h2 id="questions-title">Check the fit for your homelab.</h2>
  <div class="faq">
    <details><summary>Can I keep Plex on Linux without a GPU?</summary><p>Yes, for the supported Plex video path. The Mac handles video decode, resize and encode; Linux keeps Plex, audio processing and stream delivery. The Plex integration needs no Linux GPU or DRM render node. See the <a href="plex.html">Plex requirements</a> for supported builds and playback checks.</p></details>
    <details><summary>Which Mac and clients can I use?</summary><p>The server requires macOS 13+ on Apple Silicon or a supported Intel Mac with VideoToolbox hardware. FFmpeg clients run on Linux, Windows and macOS. Plex and the VA-API driver target Linux x86_64. Check the <a href="getting-started.html#requirements">platform requirements</a> before downloading.</p></details>
    <details><summary>Does this offload every Plex transcode?</summary><p>Offload covers recognized Plex builds and supported H.264/HEVC video paths. Tone mapping, deinterlacing and subtitle burn-in stay on the native path. Normal hardware-accelerated Plex playback requires Plex Pass. The <a href="plex.html">compatibility guide</a> explains the current scope.</p></details>
    <details><summary>How much power will my setup use?</summary><p>VideoToolbox uses the Mac's dedicated media hardware, and low-power transcoding is a core goal. The Performance guide reports quality, throughput and host resource use. Whole-system watts have not been measured. <a href="performance.html#power-and-quality">Measure both hosts over a complete job</a> to compare energy use on your setup.</p></details>
    <details><summary>Do I need a fast network?</summary><p>A wired LAN is recommended. Plex and FFmpeg packet transcoding send compressed video in both directions. Remote encoding for OBS, VA-API or local FFmpeg filters sends raw frames and needs more bandwidth. See <a href="performance.html#network-and-performance-guidance">network and performance guidance</a>.</p></details>
    <details><summary>Is the OBS plugin ready for my stream?</summary><p>The plugin is experimental. It provides remote H.264 and HEVC encoding, while scene composition, audio and stream output stay in OBS. Build it from source and test your full recording or streaming workflow. Start with the <a href="obs-plugin.html">OBS setup and validation guide</a>.</p></details>
  </div>
</section>
<section class="closing"><div><h2>Give your server a Mac's media engine.</h2><p>Start with one transcode. Keep Plex and your files where they are.</p></div><div class="actions"><a class="button primary" href="getting-started.html">Set up remote transcoding</a><a class="button" href="{{ site.repository_url }}">View on GitHub ↗</a></div></section>
