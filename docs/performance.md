---
title: Performance
description: "Compare Intel VA-API, CPU fast/medium presets, local VideoToolbox and remote VideoToolbox using Big Buck Bunny and FFmpeg test signals."
---

# Performance

Compare complete video pipelines at matched bitrate excluding filler: Intel iGPU VA-API, CPU encoding with `fast` and `medium` presets, local VideoToolbox, and remote VideoToolbox. Local and remote VideoToolbox use the **same M2 Mac**. The remote client runs on the Intel Linux host.

## Current comparison

{% assign performance = site.data.performance %}
{% if performance %}
Measured {{ performance.date }} with VideoToolbox Remote **{{ performance.release }}**. Every encoder uses average/VBR rate control, zero frame reordering and a 60-frame maximum GOP. Each throughput value is the median of three measured runs after warm-up. Every moving-video output met its common **non-filler bitrate** budget within **2%**. Every output passed frame, packet, GOP, reordering, timestamp and independent software-decode checks.

[View the measured data (JSON)]({{ site.repository_url }}/blob/main/docs/_data/performance.json), including requested, total and non-filler bitrate, filler bytes, throughput ranges and validation results for every case.

| Host | Hardware and role |
| --- | --- |
| Intel host | Intel Core i7-12650H, 32 GB RAM, Ubuntu 24.04; Intel iHD 24.3.4 / libva 2.22; CPU and remote-client runs |
| Mac host | Apple M2, 16 GB RAM, macOS 15.7.5; local VideoToolbox and remote daemon |
| Network | Direct private LAN; the Mac's wired interface negotiated 2.5 GbE |

{% for fixture in performance.fixtures %}
### {{ fixture.label }}

{% if fixture.id == "smptebars" %}
**Control workload:** static bars verify a simple signal across the pipelines. Encoders can produce sparse output far below the requested budget. These outputs are exempt from bitrate matching; use them as a control, not to rank encoder quality or speed at matched bitrate.
{% endif %}

{% for output in performance.outputs %}
**{{ output.label }}**

| Pipeline | fps | Total Mb/s | Non-filler Mb/s | Filler Mb/s | VMAF | SSIM | Client CPU seconds | fps range |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
{% assign rows = performance.rows | where: "fixture", fixture.id | where: "codec", output.codec | where: "size", output.size %}{% for row in rows %}| {{ row.label }} | {{ row.median_fps | round: 1 }} | {{ row.median_delivered_mbps | round: 3 }} | {{ row.median_non_filler_mbps | round: 3 }} | {{ row.median_filler_mbps | round: 3 }} | {{ row.vmaf | round: 2 }} | {{ row.ssim | round: 4 }} | {{ row.median_cpu_seconds | round: 2 }} | {{ row.min_fps | round: 1 }}–{{ row.max_fps | round: 1 }} |
{% endfor %}
{% endfor %}
{% endfor %}
{% endif %}

## Inputs and output settings

- **Big Buck Bunny:** seconds 60–120 of the Blender Foundation's [official 1080p30 Sunflower release](https://download.blender.org/demo/movies/BBB/), prepared as a reusable 60-second H.264 input. Credit: Big Buck Bunny, Blender Foundation; Sunflower release, Blender Institute. See the [project](https://peach.blender.org/) for attribution and licensing.
- **FFmpeg `testsrc2`:** 60 seconds of moving synthetic content at 1920×1080, 30 fps.
- **FFmpeg `smptebars`:** 60 seconds of static color bars at the same size and frame rate. This is a color/control workload, not representative natural video.

All three prepared inputs contain 1,800 frames, H.264 High 8-bit video, and BT.709 signaling. Preparation uses `libx264 -preset fast -crf 10`. Input files are copied to both hosts and their SHA-256 hashes must match before measurement. The quality reference is the software-decoded prepared input, rather than the original uncompressed movie or signal.

Output is H.264 High or HEVC Main, 8-bit 4:2:0, at 720p or 1080p and 30 fps. The common output budgets are 4/6 Mb/s for H.264 and 3/4 Mb/s for HEVC at 720p/1080p respectively. Every pipeline requests average/VBR rate control, a 60-frame maximum keyframe interval and `-bf 0` (or its remote equivalent). No explicit peak-bitrate or VBV cap is requested. The runner checks the actual GOP lengths, zero decoder reordering and equal presentation/decode timestamps. These shared settings do not make different encoders' internal algorithms identical.

