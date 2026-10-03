---
title: VideoToolbox Remote
description: "High-quality, low-power H.264 and HEVC transcoding over LAN. Keep Plex on Linux and use a Mac's VideoToolbox hardware for Plex, FFmpeg, VA-API and OBS."
home: true
---

<section class="hero" aria-labelledby="hero-title">
  <div>
    <div class="eyebrow">Apple media hardware. Across your LAN.</div>
    <h1 id="hero-title">High quality.<br>Low power.<br><span>Anywhere on LAN.</span></h1>
    <p class="lead">Keep your server on Linux. Put a Mac's efficient VideoToolbox hardware to work for Plex, batch transcodes and live video.</p>
    <div class="actions">
      <a class="button primary" href="getting-started.html">Get started</a>
      <a class="button" href="{{ site.latest_release_url }}">Download {{ site.current_release }} ↗</a>
    </div>
    <p class="hero-note">H.264 / HEVC · Apple Silicon &amp; supported Intel Macs</p>
  </div>
  <div class="engine" aria-label="Plex remote transcode data flow">
    <div class="engine-title"><span>Plex · packet transcode</span><span>TCP / LAN</span></div>
    <div class="engine-node"><strong>Your Linux server</strong><p>Plex · media storage · audio · delivery</p></div>
    <div class="engine-flow">Compressed H.264 / HEVC input <span aria-hidden="true">↓</span></div>
    <div class="engine-node mac"><strong>Mac + VideoToolbox</strong><p>Hardware decode → resize → hardware encode</p></div>
    <div class="engine-flow">Encoded video packets <span aria-hidden="true">↑</span></div>
    <div class="engine-node"><strong>Your Plex playback</strong><p>Linux serves the resulting stream</p></div>
    <p class="engine-caption">A separate Mac supplies the video engine. Plex stays on your existing host.</p>
  </div>
</section>
<div class="compatibility"><strong>{{ site.current_release }}</strong><span>macOS 13+ server</span><span>Linux · Windows · macOS FFmpeg</span><span>Stable protocol v1</span></div>

<section class="landing-section" aria-labelledby="benefits-title">
  <div class="section-label">Why remote VideoToolbox</div>
  <h2 id="benefits-title">More video. Less server work.</h2>
  <div class="benefits">
    <div><h3>Efficient by design.</h3><p>Use dedicated media hardware instead of making a small server's CPU do every video encode. A Mac mini can be your homelab's shared video engine.</p><a class="text-link" href="benchmarks.html#power-and-quality">Power &amp; quality context →</a></div>
    <div><h3>Quality comes first.</h3><p>H.264, HEVC and HEVC Main 10, with bitrate, profile and color controls. Published comparisons include VMAF at matched output bitrates.</p><a class="text-link" href="benchmarks.html">Explore the measurements →</a></div>
    <div><h3>A lighter host.</h3><p>Let low-powered and GPU-less devices keep the jobs they do well: storage, automation and serving media. Offload the supported video path to the Mac.</p><a class="text-link" href="plex.html">Plex on Linux →</a></div>
  </div>
</section>

<section class="landing-section" aria-labelledby="usecases-title">
  <div class="section-label">One Mac. Several workflows.</div>
  <h2 id="usecases-title">Your workflow, accelerated.</h2>
  <div class="usecase"><span class="usecase-number">01</span><div><h3>Plex on your Linux homelab.</h3><span class="tag">External video engine · Linux x86_64</span></div><div><p>Keep Plex on your server or NAS. The container integration sends compressed video to a Mac for decode, resize and encode, without a Linux GPU for that path. Supported Plex builds and filter graphs are checked before offloading.</p><a class="text-link" href="plex.html">Install &amp; verify Plex →</a></div></div>
  <div class="usecase"><span class="usecase-number">02</span><div><h3>Batch transcodes, quietly.</h3><span class="tag">FFmpeg · H.264 / HEVC / Main 10</span></div><div><p>Queue library conversions on Linux, Windows or macOS and use a Mac's hardware encoder. Packet transcoding keeps raw video off the network; remote encoding also supports your local FFmpeg filters.</p><a class="text-link" href="getting-started.html#packet-transcoding-for-batch-jobs">Run a batch job →</a></div></div>
  <div class="usecase"><span class="usecase-number">03</span><div><h3>OBS with a remote encoder.</h3><span class="tag">Experimental · H.264 / HEVC</span></div><div><p>Compose scenes in OBS Studio and send frames to VideoToolbox on another Mac. Dedicated H.264 and HEVC encoder entries use the same daemon. Build and lifecycle validation are still evolving.</p><a class="text-link" href="obs-plugin.html">Explore the OBS plugin →</a></div></div>
  <div class="usecase"><span class="usecase-number">04</span><div><h3>Stock Linux VA-API tools.</h3><span class="tag">Encode-only · Linux x86_64</span></div><div><p>Use <code>h264_vaapi</code> or <code>hevc_vaapi</code> with stock FFmpeg through the Linux driver. Decode and filters stay local; a DRM render node, including VGEM where available, initializes libva.</p><a class="text-link" href="vaapi-driver.html">Set up VA-API →</a></div></div>
