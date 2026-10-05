# Performance

Compare **Intel iGPU VA-API, CPU fast, CPU medium, local VideoToolbox and remote VideoToolbox** on the same inputs and output budgets. Local and remote VideoToolbox use the same M2 Mac; the remote client runs on Linux.

{% assign performance = site.data.performance %}

Each result uses a 60-second, 1,800-frame clip and three measured runs after warm-up. File sizes and bitrates include the complete original output, including container overhead and filler.

Measured **{{ performance.date }}**; Big Buck Bunny H.264 VideoToolbox results refreshed **{{ performance.refresh.date }}** using **{{ performance.refresh.release }}**, with screen sharing closed. Other results retain their original **{{ performance.release }}** measurements. Exact values identify the date and release for each pipeline.

<div class="benchmark" id="benchmark">
  <div class="benchmark-controls" aria-label="Benchmark selection">
    <label>Input<select id="benchmark-input"><option value="big-buck-bunny">Big Buck Bunny</option><option value="testsrc2">Moving test signal</option><option value="smptebars">Static color bars</option></select></label>
    <label>Codec<select id="benchmark-codec"><option value="h264">H.264</option><option value="hevc">HEVC</option></select></label>
    <label>Output<select id="benchmark-size"><option value="1920x1080">1080p</option><option value="1280x720">720p</option></select></label>
  </div>
  <p class="benchmark-selection" id="benchmark-selection" aria-live="polite"></p>
  <p class="benchmark-control-note" id="benchmark-control-note" hidden>Static color bars are a control. Their output sizes differ substantially; use moving inputs to compare quality at the same file budget.</p>
  <div class="benchmark-charts">
    <figure class="benchmark-chart"><figcaption><strong>Transcode speed</strong><span>Frames per second · higher is faster</span></figcaption><div class="benchmark-canvas"><canvas id="benchmark-speed" role="img" aria-label="Median transcode speed by pipeline. Exact values appear below."></canvas></div></figure>
    <figure class="benchmark-chart"><figcaption><strong>Video quality</strong><span>VMAF · higher is better · 0–100 scale</span></figcaption><div class="benchmark-canvas"><canvas id="benchmark-quality" role="img" aria-label="Video quality by pipeline. Exact values appear below."></canvas></div></figure>
    <figure class="benchmark-chart"><figcaption><strong>FFmpeg CPU time</strong><span>CPU seconds for the 60-second clip · lower uses less CPU</span></figcaption><div class="benchmark-canvas"><canvas id="benchmark-cpu" role="img" aria-label="Submitting FFmpeg CPU time by pipeline. Exact values appear below."></canvas></div></figure>
  </div>
  <p class="benchmark-caption">Speed is the median of three complete transcodes. Hover or tap a bar for exact values and run ranges. Remote CPU time excludes the Mac daemon; CPU time is not a power measurement.</p>
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
Static bars are controls. Their sizes differ and they do not rank quality at an equal file budget.
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

File MB uses decimal megabytes. File Mb/s is the complete container bitrate reported by ffprobe. VMAF scores every frame of the first measured repeat. [Download the measured data]({{ site.repository_url }}/blob/main/docs/_data/performance.json) for SSIM, exact scored-file sizes, hashes, CPU time and all repeat-level measurements.

## Hardware and method

| Machine | Configuration |
| --- | --- |
| Linux | Intel Core i7-12650H, 32 GB RAM, Ubuntu 24.04; Intel iHD 24.3.4 / libva 2.22 |
| Mac | Apple M2, 16 GB RAM, macOS 15.7.5; both VideoToolbox pipelines |
| Network | Private wired LAN; Mac interface negotiated 2.5 GbE |

These are complete **decode → resize → encode → file** workflows. Remote VideoToolbox sends compressed video from Linux to the Mac and receives the encoded output. Intel uses hardware decode, `scale_vaapi` and encode; CPU pipelines use software decode and bicubic scaling; native Mac uses hardware decode, `scale_vt` and encode.

<details class="benchmark-method" markdown="1">
<summary>Inputs, settings and measurement details</summary>

