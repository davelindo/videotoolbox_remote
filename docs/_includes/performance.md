# Performance

Give your SBC, mini PC or compact Linux server hardware video processing through a Mac on the LAN, without adding a discrete GPU.

Remote VideoToolbox delivers **186–209 fps** in the 1080p moving-video tests, with **less than one CPU second** of Linux FFmpeg work per 60-second clip.

{% assign performance = site.data.performance %}

<div class="benchmark" id="benchmark">
  <div class="benchmark-controls" aria-label="Benchmark selection">
    <label>Input<select id="benchmark-input"><option value="big-buck-bunny">Big Buck Bunny</option><option value="testsrc2">Moving test signal</option><option value="smptebars">Static color bars</option></select></label>
    <label>Codec<select id="benchmark-codec"><option value="h264">H.264</option><option value="hevc" selected>HEVC</option></select></label>
    <label>Output<select id="benchmark-size"><option value="1920x1080">1080p</option><option value="1280x720">720p</option></select></label>
  </div>
  <p class="benchmark-selection" id="benchmark-selection" aria-live="polite"></p>
  <p class="benchmark-control-note" id="benchmark-control-note" hidden>Static color bars are a control. Use the moving inputs for quality comparisons.</p>
  <div class="benchmark-charts">
    <figure class="benchmark-chart"><figcaption><strong>Transcode speed</strong><span>Frames per second · higher is faster</span></figcaption><div class="benchmark-canvas"><canvas id="benchmark-speed" role="img" aria-label="Median transcode speed by pipeline. Exact values appear below."></canvas></div></figure>
    <figure class="benchmark-chart"><figcaption><strong>Video quality</strong><span>VMAF · higher is better · 0–100 scale</span></figcaption><div class="benchmark-canvas"><canvas id="benchmark-quality" role="img" aria-label="Video quality by pipeline. Exact values appear below."></canvas></div></figure>
    <figure class="benchmark-chart"><figcaption><strong>FFmpeg CPU time</strong><span>CPU seconds for the 60-second clip · lower uses less CPU</span></figcaption><div class="benchmark-canvas"><canvas id="benchmark-cpu" role="img" aria-label="Submitting FFmpeg CPU time by pipeline. Exact values appear below."></canvas></div></figure>
    <figure class="benchmark-chart"><figcaption><strong>Transcode energy</strong><span>Mac system and NVIDIA GPU board · joules per clip · lower uses less energy</span></figcaption><div class="benchmark-canvas"><canvas id="benchmark-energy" role="img" aria-label="Mac-system energy for VideoToolbox and GPU-board energy for NVENC. Exact values appear below."></canvas></div></figure>
  </div>
  <p class="benchmark-caption">Speed is the median of three complete transcodes. Hover or tap a bar for exact values and run ranges. Remote CPU time measures the Linux FFmpeg client.</p>
  <details class="benchmark-exact"><summary>Exact values for this comparison</summary><div id="benchmark-values"></div></details>
  <noscript><p>The complete measured tables are available below without JavaScript.</p></noscript>
</div>

<script id="benchmark-data" type="application/json">{{ performance | jsonify }}</script>
<script src="{{ '/assets/vendor/chart.umd.min.js' | relative_url }}" defer></script>
<script src="{{ '/assets/performance.js' | relative_url }}" defer></script>

## All measured results

{% for fixture in performance.fixtures %}
<details class="benchmark-results" markdown="1">
<summary>{{ fixture.label }} — all codecs and resolutions</summary>

{% if fixture.id == "smptebars" %}
Static bars are controls. Use the moving inputs for quality comparisons.
{% endif %}

{% for output in performance.outputs %}
### {{ output.label }}

| Pipeline | fps | VMAF | File MB | File Mb/s |
| --- | ---: | ---: | ---: | ---: |
{% assign rows = performance.rows | where: "fixture", fixture.id | where: "codec", output.codec | where: "size", output.size %}{% for row in rows %}| {{ row.label }} | {{ row.median_fps | round: 1 }} | {{ row.vmaf | round: 2 }} | {{ row.median_file_bytes | divided_by: 1000000.0 | round: 3 }} | {{ row.median_container_mbps | round: 3 }} |
{% endfor %}
{% endfor %}
</details>
{% endfor %}

File MB uses decimal megabytes. File Mb/s is the complete container bitrate reported by ffprobe. VMAF scores every frame of the first measured repeat. [Download the measured data]({{ site.repository_url }}/blob/main/docs/_data/performance.json) for SSIM, exact scored-file sizes, hashes, CPU time, energy and all repeat-level measurements.

## Hardware and method

| Machine | Configuration |
| --- | --- |
| Linux | Intel Core i7-12650H, 32 GB RAM, Ubuntu 24.04; Intel iHD 24.3.4 / libva 2.22 |
| Mac | Apple M2, 16 GB RAM, macOS 15.7.5; both VideoToolbox pipelines |
| NVIDIA | GeForce RTX 3070 Ti, 8 GB VRAM; Ryzen 7 5800X3D, 48 GB RAM, Ubuntu 24.04; driver {{ performance.nvenc.driver }}, {{ performance.nvenc.power_limit_watts }} W GPU limit |
| Remote connection | Wired LAN; Mac interface negotiated 2.5 GbE |

