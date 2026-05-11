---
title: v0.4.1 Implementation Plan
description: "Implementation plan for the v0.4.1 expanded pipeline parity release: hardware-frame ingest/output, broader HEVC pixel formats, side-data forwarding, protocol capability negotiation, and release hardening."
---

# v0.4.1 Implementation Plan

## Release Goal

`v0.4.1` is an expanded pipeline parity release for the `v0.4.0` OBS beta foundation. It should move beyond packaging hardening and close the next practical compatibility gaps that block real FFmpeg, OBS, and macOS VideoToolbox workflows from behaving like local VideoToolbox where possible.

Target outcome:
- FFmpeg callers can feed hardware-backed frames into remote encode/transcode paths without unnecessary software round-trips.
- Remote decode can expose hardware-backed output where the caller requests and negotiates it.
- HEVC remote paths support the broader pixel-format surface users expect from local VideoToolbox, including `bgra`, `ayuv`, and `p210` where VideoToolbox and the protocol can represent them safely.
- Side-data propagation is explicit, tested, and preserved across encode, decode, and transcode paths for the metadata classes needed by HDR, colorimetry, alpha, timing, and packet/display behavior.
- Protocol capability negotiation becomes the compatibility gate for new media surfaces instead of relying on implicit version assumptions.
- Build, install, artifact, and mock-test hardening remains in scope so the release is supportable once the deeper media work lands.

## Scope

### In Scope

- Hardware-frame ingest for encoder and transcode inputs where FFmpeg supplies `AVHWFramesContext`/VideoToolbox-backed frames.
- Decoder hardware-frame output for callers that request hardware frames and for filter graphs that can consume them.
- Broader HEVC pixel-format support, including `bgra`, `ayuv`, and `p210`, with explicit server capability validation.
- Expanded frame and packet side-data forwarding across encode, decode, and transcode protocol paths.
- Protocol capability additions required to negotiate the new frame memory, pixel-format, and side-data behavior.
- Compatibility fallback paths when a server or local VideoToolbox runtime lacks a requested feature.
- Mock and real-server integration coverage for the new protocol and media-surface behavior.
- Linux build dependency and assembler diagnostics.
- `--disable-x86asm` fallback documentation and Makefile affordances.
- macOS `vtremoted` install, restart, and verification workflow.
- Release artifact smoke checks in CI.
- Documentation, release notes, and changelog coverage for the new feature surface and operational hardening.

### Out of Scope

- OBS UI or UX work that is not needed to consume the new pipeline behavior.
- A broad FFmpeg subtree sync unless required to unblock the scoped media work.
- Performance rewrites unrelated to hardware-frame avoidance, memory-copy reduction, or correctness of the new paths.
- New codecs beyond H.264/HEVC remote paths.
- Non-VideoToolbox hardware APIs.

## Workstreams

## 1. Protocol Capability Negotiation

Problem:
`0.4.0` validates core format compatibility, but the broader 0.4.1 surface needs explicit negotiation for hardware memory, additional pixel formats, side-data classes, and decode-output behavior. Without this, client and server mismatches become runtime failures or silent metadata loss.

Implementation:
- Add protocol capability bits or structured capability fields for:
  - hardware-frame ingest
  - hardware-frame decode output
  - supported input pixel formats by codec and mode
  - supported output pixel formats by codec and mode
  - side-data classes accepted on frames
  - side-data classes returned on packets/frames
- Keep negotiation backward-compatible with `0.4.0` servers.
- Validate required caps once during handshake/configure, not in per-frame hot paths unless the per-frame value can legitimately change.
- Add user-facing errors that name the missing capability and the requested feature.
- Update mock server strict-mode validation to reject unsupported negotiated features.

Suggested files:
- `ffmpeg/libavcodec/vtremote_*`
- `ffmpeg/libavcodec/vtremote_proto*`
- `ffmpeg/libavcodec/vtremote_enc_common.c`
- `ffmpeg/libavcodec/vtremote_decode*.c`
- `ffmpeg/libavcodec/bsf/vtremote_transcode*.c`
- `vtremoted/Sources/VTRemotedCore/*`
- `tests/integration/mock_vtremoted/mock_vtremoted.py`

