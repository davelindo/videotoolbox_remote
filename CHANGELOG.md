# Changelog

All notable changes to this project are documented in this file.

The format follows Keep a Changelog principles, using repository release tags (`v*`) in reverse chronological order.
The non-version `nightly` tag is intentionally excluded.

## [Unreleased]

## [v0.8.2] - 2026-09-06

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `f93cd72dde30` (from `9997fd060680`).

## [v0.8.1] - 2026-09-05

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `9997fd060680` (from `818e5d965be9`).

## [v0.8.0] - 2026-09-04

### Added

- Added an in-tree Linux x86_64 VA-API encode driver for H.264 and HEVC,
  including Main 10/P010, CBR/VBR/CQP rate control, LZ4/Zstandard/automatic
  wire compression, an experimental static C SDK, release packaging, and stock
  FFmpeg integration tests.
- Added a Plex-specific FFmpeg 6 bitstream-filter shim and container image that
  send compressed H.264 or HEVC packets to `vtremoted` for remote decode,
  scale, and encode. The release includes automated unclaimed-server coverage
  and an opt-in claimed-server playback smoke. The Plex path does not require
  a Linux GPU or render node.

### Fixed

- Recognized the SDR VA-API upload/scale/upload graph emitted by Plex 1.43.4,
  including H.264 and HEVC output, while leaving unsupported HDR tone-mapping
  graphs on Plex's native path.
- Treated Plex's disabled A53 closed-caption option as a no-op instead of
  rejecting an otherwise supported remote transcode.
- Converted the encoder configuration returned by `vtremoted` to Annex-B
  parameter sets and included them on keyframes, making VA-API H.264 and HEVC
  output independently decodable.
- Released client buffers after failed handshakes so reconnecting through the
  experimental C SDK does not leak retry allocations.
- Kept fixed-level HEVC Plex requests on the native path because
  VideoToolbox exposes only automatic HEVC level selection.

### Changed

- Bumped the packaged `vtremoted --version` output to `0.8.0`.
- Restricted Plex rewriting to one directly mapped video stream and a tested
  software-scale/format/upload graph. Ambiguous graphs and unsupported
  compatibility constraints remain on Plex's native path.
- Added exact Plex `libavcodec` version and binary fingerprint gates before
  accessing FFmpeg private internals, with native pass-through for unknown
  Plex releases.
- Preserved Plex bitrate, maximum-rate, VBV window, GOP, profile, H.264 level,
  entropy, rate-control, closed-caption, and periodic keyframe constraints in
  supported remote transcodes.
- Expanded CI and end-to-end coverage for the Plex preload module, H.264 and
  HEVC inputs and outputs, independent HLS segment decoding, reconnects, and
  packaged stock-FFmpeg artifacts.
- Included the Plex Transcoder wrapper and preload module in the prebuilt Linux
  bundle, and made artifact smoke tests reject incomplete Plex payloads.
- Moved per-context network flushes outside the VA driver's global object lock
  so one slow teardown cannot stall unrelated contexts.
- Added shared HELLO, CONFIGURE, compressed FRAME, PACKET side-data, and
  malformed-length golden vectors for the C SDK and FFmpeg protocol clients.
- Documented a matched-bitrate HEVC Main10 packet-transcode comparison against
  Intel VA-API. The remote Apple M2 path was 1.58x faster for HEVC Main10
  output, while the Intel path was 2.31x faster for H.264 output on the tested
  1080p-to-720p workload.

## [v0.7.25] - 2026-09-04

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `818e5d965be9` (from `9fc8c785e274`).

## [v0.7.24] - 2026-09-02

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `9fc8c785e274` (from `c27482a18d7e`).

## [v0.7.23] - 2026-09-01

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `c27482a18d7e` (from `c9e36046a338`).

## [v0.7.22] - 2026-08-31

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `c9e36046a338` (from `b32f8d1c2377`).

## [v0.7.21] - 2026-08-30

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `b32f8d1c2377` (from `1ae404821882`).

## [v0.7.20] - 2026-08-29

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `1ae404821882` (from `df48dc624e71`).

## [v0.7.19] - 2026-08-28

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `df48dc624e71` (from `9f35e220ffbb`).

## [v0.7.18] - 2026-08-27

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `9f35e220ffbb` (from `27b7fa0c107c`).

## [v0.7.17] - 2026-08-26

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `27b7fa0c107c` (from `007cd1fd4399`).

## [v0.7.16] - 2026-08-25

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `007cd1fd4399` (from `1019f8f03660`).

## [v0.7.15] - 2026-08-24

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `1019f8f03660` (from `b79d4c4c0a16`).

## [v0.7.14] - 2026-08-23

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `b79d4c4c0a16` (from `eb0bfa852e7b`).

## [v0.7.13] - 2026-08-22

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `eb0bfa852e7b` (from `5f69124aaaed`).

