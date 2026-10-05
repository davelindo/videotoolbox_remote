# Performance

Measured quality, throughput and CPU use for Intel iGPU VA-API, CPU `fast`/`medium`, local VideoToolbox and remote VideoToolbox. Both VideoToolbox paths run on the **same M2 Mac**, with the remote client on the Intel Linux host.

The results cover complete decode/resize/encode pipelines using Big Buck Bunny and FFmpeg test signals. **Physical file size and full container bitrate include every byte**, including filler and container overhead.

{% assign performance = site.data.performance %}
{% assign resize = site.data.resize_validation %}

## Resize fix released in v0.9.16

In the paired Big Buck Bunny 720p tests, the fix raised H.264 VMAF from **91.08 to 96.16** and HEVC from **91.40 to 96.63**. The corresponding physical file sizes changed by **0.125% and 0.087%**. The comparison measures the complete changed transfer path against the same reference; it does not attribute the entire quality gain to displacement alone.

Measured {{ resize.date }} using unchanged and fixed release-mode daemon builds, the same M2, the same compiler, the same Linux client and scorer, and sequential alternating runs. Each case has a 60-frame warm-up and three measured **1,800-frame / 60-second** outputs per variant. All **48 measured files** passed media validation, and all 16 first-repeat quality comparisons scored every frame.

These measurements used the earlier physical validation builds, whose version strings were still 0.9.14. The fixed production implementation was subsequently [released in {{ resize.fix_release }}]({{ site.repository_url }}/releases/tag/{{ resize.fix_release }}). The measured daemon hashes are in the [paired data]({{ site.repository_url }}/blob/main/docs/_data/resize_validation.json). Later smoke tests verified the published release and upgraded service; those short tests are excluded from these performance results.

### Actual output cost and quality

| Input / output | File MB: before → fixed | File Mb/s: before → fixed | VMAF: before → fixed | SSIM: before → fixed |
| --- | ---: | ---: | ---: | ---: |
{% for row in resize.rows %}| {{ row.label }} | {{ row.baseline.median_file_bytes | divided_by: 1000000.0 | round: 3 }} → {{ row.fixed.median_file_bytes | divided_by: 1000000.0 | round: 3 }} | {{ row.baseline.median_container_mbps | round: 6 }} → {{ row.fixed.median_container_mbps | round: 6 }} | {{ row.baseline.vmaf | round: 3 }} → {{ row.fixed.vmaf | round: 3 }} | {{ row.baseline.ssim | round: 6 }} → {{ row.fixed.ssim | round: 6 }} |
{% endfor %}

File size and reported container bitrate are medians of three repeats. In this paired study every case/variant had identical file sizes across its three repeats, so the median also equals the scored first-repeat size. The JSON retains each output's bytes, SHA-256, bitrate and repeat number, plus the scoring command for the first repeat.

All 36 moving-video outputs met their whole-file bitrate budget within 2%. The largest before/after physical size change among moving cases was 0.125%. **Static bars are controls with different output sizes**: H.264 increased by 22.6% and HEVC by 72.5%. Their score changes are not matched-size quality comparisons. All 48 measured outputs contained zero detected filler; their original files were preserved and scored.

### Throughput and CPU cost

| Input / output | Median fps: before → fixed | fps range: before / fixed | Linux client CPU s: before → fixed | Mac daemon CPU s: before → fixed |
| --- | ---: | ---: | ---: | ---: |
{% for row in resize.rows %}| {{ row.label }} | {{ row.baseline.median_fps | round: 1 }} → {{ row.fixed.median_fps | round: 1 }} | {{ row.baseline.min_fps | round: 1 }}–{{ row.baseline.max_fps | round: 1 }} / {{ row.fixed.min_fps | round: 1 }}–{{ row.fixed.max_fps | round: 1 }} | {{ row.baseline.median_client_cpu_seconds | round: 3 }} → {{ row.fixed.median_client_cpu_seconds | round: 3 }} | {{ row.baseline.median_daemon_cpu_seconds | round: 2 }} → {{ row.fixed.median_daemon_cpu_seconds | round: 2 }} |
{% endfor %}

Staging adds measured Mac CPU work. Throughput varied on these shared hosts: even unchanged-size HEVC varied substantially before the fix. The ranges do not establish a causal speed improvement or absence of a regression. Both unchanged-size Big Buck Bunny cases retained their quality scores; the first measured 1080p repeats also passed 3,600 paired decoded-frame comparisons across H.264 and HEVC.