Acceptance criteria:
- A 0.4.1 client can still connect to a 0.4.0 server for pre-existing software-frame features.
- Requests for 0.4.1-only surfaces fail during handshake/configure with a clear error on older servers.
- Mock strict mode verifies every new capability used by tests.
- Capability checks are documented in the protocol notes and do not add avoidable branches to the per-frame encode hot path.

Validation:

```bash
bash tests/integration/run_mock_protocol_capabilities.sh
bash tests/integration/run_mock_roundtrip.sh
bash tests/integration/run_mock_decode.sh
```

## 2. Hardware-Frame Ingest

Problem:
FFmpeg users and OBS-style pipelines can already hold frames in VideoToolbox/CoreVideo memory. Forcing a download to software frames before remote encode/transcode loses the benefit of a hardware pipeline and diverges from local VideoToolbox behavior.

Implementation:
- Detect hardware-backed FFmpeg input frames in the remote encoder and transcode paths.
- Map supported `AVHWFramesContext`/VideoToolbox frame metadata into the vtremote wire representation.
- Add protocol fields that distinguish software image planes from hardware-frame descriptors.
- On macOS clients, serialize the minimum safe descriptor state needed by the remote server. If a true zero-copy cross-host transfer is impossible, provide a bounded fallback that preserves correctness and reports the copy path.
- Preserve existing software-frame behavior unchanged.
- Fail early when hardware frames are supplied but the server does not advertise hardware-frame ingest.
- Add instrumentation at debug log level that distinguishes software upload, hardware-frame ingest, and fallback copy paths.

Design constraints:
- Do not assume IOSurface or CVPixelBuffer handles are meaningful across machines unless an explicit transport supports them.
- Avoid hidden CPU readbacks when the user explicitly requested hardware-frame operation; either negotiate the fallback or fail with a clear message.
- Keep the configured wire pixel format authoritative after configure.

Suggested files:
- `ffmpeg/libavcodec/vtremote_enc_common.c`
- `ffmpeg/libavcodec/vtremote_h264enc.c`
- `ffmpeg/libavcodec/vtremote_hevcenc.c`
- `ffmpeg/libavcodec/bsf/vtremote_transcode*.c`
- `vtremoted/Sources/VTRemotedCore/*`
- `tests/integration/*hardware*`

Acceptance criteria:
- Software-frame encode/transcode behavior and outputs remain unchanged.
- Hardware-frame inputs either use the negotiated hardware-frame path or fail before processing frames with a clear unsupported-feature error.
- Fallback copies, if implemented, are explicit in logs and tests.
- Real-server tests on `srv4` cover at least one hardware-frame ingest path.

Validation:

```bash
FFMPEG_BIN=$PWD/ffmpeg/ffmpeg bash tests/integration/run_vtremoted_hardware_ingest.sh
FFMPEG_BIN=$PWD/ffmpeg/ffmpeg bash tests/integration/run_vtremoted_transcode_hardware_ingest.sh
```

## 3. Decoder Hardware-Frame Output

Problem:
Remote decode currently behaves like a software-frame producer for many downstream users. That is safe, but it prevents hardware-native filter graphs and applications from maintaining a VideoToolbox-backed decode pipeline.

Implementation:
- Add client options for requesting decoder hardware-frame output.
- Negotiate decoder output memory type during configure.
- Return hardware-backed frames when the server and caller both support them.
- Preserve software output as the default compatibility mode.
- Ensure `ffprobe`, simple decode-to-null, and software filters keep working without new options.
- Add clear diagnostics when a hardware-frame output request cannot be satisfied.

Design constraints:
- Hardware output must respect FFmpeg's `get_format`, `hw_frames_ctx`, and frame lifetime semantics.
- Do not leak server-side resource lifetime into client-side frame ownership.
- If remote hardware output requires a copy or rewrap, represent that honestly in logs and docs.

