# Development notes

This is for contributors who want to modify the client codecs, protocol, or daemon.

## Repo layout

- `vtremoted/` — Swift macOS daemon that exposes VideoToolbox over TCP
- `ffmpeg/` — FFmpeg fork containing the remote codec implementations
- `docs/` — protocol + architecture docs

## Where the FFmpeg-side logic lives

Key files (for navigation) include:
- `ffmpeg/libavcodec/vtremote_enc_common.*` — shared encoder client
- `ffmpeg/libavcodec/vtremote_dec_common.*` — shared decoder client
- `ffmpeg/libavcodec/vtremote_proto.*` — protocol framing + I/O
- `ffmpeg/libavcodec/vtremote_h264*` / `vtremote_hevc*` — codec wrappers
- `ffmpeg/libavcodec/allcodecs.c` — codec registration
- `ffmpeg/configure` — build deps (liblz4 + networking)
- `ffmpeg/doc/encoders.texi` / `ffmpeg/doc/decoders.texi` — user-facing docs

(See the root README for the original quick map of these files.)
---
title: Development
---

# Development

## vtremoted (Swift)

```bash
cd vtremoted
swift build -c release
swift test
make format
make lint
```

## FFmpeg fork

```bash
cd ffmpeg
./configure ... --enable-liblz4 \
  --enable-encoder=h264_videotoolbox_remote --enable-encoder=hevc_videotoolbox_remote \
  --enable-decoder=h264_videotoolbox_remote --enable-decoder=hevc_videotoolbox_remote
make -j
```

## Integration tests

See `tests/integration/README.md` for the roundtrip and parity scripts.
