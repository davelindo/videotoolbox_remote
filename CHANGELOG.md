# Changelog

All notable changes to this project are documented in this file.

The format follows Keep a Changelog principles, using repository release tags (`v*`) in reverse chronological order.
The non-version `nightly` tag is intentionally excluded.

## [Unreleased]

## [v0.5.1] - 2026-05-23

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `aa08cf8112c5` (from `2e142e52ae8b`).

## [v0.5.0] - 2026-05-22

### Changed
- Bumped the packaged `vtremoted --version` output to `0.5.0`.

### Fixed
- Prevented `vtremote_transcode` from wedging with ACK-capable servers when corrupt compressed input packets are consumed by the remote decoder without producing output frames.

## [v0.4.12] - 2026-05-22

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `2e142e52ae8b` (from `085714182302`).

## [v0.4.11] - 2026-05-21

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `085714182302` (from `1572784128c1`).

## [v0.4.10] - 2026-05-19

### Changed
- Bumped the packaged `vtremoted --version` output to `0.4.10`.
- Shared the SIGPIPE-safe FFmpeg decoder probe used by speed decode integration scripts.

### Fixed
- Released partially populated FFmpeg decode frames when VideoToolbox hardware-frame output or compressed software-frame population fails after buffer allocation.
- Treated interrupted POSIX `poll()` and blocking `connect()` calls as recoverable where the underlying socket operation can continue.
- Avoided unaligned big-endian integer reads in the OBS plugin wire client.
- Preserved P010 OBS encoder input when the active OBS video output is P010.

## [v0.4.9] - 2026-05-19

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `1572784128c1` (from `b4d11dffbf25`).

## [v0.4.8] - 2026-05-18

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `b4d11dffbf25` (from `239c679c5469`).

## [v0.4.7] - 2026-05-17

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `239c679c5469` (from `2aad4fb2e37c`).

## [v0.4.6] - 2026-05-16

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `2aad4fb2e37c` (from `b2867481d95b`).

## [v0.4.5] - 2026-05-15

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `b2867481d95b` (from `a327bc056124`).

## [v0.4.4] - 2026-05-14

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `a327bc056124` (from `4851060ccd28`).

## [v0.4.3] - 2026-05-13

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `4851060ccd28` (from `6b3e0f903e08`).

## [v0.4.2] - 2026-05-12

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `6b3e0f903e08` (from `17bc88e67feb`).

## [v0.4.1] - 2026-05-11

### Added
- Added expanded 0.4.1 protocol capability negotiation for hardware-frame ingest, decoder hardware-frame output, HEVC `bgra`/`ayuv`/`p210le`, and typed frame/packet side-data surfaces.
- Added PACKET side-data forwarding across remote decode and `vtremote_transcode`, complementing the existing frame-side metadata path for HDR/colorimetry and mux-facing metadata.
- Added mock protocol tests for strict capability rejection, exact side-data round-trips, and HEVC extended pixel-format negotiation.
- Added real `vtremoted` coverage for hardware-frame encode ingest, hardware-frame transcode ingest, decoder hardware-frame output, HEVC `bgra`/`ayuv`/`p210le`, and HDR color-signaling preservation.
- Added `FFMPEG_DISABLE_X86ASM=1` as a documented compatibility fallback for Linux environments with broken or unsupported FFmpeg x86 assembler toolchains.
- Added `vtremoted --help` and `vtremoted --version` so packaged server artifacts can be checked without binding a socket.
- Added CI artifact smoke checks that unpack packaged FFmpeg and `vtremoted` tarballs before upload and verify the expected vtremote feature surface.
- Added explicit mock coverage for LZ4 and Zstd frame-payload compression.
- Added a `make install-vtremoted-restart` workflow and launchd verification output for macOS server upgrades.

### Changed
- Expanded `tests/integration/run_all.sh` so the standard macOS suite exercises the new capability, side-data, hardware-frame, and HEVC pixel-format checks.
- Updated protocol, architecture, README, development, and integration-test documentation for the expanded 0.4.1 media surface and compatibility gates.
- Updated Linux build, macOS install, troubleshooting, and release-note documentation with concrete recovery and verification commands.
- Made release notes call out x86 assembly build fallback guidance and packaged-artifact smoke validation.

