# Changelog

All notable changes to this project are documented in this file.

The format follows Keep a Changelog principles, using repository release tags (`v*`) in reverse chronological order.
The non-version `nightly` tag is intentionally excluded.

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
