---
title: Remote Plex & FFmpeg transcoding
description: "High-quality, low-power video transcoding with a Mac's VideoToolbox hardware. Keep Plex on Linux, convert files with FFmpeg and offload OBS or VA-API encoding over LAN."
home: true
---

<section class="hero" aria-labelledby="hero-title">
  <div>
    <h1 id="hero-title">Let your Mac<br>handle the<br><span>transcodes.</span></h1>
    <p class="lead">High-quality, low-power transcoding over LAN. Keep Plex, your files and your workflows where they are.</p>
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
      <h3>Work through your batch queue.</h3>
      <p>Convert H.264 or HEVC files using the Mac's efficient media engine. Packet transcoding sends compressed video both ways, keeping network traffic low.</p>
      <a class="text-link" href="getting-started.html#packet-transcoding-for-batch-jobs">Run a batch transcode →</a>
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

<section class="landing-section performance-preview" aria-labelledby="performance-title">
  <div>
    <h2 id="performance-title">See the speed.<br>Check the quality.</h2>
    <p>Compare Intel iGPU VA-API, CPU fast and medium presets, and local and remote VideoToolbox. Explore throughput, VMAF and physical file size at the same bitrate budget.</p>
    <a class="text-link" href="performance.html">Explore the interactive benchmarks →</a>
    <p class="measurement-note">Big Buck Bunny and FFmpeg test signals. Whole-system power has not been measured; see <a href="performance.html#power-and-quality">power and quality guidance</a>.</p>
  </div>
  <figure class="performance-shot">
    <a href="performance.html" aria-label="Open the interactive performance benchmarks"><img src="assets/performance-preview.png" width="760" height="360" loading="lazy" alt="Measured HEVC 1080p throughput for five pipelines, plotted from zero. Remote VideoToolbox: 186.1 frames per second. Open the benchmarks for all values and quality results."></a>
    <figcaption>Big Buck Bunny · HEVC · 1080p · 4 Mb/s budget<br>Measured 2026-10-04 · v0.9.14 · median of three runs</figcaption>
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
