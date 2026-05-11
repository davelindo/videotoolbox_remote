# Mock vtremoted (protocol framing only)

Purpose: lightweight Python 3 server to exercise VideoToolbox Remote protocol framing and basic message flow before touching VideoToolbox. It understands HELLO/CONFIGURE/FRAME/FLUSH, echoes CONFIGURE_ACK, emits Annex B PACKETs for each FRAME, and sends DONE on FLUSH.

## Usage

```bash
python3 tests/integration/mock_vtremoted/mock_vtremoted.py \
  --listen 127.0.0.1:5555 \
  --token TESTTOKEN \
  --once
```

Connect with your client/encoder under test using the same token (or omit `--token` to disable auth). The server:
- Validates HELLO token if configured (authfail if mismatched)
- Reports caps: h264, hevc, pixfmt.nv12, pixfmt.p010, pixfmt.bgra, pixfmt.ayuv, pixfmt.p210, hwframes.videotoolbox.input, hwframes.videotoolbox.output, side_data.v2; max_sessions from flag (default 4)
- Returns empty extradata in CONFIGURE_ACK by default, or caller-supplied hex fixtures via `--configure-extradata-hex[-file]`
- Emits one PACKET per FRAME with pts/dts/duration copied from the frame and keyframe flag set if the frame requested a keyframe; packet data defaults to a tiny dummy NAL but can be overridden via `--packet-data-hex[-file]`
- Replies PONG to PING; sends DONE on FLUSH; sends ERROR for unknown messages

## Notes
- Annex B payload is a small dummy NAL and not decodable video.
- The fixture flags make it possible to exercise mux-visible signaling paths such as `hvc1`, MP4 `nclx` metadata, and HDR color signaling without a real VideoToolbox server.
- Keep this mock portable and dependency-free; standard library only.
