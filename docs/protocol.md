---
title: Protocol
---

# VideoToolbox Remote Protocol — Version 1 (authoritative)

Status: draft locked for MVP (as of 2026-01-12). On-wire bitstream format is **Annex B** (mandatory for v1).

## 1. Transport
- TCP, one connection per encode session.
- Default port: 5555 (configurable).
- Length-prefixed binary messages; all integers are **network byte order** (big endian).
- No TLS in MVP (optional token + trusted LAN); TLS/mTLS reserved for v2.

## 2. Framing

```c
struct MsgHeader {
    uint32_t magic;   // 'VTR1' = 0x56545231
    uint16_t version; // 1
    uint16_t type;    // enum MsgType
    uint32_t length;  // payload bytes (does NOT include header)
};
```

Header size: 12 bytes. Every frame carries the header, even for zero-length payloads.

## 3. Message types (v1)
Numeric codes are fixed for v1. Future versions must either bump `version` or remain backward compatible.

| Type | Code | Direction | Payload |
| --- | --- | --- | --- |
| HELLO | 1 | C→S | token (optional), requested_codec, client_name, client_build_id |
| HELLO_ACK | 2 | S→C | status, server_name, server_version, capabilities, max_sessions, active_sessions |
| CONFIGURE | 3 | C→S | width, height, pix_fmt, time_base, framerate (opt), options map, extradata |
| CONFIGURE_ACK | 4 | S→C | status, codec_extradata, reported_pix_fmt, warnings |
| FRAME | 5 | C→S (encode) / S→C (decode) | pts, duration, flags, planes[] |
| PACKET | 6 | S→C (encode) / C→S (decode) | pts, dts, duration, flags, data |
| FLUSH | 7 | C→S | none |
| DONE | 8 | S→C | none |
| ERROR | 9 | C↔S | code, message |
| PING | 10 | C↔S | none |
| PONG | 11 | C↔S | none |

`status` in ACKs: `0=ok`, `1=busy`, `2=authfail`, `3=unsupported`, `4=internal`.

`flags` bitfield (FRAME): bit0=force_keyframe.  
`flags` bitfield (PACKET): bit0=keyframe.

## 4. Payload encoding

### Strings
UTF‑8. Prefix with `uint16_t len`, followed by `len` bytes (no NUL).

### Options map
`uint16_t count` followed by repeated key/value string pairs.
Mandatory key: `mode` (`encode` or `decode`).
Optional key: `wire_compression` (`0`=none, `1`=lz4). When set to `1`, FRAME plane data is LZ4-compressed. Client default is `lz4` unless overridden.

### CONFIGURE extradata
`uint32_t extradata_len` + `extradata_len` bytes. For decode, send codec config
records (avcC/hvcC) when available.

### Pixel formats (enum)
`1=NV12`, `2=P010`. NV12 is required for v1; P010 may be rejected with `unsupported`.

### FRAME planes
`uint8_t plane_count`, then for each plane: `uint32_t stride`, `uint32_t height`, `uint32_t data_len`, `data`.  
MVP requires plane_count=2 (NV12).
If `wire_compression=1`, `data` is LZ4-compressed and must decompress to `stride * height` bytes for that plane.

### PACKET data
- `uint32_t data_len` + `data` (Annex B NAL units).
- Optional side data is reserved for future versions (length=0 in v1).

### Extradata in CONFIGURE_ACK
- H.264: `AVCDecoderConfigurationRecord` (avcC box contents).
- HEVC: `HEVCDecoderConfigurationRecord` (hvcC box contents).
- Clients may also extract SPS/PPS(/VPS) from the record to emit Annex B start-code copies if required by the muxer; PACKET data is already Annex B.

## 5. Timing
- Client supplies `pts` and `duration` per FRAME (int64, in stream timebase).
- Server emits `pts`, `dts`, `duration` per PACKET derived from CMSampleBuffer timing. **Client must not guess DTS.**
- Time base is provided in CONFIGURE as `num/den`.
Decode mode: client supplies `pts`, `dts`, `duration` per PACKET and server emits FRAME timestamps.

## 6. Backpressure & inflight
- Rely on TCP backpressure.
- Client must cap inflight frames; recommended default 16, configurable.
- Server may return `ERROR busy` or `HELLO_ACK busy` if `max_sessions` exceeded.

## 7. Keepalive / timeouts
- Optional `PING/PONG`; suggested every 5s idle with a 10s read timeout.
- If socket errors or timeouts occur, endpoints must free session resources promptly.

## 8. Error codes (ERROR message)
`1=authfail`, `2=busy`, `3=unsupported`, `4=bad_request`, `5=internal`, `6=timeout`, `7=protocol_violation`.

## 9. Versioning rules
- Any change to framing or field order/meaning must bump `version`.
- Backward-compatible extensions (e.g., new optional flags) must not break v1 parsers and must be documented here.

## 10. Security
- MVP: pre-shared token in HELLO. If server is configured with a token, reject on mismatch. If server has no token configured, accept any token (including empty).
- No compression bombs: enforce reasonable maxima (e.g., token ≤256 bytes, planes data_len bounds vs. configured width/height).

## 11. Bitstream format (locked)
- Wire PACKET payloads are **Annex B** start-code prefixed NAL units for both H.264 and HEVC.
- Extradata remains avcC/hvcC so containers that need configuration records are satisfied.
- Servers MUST convert VideoToolbox length-prefixed output to Annex B before sending.

## 12. Compliance checklist (MVP)
- HELLO/HELLO_ACK implemented with token + codec negotiation.
- CONFIGURE/CONFIGURE_ACK roundtrip returns extradata and coerced pix_fmt if needed.
- FRAME → PACKET path handles NV12 planes.
- FLUSH drains delayed frames; DONE terminates stream.
- ERROR is sent on fatal issues; connection closes after fatal errors.
- PING/PONG supported for keepalive.
