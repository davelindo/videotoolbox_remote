# VideoToolbox Remote

[![CI](https://github.com/davelindo/videotoolbox_remote/actions/workflows/ci.yml/badge.svg)](https://github.com/davelindo/videotoolbox_remote/actions/workflows/ci.yml)
[![Docs](https://github.com/davelindo/videotoolbox_remote/actions/workflows/pages.yml/badge.svg)](https://davelindo.github.io/videotoolbox_remote/)
[![Latest release](https://img.shields.io/github/v/release/davelindo/videotoolbox_remote?label=release)](https://github.com/davelindo/videotoolbox_remote/releases/latest)
[![License](https://img.shields.io/badge/license-LGPLv2.1%2B-blue)](LICENSE.md)
[![Platform](https://img.shields.io/badge/server-macOS%2013%2B-lightgrey)](docs/getting-started.md)

**Remote VideoToolbox for FFmpeg: use a Mac or Apple Silicon system over LAN as an IP-based H.264/HEVC encode, decode, and transcoding accelerator.**

VideoToolbox Remote turns a Mac into a networked FFmpeg hardware transcoding server. Linux, Windows, and macOS clients run the included FFmpeg client locally, keep their normal input, filter, audio, subtitle, and muxing pipeline, and offload H.264/HEVC media work to VideoToolbox on a remote Apple Silicon or T2 Mac.

This is useful when your FFmpeg workflow lives on a Linux box, Windows workstation, NAS, or homelab server, but the fastest hardware encoder available to you is a Mac on the same LAN.

## Try It in 1 Minute

Download prebuilt binaries from the [latest release](https://github.com/davelindo/videotoolbox_remote/releases/latest).

On the Mac that will run VideoToolbox:

```bash
tar -xzf vtremoted-macos-arm64.tar.gz
# Trusted private LAN only. Never expose this port directly to the internet.
./vtremoted/vtremoted --listen <MAC_PRIVATE_IP>:5555 --log-level 1
```

On the FFmpeg client:

```bash
mkdir -p ffmpeg-client
tar -xzf ffmpeg-linux-x86_64.tar.gz -C ffmpeg-client
./ffmpeg-client/ffmpeg -i input.mkv \
  -c:v h264_videotoolbox_remote \
  -vt_remote_host <MAC_IP>:5555 \
  -b:v 6000k \
  output.mkv
```

Start with the [getting started guide](docs/getting-started.md) for setup, security notes, and platform-specific build instructions.

## Which Asset Do I Need?

| Asset | Use it for |
| --- | --- |
| `vtremoted-macos-arm64.tar.gz` | macOS server binary for Apple Silicon Macs |
| `vtremoted-macos-x86_64.tar.gz` | macOS server binary for Intel Macs |
| `ffmpeg-linux-x86_64.tar.gz` | FFmpeg client build for Linux x86_64 |
| `vtremote-vaapi-linux-x86_64.tar.gz` | Encode-only VA-API driver and experimental static C SDK for Linux/Plex |
| `vtremote-vaapi-*-source.tar.gz` | Matching VA-API driver source bundle |
| `ffmpeg-macos-arm64.tar.gz` | FFmpeg client build for Apple Silicon Macs |
| `ffmpeg-macos-x86_64.tar.gz` | FFmpeg client build for Intel Macs |
| `ffmpeg-windows-x86_64.tar.gz` | FFmpeg client build for Windows x86_64 |
| `SHA256SUMS.txt` | Checksums for release tarballs |

## When to Use It

Good fit:

- Homelab and NAS media automation where FFmpeg runs on Linux or Windows.
- Batch transcodes where a Mac on wired LAN can provide faster H.264/HEVC hardware encoding.
- Pipelines that need standard FFmpeg behavior while only swapping the video codec name.
- Remote transcode jobs where compressed packets can cross the network and decode+encode happens on the Mac.

Not a good fit:

- Untrusted networks without an SSH tunnel, VPN, or equivalent network isolation.
- Workflows that require public internet exposure of the daemon.
- GPU codecs outside VideoToolbox H.264/HEVC support.

## How It Works

The system has four main parts:

- **Server (`vtremoted`)**: A lightweight Swift daemon on macOS that wraps VideoToolbox.
- **FFmpeg client**: A patched FFmpeg build with `h264_videotoolbox_remote` and `hevc_videotoolbox_remote` codecs.
- **OBS plugin (`obs-plugin/`)**: Experimental OBS encoder plugin using the same protocol client.
- **VA-API driver (`vaapi-driver/`)**: Linux encode driver for stock VA-API applications, including an experimental Plex path.

FFmpeg stays local for files, filters, audio, subtitles, and muxing. The remote codec sends video work over TCP to the Mac and receives encoded packets or decoded frames back.

## Operating Modes

### Remote Encode

Send raw frames to the Mac and receive compressed H.264/HEVC packets:

```bash
ffmpeg -i input.mkv \
  -c:v h264_videotoolbox_remote \
  -vt_remote_host <MAC_IP>:5555 \
  -b:v 6000k \
  -c:a copy -c:s copy \
  output.mkv
```

### Remote Decode

Send H.264/HEVC packets to the Mac and receive raw frames for the rest of the local FFmpeg pipeline.

### Remote Transcode

Send compressed packets to the Mac and receive compressed packets back. Decode, optional server-side resize/pixel-format conversion where configured, and encode happen on the Mac; FFmpeg filters, audio, subtitles, and muxing remain local on the client.

```bash
ffmpeg -i input.mkv \
  -map 0 \
  -c copy \
  -vt_remote_transcode:v:0 \
  -vt_remote_host <MAC_IP> \
  -vt_remote_port 5555 \
  -vt_remote_out_codec:v:0 hevc \
  -b:v:0 6000k \
  output.mkv
```

## Performance and Compatibility

- Wired LAN is strongly recommended: 1GbE minimum, 2.5GbE+ for 4K.
- Wire compression supports LZ4 and Zstd. FFmpeg/OBS request LZ4 by default;
  the VA-API driver defaults to automatic selection.
- Current benchmark docs report 1080p H.264 around 230 fps and 4K H.264 around 62 fps on Apple Silicon loopback tests. See [benchmarks](docs/benchmarks.md) for caveats and reproduction commands.
- The remote codecs aim to preserve local VideoToolbox option behavior where the transport and protocol can represent it.

Current parity coverage includes:

- Encoder option-surface parity checks for `h264/hevc_videotoolbox` vs `h264/hevc_videotoolbox_remote`.
- Remote encoder software-frame upload parity for common 8-bit and 10-bit formats.
- Remote encoder hardware-frame ingest for local `AV_PIX_FMT_VIDEOTOOLBOX` inputs.
- Optional remote decoder hardware-frame output with `-vt_remote_output_hw_frames 1`.
- Common HDR, ICC, display, timecode, Dolby Vision, SEI, caption, and mux-facing metadata forwarding.
- `vtremote_transcode` preservation for HEVC `hvc1`/HDR signaling and packet side data.

## Build From Source

### Server on macOS

```bash
cd vtremoted
swift build -c release
```

The Swift package and top-level Makefile default to a macOS 13.0 deployment target. LZ4 and Zstd are loaded at runtime only when a client requests wire compression.

### Client on Linux, Windows, or macOS

```bash
make build-ffmpeg
```

The standard build enables VMAF, SSIM/PSNR, and common codec libraries, including AV1. Linux release artifacts and CI builds target `x86_64`; 32-bit `i686` builds are not part of the supported matrix.

### VA-API driver on Linux

For stock VA-API applications, install `vtremote-vaapi-linux-x86_64.tar.gz`
or run `make test-vaapi-driver`. The driver supports H.264 and HEVC encode,
including Main 10/P010, with software decode and filtering. See the
[VA-API and Plex guide](docs/vaapi-driver.md).

If a Linux source build fails in FFmpeg x86 assembly after installing current `nasm` and `yasm`, use the diagnostic fallback:

```bash
make clean-ffmpeg
make build-ffmpeg FFMPEG_DISABLE_X86ASM=1
```

## Documentation

- [Getting started](docs/getting-started.md) - Install binaries, run the server, and make the first FFmpeg call.
- [Benchmarks](docs/benchmarks.md) - Performance numbers, caveats, and reproduction commands.
- [Architecture](docs/architecture.md) - System design and data flow.
- [Protocol](docs/protocol.md) - Wire protocol specification.
- [Security](docs/security.md) - Recommended secure deployment.
- [Troubleshooting](docs/troubleshooting.md) - Common issues and fixes.
- [OBS plugin](docs/obs-plugin.md) - Experimental plugin build/testing notes.
- [VA-API driver and Plex](docs/vaapi-driver.md) - Linux driver installation, scope, and playback validation.
- [Development](docs/development.md) - Build, test, benchmark, and release notes.

## Contributing and Support

Issues and pull requests are welcome. Please include the server platform, client platform, exact FFmpeg command, `vtremoted --version`, release tag or commit, and relevant logs when reporting a problem.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development workflow and [SECURITY.md](SECURITY.md) for security reporting.

## License

This project follows FFmpeg-style licensing: LGPL v2.1+ by default, with optional GPL parts depending on how FFmpeg is configured. See [LICENSE.md](LICENSE.md), [COPYING.LGPLv2.1](COPYING.LGPLv2.1), and [ffmpeg/LICENSE.md](ffmpeg/LICENSE.md).
