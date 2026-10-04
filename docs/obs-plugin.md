---
title: Remote OBS encoding
description: "Build the experimental OBS Studio remote encoder. Compose scenes locally and use a Mac's VideoToolbox hardware for H.264 or HEVC video encoding over LAN."
---

# Remote OBS encoding

Compose scenes in OBS Studio and use VideoToolbox on a separate Mac for the encode. The `obs-plugin/` tree contains an **experimental** encoder plugin using the same daemon and protocol as FFmpeg. OBS keeps scene composition, audio, recording/streaming and output delivery local; raw video frames cross the LAN and encoded packets return.

## Codec Selection

Plugin 2.0 exposes separate **VideoToolbox Remote H.264** and **VideoToolbox Remote HEVC** encoder entries. Choose the encoder itself; there is no codec dropdown. The codec and supported formats are negotiated in HELLO. H.264 uses NV12; HEVC supports NV12 and P010 when the server has the required capability.

For older saved configurations that selected HEVC through the former shared encoder, select the dedicated HEVC entry again. The original encoder ID now selects H.264.

## Scope

Current coverage focuses on protocol/client integration, encoder lifecycle and mock-backed libobs checks. These checks do not establish complete real-world recording/streaming behavior for every OBS output and shutdown path. Validate a local recording, sustained operation and stop/drain behavior on your build before using a live destination. The bounded worker pipeline exercised by `run_obs_pipeline.py` is not enabled in the plugin build pending OBS drain integration.

- Source: `obs-plugin/src/`
- Locale/resources: `obs-plugin/data/`
- Standalone OBS config stub: `obs-plugin/include/obsconfig.h`

## Build

```bash
cd obs-plugin
cmake -S . -B build
cmake --build build
```

If `libobs` is not discoverable, set explicit OBS paths:

```bash
cmake -S . -B build \
  -DOBS_SOURCE_DIR=/path/to/obs-studio \
  -DOBS_BUILD_DIR=/path/to/obs-studio/build
```

After building, `cmake --install build` uses the platform-specific user OBS plugin directory defined in the project. See [CMake installation rules]({{ site.repository_url }}/blob/main/obs-plugin/CMakeLists.txt) for the target paths. Restart OBS to discover the module.

## Configure OBS

1. Start the [Mac daemon](getting-started.html#install-the-release-binaries) on a reachable private endpoint. Install LZ4 on the Mac for the plugin's default wire compression.
2. In OBS advanced output settings, select **VideoToolbox Remote H.264** or **VideoToolbox Remote HEVC** for the recording or streaming output that accepts that codec.
3. Set **Server Host**, **Server Port** (default 5555), **Auth Token** if needed, **Bitrate** in kbps, **Keyframe Interval** in seconds, and **Wire Compression**.
4. Start with a local recording. Inspect OBS and `vtremoted` logs, check the resulting file and frame counts, and verify that stopping the output drains correctly.

The plugin provides an encoder; it does not add codec support to a streaming service. Choose H.264 or HEVC according to your destination. Raw-frame transport benefits from wired networking; resolution, frame rate, format and content affect bandwidth. See [security](security.html) before sharing the daemon.

## Test

Run the protocol smoke test from repo root:

```bash
make test-obs-plugin
```

This runs:
- the fast client smoke test, which compiles `vtremoted-client.cpp` with local stubs and validates HELLO/CONFIGURE/FRAME/PACKET flow against the Python mock server
- the `libobs` integration test, which builds and loads the real plugin module, then exercises defaults, properties, creation, updates, encoding, extra-data retrieval and destruction against the same mock server

If `libobs` dev headers/libs are unavailable, the integration runner skips locally. CI installs `libobs` and runs both paths.

## CI

GitHub Actions includes an `obs-plugin` Linux job that installs `libobs` and runs both the smoke and `libobs` integration tests whenever OBS plugin or related integration files change.