## [v0.7.12] - 2026-08-21

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `5f69124aaaed` (from `7d77562d2a18`).

## [v0.7.11] - 2026-08-20

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `7d77562d2a18` (from `cb2370e546bb`).

## [v0.7.10] - 2026-08-19

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `cb2370e546bb` (from `89153eb701d3`).

## [v0.7.9] - 2026-08-18

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `89153eb701d3` (from `426841da9d91`).

## [v0.7.8] - 2026-08-17

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `426841da9d91` (from `0056dd32fd94`).

## [v0.7.7] - 2026-08-16

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `0056dd32fd94` (from `e2c335ab5c81`).

## [v0.7.6] - 2026-08-15

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `e2c335ab5c81` (from `2f0848c9bb49`).

## [v0.7.5] - 2026-08-14

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `2f0848c9bb49` (from `b397eba2f0d3`).

## [v0.7.4] - 2026-08-13

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `b397eba2f0d3` (from `03dc244a693c`).

## [v0.7.3] - 2026-08-11

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `03dc244a693c` (from `6bbc22dc09c2`).

## [v0.7.2] - 2026-08-10

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `6bbc22dc09c2` (from `0f7eec026cb7`).

## [v0.7.1] - 2026-08-09

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `0f7eec026cb7` (from `946272b79a32`).

## [v0.7.0] - 2026-08-01

### Fixed
- Prevented remote encoders from submitting an input frame twice or dropping it when queued and transmitted frames jointly fill the in-flight window, restoring exact input-frame/output-packet parity under real network timing.
- Detected HEVC Main10 from the codec profile or extradata when `bits_per_raw_sample` is unavailable, so remote decode negotiates P010 instead of NV12.
- Corrected benchmark capability probes that could misinterpret a matcher SIGPIPE under `pipefail` as an unsupported FFmpeg option.

### Changed
- Strengthened roundtrip and decode integration coverage with exact expected frame counts and explicit Main10-to-P010 negotiation checks.
- Updated hardware-frame decode coverage and benchmark documentation for the corrected Main10 path and measured 2.5 GbE behavior.
- Bumped the packaged `vtremoted --version` output to `0.7.0`.

## [v0.6.48] - 2026-08-01

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `946272b79a32` (from `ad5372898453`).

## [v0.6.47] - 2026-07-31

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `ad5372898453` (from `2ae24134889e`).

## [v0.6.46] - 2026-07-30

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `2ae24134889e` (from `d43b1efd2e94`).

## [v0.6.45] - 2026-07-29

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `d43b1efd2e94` (from `fe953596e9f5`).

## [v0.6.44] - 2026-07-28

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `fe953596e9f5` (from `acf6b520c1e7`).

## [v0.6.43] - 2026-07-27

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `acf6b520c1e7` (from `601d9ee881fb`).

## [v0.6.42] - 2026-07-26

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `601d9ee881fb` (from `2a06abd2d7cf`).

## [v0.6.41] - 2026-07-25

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `2a06abd2d7cf` (from `2f209337fc66`).

## [v0.6.40] - 2026-07-24

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `2f209337fc66` (from `80eb9e99b934`).

## [v0.6.39] - 2026-07-23

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `80eb9e99b934` (from `1b1f6026990b`).

## [v0.6.38] - 2026-07-22

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `1b1f6026990b` (from `ccc57378b37d`).

## [v0.6.37] - 2026-07-21

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `ccc57378b37d` (from `c23123630e6a`).

## [v0.6.36] - 2026-07-20

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `c23123630e6a` (from `b96701098fd8`).

## [v0.6.35] - 2026-07-19

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `b96701098fd8` (from `0869e710e687`).

## [v0.6.34] - 2026-07-18

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `0869e710e687` (from `8d394252d80d`).

## [v0.6.33] - 2026-07-17

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `8d394252d80d` (from `ceabc9b306f5`).

## [v0.6.32] - 2026-07-16

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `ceabc9b306f5` (from `1588bce21b6d`).

## [v0.6.31] - 2026-07-15

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `1588bce21b6d` (from `8bea614d987e`).

## [v0.6.30] - 2026-07-14

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `8bea614d987e` (from `a09be9b91e8e`).

## [v0.6.29] - 2026-07-12

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `a09be9b91e8e` (from `300cac307818`).

## [v0.6.28] - 2026-07-11

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `300cac307818` (from `35f8f4bdc075`).

## [v0.6.27] - 2026-07-10

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `35f8f4bdc075` (from `8de8405796df`).

## [v0.6.26] - 2026-07-09

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `8de8405796df` (from `c29d710cd5d0`).

## [v0.6.25] - 2026-07-08

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `c29d710cd5d0` (from `160737cf0da1`).

## [v0.6.24] - 2026-07-07

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `160737cf0da1` (from `c6498178bbfc`).

## [v0.6.23] - 2026-07-06

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `c6498178bbfc` (from `97cbffe9172f`).

