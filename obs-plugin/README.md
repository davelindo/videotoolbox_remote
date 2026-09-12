# OBS Plugin (Experimental)

This directory contains an experimental OBS plugin for remote H.264/HEVC encoding via `vtremoted`.

## Layout

- `src/`: plugin and protocol client sources.
- `data/`: plugin locale resources.
- `include/`: standalone `obsconfig.h` stub for local builds.

## Build

```bash
cd obs-plugin
cmake -S . -B build
cmake --build build
```

You may need to provide OBS paths if `libobs` is not discoverable:

```bash
cmake -S . -B build \
  -DOBS_SOURCE_DIR=/path/to/obs-studio \
  -DOBS_BUILD_DIR=/path/to/obs-studio/build
```

## Protocol Smoke Test

From repo root:

```bash
tests/integration/run_obs_plugin_client_mock.sh
```

This compiles the plugin client and validates connect/configure/frame/packet flow against the Python mock server.

## Codec Selection

Select **VideoToolbox Remote H.264** or **VideoToolbox Remote HEVC** from OBS's
encoder list. H.264 uses NV12; HEVC supports NV12 and P010. The selected codec is
negotiated in the protocol HELLO message and honored by `vtremoted` when the
server advertises the matching capability (HEVC requires Apple Silicon).

### Upgrading to plugin 2.0.0

Plugin 2.0.0 is included in the v0.9.0 repository release. The former **Video
Codec** property has been removed. If saved output settings selected HEVC
through that property, choose **VideoToolbox Remote HEVC** after upgrading.
The existing `vtremoted_encoder` ID now selects H.264 explicitly; HEVC uses
`vtremoted_hevc_encoder`.