### Fixed
- Preserved packet side data returned by remote encode/decode/transcode sessions instead of dropping optional trailing PACKET metadata.
- Kept 0.4.1-only media requests behind configure-time capability checks so older or reduced-capability servers fail clearly before frame processing.
- Kept framing-only mock tests isolated from automatic wire-compression defaults by testing compressed-frame behavior in a dedicated script.
- Hardened launchd installer output so user vs system service domains, binary paths, and verification commands are explicit.

## [v0.4.0] - 2026-05-11

### Added
- Added remote encoder hardware-frame ingest for local `AV_PIX_FMT_VIDEOTOOLBOX` inputs.
- Added optional remote decoder hardware-frame output with `-vt_remote_output_hw_frames 1`.
- Added HEVC remote encode support for `bgra`, `ayuv`, and `p210le` input paths.
- Added protocol capability advertising and parsing for expanded pixel formats, VideoToolbox hardware-frame input/output, and typed frame side-data records.
- Added real `vtremoted` integration coverage for HEVC pixel-format parity, hardware-frame ingest, and hardware-frame decoder output.

### Changed
- Generalized FFmpeg and Swift frame-plane handling beyond the original two-plane NV12/P010 assumptions.
- Expanded frame side-data forwarding on the FFmpeg client side with allowlisted metadata types and bounded payload size.
- Made server capability advertisement reflect the active backend so non-VideoToolbox builds do not claim unsupported hardware-frame or extended pixel-format support.
- Updated protocol, mock-server, integration, and README parity documentation for the v0.4.0 pipeline-parity surface.

### Fixed
- Added client-side capability gates so unsupported server pixel formats or hardware-frame paths fail before CONFIGURE with clearer diagnostics.
- Validated caller-provided VideoToolbox hardware frame/device contexts before decoder hardware-frame output setup.
- Avoided retaining unused per-frame side-data copies in the Swift server encode path.

## [v0.3.19] - 2026-05-11

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `17bc88e67feb` (from `5bbc00c05d6e`).

## [v0.3.18] - 2026-05-10

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `5bbc00c05d6e` (from `8518599cd135`).

## [v0.3.17] - 2026-05-09

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `8518599cd135` (from `ff0ad0278d6f`).

## [v0.3.16] - 2026-05-08

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `ff0ad0278d6f` (from `f2e5eff3ff21`).

## [v0.3.15] - 2026-05-07

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `f2e5eff3ff21` (from `17734f696752`).

## [v0.3.14] - 2026-05-06

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `17734f696752` (from `7fc335cb2770`).

## [v0.3.13] - 2026-05-05

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `7fc335cb2770` (from `b40d91cad92f`).

## [v0.3.12] - 2026-05-04

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `b40d91cad92f` (from `702b0784b73d`).

## [v0.3.11] - 2026-05-03

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `702b0784b73d` (from `dba0b078c810`).

## [v0.3.10] - 2026-05-02

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `dba0b078c810` (from `a7d42bfba8bb`).

## [v0.3.9] - 2026-05-01

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `a7d42bfba8bb` (from `cc3ca1712760`).

## [v0.3.8] - 2026-04-30

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `cc3ca1712760` (from `7c67748537d9`).

## [v0.3.7] - 2026-04-29

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `7c67748537d9` (from `3cdd76ba96ab`).

## [v0.3.6] - 2026-04-28

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `3cdd76ba96ab` (from `4867d251ade4`).

## [v0.3.5] - 2026-04-27

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `4867d251ade4` (from `e717604a2999`).

## [v0.3.4] - 2026-04-26

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `e717604a2999` (from `45fe315cf02c`).

## [v0.3.3] - 2026-04-24

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `45fe315cf02c` (from `08f56d4898ea`).

## [v0.3.2] - 2026-04-23

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `08f56d4898e` (from `9c63742425a`).
- Aligned the remote H.264 and HEVC encoder descriptors with upstream wrapper metadata expectations.

