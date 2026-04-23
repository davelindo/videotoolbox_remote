# Changelog

All notable changes to this project are documented in this file.

The format follows Keep a Changelog principles, using repository release tags (`v*`) in reverse chronological order.
The non-version `nightly` tag is intentionally excluded.

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
