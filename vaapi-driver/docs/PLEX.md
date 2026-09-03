# Plex remote video-transcode integration

The supported Plex path sends compressed H.264 or HEVC packets to
`vtremoted`. The Mac performs video decode, resize, and H.264/HEVC encode;
Plex on Linux retains demuxing, audio/subtitle processing, and muxing. Decoded
frames do not cross the network, and the Linux host needs no GPU or DRM render
node.

The image installs a narrow wrapper in front of Plex Transcoder. It recognizes
Plex's ordinary software-scale/format/hardware-upload graph and replaces the
complete video chain with the `vtremote_transcode` packet filter. Unknown
codecs, multiple hardware graphs, tone mapping, deinterlace, and other
unrecognized graphs pass through unchanged to Plex's native Transcoder. The
same native fallback applies to multiple video streams, indirect filter labels,
and compatibility-critical encoder options that cannot be translated exactly.
A native fallback can use only devices that you separately expose to the
container.

The image pins an amd64 official `pms-docker` bootstrap digest. Like the
upstream `beta` image, its init script downloads the configured Plex Media
Server version when the container starts. Build from the repository root:

```bash
docker build -f vaapi-driver/docker/Dockerfile.plex \
  --build-arg VTREMOTE_VERSION="$(git describe --tags --always)" \
  -t plex-vtremote .
```

Use `docker/docker-compose.plex.yml.example` as a merge fragment. Set
`VTREMOTE_HOST` and optionally `VTREMOTE_TOKEN`; set `PLEX_CLAIM` or reuse an
existing Plex configuration as required by the official image. Do not add a
render device for the remote path.

The integration builds its injected filter against official FFmpeg 6.1.1
headers. Container startup checks the bundled `libavcodec` against an explicit
allowlist of tested fingerprints before installing the wrapper, and each
wrapper invocation checks the full runtime `avcodec_version()` before rewriting
arguments. The preload module repeats the full-version check before accessing
the private BSF context. Plex Media Server 1.43.3.10896 is covered by an
unclaimed-server end-to-end test. An unrecognized Plex upgrade fails closed and
keeps native transcoding.

The recognized path translates bitrate, maximum rate, buffer window,
GOP/B-frame settings, profile, H.264 level, entropy mode, and CBR/VBR/CQP
selection. The ordinary periodic `force_key_frames` expression becomes a
keyframe interval and closed-GOP request based on Plex's requested frame rate.
VideoToolbox exposes only automatic HEVC level selection, so a fixed HEVC level
request leaves the original command intact. The same applies to any other
unsupported value.

## Unclaimed-server validation

First validate the bundled Plex Transcoder without claiming a server. The
script covers H.264 encode, HEVC Main10 decode to H.264, and HEVC encode with
Plex-shaped hardware graphs. Each case must return 96 frames across at least
three independently decodable, keyframe-aligned segments at the remotely
requested dimensions and profile:

```bash
PLEX_CONTAINER=plex \
  ./vaapi-driver/scripts/plex-transcoder-remote-smoke.sh
```

This validates the actual Plex binary, injected filter, network protocol, Mac
decoder/scaler/encoder, and returned bitstream. It requires host `ffmpeg` and
`ffprobe`, but no Plex token, library, or Plex Pass entitlement.

## Claimed-server playback validation

Enable hardware acceleration and hardware encoding in a claimed Plex Pass
server, then exercise a real playback decision and HLS request:

```bash
PLEX_URL=http://127.0.0.1:32400 \
PLEX_TOKEN=... \
PLEX_RATING_KEY=12345 \
PLEX_CONTAINER=plex \
  ./vaapi-driver/scripts/plex-playback-smoke.sh
```

Use an SDR H.264 or HEVC item whose transcode needs only resize and encode.
The script downloads one HLS segment, verifies decodable frames, requires a
new successful-handshake audit marker, and stops only its own session.

A marker in `VTREMOTE_PLEX_AUDIT_FILE` proves that remote decode/scale/encode
started; its absence means Plex used a native or unsupported path. A valid
segment plus a new marker proves media returned through the remote path. Check
Linux process CPU and `vtremoted` logs separately when validating performance.