These are complete **decode → resize → encode → file** workflows. Remote VideoToolbox sends compressed video from Linux to the Mac and receives the encoded output. Intel uses hardware decode, `scale_vaapi` and encode; CPU pipelines use software decode and bicubic scaling; native Mac uses hardware decode, `scale_vt` and encode. NVIDIA uses NVDEC, bicubic `scale_cuda` and NVENC with local files.

<details class="benchmark-method" markdown="1">
<summary>Inputs, settings and measurement details</summary>

- **Big Buck Bunny:** seconds 60–120 of the Blender Foundation's [1080p30 Sunflower release](https://download.blender.org/demo/movies/BBB/). Credit: Big Buck Bunny, Blender Foundation; Sunflower release, Blender Institute. [Project and licensing](https://peach.blender.org/).
- **Moving test signal:** FFmpeg `testsrc2`, 1920×1080 at 30 fps for 60 seconds.
- **Static color bars:** FFmpeg `smptebars` with the same dimensions, frame rate and duration.

Prepared inputs use H.264 High, 8-bit BT.709, `libx264 -preset fast -crf 10`. All pipelines use the same preparation recipe and source segment. Quality is measured against the prepared input.

Each run processes one stream of H.264 High or HEVC Main, 8-bit 4:2:0 video at 30 fps. File budgets are 4/6 Mb/s for H.264 and 3/4 Mb/s for HEVC at 720p/1080p. Calibration adjusts the requested bitrate using the full clip. Tables report the actual file sizes and rates; static bars are controls.

Reported file sizes and bitrates include container overhead and filler. The NVENC and Mac energy matrices use whole-file calibration within 2% of the moving-video budgets.

All pipelines use average/VBR, a 60-frame maximum GOP and zero frame reordering. Both VideoToolbox paths require hardware encoding with `realtime=0` and `prio_speed=0`.

NVENC uses P4 and P7 with `tune=hq`, `rc=vbr`, `multipass=disabled` and `-bf 0`, at a {{ performance.nvenc.power_limit_watts }} W GPU limit.

Three measured repeats follow a 60-frame warm-up. Pipeline order rotates and jobs run sequentially. Throughput includes FFmpeg startup, video processing and writing the file. Calibration, validation and scoring run separately.

Outputs are independently decoded and checked for frame counts, format, dimensions, GOP and timestamps.

VMAF 0.6.1 and SSIM score all 1,800 frames of the first measured repeat, using bicubic reference resizing and aligned timestamps.

Binary and input SHA-256 hashes, scorer version and unrounded measurements are in the downloadable data.
</details>

## Power and quality

Energy is measured over each complete transcode: **Mac system** for local VideoToolbox and **GPU board** for NVENC. Exact values include average watts and frames per joule.

| Input | Output | VideoToolbox, Mac system J | NVENC P4, GPU board J | NVENC P7, GPU board J |
| --- | --- | ---: | ---: | ---: |
{% for row in performance.videotoolbox_energy.rows %}{% assign p4 = performance.rows | where: "fixture", row.fixture | where: "codec", row.codec | where: "size", row.size | where: "backend", "nvenc-p4" | first %}{% assign p7 = performance.rows | where: "fixture", row.fixture | where: "codec", row.codec | where: "size", row.size | where: "backend", "nvenc-p7" | first %}| {{ row.fixture }} | {{ row.codec | upcase }} {{ row.size }} | {{ row.median_mac_system_joules | round: 1 }} | {{ p4.median_gpu_board_joules | round: 1 }} | {{ p7.median_gpu_board_joules | round: 1 }} |
{% endfor %}

<details class="benchmark-method" markdown="1">
<summary>Energy measurement and sources</summary>

Mac system energy integrates SMC PSTR power readings using mactop {{ performance.videotoolbox_energy.mac_power.sampler.version }}. NVENC energy uses the change in the NVML cumulative counter between FFmpeg start and end. Both include idle consumption during the transcode.

Measurement references: [SMC system-power sensor](https://github.com/metaspartan/mactop/blob/v2.1.6/internal/app/ioreport.m#L816-L836), [mactop power calculation](https://github.com/metaspartan/mactop/blob/v2.1.6/internal/app/metrics.go#L111-L127), and [NVIDIA NVML API](https://docs.nvidia.com/deploy/nvml-api/latest/api/group__nvmlDeviceQueries.html).

Further reading: [Waseda's NVENC board/chip power study](https://arxiv.org/html/2605.01187v1#S3.T4) and [Notebookcheck's M2 Air power measurements](https://www.notebookcheck.net/Apple-MacBook-Air-M2-Entry-Review-A-very-good-but-too-expensive-daily-MacBook.636637.0.html).
</details>

## Network and performance guidance

Use a wired LAN for remote encoding. Packet transcoding transfers compressed video in both directions, keeping bandwidth low. Raw-frame workflows such as OBS send the uncompressed frames to the Mac.

## Reproduce the comparison

The [benchmark instructions]({{ site.repository_url }}/blob/main/tests/integration/README.md#performance-comparison) cover the five-pipeline suite, `nvenc-suite` and `videotoolbox-energy`, including preparation, dependencies and publication commands.