</section>

<section class="landing-section quickstart" aria-labelledby="quickstart-title">
  <div><div class="section-label">Start small</div><h2 id="quickstart-title">Your first remote encode.</h2><p>Download the matching server and FFmpeg binaries. Start <code>vtremoted</code> on your Mac, then select the remote codec on the client.</p><p>Begin on a trusted LAN. Configure a token or tunnel before sharing the endpoint.</p><a class="text-link" href="getting-started.html">Installation &amp; authentication →</a></div>
  <div class="terminal"><div class="terminal-label">FFmpeg client · Mac endpoint 192.168.1.20</div><pre><code>ffmpeg -i input.mkv \
  -c:v h264_videotoolbox_remote \
  -vt_remote_host 192.168.1.20:5555 \
  -b:v 6M -c:a copy -c:s copy \
  output.mkv</code></pre></div>
</section>

<section class="landing-section" aria-labelledby="modes-title">
  <div class="section-label">Choose the path that fits</div><h2 id="modes-title">Frames or packets. Your choice.</h2>
  <div class="modes"><div><h3>Encode</h3><p>Raw frames in, compressed packets out. For local filters, OBS and the VA-API driver. Raw-frame bandwidth depends on resolution, format and content.</p></div><div><h3>Decode</h3><p>Compressed packets in, raw frames out. For workloads that need decoded video locally. High-resolution raw output needs a fast LAN.</p></div><div><h3>Transcode</h3><p>Compressed packets in and out. Mac-side decode, optional resize and encode. The efficient network path for supported Plex and batch jobs.</p></div></div>
</section>

<section class="landing-section" aria-labelledby="guides-title">
  <div class="section-label">Documentation</div><h2 id="guides-title">From first frame to the wire.</h2>
  <div class="guide-grid">
    <a href="getting-started.html"><strong>Getting started →</strong><span>Binaries, source builds and first transcodes.</span></a>
    <a href="plex.html"><strong>Plex →</strong><span>Linux host, Mac engine and playback checks.</span></a>
    <a href="vaapi-driver.html"><strong>Linux VA-API →</strong><span>Driver installation, render nodes and scope.</span></a>
    <a href="obs-plugin.html"><strong>OBS Studio →</strong><span>Experimental remote encoder setup.</span></a>
    <a href="benchmarks.html"><strong>Quality &amp; benchmarks →</strong><span>Measured results and their limits.</span></a>
    <a href="architecture.html"><strong>Architecture →</strong><span>Components and video data flow.</span></a>
    <a href="security.html"><strong>Security →</strong><span>Tokens, SSH tunnels and network isolation.</span></a>
    <a href="troubleshooting.html"><strong>Troubleshooting →</strong><span>Connection, compatibility and performance.</span></a>
    <a href="development.html"><strong>Development →</strong><span>Tests, protocol and release workflow.</span></a>
  </div>
</section>
<section class="closing"><div><h2>Put that Mac to work.</h2><p>Keep your Linux server. Add Apple's media hardware.</p></div><div class="actions"><a class="button primary" href="plex.html">Set up Plex</a><a class="button" href="{{ site.repository_url }}">View on GitHub ↗</a></div></section>
