# Architecture

The module implements the libva 1.22 driver ABI and advertises encode-only
H.264 and HEVC profiles. VA surfaces are process-owned linear NV12/P010 memory.
An application uploads software-decoded or filtered pixels through the normal
VA image APIs.

At the first `vaEndPicture`, the driver opens one protocol-v1 TCP session for
the VA context, sends HELLO and CONFIGURE, compresses each frame plane, and
waits synchronously for one PACKET. The returned access unit is published as a
single `VACodedBufferSegment`. The exact H.264 or HEVC libva sequence and
picture structures select the coded buffer, bitrate, GOP, and forced-IDR state.

The global object lock protects fixed-capacity VA object tables. Each encode
context has a separate network lock, so independent contexts can make progress
in parallel. Network I/O happens without the global object lock. A transport
failure poisons that context to prevent an accidental second stream on a new
connection.

The module does not link to libva itself: libva loads it. It links to pthread,
LZ4, Zstandard, and the C runtime. The separately installed experimental static
client SDK exposes the protocol transport without VA-API.