## Five-pipeline comparison

Measured {{ performance.date }} with VideoToolbox Remote **{{ performance.release }}**, before the resize fix. This is the complete five-pipeline baseline. Its native and remote VideoToolbox downscales both exercised the affected Apple transfer path; the paired study above shows the released remote workaround separately.

Each row is the median of three measured runs after warm-up. Every output passed frame/packet counts, profile, pixel format, dimensions, GOP, reordering, timestamps and independent software decoding. VMAF and SSIM use all 1,800 frames of the first measured repeat, with a common Linux scorer and reference.

All pipelines used average/VBR and the same full-clip byte-only calibration against the encoded-video budget. Every measured output contained zero detected filler. **Full physical file cost is shown below.** Of 120 moving-video outputs, 117 were within 2% of the common whole-file budget; three Big Buck Bunny 720p HEVC CPU-medium outputs exceeded it slightly, with a maximum deviation of **2.066%**, including container overhead. Those actual measurements are retained without correction. Static bars remain a separate control.

[Measured comparison data]({{ site.repository_url }}/blob/main/docs/_data/performance.json) includes every repeat's physical bytes, reported container bitrate, full video bitrate, filler diagnostic, output hash, throughput and validation; each quality score is bound to its own first-repeat file and scoring command.

| Host | Hardware and role |
| --- | --- |
| Intel host | Intel Core i7-12650H, 32 GB RAM, Ubuntu 24.04; Intel iHD 24.3.4 / libva 2.22; CPU and remote-client runs |
| Mac host | Apple M2, 16 GB RAM, macOS 15.7.5; local VideoToolbox and remote daemon |
| Network | Direct private LAN; the Mac's wired interface negotiated 2.5 GbE |

{% for fixture in performance.fixtures %}
### {{ fixture.label }}

{% if fixture.id == "smptebars" %}
**Control workload:** static signals may produce sparse files far below the requested budget. These rows are exempt from rate matching and do not rank quality at equal file size.
{% endif %}

{% for output in performance.outputs %}
**{{ output.label }}**

| Pipeline | fps | File MB | File Mb/s | Scored file Mb/s | VMAF | SSIM | Client CPU s | fps range |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
{% assign rows = performance.rows | where: "fixture", fixture.id | where: "codec", output.codec | where: "size", output.size %}{% for row in rows %}| {{ row.label }} | {{ row.median_fps | round: 1 }} | {{ row.median_file_bytes | divided_by: 1000000.0 | round: 3 }} | {{ row.median_container_mbps | round: 3 }} | {{ row.scored_output.container_mbps | round: 3 }} | {{ row.vmaf | round: 2 }} | {{ row.ssim | round: 4 }} | {{ row.median_cpu_seconds | round: 2 }} | {{ row.min_fps | round: 1 }}–{{ row.max_fps | round: 1 }} |
{% endfor %}
{% endfor %}
{% endfor %}

File MB uses decimal megabytes. File Mb/s is the complete container bitrate reported by ffprobe. The scored-file column identifies the bitrate of the exact first-repeat file used for VMAF/SSIM; it is separate from the three-repeat median. The JSON retains unrounded values and hashes.

## Inputs and output settings

- **Big Buck Bunny:** seconds 60–120 of the Blender Foundation's [official 1080p30 Sunflower release](https://download.blender.org/demo/movies/BBB/), prepared as a reusable H.264 input. Credit: Big Buck Bunny, Blender Foundation; Sunflower release, Blender Institute. See the [project](https://peach.blender.org/) for attribution and licensing.
- **FFmpeg `testsrc2`:** 60 seconds of moving synthetic content at 1920×1080, 30 fps.
- **FFmpeg `smptebars`:** 60 seconds of static color bars at the same size and frame rate.

All prepared inputs contain 1,800 frames, H.264 High 8-bit video and BT.709 signaling. Preparation uses `libx264 -preset fast -crf 10`. Both hosts use identical frozen input hashes. The reference is the software-decoded prepared input, not an uncompressed movie master.

Output is H.264 High or HEVC Main, 8-bit 4:2:0, at 720p or 1080p and 30 fps. Common budgets are 4/6 Mb/s for H.264 and 3/4 Mb/s for HEVC at 720p/1080p. Every pipeline requests average/VBR, a 60-frame maximum GOP, zero frame reordering and `-bf 0` or its remote equivalent. No explicit peak-rate or VBV cap is requested. Presets and GOP settings remain fixed during calibration; calibration does not inspect quality scores.