Suggested files:
- `ffmpeg/libavcodec/vtremote_decode*.c`
- `ffmpeg/libavcodec/vtremote_proto*`
- `vtremoted/Sources/VTRemotedCore/*`
- `tests/integration/run_vtremoted_decode*.sh`

Acceptance criteria:
- Existing decode tests pass unchanged.
- New decode tests can request hardware-frame output and verify the negotiated format.
- Unsupported servers fail during configure, not after packets are decoded.
- Hardware output does not regress PTS/DTS or color metadata propagation.

Validation:

```bash
FFMPEG_BIN=$PWD/ffmpeg/ffmpeg bash tests/integration/run_vtremoted_decode.sh
FFMPEG_BIN=$PWD/ffmpeg/ffmpeg bash tests/integration/run_vtremoted_decode_hardware_output.sh
```

## 4. Broader HEVC Pixel Formats

Problem:
HEVC VideoToolbox workflows commonly need formats beyond the current narrow surface. `bgra`, `ayuv`, and `p210` are important for alpha, high bit depth, packed/component workflows, and parity with local VideoToolbox behavior.

Implementation:
- Extend pixel-format mapping tables for HEVC encode/transcode/decode where applicable.
- Add protocol pixel-format identifiers for `bgra`, `ayuv`, and `p210`.
- Map each new format to the correct CoreVideo pixel format on the server.
- Validate bit depth, alpha, chroma siting, color range, and plane layout assumptions.
- Add server-side rejection for formats unavailable on the current macOS/VideoToolbox runtime.
- Update FFmpeg option/help output where pixel-format lists are surfaced.

Design constraints:
- `p210` support must preserve 10-bit semantics and not silently degrade to 8-bit.
- `ayuv` and `bgra` must preserve alpha behavior where the codec/path supports it.
- Do not advertise a format unless both client wire mapping and server VideoToolbox mapping are implemented.

Suggested files:
- `ffmpeg/libavcodec/vtremote_pixfmt*`
- `ffmpeg/libavcodec/vtremote_enc_common.c`
- `ffmpeg/libavcodec/vtremote_decode*.c`
- `vtremoted/Sources/VTRemotedCore/*Pixel*`
- `tests/integration/run_*hevc*pixel*.sh`

Acceptance criteria:
- `hevc_videotoolbox_remote` accepts `bgra`, `ayuv`, and `p210` only when negotiated support exists.
- Unsupported runtime/format combinations fail clearly.
- At least one real-server encode/transcode test exists for each newly advertised format, or the format remains disabled behind capability detection until testable.
- Pixel-format negotiation is covered by mock tests and real `srv4` tests.

Validation:

```bash
FFMPEG_BIN=$PWD/ffmpeg/ffmpeg bash tests/integration/run_vtremoted_hevc_pixfmts.sh
FFMPEG_BIN=$PWD/ffmpeg/ffmpeg bash tests/integration/run_mock_hevc_pixfmt_negotiation.sh
```

## 5. Expanded Side-Data Forwarding

Problem:
Remote pipelines must preserve metadata that local FFmpeg and VideoToolbox users rely on for correct display, HDR signaling, alpha handling, and packet semantics. `0.4.0` covers important cases, but the side-data forwarding surface should be broader and explicitly tested.

Implementation:
- Inventory current frame-side and packet-side side-data handling by path:
  - encode
  - decode
  - transcode bitstream filter
  - OBS plugin client path where applicable
- Add protocol representations for required side-data classes, including:
  - mastering display metadata
  - content light level metadata
  - HDR10+/dynamic HDR metadata where FFmpeg exposes it and the path can preserve it
  - display matrix/orientation where relevant
  - alpha mode or alpha-related metadata where represented by FFmpeg
  - color range, primaries, transfer, matrix, chroma location, and sample aspect ratio when not already carried elsewhere
  - A53/closed-caption data where packet side data needs to survive transcode
  - packet timing and dependency metadata needed by DTS/PTS correctness tests
