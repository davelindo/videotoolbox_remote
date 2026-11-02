---
title: Remote video encoding and transcoding
description: "Capture video on any PC and let your Mac encode it. NV12/P010 capture, Plex, FFmpeg, OBS and VA-API use the Mac's dedicated media hardware over the network."
home: true
---

<section class="hero" aria-labelledby="hero-title">
  <div>
    <h1 id="hero-title">Let your Mac<br>handle the<br><span>encoding.</span></h1>
    <p class="lead">Produce video on any PC. Keep capture, applications and files where they are, and use the Mac's dedicated media hardware for encoding.</p>
    <div class="actions">
      <a class="button primary" href="getting-started.html">Get started</a>
      <a class="button" href="{{ site.latest_release_url }}">Download {{ site.current_release }} ↗</a>
    </div>
    <p class="hero-note">Open source · H.264 &amp; HEVC · 10-bit HEVC support</p>
  </div>
  <figure class="mac-visual">
    <div class="mac-product"><img src="assets/mac-mini.png" width="1240" height="1240" fetchpriority="high" alt="A silver Mac mini with the Apple logo, the hardware that runs the remote VideoToolbox server."></div>
  </figure>
</section>

<section class="landing-section" aria-labelledby="workflows-title">
  <h2 id="workflows-title">An encoder for the tools you already use.</h2>
  <div class="workflow-grid">
    <div class="workflow-card">
      <div class="workflow-brand"><img class="product-icon plex-icon" src="assets/brands/plex.svg" width="64" height="32" alt="Plex"><span class="workflow-tag">Linux x86_64</span></div>
      <h3>Stream from a GPU-less server.</h3>
      <p>Keep Plex on Linux or your NAS. The Mac handles supported video decode, resize and encode; your server delivers playback. No Linux GPU required.</p>
      <a class="text-link" href="plex.html">Set up Plex offload →</a>
      <p class="workflow-scope">Plex Pass and a supported Plex build required.</p>
    </div>
    <div class="workflow-card">
      <div class="workflow-brand"><img class="product-icon ffmpeg-icon" src="assets/brands/ffmpeg.svg" width="32" height="32" alt=""><span>FFmpeg</span><span class="workflow-tag">Linux · Windows · macOS</span></div>
      <h3>Capture here. Encode on your Mac.</h3>
      <p>Send frames from cameras, desktop capture, recording systems or your application to the Mac. NV12 and P010 keep the source PC free from an intermediate video encode.</p>
      <a class="text-link" href="capture-and-encode.html">Encode from any PC →</a>
      <p class="workflow-scope">Use the matching FFmpeg client release.</p>
    </div>
    <div class="workflow-card">
      <div class="workflow-brand"><img class="product-icon" src="assets/brands/obsstudio.svg" width="32" height="32" alt=""><span>OBS Studio</span><span class="workflow-tag experimental">Experimental</span></div>
      <h3>Offload your live encoder.</h3>
      <p>Compose scenes on your OBS machine and send frames to the Mac for H.264 or HEVC encoding. Recording, audio and stream delivery stay in OBS.</p>
      <a class="text-link" href="obs-plugin.html">Try the OBS plugin →</a>
      <p class="workflow-scope">Build from source and test your streaming setup.</p>
    </div>
    <div class="workflow-card">
      <div class="workflow-brand"><img class="product-icon" src="assets/brands/linux.svg" width="32" height="32" alt=""><span>VA-API</span><span class="workflow-tag">Linux x86_64</span></div>
      <h3>Keep your existing FFmpeg.</h3>
      <p>Use stock FFmpeg's <code>h264_vaapi</code> or <code>hevc_vaapi</code> encoders with VideoToolbox on the Mac. Decode and filters run on Linux.</p>
      <a class="text-link" href="vaapi-driver.html">Install the VA-API driver →</a>
      <p class="workflow-scope">Encode-only. Libva requires a DRM render node.</p>
    </div>
  </div>
</section>