### Fixed
- Replaced deprecated `av_init_packet()` usage in `vtremote_transcode` with packet zero-initialization compatible with newer FFmpeg.

### CI
- Scheduled nightly runs now rebuild only when artifact-affecting inputs changed or the existing nightly assets are missing.
- Added a `nightly-main` tag that tracks the latest `main` commit separately from the built `nightly` artifact tag, keeping nightly source archives aligned with the published binaries.
- Expanded FFmpeg CI smoke coverage for the remote codecs and `vtremote_transcode`, and added Linux mock regressions for PTS/DTS and HDR/hvc1 transcode behavior.

## [v0.3.1] - 2026-04-09

### Added
- Added mock `vtremote_transcode` HDR signaling regression coverage with fixture-backed HEVC Main 10 `hvcC`/packet payloads.
- Added fixture provenance and regeneration notes for the mock HEVC HDR payloads.

### Changed
- Improved mock transcode integration coverage to verify:
  - explicit `hvc1`/HDR override forwarding
  - source-metadata preservation without explicit overrides
  - MP4 `nclx` container metadata in the generated init segment
  - CLI color-option alias handling, including `colorspace=rgb`
- Updated integration scripts that generate local `h264_videotoolbox` `nv12` inputs to set limited-range color metadata explicitly.

### Fixed
- Fixed `vtremote_transcode` output signaling to preserve HEVC `hvc1` tagging and HDR color metadata on mux-facing output parameters.
- Fixed `vtremote_transcode` codec-tag handling to apply MP4-style defaults only for MP4/fMP4 outputs instead of forcing `avc1`/`hvc1` onto non-MP4 muxers.
- Fixed `vtremote_transcode` color-option forwarding to accept the same FFmpeg CLI enum aliases as normal codec option parsing.
- Fixed `vtremote_transcode` explicit color-option validation to reject invalid numeric enum values instead of silently dropping unsupported metadata.
- Fixed `vtremote_transcode` colorspace handling so valid enum value `0` (`rgb`/GBR) is no longer treated as “unset”.
- Fixed mock fixture loading to fail early on oversized protocol payloads instead of erroring later during packet assembly.

## [v0.3.0] - 2026-03-24

### Fixed
- Fixed missing `inet_pton` return value check in OBS plugin client, preventing confusing errors on invalid addresses.
- Fixed potential NULL dereference in OBS encoder when video output is not yet attached.
- Improved `read_exact` in OBS plugin client to distinguish disconnection from errors and retry on transient failures (EAGAIN/EINTR).
- Added warning log when side-data allocation fails during remote decode, preventing silent metadata loss.
- Fixed hardcoded 2-plane assumption in `fill_frame_from_view`; now copies all planes reported by the remote server.
- Replaced force unwraps on `baseAddress!` in Swift server decode/encode paths with safe guards, preventing crashes on malformed zero-length payloads.
- Replaced unsynchronized Swift Array with `UnsafeMutableBufferPointer` for concurrent plane error collection, eliminating potential data race.

### CI
- Added `swift test` step to both macOS arm64 and x86_64 CI jobs, enabling the 38 existing unit tests that were previously not run in CI.
- Added `timeout-minutes` to Swift (15 min) and FFmpeg (45 min) build jobs to prevent runaway CI usage.
- Added mock-based integration tests (`run_mock_roundtrip.sh`, `run_mock_decode.sh`) to the Linux FFmpeg CI build.

## [v0.2.10] - 2026-03-22

### Added
- Added GitHub metadata and release-note maintenance helpers:
  - `scripts/sync_github_metadata.sh`
  - `scripts/generate_release_notes.sh`
  - `scripts/apply_release_notes.sh`

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `9c63742425` (from `5ba2525c7af`).
- Improved README, getting-started, and development docs for GitHub discovery and release onboarding.

### Fixed
- Fixed remote encoder drain/flush handling to tolerate a peer close after `DONE` and avoid redundant `FLUSH` sends against one-shot peers.
- Bounded OBS integration runner hangs during local and CI test runs.

### CI
- Fixed nightly publish gating in GitHub Actions.
- Updated OBS integration CI to run under `xvfb`.