- Define pass-through, translate, and intentionally-drop behavior for every side-data class.
- Log intentionally dropped side data at debug level with a stable reason.
- Add mock tests that assert exact side-data round-trips.

Design constraints:
- Side-data forwarding must not create malformed output when the destination codec/container cannot represent the metadata.
- Do not silently transform metadata between incompatible representations.
- Keep unknown side data behavior explicit: either pass opaque bytes with a type tag when safe, or reject/drop with a documented reason.

Suggested files:
- `ffmpeg/libavcodec/vtremote_side_data*`
- `ffmpeg/libavcodec/vtremote_enc_common.c`
- `ffmpeg/libavcodec/vtremote_decode*.c`
- `ffmpeg/libavcodec/bsf/vtremote_transcode*.c`
- `vtremoted/Sources/VTRemotedCore/*SideData*`
- `tests/integration/run_mock_side_data_roundtrip.sh`
- `tests/integration/run_vtremoted_hdr_side_data.sh`

Acceptance criteria:
- Existing HDR signaling tests continue to pass.
- New side-data tests prove preservation for each supported side-data class.
- Unsupported or intentionally dropped side data has documented behavior and debug logs.
- Transcode path preserves side data needed for HEVC `hvc1` HDR signaling.

Validation:

```bash
bash tests/integration/run_mock_side_data_roundtrip.sh
FFMPEG_BIN=$PWD/ffmpeg/ffmpeg bash tests/integration/run_vtremoted_hdr_side_data.sh
bash tests/integration/run_mock_transcode_hvc1_hdr_signaling.sh
```

## 6. Linux FFmpeg Build Guardrails

Problem:
Some users may report failures as "FFmpeg x86 assembly" failures. Our `linux-x86_64` CI passes, but user environments can differ by assembler version, distro, CPU target, or 32-bit vs 64-bit toolchain.

Implementation:
- Document that supported Linux artifacts are `x86_64`, not 32-bit `i686`.
- Add a troubleshooting section for assembler failures:
  - install `nasm` and `yasm`
  - check `nasm -v` and `yasm --version`
  - clean/reconfigure after installing tools
  - use `--disable-x86asm` as a confirmation workaround
- Add a Makefile-friendly opt-in flag for the workaround.

Makefile interface:

```bash
make build-ffmpeg FFMPEG_DISABLE_X86ASM=1
```

Behavior:
- When `FFMPEG_DISABLE_X86ASM=1`, append `--disable-x86asm` to `FFMPEG_CONFIGURE_FLAGS` unless already present.
- Do not make this the default.
- Keep CI's normal Linux build using x86 assembly.

Suggested files:
- `Makefile`
- `docs/troubleshooting.md`
- `docs/development.md`
- `README.md`

Acceptance criteria:
- Normal `make build-ffmpeg` still configures with x86 assembly where supported.
- `make build-ffmpeg FFMPEG_DISABLE_X86ASM=1` configures with `--disable-x86asm`.
- Docs include exact commands for both the normal fix and fallback build.
- CI still passes `FFmpeg (linux-x86_64)`.

Validation:

```bash
make clean-ffmpeg
make build-ffmpeg FFMPEG_DISABLE_X86ASM=1
./ffmpeg/ffmpeg -hide_banner -encoders | grep h264_videotoolbox_remote
./ffmpeg/ffmpeg -hide_banner -decoders | grep h264_videotoolbox_remote
./ffmpeg/ffmpeg -hide_banner -bsfs | grep vtremote_transcode
```

## 7. macOS Server Install and Upgrade Hygiene

Problem:
Updating `vtremoted` on a live Mac can involve multiple launchd jobs and multiple binary paths. On `srv4`, user LaunchAgents and a root LaunchDaemon can point at different binaries.

Implementation:
- Add a documented "upgrade an existing server" flow.
- Add a script or Makefile target to install and restart `vtremoted` predictably.
- Include a verification command that checks:
  - binary checksums
  - launchd program path
  - listening ports
  - active process command lines

