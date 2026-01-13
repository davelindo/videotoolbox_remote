# VideoToolbox Remote

VideoToolbox Remote offloads VideoToolbox encoding/decoding to a macOS daemon while keeping
the rest of the FFmpeg pipeline (demux, decode/filters, audio/subs, mux) local.

## Components

- `vtremoted/` — macOS daemon (VideoToolbox encode/decode over TCP)
- `ffmpeg/` — FFmpeg fork with `h264_videotoolbox_remote` / `hevc_videotoolbox_remote`
- `docs/` — protocol + architecture docs

## FFmpeg changes (key files)

For quick navigation (subtree diffs are noisy), these are the core files added/modified
under `ffmpeg/`:

- `ffmpeg/libavcodec/vtremote_enc_common.c` / `ffmpeg/libavcodec/vtremote_enc_common.h` — shared encoder client
- `ffmpeg/libavcodec/vtremote_dec_common.c` / `ffmpeg/libavcodec/vtremote_dec_common.h` — shared decoder client
- `ffmpeg/libavcodec/vtremote_proto.c` / `ffmpeg/libavcodec/vtremote_proto.h` — protocol framing + I/O
- `ffmpeg/libavcodec/vtremote_h264.c` / `ffmpeg/libavcodec/vtremote_hevc.c` — encoders
- `ffmpeg/libavcodec/vtremote_h264_dec.c` / `ffmpeg/libavcodec/vtremote_hevc_dec.c` — decoders
- `ffmpeg/libavcodec/allcodecs.c` — codec registration
- `ffmpeg/configure` — build deps for liblz4 + network
- `ffmpeg/doc/encoders.texi` / `ffmpeg/doc/decoders.texi` — user-facing docs

## Quickstart

### 1) macOS server (vtremoted)

```bash
brew install lz4 pkg-config
cd vtremoted
swift build -c release
```

Run manually:

```bash
.build/release/vtremoted --listen 0.0.0.0:5555 --log-level 1
```

Or install as launchd (recommended):

```bash
./install_launchd.sh --bin /usr/local/bin/vtremoted --listen 0.0.0.0:5555
```

### 2) FFmpeg client (Linux/Windows/macOS)

Install liblz4 + pkg-config, then configure FFmpeg with the remote codecs:

```bash
./configure ... --enable-liblz4 \
  --enable-encoder=h264_videotoolbox_remote --enable-encoder=hevc_videotoolbox_remote \
  --enable-decoder=h264_videotoolbox_remote --enable-decoder=hevc_videotoolbox_remote
make -j
```

### 3) Encode remotely

```bash
ffmpeg -i input.mkv \
  -c:v h264_videotoolbox_remote -vt_remote_host macmini.local:5555 \
  -b:v 6000k -g 240 \
  -c:a copy -c:s copy \
  output.mkv
```

## Notes

- Wire compression is **enabled by default** (LZ4). Disable with:
  `-vt_remote_wire_compression none`.
- Token auth is optional; set `-vt_remote_token` on the client and `--token` on the server to enforce.

## License

This project uses the same licensing terms as FFmpeg (LGPL v2.1+ with optional GPL parts).
See `LICENSE.md` and `COPYING.*` at the repo root, plus `ffmpeg/LICENSE.md` for details.