## [v0.2.9] - 2026-03-19

### Added
- Added a real `libobs`-backed OBS plugin integration test:
  - `tests/integration/obs_plugin_integration.cpp`
  - `tests/integration/run_obs_plugin_integration.sh`
- Added `make test-obs-plugin-integration`.

### Changed
- Expanded OBS plugin test coverage and docs to include both client smoke validation and full encoder lifecycle integration coverage.
- Updated OBS plugin build/test wiring to support `libzstd` and `libobs` discovery across CI and local environments.

### Fixed
- Fixed the OBS plugin `wire_compression=Zstd` path to actually Zstd-compress frame payloads instead of sending raw bytes.
- Hardened OBS plugin receive paths against oversized peer-controlled message bodies before allocation.

### CI
- Updated the Linux OBS plugin job to install `libzstd-dev` and `libobs-dev` and run both the smoke and `libobs` integration tests.

## [v0.2.8] - 2026-02-25

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `5ba2525c7af` (from `33b215d1554`).
- Includes upstream FFmpeg changes in this range only; no additional project-specific behavior changes were introduced in this release.

## [v0.2.7] - 2026-02-25

### Changed
- Aligned remote `max_ref_frames` handling with local VideoToolbox behavior: unsupported `ReferenceBufferCount` is now best-effort (warning) instead of a fatal configure error.

### Fixed
- Fixed HEVC Main10 remote upload conversion for `yuv420p10le`/`yuv420p10be` inputs by packing 10-bit samples into P010's high bits. This resolves severe bitrate/fidelity collapse observed on remote Main10 sweeps.

## [v0.2.6] - 2026-02-24

### Added
- Added integration option-surface parity check:
  - `tests/integration/run_option_surface_parity.sh`
- Added optional run-all toggle to execute encoder option parity checks:
  - `VTREMOTE_RUN_OPTION_PARITY=1`

### Changed
- Expanded remote encoder accepted software input formats to align with local VideoToolbox 4:2:0 paths:
  - `h264_videotoolbox_remote`: `nv12`, `yuv420p`
  - `hevc_videotoolbox_remote`: `nv12`, `yuv420p`, `p010le`, `yuv420p10le`, `yuv420p10be`
- Added upload-frame conversion in the remote encoder path for supported 4:2:0 software inputs (to NV12/P010 wire-ready layouts).
- Updated docs to include parity status and backlog.

### Fixed
- Fixed 10-bit big-endian (`yuv420p10be`) software upload conversion to correctly produce little-endian P010 wire data.
- Fixed raw-wire bandwidth estimation and configure wire pixel-format selection to follow the effective remote upload format.

## [v0.2.5] - 2026-02-20

### Added
- Added experimental OBS plugin source tree under `obs-plugin/`.
- Added OBS plugin client smoke test harness:
  - `tests/integration/run_obs_plugin_client_mock.sh`
  - `tests/integration/obs_plugin_client_smoke.cpp`
  - `tests/integration/obs_plugin_test_stubs/obs-module.h`
- Added `make test-obs-plugin` convenience target.
- Added dedicated OBS plugin documentation (`docs/obs-plugin.md` and `obs-plugin/README.md`).

### Changed
- Updated docs and integration references to include OBS plugin support and testing entry points.
- Updated buffer-pool reuse behavior in `BufferPool` to clear returned `Data` with `removeAll(keepingCapacity:)`.
- Simplified best-fit fallback path in `BufferPool.get(capacity:)`.
- Aligned `TimestampTracker` baseline test expectations with current PTS/DTS semantics.

### Fixed
- Fixed OBS plugin `CONFIGURE` option encoding to use length-prefixed UTF-8 key/value pairs expected by `vtremoted`.
- Fixed OBS plugin `CONFIGURE_ACK` parsing (status + extradata length/body handling).
- Hardened Python mock parsing for strict CONFIGURE payload validation and bounds checks.

### CI
- Added `obs-plugin-smoke` Linux job in GitHub Actions.
- Added `obs_plugin` change detection in CI path filters to trigger plugin smoke validation when relevant files change.

## [v0.2.4] - 2026-02-17