Target:

```bash
make install-vtremoted-restart VTREMOTED_LISTEN=0.0.0.0:5555
```

Design constraints:
- Do not assume passwordless `sudo`.
- Support user LaunchAgent installs without sudo.
- Support system LaunchDaemon installs when the operator explicitly uses sudo.
- Never silently change a root-owned daemon from a user-only command.
- Print exact follow-up commands when privilege is required.

Suggested files:
- `Makefile`
- `vtremoted/install_launchd.sh`
- `docs/getting-started.md`
- `docs/troubleshooting.md`
- `scripts/generate_release_notes.sh`

Acceptance criteria:
- Fresh user-level install works.
- Reinstall/restart of an existing user LaunchAgent works.
- System LaunchDaemon path gives a clear sudo-required command if not root.
- Docs include a "verify running version" section.

Validation:

```bash
make build-vtremoted
make install-vtremoted-restart VTREMOTED_LISTEN=0.0.0.0:5555
launchctl print "gui/$(id -u)/com.davelindon.vtremoted"
pgrep -fl vtremoted
lsof -nP -iTCP:5555 -sTCP:LISTEN
shasum -a 256 vtremoted/.build/release/vtremoted "$(command -v vtremoted)"
```

## 8. Release Artifact Smoke Checks

Problem:
CI builds artifacts, but the release process should prove the uploaded tarballs are usable after packaging, not only that the build job completed.

Implementation:
- Add a post-package smoke step for each artifact before upload.
- For FFmpeg artifacts:
  - unpack staged tarball into a temp directory
  - run `ffmpeg -version`
  - verify remote encoders are listed
  - verify remote decoders are listed
  - verify `vtremote_transcode` bitstream filter is listed
  - verify quality filters still exist where expected (`psnr`, `ssim`, `libvmaf`)
- For `vtremoted` artifacts:
  - unpack staged tarball
  - run `vtremoted --help` and `vtremoted --version` without binding a socket

Suggested files:
- `.github/workflows/ci.yml`
- `scripts/smoke_release_artifact.sh`
- `vtremoted` CLI entry point

Acceptance criteria:
- Tag CI fails before upload if a packaged FFmpeg artifact lacks vtremote codecs or BSF.
- Tag CI verifies artifact contents from the tarball, not just the build directory.
- `v0.4.1` release notes can say artifacts were smoke-tested after packaging.

Validation:

```bash
bash scripts/smoke_release_artifact.sh ffmpeg ffmpeg-linux-x86_64.tar.gz
bash scripts/smoke_release_artifact.sh vtremoted vtremoted-macos-arm64.tar.gz
```

## 9. Mock and Protocol Test Hardening

Problem:
Mock tests should be explicit about whether they are testing framing, compression, side data, hardware frames, protocol capabilities, or real server behavior. `0.4.0` exposed places where mock tests accidentally depended on defaults.

Implementation:
- Keep framing-only mock tests pinned to `-vt_remote_wire_compression none`.
- Add a separate mock compression validation test for LZ4 and Zstd if not already explicit enough.
- Add mock capability-negotiation tests for all new 0.4.1 protocol surfaces.
- Add side-data round-trip tests with exact expected metadata.
- Add hardware-frame negotiation tests that cover supported, fallback, and rejected paths.
- Ensure Bash scripts are compatible with macOS Bash 3.2 under `set -u`.
- Add a small style rule to avoid unguarded empty-array expansion in integration scripts.

Suggested files:
- `tests/integration/run_mock_roundtrip.sh`
- `tests/integration/run_mock_pts_dts_semantics.sh`
- `tests/integration/run_complex_chain_test.sh`
- `tests/integration/run_transcode_test.sh`
- `tests/integration/run_mock_transcode_hvc1_hdr_signaling.sh`
- `tests/integration/run_mock_wire_compression.sh`
- `tests/integration/run_mock_protocol_capabilities.sh`
- `tests/integration/run_mock_side_data_roundtrip.sh`
- `tests/integration/README.md`