{% assign transport = site.data.transport %}
{% assign capture = transport.rows | where: "size", "3840x2160" | where: "variant", "mixed" | first %}
{% assign packet_control = transport.rows | where: "variant", "packet-only" | first %}
{% assign p010 = transport.rows | where: "pixel_format", "p010le" | where: "mode", "encode" | first %}
<section class="landing-section performance-preview" aria-labelledby="capture-title">
  <div>
    <h2 id="capture-title">Raw frames.<br>Remote hardware.</h2>
    <p>Thunderbolt networking and fast Ethernet make raw video offload practical. Capture on a mini PC, SBC or workstation, and hand encoding to the Mac.</p>
    <a class="text-link" href="capture-and-encode.html">Explore capture and frame workflows →</a>
    <p class="measurement-note">Two-core Intel NUC → Apple M2 · {{ transport.release }} · Median of three FFmpeg runs</p>
  </div>
  <div class="capture-metrics">
    <div><strong>{{ capture.median_fps | round: 1 }} <span>fps</span></strong><p>4K decode → Linux filter → encode<br>{{ packet_control.median_fps | round: 1 }} fps for packet-only transcoding</p></div>
    <div><strong>{{ p010.median_fps | round: 1 }} <span>fps</span></strong><p>4K P010 → HEVC Main 10<br>{{ p010.upload_gbps | round: 2 }} Gb/s of raw frame traffic</p></div>
  </div>
</section>

<section class="landing-section performance-preview" aria-labelledby="performance-title">
  <div>
    <h2 id="performance-title">Hardware transcoding<br>for compact servers.</h2>
    <p>Keep Linux on an SBC, mini PC or compact server. Use a Mac already on your LAN for hardware video processing, without adding a discrete GPU to your server.</p>
    <a class="text-link" href="performance.html">Explore the interactive benchmarks →</a>
    <p class="measurement-note">Compare speed, quality, CPU time and energy with local VideoToolbox, NVIDIA NVENC, Intel VA-API and CPU encoding.</p>
  </div>
  <figure class="performance-shot">
    <a href="performance.html" aria-label="Open the interactive performance benchmarks"><img src="assets/performance-preview.png" width="760" height="360" loading="lazy" alt="Measured HEVC 1080p throughput for seven pipelines, plotted from zero. NVIDIA NVENC P4: 352.5 frames per second. Open the benchmarks for all values and quality results."></a>
    <figcaption>Big Buck Bunny · HEVC · 1080p · 4 Mb/s budget<br>Median of three runs</figcaption>
  </figure>
</section>

<section class="landing-section quickstart" aria-labelledby="setup-title">
  <div>
    <h2 id="setup-title">Connect once.<br>Start encoding.</h2>
    <p>Install the server on your Mac and the matching client on the machine running your jobs. Set the Mac endpoint, then try a short transcode.</p>
    <div class="actions"><a class="button primary" href="getting-started.html">Installation guide →</a><a class="text-link" href="security.html">Secure your connection →</a></div>
    <div class="platform-note"><img class="product-icon" src="assets/brands/macos.svg" width="48" height="32" alt="macOS"><span>13+ · Apple Silicon or supported Intel Mac<br>Wired LAN recommended</span></div>
  </div>
  <div class="terminal">
    <div class="terminal-label"><img class="product-icon" src="assets/brands/ffmpeg.svg" width="16" height="16" alt="">FFmpeg · remote HEVC encode</div>
    <pre><code>ffmpeg -i input.mkv \
  -c:v hevc_videotoolbox_remote \
  -vt_remote_host "${MAC_HOST}:5555" \
  -b:v 4M -c:a copy \
  output.mkv</code></pre>
    <p class="terminal-note">Set <code>MAC_HOST</code> to your Mac's LAN address. This encode keeps decoding on the client.</p>
  </div>
</section>
<p class="image-credit">Mac mini image © Apple · <a href="https://www.apple.com/mac-mini/">Image source</a></p>
