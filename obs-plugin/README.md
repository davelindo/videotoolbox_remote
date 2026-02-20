# OBS Plugin (Experimental)

This directory contains an experimental OBS plugin for remote H.264 encoding via `vtremoted`.

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
