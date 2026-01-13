# Mock vtremoted (protocol framing only)

Purpose: lightweight Python 3 server to exercise VideoToolbox Remote protocol framing and basic message flow before touching VideoToolbox. It understands HELLO/CONFIGURE/FRAME/FLUSH, echoes CONFIGURE_ACK with empty extradata, emits dummy Annex B PACKETs for each FRAME, and sends DONE on FLUSH.

## Usage

```bash
python3 tests/integration/mock_vtremoted/mock_vtremoted.py \
  --listen 127.0.0.1:5555 \
  --token TESTTOKEN \
  --once
```

Connect with your client/encoder under test using the same token (or omit `--token` to disable auth). The server:
- Validates HELLO token if configured (authfail if mismatched)
- Reports caps: h264, hevc, nv12; max_sessions from flag (default 4)
- Returns empty extradata in CONFIGURE_ACK (this mock is for framing, not real decode)
- Emits one dummy PACKET per FRAME with pts/dts/duration copied from the frame and keyframe flag set if the frame requested a keyframe
- Replies PONG to PING; sends DONE on FLUSH; sends ERROR for unknown messages

## Notes
- Annex B payload is a small dummy NAL and not decodable video.
- Keep this mock portable and dependency-free; standard library only.