- **Big Buck Bunny:** seconds 60–120 of the Blender Foundation's [1080p30 Sunflower release](https://download.blender.org/demo/movies/BBB/). Credit: Big Buck Bunny, Blender Foundation; Sunflower release, Blender Institute. [Project and licensing](https://peach.blender.org/).
- **Moving test signal:** FFmpeg `testsrc2`, 1920×1080 at 30 fps for 60 seconds.
- **Static color bars:** FFmpeg `smptebars` with the same dimensions, frame rate and duration.

Prepared inputs use H.264 High, 8-bit BT.709, `libx264 -preset fast -crf 10`. Both machines use identical input hashes. Quality is measured against the software-decoded prepared input, rather than an uncompressed movie master.

Outputs use H.264 High or HEVC Main, 8-bit 4:2:0, at 30 fps. File budgets are 4/6 Mb/s for H.264 and 3/4 Mb/s for HEVC at 720p/1080p. Of 120 moving-video outputs, 117 are within 2% of the target. The three retained CPU-medium Big Buck Bunny HEVC 720p files deviate by at most 2.066%; their actual sizes and rates remain visible. Static bars are exempt from rate matching.

Original measurements calibrated encoded packet bytes; every measured output contained zero detected filler. The refreshed VideoToolbox rows calibrate complete file bitrate. Both methods adjust only the requested bitrate using the full clip, without inspecting quality scores. Reported costs always include the complete physical file.

All pipelines use average/VBR, a 60-frame maximum GOP and zero frame reordering. Intel HEVC uses driver-required past-reference GPB B-slices despite `-bf 0`; PTS/DTS and zero decoder reordering are validated. VideoToolbox encoding requires hardware, with `realtime=0` and `prio_speed=0` on both paths. Native Linux uses the v0.9.14 vendored FFmpeg with x264/x265 and VA-API enabled; native Mac uses stock Homebrew FFmpeg 9.0.2. The refreshed remote rows use the checksum-verified published v0.9.16 client and daemon. Remaining remote rows use v0.9.14.

Three measured repeats follow a 60-frame warm-up. Pipeline order rotates and jobs run sequentially. The refreshed rows were collected with screen sharing closed after the original Big Buck Bunny H.264 1080p timing showed contention. Throughput includes FFmpeg startup, video processing and writing the file; it excludes calibration, media validation and scoring. Both machines also run existing services. The data includes all repeats and ranges so variation remains visible.

All outputs must pass independent decoding, exact frame/packet counts, profile, pixel format, dimensions, GOP, reordering and timestamp checks. The original files are scored and retained. Filler diagnostics operate on separate copies and never reduce reported storage or bandwidth cost.

VMAF uses `vmaf_v0.6.1`, `n_subsample=1` and the arithmetic mean from `pooled_metrics.vmaf.mean`; SSIM also scores all 1,800 frames. Linux scoring uses the same bicubic reference settings, 8-bit pixels and `settb=AVTB,setpts=N/(30*TB)`. Original and refreshed scorer builds are identified per row in the data. No alignment or score correction is applied. Scalers and software versions differ between pipelines and can affect quality.

Binary and input SHA-256 hashes, scorer version and unrounded measurements are in the downloadable data.
</details>

## Power and quality

FFmpeg CPU time shows how much work remains in the submitting process. The remote figure excludes the Mac daemon. **Whole-system watts and energy savings have not been measured.** CPU seconds and Intel RAPL package energy cannot establish power use across both machines.

## Network and performance guidance

Use a wired LAN for remote encoding. Packet transcoding transfers compressed video; raw-frame encoding for OBS, VA-API or local filters needs more bandwidth. These results measure one stream at a time in 8-bit SDR; they do not measure simultaneous Plex streams, HDR tone mapping, subtitle burn-in or OBS latency.

## Reproduce the comparison

Run [the manual benchmark suite]({{ site.repository_url }}/blob/main/tests/integration/performance.py) using its [setup instructions]({{ site.repository_url }}/blob/main/tests/integration/README.md#performance-comparison). It dispatches measurement jobs to the designated Linux and Mac machines and uses a temporary benchmark daemon. The coordinator does not encode video. Benchmarks run manually.