Acceptance criteria:
- `tests/integration/run_all.sh` passes on macOS.
- Linux mock subset passes in CI.
- Mock framing tests do not depend on automatic compression choices.
- Compression, capability negotiation, side-data forwarding, and hardware-frame negotiation are covered by named tests.

Validation:

```bash
bash -n tests/integration/*.sh
tests/integration/run_all.sh
```

## 10. Documentation and Release Notes

Implementation:
- Update `README.md` with high-signal user-facing notes for the expanded 0.4.1 feature surface.
- Put detailed commands and compatibility caveats in docs pages.
- Document hardware-frame behavior, including when a fallback copy is possible and when a request fails.
- Document supported HEVC pixel formats and runtime capability caveats.
- Document side-data classes that are preserved, translated, dropped, or unsupported.
- Update generated release notes template so `0.4.1` release notes include:
  - hardware-frame ingest/output
  - expanded HEVC pixel-format support
  - side-data forwarding improvements
  - protocol capability negotiation
  - build fallback for x86 assembly failures
  - server upgrade verification
  - supported artifact/platform list
  - link to troubleshooting

Suggested files:
- `README.md`
- `docs/getting-started.md`
- `docs/development.md`
- `docs/troubleshooting.md`
- `docs/architecture.md`
- `scripts/generate_release_notes.sh`
- `CHANGELOG.md`

Acceptance criteria:
- A user can tell which 0.4.1 pipeline features require a 0.4.1 server.
- A user can recover from the common Linux assembler failure from docs alone.
- A user can verify a running server binary after upgrade.
- Release notes point to the correct docs and artifact names.

## 11. CI and Release Process

Implementation:
- Ensure tag CI is green before announcing a release.
- Preserve the current matrix:
  - `FFmpeg (linux-x86_64)`
  - `FFmpeg (windows-x86_64)`
  - `FFmpeg (macos-x86_64)`
  - `FFmpeg (macos-arm64)`
  - `Swift (vtremoted) macOS arm64`
  - `Swift (vtremoted) macOS x86_64`
  - `OBS plugin tests (Linux)`
- Add artifact smoke checks as described above.
- Add targeted CI coverage for mock capability, side-data, pixel-format negotiation, and wire compression tests.
- Consider gating release asset publishing on all artifact smoke checks.

Acceptance criteria:
- PR CI green.
- Main CI green after squash merge.
- Tag CI green after `v0.4.1` tag.
- Release assets published only after artifact smoke passes.

## Implementation Order

1. Update protocol capability model and mock strict-mode parsing.
2. Add side-data inventory and protocol representation before adding new media paths.
3. Add HEVC pixel-format mapping and negotiation for `bgra`, `ayuv`, and `p210`.
4. Implement hardware-frame ingest for encode/transcode with explicit fallback behavior.
5. Implement decoder hardware-frame output negotiation and frame ownership handling.
6. Add mock and real-server tests for capabilities, pixel formats, side data, and hardware frames.
7. Add Makefile Linux x86asm fallback and Linux build docs.
8. Add artifact smoke script and wire it into CI packaging steps.
9. Add or improve `vtremoted --version` / `--help` for artifact smoke.
10. Improve install/restart docs and helper target.
11. Add mock compression test and Bash 3.2 cleanup.
12. Update release notes/changelog.
13. Run local and `srv4` validation.
14. Open PR, wait for full CI, squash merge, tag `v0.4.1`.

## Validation Checklist

Local:

```bash
git diff --check
bash -n tests/integration/*.sh
make build-ffmpeg
make build-ffmpeg FFMPEG_DISABLE_X86ASM=1
```

Linux mock subset:

```bash
bash tests/integration/run_mock_roundtrip.sh
bash tests/integration/run_mock_decode.sh
bash tests/integration/run_mock_pts_dts_semantics.sh
bash tests/integration/run_mock_transcode_pts_dts_semantics.sh
bash tests/integration/run_mock_transcode_hvc1_hdr_signaling.sh
bash tests/integration/run_mock_wire_compression.sh
bash tests/integration/run_mock_protocol_capabilities.sh
bash tests/integration/run_mock_side_data_roundtrip.sh
bash tests/integration/run_mock_hevc_pixfmt_negotiation.sh
```