### Changed
- Completed incremental nonblocking receive handling in `ffmpeg/libavcodec/bsf/vtremote_transcode.c`, including persistent header/payload read state.
- Unified blocking and nonblocking message reads behind a shared internal receive path.
- Tightened packet queue hot paths in the transcode BSF by removing avoidable wrap/ref overhead.
- Refined `VTRClientHandler` output accounting with a dedicated fast-path byte-count helper.
- Reduced small-frame overhead in `VideoToolboxCodecSession` by using adaptive serial vs parallel plane compression.

### Fixed
- Reset receive-state lifecycle consistently across transcode init, handshake, flush, and close paths.
- Improved buffer-pool exact-fit reuse behavior to reduce unnecessary search/work.
- Avoided repeated pointer closure setup in `POSIXIO.readExact` for cleaner low-level read loop behavior.

## [v0.2.3] - 2026-02-16

### Changed
- Optimized vtremote hot paths in both `ffmpeg` and `vtremoted`.
- Reduced overhead in reorder-buffer and wire-connection internals.
- Tuned decoded-frame pipeline behavior in VideoToolbox session handling for higher throughput.

## [v0.2.2] - 2026-02-16

### Added
- Added `tests/integration/run_realtime_encode.sh`.
- Added `tests/integration/run_quality_compare.sh`.

### Changed
- Refactored vtremote codec flow across client/server paths.
- Simplified message, configuration, and buffer-management code in `vtremoted` core components.
- Refactored `ffmpeg/libavcodec/bsf/vtremote_transcode.c` for clearer flow and easier maintenance.

## [v0.2.1] - 2026-02-16

### Changed
- Rebased the `ffmpeg/` subtree to upstream master snapshot `33b215d155` (from `80a3ba7d79`).
- This release contains FFmpeg subtree synchronization only.

## [v0.2.0] - 2026-02-07

### Added
- Added long-running transcode BSF regression coverage.
- Added stronger timestamp and muxer-warning validation in integration tests.
- Added mock transcode PTS/DTS semantics regression coverage.

### Changed
- Improved end-to-end PTS/DTS semantics handling across encode, decode, and transcode paths.
- Hardened integration scripts for long-run and edge-case timestamp scenarios.

### Fixed
- Fixed transcode flush ordering in `VideoToolboxCodecSession`.
- Fixed reorder-mode DTS timing to avoid muxer `dts > pts` rewrites.
- Fixed long transcode BSF host/port parsing in test tooling.
- Fixed local ffmpeg detection/fallback behavior in decode integration tests.

## [v0.1.1] - 2026-02-06

### Changed
- Enabled broader default codec feature set in build configuration (including libvmaf and AV1 stack support).

### CI
- Updated Linux CI to build `libvmaf` from source.
- Pinned source-built `libvmaf` to `v3.0.0`.
- Updated Linux CI to build `svt-av1` from source.

## [v0.1.0] - 2026-02-05

### Added
- Added vtremote transcode mode and related CLI/configuration path.
- Added non-blocking send queue in the vtremote encoder path.
- Added automatic wire-compression selection and adaptive inflight behavior.
- Added configurable zstd wire-compression controls (level/workers).
- Expanded integration workflows for decode, transcode, speed, and benchmarking.

### Changed
- Set default wire compression to LZ4.
- Improved vtremoted throughput with I/O, buffer, and processing-path optimizations.
- Improved macOS build/configure behavior for compiler/sysroot/pkg-config handling.
- Reorganized project documentation and README structure.

### Fixed
- Fixed remote HEVC frame-loss and FRAME payload streaming issues.
- Fixed handshake send-queue cleanup behavior.
- Fixed payload buffer leak.
- Fixed launchd install behavior in edge cases.
- Fixed shell compatibility issues in integration scripts (including Bash 3.2 and nounset paths).

## [v0.0.0] - 2026-02-06

### Added
- Initial monorepo import.
- Initial baseline for `ffmpeg/` subtree with VideoToolbox Remote integration.
- Initial baseline for `vtremoted/` server implementation.
- Initial baseline for integration test harness and project docs.
