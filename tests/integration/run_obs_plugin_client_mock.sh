#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

CXX="${CXX:-c++}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "$CXX" >/dev/null 2>&1; then
  echo "ERROR: C++ compiler not found: $CXX" >&2
  exit 1
fi

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "ERROR: python3 not found" >&2
  exit 1
fi

if ! command -v pkg-config >/dev/null 2>&1; then
  echo "ERROR: pkg-config not found (needed for liblz4)" >&2
  exit 1
fi

if ! pkg-config --exists liblz4; then
  echo "ERROR: liblz4 dev package not found" >&2
  exit 1
fi

PORT="${VTREMOTE_OBS_PLUGIN_PORT:-}"
if [[ -z "$PORT" ]]; then
  PORT="$("$PYTHON_BIN" - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
fi

SERVER_ADDR="127.0.0.1:${PORT}"
SERVER_TOKEN="${VTREMOTE_OBS_PLUGIN_TOKEN:-obs-plugin-test-token}"

BUILD_DIR="$(mktemp -d /tmp/obs-plugin-smoke.XXXXXX)"
MOCK_LOG="/tmp/obs_plugin_mock_server.log"
CLIENT_LOG="/tmp/obs_plugin_client_smoke.log"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

LZ4_CFLAGS="$(pkg-config --cflags liblz4)"
LZ4_LIBS="$(pkg-config --libs liblz4)"

"$CXX" -std=c++17 \
  "$ROOT/tests/integration/obs_plugin_client_smoke.cpp" \
  "$ROOT/obs-plugin/src/vtremoted-client.cpp" \
  -I"$ROOT/obs-plugin/src" \
  -I"$ROOT/tests/integration/obs_plugin_test_stubs" \
  $LZ4_CFLAGS \
  $LZ4_LIBS \
  -o "$BUILD_DIR/obs_plugin_client_smoke"

"$PYTHON_BIN" "$ROOT/tests/integration/mock_vtremoted/mock_vtremoted.py" \
  --listen "$SERVER_ADDR" \
  --token "$SERVER_TOKEN" \
  --strict-config-options \
  --once \
  >"$MOCK_LOG" 2>&1 &
SERVER_PID=$!

sleep 0.2

"$BUILD_DIR/obs_plugin_client_smoke" \
  --host 127.0.0.1 \
  --port "$PORT" \
  --token "$SERVER_TOKEN" \
  >"$CLIENT_LOG" 2>&1

echo "OK: OBS plugin client protocol smoke test passed; logs at $MOCK_LOG and $CLIENT_LOG"