The original studies calibrated encoded-video bytes with a separate filler diagnostic; all measured files had zero detected filler. The current runner calibrates directly against **whole-file bitrate reported by ffprobe**, including container overhead and any filler. Filler always counts toward storage and bandwidth; the diagnostic operates on a separate copy, and quality scoring uses the original file.

The tested Intel HEVC driver represents P pictures as past-reference GPB B-slices. They appear as B pictures despite `-bf 0`, with zero future references and zero decoder reordering. Full-stream preflight header inspection and equal PTS/DTS checks validated this behavior; actual picture counts, GOP and reordering are retained in the data.

## What the comparison measures

Intel VA-API uses hardware decode, `scale_vaapi` and encode through iHD. CPU rows use software decode and bicubic scaling with `libx264`/`libx265`. Native VideoToolbox uses hardware decode, `scale_vt` and encode. Remote VideoToolbox sends compressed packets from Linux to that same M2 for decode, resize and encode, then receives compressed output.

These are complete file-to-file workflows. Their scalers, decoders and software builds differ. Keeping the Mac constant controls hardware differences between local and remote VideoToolbox. The original local `scale_vt` path retains the storage-dependent resize behavior; the remote workaround changes its transfer path.

Native Linux runs share an isolated build of the measured release's vendored FFmpeg with x264 core 164, x265 3.5, VA-API and libvmaf 3.0.0 enabled. Native Mac uses Homebrew FFmpeg. The five-pipeline remote client and daemon come from the checksum-verified v0.9.14 release; the paired daemon build identities are recorded separately.

### Build identities

| FFmpeg version | Binary SHA-256 |
| --- | --- |
{% for build in performance.builds %}| {{ build.version }} | `{{ build.sha256 }}` |
{% endfor %}

### Input identities

| Prepared input | SHA-256 |
| --- | --- |
{% for input in performance.source_hashes %}| {{ input.fixture }} | `{{ input.sha256 }}` |
{% endfor %}

Throughput includes FFmpeg startup, video processing and writing output; it excludes preparation, calibration and validation. Jobs run sequentially, with rotating pipeline order in the five-pipeline study and alternating variants in the paired study. The hosts also run existing services. Read the repeat ranges when comparing close medians.

VMAF uses `vmaf_v0.6.1`, all frames (`n_subsample=1`), and the arithmetic mean from `pooled_metrics.vmaf.mean`. SSIM uses all frames. The common reference is software-decoded and bicubic-scaled to the output size. Both streams use `settb=AVTB,setpts=N/(30*TB)` and 8-bit pixels. No image alignment, interpolation or score correction is applied. Paths in public scoring commands are translated to generic filenames while preserving all filter and scoring options.

Common quality scorer: FFmpeg **{{ performance.quality_scorer.version }}**, SHA-256 `{{ performance.quality_scorer.sha256 }}`. The same scorer is used for the paired study. The paired evidence records libvmaf runtime version `{{ resize.libvmaf_runtime_version }}` and every first-repeat output identity.

## Power and quality

Linux client CPU time demonstrates video offload to the Mac. It excludes Mac daemon work; the paired study reports that work separately. Peak RSS in the five-pipeline JSON belongs to the submitting FFmpeg process.

Intel package energy from RAPL includes other host work and excludes the Mac and network. **Whole-system watts and energy savings have not been measured.** Measure both hosts over complete jobs, including idle energy, to compare energy per file or stream.

## Network and performance guidance

Packet transcoding sends compressed video in both directions when the client needs supported Mac-side video operations. Raw-frame encoding for local filters, OBS or VA-API has a different bandwidth cost, especially for 4K and 10-bit video. Use a wired LAN and record link speed, competing traffic and settings with measurements.

The published comparisons cover one stream at a time and 8-bit SDR. They do not measure concurrent Plex capacity, HDR tone mapping, subtitle burn-in or OBS latency.

## Reproduce the comparison

Use [the manual performance runner]({{ site.repository_url }}/blob/main/tests/integration/performance.py) and its [setup instructions]({{ site.repository_url }}/blob/main/tests/integration/README.md#performance-comparison). It prepares fixtures on Linux, dispatches native workers to the designated hosts, owns a temporary Mac daemon and exports measured results. The coordinator does not encode benchmark video. These benchmarks are not CI jobs.

See [Troubleshooting](troubleshooting.html) for connection or throughput problems and [Security](security.html) for network isolation and authentication.
