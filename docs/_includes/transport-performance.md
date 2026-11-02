{% assign transport = site.data.transport %}
{% assign nv12 = transport.rows | where: "size", "3840x2160" | where: "pixel_format", "nv12" %}
{% assign mixed = nv12 | where: "variant", "mixed" | first %}
{% assign packets = nv12 | where: "variant", "packet-only" | first %}
{% assign raw_encode = nv12 | where: "mode", "encode" | where: "variant", "none" | first %}
{% assign lz4_encode = nv12 | where: "mode", "encode" | where: "variant", "lz4" | first %}
{% assign throughput_percent = mixed.median_fps | divided_by: packets.median_fps | times: 100 %}
{% assign cpu_ratio = raw_encode.client_cpu_ms_per_frame | divided_by: lz4_encode.client_cpu_ms_per_frame | times: 100 %}
{% assign cpu_saving = 100 | minus: cpu_ratio %}

## Raw frame transport

The extra bandwidth makes raw 4K frame workflows practical on a two-core mini PC. The full **decode → Linux `hflip` → HEVC encode** round trip reached **{{ mixed.median_fps | round: 1 }} fps**, compared with **{{ packets.median_fps | round: 1 }} fps** for packet-only transcoding: **{{ throughput_percent | round: 1 }}% of its throughput**.

All figures below are medians of three FFmpeg runs. Encode uploads NV12 and receives HEVC; decode sends H.264 and receives NV12.

| 3840×2160 wire compression | Encode, fps | Decode, fps | Filter round trip, fps |
| --- | ---: | ---: | ---: |
{% assign variants = "none,lz4,zstd" | split: "," %}{% for variant in variants %}{% assign encode = nv12 | where: "mode", "encode" | where: "variant", variant | first %}{% assign decode = nv12 | where: "mode", "decode" | where: "variant", variant | first %}{% assign roundtrip = nv12 | where: "mode", "roundtrip" | where: "variant", variant | first %}| {% if variant == "none" %}None{% elsif variant == "lz4" %}LZ4{% else %}Zstd{% endif %} | {{ encode.median_fps | round: 1 }} | {{ decode.median_fps | round: 1 }} | {{ roundtrip.median_fps | round: 1 }} |
{% endfor %}| LZ4 return, uncompressed upload | — | — | **{{ mixed.median_fps | round: 1 }}** |

Uncompressed NV12 upload used **{{ cpu_saving | round: 0 }}% less client CPU work per frame** than LZ4. It carried {{ raw_encode.upload_gbps | round: 2 }} Gb/s toward the Mac. The mixed filter round trip carried {{ mixed.upload_gbps | round: 2 }} Gb/s toward the Mac and {{ mixed.return_gbps | round: 2 }} Gb/s returning.

| Other pipeline | Median fps | Run range, fps |
| --- | ---: | ---: |
{% for row in transport.rows %}{% if row.size == "1920x1080" or row.pixel_format == "p010le" %}| {% if row.pixel_format == "p010le" %}4K P010{% else %}1080p NV12{% endif %} {% if row.mode == "encode" %}upload → HEVC{% if row.pixel_format == "p010le" %} Main 10{% endif %}{% elsif row.mode == "decode" %}raw return{% else %}filter round trip{% endif %} | {{ row.median_fps | round: 1 }} | {{ row.min_fps | round: 1 }}–{{ row.max_fps | round: 1 }} |
{% endif %}{% endfor %}

Paced stream checks delivered every frame: **4K60 raw NV12 return**, **4K30 decode/filter/encode**, and **4K30 P010 upload and return**. All 48 measured runs passed frame and packet checks. Each encoded pipeline was independently decoded, and all 240 checked NV12 frames were byte-identical across the three wire modes.

<details class="benchmark-method" markdown="1">
<summary>Transport hardware and method</summary>

Measured {{ transport.date }} with release {{ transport.release }}:

| Machine | Configuration |
| --- | --- |
| Client | {{ transport.hardware.client_model }}, {{ transport.hardware.client_cpu }}, {{ transport.hardware.client_ram_gib }} GB RAM |
| Encoder | {{ transport.hardware.encoder_model }}, {{ transport.hardware.encoder_ram_gib }} GB RAM, {{ transport.hardware.encoder_os }} |
| Link | 20 Gb/s Thunderbolt networking, MTU {{ transport.mtu }}; single-stream TCP {{ transport.tcp_upload_gbps | round: 1 }} Gb/s toward the Mac and {{ transport.tcp_return_gbps | round: 1 }} Gb/s returning |

Three measured runs followed a 180-frame warm-up for each pipeline. Repeated [Big Buck Bunny 2160p60]({{ transport.source.url }}) fixtures started at 60 seconds; cached raw-frame rings supplied the encode tests. HEVC output used 20 Mb/s at 4K and 8 Mb/s at 1080p, GOP 60, zero B frames and 32 in-flight frames. A fresh isolated daemon served each run. Timings include client startup, processing and output; preparation and validation run separately.

[Download the transport measurements]({{ '/assets/data/transport.json' | relative_url }}) for individual repeats, CPU time, wire bytes, output hashes and paced stream checks.
</details>
