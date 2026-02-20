---
title: OBS Plugin
---

# OBS Plugin (Experimental)

The `obs-plugin/` tree contains an experimental OBS encoder plugin that connects to `vtremoted` and uses the same wire protocol as the FFmpeg client.

## Scope

Current plugin scope is focused on protocol/client integration and smoke validation.

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

This compiles the plugin client and validates HELLO/CONFIGURE/FRAME/PACKET flow against the Python mock server.

## CI

GitHub Actions includes an `obs-plugin-smoke` job on Linux that runs the same smoke test whenever OBS plugin or related integration files change.
