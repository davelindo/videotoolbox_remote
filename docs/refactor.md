# Refactor Notes — VideoToolbox Remote Encode/Decode

## Naming decision
Options considered:
- `h264_videotoolbox_remote` / `hevc_videotoolbox_remote` (recommended)
- `h264_videotoolbox_offload` / `hevc_videotoolbox_offload`
- `h264_videotoolbox_proxy` / `hevc_videotoolbox_proxy`

Recommendation: `*_videotoolbox_remote`. It mirrors FFmpeg’s existing `*_videotoolbox` naming, makes the offload nature explicit, and does not suggest URL/input semantics.

Compatibility:
- No aliases retained (pre-release cleanup).

## Top 5 complexity sources (pre-refactor)
1. Encoder naming/options were project-specific, increasing user/API friction.
2. Per-message allocation (header+payload copy) in the client send path.
3. Per-frame payload buffer allocation/teardown and repeated `av_malloc`/`av_free`.
4. Warmup output mixing with live output (extra packet vs frame count).
5. Incomplete lifecycle cleanup on server disconnect (VT session cleanup not explicit).

## Top 5 performance risks (pre-refactor)
1. Allocation+memcpy in every message send (frame + packet control).
2. Reallocating the payload buffer for each frame.
3. Small syscalls due to per-message buffer building.
4. Backpressure path returned `EAGAIN` without draining, risking stalls.
5. Extra packet from warmup skewing counts and mux timing.

## Simplifications and performance changes
- Encoder names now follow FFmpeg conventions: `h264_videotoolbox_remote` / `hevc_videotoolbox_remote`.
- AVOptions renamed to `vt_remote_*` (no aliases retained).
- Client send path now writes header + payload directly (no full-message allocation).
- Client reuses a per-context frame payload buffer (no per-frame malloc/free).
- Backpressure now drains packets before returning `EAGAIN`.
- Server always discards warmup output and drops its encode timestamp.
- Server explicitly invalidates VTCompressionSession on teardown.
- Lightweight per-session stats on both sides (behind log level).

## Hot paths (critical)
Client encode:
1. Decode/filter → NV12/P010 `AVFrame`
2. Serialize FRAME payload
3. TCP send (header + payload)
4. Receive PACKET
5. Queue into muxer

Client decode:
1. Send PACKET payload
2. Receive FRAME payload
3. Copy into `AVFrame`

Server encode:
1. Receive FRAME payload
2. Build `CVPixelBuffer` (NV12/P010)
3. `VTCompressionSessionEncodeFrame`
4. Output callback converts to Annex B
5. TCP send PACKET

Server decode:
1. Receive PACKET payload
2. Convert Annex B → length-prefixed
3. `VTDecompressionSessionDecodeFrame`
4. Output callback copies planes
5. TCP send FRAME

## Invariants (must never regress)
- **Timestamps:** client uses server-provided PTS/DTS verbatim; no DTS guessing.
- **Bitstream:** Annex B on wire; extradata remains avcC/hvcC.
- **Pixel format:** H.264 NV12 only; HEVC NV12/P010.
- **Mux behavior:** unchanged; only video encode/decode are remote.
- **Cleanup:** VT session freed on normal close and on errors/disconnect.

## Tests added (regressions caught)
- `check_frame_packet_count.sh`: ensures packets == frames (catches warmup/extra packets).
- `check_bitrate.sh`: validates bitrate within tolerance (catches mis-set rate control).
- `run_vtremoted_roundtrip.sh`: now exercises the new checks.

## Benchmarks
Script: `tests/integration/bench_vtremote.sh`

Observed before/after fixes (representative):
- **1080x1920@59.94, target 10 Mb/s (remote)**  
  Before: ~6.9 Mb/s (rate-control mismatch)  
  After: ~9.96 Mb/s (AvgBitRate SInt32, no DataRateLimits)
- **Frame/packet parity (remote)**  
  Before: frames=300, packets=301 (warmup leak)  
  After: frames=300, packets=300

For full sweeps (720p30/1080p30/1080p60), run the benchmark script and record CPU with Activity Monitor or `ps`.
