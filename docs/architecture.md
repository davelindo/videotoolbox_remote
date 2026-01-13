# VideoToolbox Remote Architecture (MVP)

Updated: 2026-01-12

## Components
- **Client (FFmpeg)**: encoders/decoders `h264_videotoolbox_remote` / `hevc_videotoolbox_remote`. Responsibilities: demux, decode/encode, filters, audio/subs, mux, rate-control policy, TCP session lifecycle, frame upload, packet reception, timestamp preservation.
- **Server (`vtremoted`, macOS)**: per-connection `VTCompressionSession` (encode) or `VTDecompressionSession` (decode); optional token auth; enforce `max_sessions`; convert incoming planes (NV12/P010) into `CVPixelBuffer`; encode/decode; convert NALs to Annex B on the wire; emit packets/frames with timing; flush on request; clean up on disconnect/error.

## Data flow (per stream)
Encode:
1) Client configures encoder → HELLO/HELLO_ACK, CONFIGURE/CONFIGURE_ACK (gets extradata).
2) Client sends FRAME messages (NV12/P010 planes). Each carries pts/duration/force-keyframe flag.
3) Server encodes, returns PACKET messages (Annex B) with pts/dts/duration + keyframe flag.
4) On end/flush: client sends FLUSH; server drains delayed frames, sends remaining PACKETs then DONE.
Decode:
1) Client configures decoder → HELLO/HELLO_ACK, CONFIGURE/CONFIGURE_ACK.
2) Client sends PACKET messages (Annex B) with pts/dts/duration.
3) Server decodes, returns FRAME messages (NV12/P010 planes) with pts/duration.
4) On end/flush: client sends FLUSH; server drains delayed frames then DONE.
Common:
5) Either side may send ERROR; connection closes after fatal error.
6) Optional PING/PONG keepalive; socket timeouts trigger cleanup.

## Bitstream decision
- **Locked**: PACKET payloads are Annex B. Extradata in CONFIGURE_ACK is avcC/hvcC for container compatibility.

## Repository layout (current repo)
- Repo root contains `ffmpeg/` (upstream fork). Use root-level paths for docs/tests/tools.
- Server location for this repo: `vtremoted/` (sibling to `ffmpeg/`).
- Tests: `tests/integration/` (root-level) for mock server + scripts.
- Protocol docs: `docs/protocol.md` (authoritative), architecture here.
- Protocol helpers: `ffmpeg/libavcodec/vtremote_proto.{c,h}` (header writing/parsing, payload builders); unit test `ffmpeg/libavcodec/tests/vtremote_proto.c` wired into FATE as `fate-vtremote-proto`.
- Mock server for framing: `tests/integration/mock_vtremoted/` (Python stdlib).
- macOS daemon: `vtremoted/` (SwiftPM) implements HELLO/CONFIGURE/FRAME/FLUSH and performs real VideoToolbox H.264 encode (Annex B on wire).

## Build expectations (to be documented in README)
- FFmpeg: minimal configure additions for `*_videotoolbox_remote` encoders; no macOS frameworks required on client.
  Example:
  ```
  ./configure ... --enable-liblz4 \
    --enable-encoder=h264_videotoolbox_remote --enable-encoder=hevc_videotoolbox_remote \
    --enable-decoder=h264_videotoolbox_remote --enable-decoder=hevc_videotoolbox_remote
  ```
- Server: SwiftPM or Xcode on macOS; flags for listen addr/port, optional token, max_sessions, log level. Requires system `liblz4`.

## Milestone alignment
- **M0**: protocol lib (`vtremote_proto.*`) + portable mock server; validate client scaffolding without VideoToolbox.
- **M1**: `h264_videotoolbox_remote` + real `vtremoted` H.264 (Annex B), full FFmpeg pipeline.
- **M2**: HEVC path + DTS correctness for B-frames.
- **M3**: stability/perf (keepalive, inflight tuning, optional wire compression).

## Not in scope (MVP)
- TLS/mTLS, HandBrake integration, HDR metadata passthrough, multi-server discovery.
