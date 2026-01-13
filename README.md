# VideoToolbox Remote

Use a **Mac (ideally Apple Silicon)** as a hardware H.264 / HEVC encoder/decoder “helper” for FFmpeg running on another machine.

This project offloads **VideoToolbox encode/decode** to a **macOS daemon** while keeping the rest of the FFmpeg pipeline (demux, filters, audio/subs, mux) on the client. 

---

```bash
make build
sudo make install
make clean
```

## Who is this for?

This is useful if:

- You run FFmpeg on **Linux/Windows** (or a machine without Apple’s hardware codecs),
- You have a **Mac on the same LAN** you can keep running as a helper,
- You care about **speed** (hardware encode/decode) more than absolute best compression efficiency.

This is *not* a good fit if:

- You only have **very slow or unstable** LAN/Wi‑Fi (1080p60 encode needs ~71–107 Mb/s in, and 4K60 decode can push ~555 Mb/s),
- You need encryption on the wire (see **Security** below),
- You want a turnkey hosted service (this repo is source‑first, though CI produces nightlies).

---

## How it works (mental model)

```mermaid
flowchart LR
  %% Encode path (remote encode only)
  subgraph C1["FFmpeg client"]
    C1a["demux -> decode -> filters -> mux"]
  end
  subgraph S1["vtremoted (macOS)"]
    S1a["VTCompressionSession"]
  end
  C1a -- "raw NV12/P010 frames<br/>VTRemote TCP (+LZ4)" --> S1a
  S1a -- "Annex B packets<br/>VTRemote TCP (+LZ4)" --> C1a

  %% Decode path (remote decode only)
  subgraph C2["FFmpeg client"]
    C2a["demux -> filters -> encode -> mux"]
  end
  subgraph S2["vtremoted (macOS)"]
    S2a["VTDecompressionSession"]
  end
  C2a -- "Annex B packets<br/>VTRemote TCP (+LZ4)" --> S2a
  S2a -- "raw NV12/P010 frames<br/>VTRemote TCP (+LZ4)" --> C2a
```

Wire compression (LZ4) is enabled by default to reduce bandwidth. 

---

## Components (repo layout)

- `vtremoted/` — macOS daemon (VideoToolbox encode/decode over TCP)
- `ffmpeg/` — FFmpeg fork with remote codecs:
  - `h264_videotoolbox_remote`
  - `hevc_videotoolbox_remote`
  - plus matching decoders
- `docs/` — protocol + architecture docs 

---

## Quickstart

### 1) macOS server: build + run `vtremoted`

On the Mac:

```bash
brew install lz4 pkg-config
cd vtremoted
swift build -c release
```

Run it in the foreground (good for first-time setup):

```bash
.build/release/vtremoted --listen 0.0.0.0:5555 --log-level 1
```

Or install as a launchd service (recommended for “always on” setups):

```bash
./install_launchd.sh --bin /usr/local/bin/vtremoted --listen 0.0.0.0:5555
```

(Port `5555` is just an example; pick what you want.)

**Make sure macOS firewall allows inbound connections** to the daemon’s port.

---

### 2) FFmpeg client: build the included FFmpeg fork

On your client machine (Linux/Windows/macOS), build the `ffmpeg/` fork in this repo.

Install dependencies:

* You need **liblz4 + pkg-config** available on the build system.

Configure FFmpeg with the remote codecs:

```bash
cd ffmpeg

./configure ... --enable-liblz4 \
  --enable-videotoolbox-remote

make -j
```

---

### 3) Encode remotely

Example: encode video using the Mac’s VideoToolbox engine, but keep audio/subs untouched:

```bash
ffmpeg -i input.mkv \
  -c:v h264_videotoolbox_remote -vt_remote_host macmini.local:5555 \
  -b:v 6000k -g 240 \
  -c:a copy -c:s copy \
  output.mkv
```

---

## Common options you’ll care about

### Remote host

Point the codec at your Mac:

* `-vt_remote_host host:port`

### Wire compression

Enabled by default (LZ4). To disable:

* `-vt_remote_wire_compression none`

### Token authentication (recommended on shared networks)

* Client: `-vt_remote_token YOUR_TOKEN`
* Server: `--token YOUR_TOKEN`

---

## Performance notes

Remote VideoToolbox means you are sending/receiving video frames over the network.
For high resolutions / high FPS, a **wired LAN** is strongly recommended.

### Required wire bandwidth for real‑time (LZ4 on)

**Headline requirement (worst case from the benchmark):**
encode needs ~395 Mb/s **upstream** (client → server) at 4K60 (HEVC P010), and
decode needs ~555 Mb/s **downstream** (server → client) at 4K60 (H.264).
Use **1 GbE minimum** and **2.5 GbE+ recommended** if you want headroom for multiple streams
or harder‑to‑compress content.

Measured from `vtremoted` session summaries using `tests/integration/bench_vtremote.sh`
(`testsrc2`, 5s, `-b:v 10M`, GOP 120, loopback). Values below are computed as
`bytes_on_wire / media_duration`. The summary log reports **throughput while encoding**,
which can be much higher than real‑time if the Mac encodes faster than 1×.
2K/4K rows use **DCI framing** (2048×1080 / 4096×2160).

We report a single **required bandwidth** value by taking **MAX(In, Out)** on the wire.
This is the minimum **unidirectional** link budget for a single remote session.
If you run **remote decode + encode** in the same ffmpeg process, **double it** to budget both directions.
Actual bandwidth is **content‑dependent** (noise, grain, and motion reduce compression).

#### Required bandwidth at real‑time (MAX(In, Out))

| Format | FPS | H.264 (NV12) Mb/s | HEVC (P010) Mb/s |
|---|---:|---:|---:|
| 720p | 30 | 26.60 | 27.74 |
| 720p | 60 | 58.33 | 62.70 |
| 720p | 120 | 124.39 | 130.68 |
| 1080p | 30 | 55.98 | 61.35 |
| 1080p | 60 | 117.59 | 125.06 |
| 1080p | 120 | 243.07 | 248.24 |
| 1440p | 30 | 97.61 | 97.42 |
| 1440p | 60 | 197.51 | 190.79 |
| 1440p | 120 | 437.46 | 390.86 |
| 2K (2048x1080) | 30 | 59.40 | 67.10 |
| 2K (2048x1080) | 60 | 123.86 | 137.19 |
| 2K (2048x1080) | 120 | 258.30 | 266.69 |
| 4K (4096x2160) | 60 | 555.51 | 433.17 |

If performance is poor:

* Try enabling/keeping LZ4 wire compression (default),
* Avoid heavy filters on the client side if you’re CPU limited,
* Prefer a faster network link (2.5GbE/10GbE if you’re doing 4K).

---

## Security

Traffic is over TCP and token auth is optional. Token auth is **not encryption**.

If you need a safer setup:

* Bind the daemon to localhost on the Mac, and use an **SSH tunnel** or VPN
* Do **not** expose the daemon port directly to the public internet

See `docs/security.md` for suggested hardened setups.

---

## Troubleshooting

Start here:

* `docs/troubleshooting.md`

Quick checks:

* Can you reach the Mac’s host/port from the client?
* Is macOS firewall blocking it?
* Do client/server tokens match?
* Run server with a higher log level to see connection/auth/protocol errors:
  `--log-level 1`

---

## License

This project follows FFmpeg-style licensing (LGPL v2.1+ with optional GPL parts). See `LICENSE.md` / `COPYING.*` and `ffmpeg/LICENSE.md`.
