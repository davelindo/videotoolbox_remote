---
title: OBS Plugin
description: "Experimental OBS Studio plugin for VideoToolbox Remote: build, configure, and stream using remote H.264 hardware encoding from a Mac over LAN."
---

# OBS Plugin (Experimental)

The `obs-plugin/` tree contains an experimental OBS encoder plugin that connects to `vtremoted` and uses the same wire protocol as the FFmpeg client.

## Scope

Current plugin scope is focused on protocol/client integration, encoder lifecycle validation, and smoke coverage.

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

## Test

Run the protocol smoke test from repo root:

```bash
make test-obs-plugin
```

This runs:
- the fast client smoke test, which compiles `vtremoted-client.cpp` with local stubs and validates HELLO/CONFIGURE/FRAME/PACKET flow against the Python mock server
- the `libobs` integration test, which builds the real plugin module, loads it via OBS, and exercises defaults/properties/create/update/encode/get_extra_data/destroy against the same mock server

If `libobs` dev headers/libs are unavailable, the integration runner skips locally. CI installs `libobs` and runs both paths.

## CI

GitHub Actions includes an `obs-plugin` Linux job that installs `libobs` and runs both the smoke and `libobs` integration tests whenever OBS plugin or related integration files change.