## [v0.6.22] - 2026-07-05

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `97cbffe9172f` (from `6f2f3755a06b`).

## [v0.6.21] - 2026-07-04

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `6f2f3755a06b` (from `aafb5c655edc`).

## [v0.6.20] - 2026-07-03

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `aafb5c655edc` (from `95a888b9cadb`).

## [v0.6.19] - 2026-07-02

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `95a888b9cadb` (from `66d9b8e48373`).

## [v0.6.18] - 2026-07-01

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `66d9b8e48373` (from `ae4314e2f461`).

## [v0.6.17] - 2026-06-30

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `ae4314e2f461` (from `de6bcf5c05e3`).

## [v0.6.16] - 2026-06-29

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `de6bcf5c05e3` (from `97115451d0af`).

## [v0.6.15] - 2026-06-28

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `97115451d0af` (from `87bd15dc3c21`).

## [v0.6.14] - 2026-06-28

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `87bd15dc3c21` (from `cbbbe4a8624f`).

## [v0.6.13] - 2026-06-23

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `cbbbe4a8624f` (from `ff1e1b5b72bc`).

## [v0.6.12] - 2026-06-22

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `ff1e1b5b72bc` (from `c6bb22dea018`).

## [v0.6.11] - 2026-06-21

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `c6bb22dea018` (from `b3689e792fdb`).

## [v0.6.10] - 2026-06-20

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `b3689e792fdb` (from `431ceceac76a`).

## [v0.6.9] - 2026-06-19

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `431ceceac76a` (from `07ae44a607d8`).

## [v0.6.8] - 2026-06-16

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `07ae44a607d8` (from `44d082edc873`).

## [v0.6.7] - 2026-06-15

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `44d082edc873` (from `6698195dc43a`).

## [v0.6.6] - 2026-06-14

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `6698195dc43a` (from `f71c30ef9eb9`).

## [v0.6.5] - 2026-06-13

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `f71c30ef9eb9` (from `2cc7b87bdb75`).

## [v0.6.4] - 2026-06-13

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `2cc7b87bdb75` (from `5f998e304dfd`).

## [v0.6.3] - 2026-06-12

### Changed
- Reworked the README and GitHub Pages landing content for faster first-run adoption, clearer release asset selection, operating modes, benchmark caveats, and security guidance.
- Added benchmark documentation, contributor/security/community templates, issue templates, and pull request template coverage.
- Added release metadata freshness checks for public docs and LLM briefing content.

## [v0.6.2] - 2026-06-11

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `5f998e304dfd` (from `f1b4b5b5f68d`).

## [v0.6.1] - 2026-06-10

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `f1b4b5b5f68d` (from `6028720d70d0`).

## [v0.6.0] - 2026-06-09

### Changed
- Bumped the packaged `vtremoted --version` output to `0.6.0`.
- Pinned the default `MACOSX_DEPLOYMENT_TARGET` to `13.0` (previously the active SDK version) so builds made on macOS 27 or newer SDKs remain compatible with earlier supported macOS releases.
- Removed hard Homebrew `liblz4`/`libzstd` load commands from the macOS server binary; wire compression now loads those libraries at runtime and fails unsupported compression requests during configure when a library is unavailable.

## [v0.5.15] - 2026-06-08

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `6028720d70d0` (from `3137d337feed`).

## [v0.5.14] - 2026-06-07

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `3137d337feed` (from `b3552002637a`).

## [v0.5.13] - 2026-06-06

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `b3552002637a` (from `4eec440e360b`).

## [v0.5.12] - 2026-06-05

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `4eec440e360b` (from `c27a3b12e3bf`).

## [v0.5.11] - 2026-06-04

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `c27a3b12e3bf` (from `1e86a92a1cd7`).

## [v0.5.10] - 2026-06-03

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `1e86a92a1cd7` (from `80375ca773a5`).

## [v0.5.9] - 2026-06-02

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `80375ca773a5` (from `bf608f16fd67`).

## [v0.5.8] - 2026-06-01

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `bf608f16fd67` (from `f778a7e2418a`).

## [v0.5.7] - 2026-05-31

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `f778a7e2418a` (from `80405d3cebae`).

## [v0.5.6] - 2026-05-30

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `80405d3cebae` (from `468a743af165`).

## [v0.5.5] - 2026-05-29

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `468a743af165` (from `7b46c6a2a333`).

## [v0.5.4] - 2026-05-28

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `7b46c6a2a333` (from `30595cbc5db6`).

## [v0.5.3] - 2026-05-27

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `30595cbc5db6` (from `34dfa8bf2b86`).

## [v0.5.2] - 2026-05-25

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `34dfa8bf2b86` (from `3baab604db9d`).

## [v0.5.1] - 2026-05-24

### Changed
- Rebased the vendored `ffmpeg/` subtree to upstream `master` snapshot `3baab604db9d` (from `2e142e52ae8b`).

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