**Intel HEVC picture types:** the tested iHD driver requires P pictures to be represented as GPB B-slices with past references. [FFmpeg's VA-API implementation](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/vaapi_encode_h265.c) uses the same past-reference lists for those slices. They appear as B pictures in ffprobe despite `-bf 0`. Header inspection of the full preflight confirmed zero future references and zero signalled reordering; all 1,800 packet presentation timestamps equaled decode timestamps. The public data records actual B-picture counts and reordering separately. Other tested pipelines emit no B pictures under these settings.

**Total bitrate** counts all encoded video packet bytes, excluding container overhead. **Non-filler bitrate** excludes codec filler while retaining picture data and stream headers. Filler is real data that consumes storage and bandwidth without adding picture detail. It can be used to meet constant-bitrate delivery requirements; counting it toward an equal quality budget can disguise unequal picture-data budgets. The runner measures it by copying the stream through [FFmpeg's filler-removal bitstream filters](https://ffmpeg.org/ffmpeg-bitstream-filters.html), without re-encoding.

Every moving-video backend starts at the same requested budget and follows the same automatic calibration: encode the complete clip, measure non-filler bytes, and adjust the requested rate by the measured ratio until it is within 2%, with at most four attempts. Calibration does not calculate or inspect VMAF or SSIM, and its encodes are excluded from throughput results. Presets, GOP and reordering settings remain fixed. Every measured moving-video repeat must stay within 2% or the suite stops. Static bars are shown separately as a control.

## What the comparison measures

Intel VA-API uses hardware decode, `scale_vaapi`, and encode through the Intel iHD driver. CPU rows use software decode and bicubic scaling with `libx264` or `libx265`. Local VideoToolbox uses hardware decode, `scale_vt`, and encode on the Mac host. Remote VideoToolbox sends compressed packets from the Intel host to that same Mac for decode, resize and encode, then receives compressed output.

These are complete file-to-file workflows. Their decoders and scalers differ, so the comparison includes the quality and cost of each pipeline. Keeping the Mac constant prevents a different machine from changing the local/remote hardware comparison. It does not remove software, transport or scaling differences.

Native Linux tests share an isolated build of the release's vendored FFmpeg source with `libx264` (core 164), `libx265` 3.5, VA-API and `libvmaf` 3.0.0 enabled. This avoids an older Ubuntu FFmpeg VA-API frame-pool failure. Native Mac tests use Homebrew FFmpeg. Remote client and daemon binaries come from the checksum-verified release shown with the results. Private raw logs preserve exact commands and output identities outside the repository; hostnames, addresses, usernames and local paths are excluded from public results.

{% if performance %}
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
{% endif %}

Throughput includes FFmpeg startup, video processing and output writing, and excludes fixture preparation and validation. Measured runs rotate pipeline order and execute sequentially, so local and remote jobs do not compete for the M2 media engine.

The designated hosts also run existing services. Results describe the observed conditions on those shared hosts; the fps range shows variation across the three repeats.

{% if performance %}
{% assign variable_rows = performance.rows | where_exp: "row", "row.fps_cv_percent > 10" %}{% assign most_variable = performance.rows | sort: "fps_cv_percent" | last %}
{{ variable_rows.size }} of {{ performance.rows.size }} cases had throughput variation above 10% (coefficient of variation); the largest was {{ most_variable.fps_cv_percent | round: 1 }}%. Read the ranges when comparing close medians.
{% endif %}

VMAF explicitly uses the `vmaf_v0.6.1` model. VMAF and SSIM cover all 1,800 frames of the first measured repeat, using the same Linux FFmpeg binary for every backend. Native Mac outputs are copied to the scorer and their SHA-256 hashes verified. The software-decoded, bicubic-scaled input is the common reference; both inputs use a frame-number clock at 30 fps and an 8-bit pixel format. These scores describe this source and configuration; they do not establish a universal encoder ranking.

{% if performance %}
Common quality scorer: FFmpeg **{{ performance.quality_scorer.version }}**, SHA-256 `{{ performance.quality_scorer.sha256 }}`.
{% endif %}

## Power and quality

Client CPU seconds show how much processing time the submitting FFmpeg process consumed. Remote-client figures omit the Mac daemon's CPU work. Peak RSS in the JSON also applies to that FFmpeg process alone. Lower Linux CPU use demonstrates offload, and helps explain why a small host can keep serving Plex while the Mac handles video.

The runner also records Intel package energy through Linux RAPL where available. That counter includes other work on the Linux host and does not measure wall power, the Mac or network equipment. **Whole-system energy savings need measurements of both hosts over complete jobs**, including idle energy. The performance tables do not claim a watt saving.

## Network and performance guidance

Use packet transcoding when the client needs only supported Mac-side video operations. Compressed video travels in both directions. Remote encoding for local filters, OBS or the VA-API driver sends raw frames and needs more bandwidth, especially at 4K or with 10-bit formats.

A wired LAN is recommended. Record link speed, competing traffic, source resolution and encoder settings alongside results. The current comparison covers one stream at a time, 8-bit SDR and these input clips. It does not measure concurrent Plex capacity, HDR tone mapping, subtitle burn-in, OBS latency or whole-system power.

## Reproduce the comparison

Use [the performance runner]({{ site.repository_url }}/blob/main/tests/integration/performance.py) and its [setup instructions]({{ site.repository_url }}/blob/main/tests/integration/README.md#performance-comparison). It prepares the inputs on Linux, runs native workers on the designated hosts, owns a disposable Mac daemon and saves machine-readable results. The coordinating computer does not encode benchmark video.

For connection or throughput problems, see [Troubleshooting](troubleshooting.html). For network isolation and authentication, see [Security](security.html).