macOS server on `srv4`:

```bash
make build-ffmpeg
make build-vtremoted
vtremoted/.build/release/vtremoted --version
vtremoted/.build/release/vtremoted --help
FFMPEG_BIN=$PWD/ffmpeg/ffmpeg bash tests/integration/run_vtremoted_hardware_ingest.sh
FFMPEG_BIN=$PWD/ffmpeg/ffmpeg bash tests/integration/run_vtremoted_transcode_hardware_ingest.sh
FFMPEG_BIN=$PWD/ffmpeg/ffmpeg bash tests/integration/run_vtremoted_decode_hardware_output.sh
FFMPEG_BIN=$PWD/ffmpeg/ffmpeg bash tests/integration/run_vtremoted_hevc_pixfmts.sh
FFMPEG_BIN=$PWD/ffmpeg/ffmpeg bash tests/integration/run_vtremoted_hdr_side_data.sh
VTREMOTED=$PWD/vtremoted/.build/release/vtremoted FFMPEG_BIN=$PWD/ffmpeg/ffmpeg bash tests/integration/run_all.sh
```

macOS install verification:

```bash
make install-vtremoted-restart VTREMOTED_LISTEN=0.0.0.0:5555
launchctl print "gui/$(id -u)/com.davelindon.vtremoted"
pgrep -fl vtremoted
lsof -nP -iTCP:5555 -sTCP:LISTEN
```

Release artifacts:

```bash
bash scripts/smoke_release_artifact.sh ffmpeg ffmpeg-linux-x86_64.tar.gz
bash scripts/smoke_release_artifact.sh vtremoted vtremoted-macos-arm64.tar.gz
```

CI:

```bash
gh pr checks --watch
gh run list --limit 10
gh run view <run-id> --json jobs,conclusion,status
```

## Risks

- Hardware-frame ingest/output can imply zero-copy semantics that are not valid across hosts. The implementation must be explicit about true hardware transfer, fallback copy, or unsupported paths.
- New protocol capabilities must stay backward-compatible with `0.4.0` servers and fail during configure for unsupported 0.4.1 features.
- New HEVC pixel formats can silently lose bit depth or alpha if mapped incorrectly. Tests must prove format identity and metadata preservation.
- Side-data forwarding can produce invalid output if metadata is copied into incompatible codec/container contexts. Unsupported cases must be documented and tested.
- `--disable-x86asm` can reduce FFmpeg performance. It should be documented as a diagnostic or compatibility fallback, not a recommended default.
- launchd install helpers can accidentally affect the wrong domain if user vs system mode is unclear. Keep commands explicit and print the resolved domain/path.
- Artifact smoke checks can make CI longer. Keep them cheap and focused on unpacking plus feature presence.
- Adding `vtremoted --version` should not change server startup behavior or existing flags.

## Release Criteria

`v0.4.1` is ready when:
- Protocol capability negotiation covers all new 0.4.1 media surfaces.
- Hardware-frame ingest is implemented or explicitly rejected with negotiated fallback behavior for encode and transcode paths.
- Decoder hardware-frame output is implemented for supported callers or fails clearly during configure.
- HEVC `bgra`, `ayuv`, and `p210` support is implemented behind real server capability checks.
- Supported side-data classes are forwarded with tests; unsupported classes have documented behavior.
- Real `srv4` tests cover the new hardware-frame, HEVC pixel-format, and side-data paths.
- Linux build fallback is documented and implemented.
- Artifact smoke checks are active in CI.
- Server upgrade docs are tested on a real macOS host.
- Mock integration tests are explicit and Bash-3.2-safe.
- `CHANGELOG.md` has a `v0.4.1` entry that reflects both pipeline parity and hardening work.
- PR, main, and tag CI all pass.
