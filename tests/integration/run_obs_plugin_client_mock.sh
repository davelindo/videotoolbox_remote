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
  echo "ERROR: pkg-config not found (needed for liblz4/libzstd)" >&2
  exit 1
fi

if ! pkg-config --exists liblz4; then
  echo "ERROR: liblz4 dev package not found" >&2
  exit 1
fi

if ! pkg-config --exists libzstd; then
  echo "ERROR: libzstd dev package not found" >&2
  exit 1
fi

BUILD_DIR="$(mktemp -d /tmp/obs-plugin-smoke.XXXXXX)"
SERVER_PID=""
CLIENT_TIMEOUT_SECS="${CLIENT_TIMEOUT_SECS:-30}"
SERVER_TIMEOUT_SECS="${SERVER_TIMEOUT_SECS:-10}"
TIMEOUT_BIN=""

if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi

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
ZSTD_CFLAGS="$(pkg-config --cflags libzstd)"
ZSTD_LIBS="$(pkg-config --libs libzstd)"
SERVER_TOKEN="${VTREMOTE_OBS_PLUGIN_TOKEN:-obs-plugin-test-token}"

run_with_timeout() {
  local seconds="$1"
  shift

  if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" --signal=TERM --kill-after=5 "$seconds" "$@"
  else
    "$@"
  fi
}

wait_for_pid_exit() {
  local pid="$1"
  local seconds="$2"
  local label="$3"
  local deadline=$((SECONDS + seconds))

  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      echo "ERROR: ${label} did not exit within ${seconds}s" >&2
      return 124
    fi
    sleep 0.2
  done

  if wait "$pid"; then
    return 0
  fi

  return $?
}

wait_for_server_ready() {
  local pid="$1"
  local log_file="$2"
  local seconds="$3"
  local label="$4"
  local deadline=$((SECONDS + seconds))

  while (( SECONDS < deadline )); do
    if grep -F "mock_vtremoted listening on" "$log_file" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "ERROR: ${label} exited before it was ready" >&2
      cat "$log_file" >&2
      return 1
    fi
    sleep 0.1
  done

  echo "ERROR: ${label} did not become ready within ${seconds}s" >&2
  cat "$log_file" >&2
  return 124
}

pick_port() {
  "$PYTHON_BIN" - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

"$CXX" -std=c++17 \
  "$ROOT/tests/integration/obs_plugin_client_smoke.cpp" \
  "$ROOT/obs-plugin/src/vtremoted-client.cpp" \
  -I"$ROOT/obs-plugin/src" \
  -I"$ROOT/tests/integration/obs_plugin_test_stubs" \
  $LZ4_CFLAGS \
  $ZSTD_CFLAGS \
  $LZ4_LIBS \
  $ZSTD_LIBS \
  -o "$BUILD_DIR/obs_plugin_client_smoke"

run_case() {
  local name="$1"
  local expected="$2"
  local client_rc=0
  local server_rc=0
  shift 2

  local -a server_args=()
  local -a client_args=()
  local phase="server"

  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--" ]]; then
      phase="client"
      shift
      continue
    fi
    if [[ "$phase" == "server" ]]; then
      server_args+=("$1")
    else
      client_args+=("$1")
    fi
    shift
  done

  local port
  port="$(pick_port)"
  local server_addr="127.0.0.1:${port}"
  local server_log="$BUILD_DIR/${name}.server.log"
  local client_log="$BUILD_DIR/${name}.client.log"

  echo "Running OBS client smoke case: $name"

  "$PYTHON_BIN" "$ROOT/tests/integration/mock_vtremoted/mock_vtremoted.py" \
    --listen "$server_addr" \
    --token "$SERVER_TOKEN" \
    --strict-config-options \
    --once \
    "${server_args[@]}" \
    >"$server_log" 2>&1 &
  SERVER_PID=$!

  wait_for_server_ready "$SERVER_PID" "$server_log" "$SERVER_TIMEOUT_SECS" \
    "mock server for case '$name'"

  if run_with_timeout "$CLIENT_TIMEOUT_SECS" "$BUILD_DIR/obs_plugin_client_smoke" \
    --host 127.0.0.1 \
    --port "$port" \
    --token "$SERVER_TOKEN" \
    "${client_args[@]}" \
    >"$client_log" 2>&1; then
    client_rc=0
  else
    client_rc=$?
  fi

  if wait_for_pid_exit "$SERVER_PID" "$SERVER_TIMEOUT_SECS" \
    "mock server for case '$name'"; then
    server_rc=0
  else
    server_rc=$?
  fi
  SERVER_PID=""

  if [[ "$client_rc" -eq 124 ]]; then
    echo "ERROR: case '$name' timed out after ${CLIENT_TIMEOUT_SECS}s" >&2
    cat "$server_log" >&2
    cat "$client_log" >&2
    exit 1
  fi

  if [[ "$server_rc" -ne 0 ]]; then
    echo "ERROR: mock server failed for case '$name' with status $server_rc" >&2
    cat "$server_log" >&2
    cat "$client_log" >&2
    exit 1
  fi

  if [[ "$expected" == "success" && "$client_rc" -ne 0 ]]; then
    echo "ERROR: case '$name' unexpectedly failed" >&2
    cat "$server_log" >&2
    cat "$client_log" >&2
    exit 1
  fi

  if [[ "$expected" == "failure" && "$client_rc" -eq 0 ]]; then
    echo "ERROR: case '$name' unexpectedly succeeded" >&2
    cat "$server_log" >&2
    cat "$client_log" >&2
    exit 1
  fi
}

run_case none success --expect-wire-compression 0 -- --wire-compression none
run_case lz4 success --expect-wire-compression 1 -- --wire-compression lz4
run_case zstd success --expect-wire-compression 2 -- --wire-compression zstd
run_case hello_oversize failure --hello-ack-bytes 70000
run_case configure_oversize failure --configure-ack-bytes 4200000
run_case packet_oversize failure --packet-bytes 9000000
run_case bad_version failure --response-version 2
run_case stalled_hello failure --stall-after hello --stall-seconds 6
run_case reset_after_configure failure --reset-after-configure-ack

LONG_TOKEN="$($PYTHON_BIN -c 'print("x" * 65536, end="")')"
run_case long_token failure --token "$LONG_TOKEN" -- --token "$LONG_TOKEN"

echo "OK: OBS plugin client smoke test passed; cases logged under $BUILD_DIR"
