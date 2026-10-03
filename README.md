# VideoToolbox Remote — low-power H.264 / HEVC transcoding over LAN

[![CI](https://github.com/davelindo/videotoolbox_remote/actions/workflows/ci.yml/badge.svg)](https://github.com/davelindo/videotoolbox_remote/actions/workflows/ci.yml)
[![Docs](https://github.com/davelindo/videotoolbox_remote/actions/workflows/pages.yml/badge.svg)](https://davelindo.github.io/videotoolbox_remote/)
[![Latest release](https://img.shields.io/github/v/release/davelindo/videotoolbox_remote?label=release)](https://github.com/davelindo/videotoolbox_remote/releases/latest)
[![License](https://img.shields.io/badge/license-LGPLv2.1%2B%20%2F%20optional%20GPL-blue)](LICENSE.md)

**Keep Plex on your Linux server. Use a Mac's efficient VideoToolbox media hardware as an external video transcoding engine.**

VideoToolbox Remote exposes H.264 (AVC), H.265 (HEVC) and HEVC Main 10 hardware encoding on an Apple Silicon or supported T2 Mac over your LAN. Low-powered, GPU-less Linux homelab servers and NAS devices can keep hosting Plex, storing media and scheduling jobs while a Mac mini or another Mac handles the supported video decode, resize and encode path.

Use it for high-quality Plex transcodes, low-power batch video conversion with FFmpeg, stock Linux VA-API encoding, or an experimental remote OBS Studio encoder. FFmpeg clients run on Linux, Windows and macOS; the VideoToolbox daemon runs on macOS 13+.

**[Documentation](https://davelindo.github.io/videotoolbox_remote/) · [Plex setup](docs/plex.md) · [Download binaries](https://github.com/davelindo/videotoolbox_remote/releases/latest) · [Quality & benchmarks](docs/benchmarks.md)**

## Why use a Mac as a remote encoder?

- **Efficient media hardware:** offload video work from a small server's CPU to VideoToolbox. The intended benefit is low-power transcoding; published results do not yet include whole-system watt measurements.
- **High-quality output:** H.264, HEVC and 10-bit HEVC with bitrate, profile and color controls. Controlled comparisons report VMAF at matched delivered bitrates; quality and speed depend on the codec, source and settings.
- **Keep your Linux homelab:** Plex, storage, audio processing and media delivery stay on your existing host. The supported Plex path needs no Linux GPU or DRM render node.
- **Efficient packet transport:** remote transcoding sends compressed video in both directions. Local filters and live sources can use raw-frame remote encoding instead.

## Choose your workflow

| Workflow | What runs on the Mac | Setup and scope |
| --- | --- | --- |
| **Plex on Linux / a GPU-less NAS** | H.264/HEVC decode, resize and encode | [Plex Docker guide](docs/plex.md). Linux x86_64 container; supported Plex library builds and filter graphs only. Plex Pass required for normal hardware-accelerated playback. |
| **FFmpeg batch transcodes** | Encode, decode, or packet-to-packet transcode | [Getting started](docs/getting-started.md). Patched FFmpeg clients for Linux, Windows and macOS. |
| **Stock Linux VA-API applications** | H.264/HEVC encode | [VA-API driver](docs/vaapi-driver.md). Linux x86_64; software decode/filter/upload and a render node remain local. |
| **OBS Studio live encoding** | H.264/HEVC encode | [OBS plugin](docs/obs-plugin.md). Experimental; build from source and validate your recording/streaming workflow. |
| **Custom C applications** | Encode through the shared protocol client | [Static C SDK](vaapi-driver/README.md#experimental-c-sdk). Experimental API; rebuild with the matching release. |

## Quick start: remote FFmpeg encoding

Download matching archives from the [latest release](https://github.com/davelindo/videotoolbox_remote/releases/latest) and check their SHA-256 checksums. On an Apple Silicon Mac:

```bash
tar -xzf vtremoted-macos-arm64.tar.gz
brew install lz4 zstd
# Bind to the Mac's private LAN address. Use a token or tunnel when sharing it.
./vtremoted/vtremoted --listen 192.168.1.20:5555 --log-level 1
```

On a Linux x86_64 FFmpeg client:

```bash
mkdir -p ffmpeg-client
tar -xzf ffmpeg-linux-x86_64.tar.gz -C ffmpeg-client
./ffmpeg-client/ffmpeg -i input.mkv \
  -c:v h264_videotoolbox_remote \
  -vt_remote_host 192.168.1.20:5555 \
  -b:v 6M -c:a copy -c:s copy \
  output.mkv
```

Replace the example IP with your Mac's address. The daemon defaults to loopback if `--listen` is omitted. Tokens authenticate but do not encrypt traffic; use an SSH tunnel or VPN on untrusted networks. See [security](docs/security.md).

### Packet transcoding for batch jobs

For H.264/HEVC input that needs only supported server-side video operations, send compressed packets to the Mac and receive compressed HEVC output:

```bash
./ffmpeg-client/ffmpeg -i input.mkv -map 0 -c copy \
  -vt_remote_transcode:v:0 \
  -vt_remote_host 192.168.1.20 -vt_remote_port 5555 \
  -vt_remote_out_codec:v:0 hevc -b:v:0 6M \
  output.mkv
```

The Mac handles video decode, optional resize/pixel-format conversion and encode. Files, audio, subtitles and muxing stay on the client. Arbitrary FFmpeg filters are not offloaded by packet mode; use remote encoding after local decode/filtering when needed.

## Downloads and platform support

| Release asset | Platform / purpose |
| --- | --- |
| `vtremoted-macos-arm64.tar.gz` | Apple Silicon server, macOS 13+ |
| `vtremoted-macos-x86_64.tar.gz` | Intel server with supported VideoToolbox hardware, macOS 13+ |
| `ffmpeg-linux-x86_64.tar.gz` | Linux x86_64 FFmpeg client |
| `ffmpeg-linux-arm64.tar.gz` | Linux arm64/aarch64 FFmpeg client; Ubuntu 24.04-compatible runtime |
| `ffmpeg-macos-arm64.tar.gz`, `ffmpeg-macos-x86_64.tar.gz` | macOS FFmpeg clients |
| `ffmpeg-windows-x86_64.tar.gz` | Windows x86_64 FFmpeg client |
| `vtremote-vaapi-linux-x86_64.tar.gz` | Linux VA-API driver, Plex packet shim and experimental static C SDK |
| `vtremote-vaapi-*-source.tar.gz` | Matching driver/shim/SDK source bundle |
| `SHA256SUMS.txt`, `*.sha256` | Release checksums |

The Linux arm64 FFmpeg archive is dynamically linked and requires glibc 2.39+ and matching shared libraries, including libvmaf 3.0.0. Build from source for Debian 12 or Raspberry Pi OS Bookworm. [Runtime requirements](docs/getting-started.md#linux-arm64-release-runtime). VA-API and Plex release integrations are Linux x86_64 only; there is no 32-bit i686 release.

## Architecture and limits

`vtremoted` is a lightweight Swift daemon wrapping VideoToolbox. FFmpeg remote codecs, the VA-API driver, the Plex packet shim and the OBS plugin share a TCP protocol. Protocol v1 keeps its existing message layouts; optional media features are capability-negotiated.

- **Remote encode:** raw frames → Mac → H.264/HEVC packets.
- **Remote decode:** H.264/HEVC packets → Mac → raw frames.
- **Remote transcode:** H.264/HEVC packets → Mac decode/resize/encode → packets.

Wired LAN is recommended. Raw frames can require substantial bandwidth, especially at 4K/10-bit; LZ4/Zstd compression depends on content. Packet mode is usually the better fit for a low-powered Plex host or batch conversion without local video filters.

The general VA-API driver is encode-only and does not provide decode, VPP, tone mapping, B-frames or external DMA-BUF surfaces. The Plex container uses a separate packet path, checks the bundled codec library and supported graph, and leaves unsupported commands on Plex's native path. Native processing may still use Linux CPU. See the guides for exact constraints.

## Build and contribute

```bash
make build-vtremoted   # macOS server
make build-ffmpeg      # FFmpeg client, on the target OS
```

The server loads LZ4/Zstd at runtime when requested. Client builds need the corresponding development libraries. [Development](docs/development.md) covers toolchains, tests, release checks and the Linux assembler diagnostic.

Remote option and metadata coverage includes common software-frame uploads, negotiated VideoToolbox hardware-frame ingest/output, HEVC pixel formats, HDR/color signaling and typed side data. Hardware frames are uploaded across hosts, not shared as zero-copy handles. See [architecture](docs/architecture.md), [protocol](docs/protocol.md) and [integration tests](tests/integration/README.md).

Issues and pull requests are welcome. Include the server/client OS, command, release or commit, `vtremoted --version` and logs. Read [CONTRIBUTING.md](CONTRIBUTING.md), [troubleshooting](docs/troubleshooting.md) and [SECURITY.md](SECURITY.md).

## License

FFmpeg-style licensing: LGPL v2.1+ by default, with optional GPL components depending on the FFmpeg configuration. See [LICENSE.md](LICENSE.md), [COPYING.LGPLv2.1](COPYING.LGPLv2.1) and [FFmpeg's license](ffmpeg/LICENSE.md).
