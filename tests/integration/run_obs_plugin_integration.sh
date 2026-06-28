#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

CXX="${CXX:-c++}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
BUILD_DIR="$(mktemp -d /tmp/obs-plugin-integration.XXXXXX)"
PLUGIN_BUILD_DIR="$BUILD_DIR/plugin"
SERVER_PID=""
CLIENT_TIMEOUT_SECS="${CLIENT_TIMEOUT_SECS:-60}"
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

if ! command -v "$CXX" >/dev/null 2>&1; then
  echo "ERROR: C++ compiler not found: $CXX" >&2
  exit 1
fi

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "ERROR: python3 not found" >&2
  exit 1
fi

if ! command -v pkg-config >/dev/null 2>&1; then
  echo "ERROR: pkg-config not found" >&2
  exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
  echo "ERROR: cmake not found" >&2
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

sanitize_pkg_config_flags() {
  local raw="$1"
  local -a filtered=()
  local token
  for token in $raw; do
    if [[ "$token" == *'$<'* ]]; then
      continue
    fi
    filtered+=("$token")
  done
  printf '%s ' "${filtered[@]}"
}

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

DL_LIBS=""
if [[ "$(uname -s)" == "Linux" ]]; then
  DL_LIBS="-ldl"
fi

OBS_SOURCE_DIR_FALLBACK="${OBS_SOURCE_DIR:-$HOME/git/obs-studio}"
OBS_APP_BUNDLE="${OBS_APP_BUNDLE:-/Applications/OBS.app}"
OBS_FRAMEWORK_DIR="${OBS_APP_BUNDLE}/Contents/Frameworks"
SIMDE_PREFIX="${SIMDE_PREFIX:-}"

OBS_CFLAGS=""
OBS_LIBS=""
PLUGIN_CMAKE_ARGS=()
HARNESS_ENV=()
HARNESS_PREFIX=()

if pkg-config --exists libobs; then
  OBS_CFLAGS="$(sanitize_pkg_config_flags "$(pkg-config --cflags libobs)")"
  OBS_LIBS="$(pkg-config --libs libobs)"
elif [[ "$(uname -s)" == "Darwin" ]] \
  && [[ -d "$OBS_SOURCE_DIR_FALLBACK/libobs" ]] \
  && [[ -f "$OBS_FRAMEWORK_DIR/libobs.framework/libobs" ]]; then
  if [[ -z "$SIMDE_PREFIX" ]]; then
    SIMDE_PREFIX="$(brew --prefix simde)"
  fi

  OBS_CFLAGS="-I$ROOT/obs-plugin/include -I$OBS_SOURCE_DIR_FALLBACK/libobs -I$OBS_SOURCE_DIR_FALLBACK/deps/media-playback -I$SIMDE_PREFIX/include -F$OBS_FRAMEWORK_DIR"
  OBS_LIBS="-F$OBS_FRAMEWORK_DIR -framework libobs -Wl,-rpath,$OBS_FRAMEWORK_DIR"
  PLUGIN_CMAKE_ARGS+=("-DOBS_SOURCE_DIR=$OBS_SOURCE_DIR_FALLBACK")
  HARNESS_ENV+=(
    "DYLD_FRAMEWORK_PATH=$OBS_FRAMEWORK_DIR"
    "DYLD_LIBRARY_PATH=$OBS_FRAMEWORK_DIR"
  )
else
  echo "SKIP: libobs dev package not found; skipping OBS plugin libobs integration test"
  exit 0
fi

if [[ "$(uname -s)" == "Linux" ]] && [[ -z "${DISPLAY:-}" ]] && [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
  if command -v xvfb-run >/dev/null 2>&1; then
    HARNESS_PREFIX=(xvfb-run -a)
  else
    echo "ERROR: headless Linux libobs integration requires xvfb-run" >&2
    exit 1
  fi
fi

SERVER_TOKEN="${VTREMOTE_OBS_PLUGIN_TOKEN:-obs-plugin-test-token}"
EXPECTED_BITRATE="${VTREMOTE_OBS_PLUGIN_BITRATE:-7000}"
EXPECTED_GOP="${VTREMOTE_OBS_PLUGIN_GOP:-3}"
EXPECTED_EXTRADATA_HEX="${VTREMOTE_OBS_PLUGIN_EXTRADATA_HEX:-000000016742001f}"
EXPECTED_CONFIGURE_BITRATE="$((EXPECTED_BITRATE * 1000))"
EXPECTED_CONFIGURE_GOP="$((EXPECTED_GOP * 30))"

pick_port() {
  "$PYTHON_BIN" - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

build_plugin() {
  echo "Building OBS plugin"
  cmake -S "$ROOT/obs-plugin" -B "$PLUGIN_BUILD_DIR" -DCMAKE_BUILD_TYPE=Release "${PLUGIN_CMAKE_ARGS[@]}" >/dev/null
  cmake --build "$PLUGIN_BUILD_DIR" >/dev/null
}

find_plugin_binary() {
  find "$PLUGIN_BUILD_DIR" -type f \
    \( -name 'libobs-vtremoted.so' -o -name 'obs-vtremoted.so' -o -name 'obs-vtremoted.dll' \
       -o -path '*/obs-vtremoted.plugin/Contents/MacOS/obs-vtremoted' \) \
    | head -n 1
}

build_harness() {
  echo "Building OBS integration harness"
  "$CXX" -std=c++17 \
    "$ROOT/tests/integration/obs_plugin_integration.cpp" \
    -I"$ROOT/obs-plugin/src" \
    $OBS_CFLAGS \
    $OBS_LIBS \
    $DL_LIBS \
    -o "$BUILD_DIR/obs_plugin_integration"
}

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
  local -a harness_cmd=("$BUILD_DIR/obs_plugin_integration")

  echo "Running OBS integration case: $name"

  "$PYTHON_BIN" "$ROOT/tests/integration/mock_vtremoted/mock_vtremoted.py" \
    --listen "$server_addr" \
    --token "$SERVER_TOKEN" \
    --strict-config-options \
    --expect-bitrate "$EXPECTED_CONFIGURE_BITRATE" \
    --expect-gop "$EXPECTED_CONFIGURE_GOP" \
    --configure-extradata-hex "$EXPECTED_EXTRADATA_HEX" \
    --once \
    "${server_args[@]}" \
    >"$server_log" 2>&1 &
  SERVER_PID=$!

  wait_for_server_ready "$SERVER_PID" "$server_log" "$SERVER_TIMEOUT_SECS" \
    "mock server for case '$name'"

  harness_cmd+=(
    --module-path "$PLUGIN_BINARY"
    --module-data-path "$ROOT/obs-plugin/data"
    --host 127.0.0.1
    --port "$port"
    --token "$SERVER_TOKEN"
    --updated-bitrate "$EXPECTED_BITRATE"
    --updated-keyint-sec "$EXPECTED_GOP"
    --expected-extradata-hex "$EXPECTED_EXTRADATA_HEX"
    "${client_args[@]}"
  )

  if run_with_timeout "$CLIENT_TIMEOUT_SECS" env "${HARNESS_ENV[@]}" "${HARNESS_PREFIX[@]}" "${harness_cmd[@]}" >"$client_log" 2>&1; then
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

build_plugin
PLUGIN_BINARY="$(find_plugin_binary)"
if [[ -z "$PLUGIN_BINARY" ]]; then
  echo "ERROR: failed to locate built OBS plugin binary" >&2
  exit 1
fi

build_harness

run_case none success --expect-wire-compression 0 -- --wire-compression none
run_case lz4 success --expect-wire-compression 1 -- --wire-compression lz4
run_case zstd success --expect-wire-compression 2 -- --wire-compression zstd
run_case packet_oversize failure --expect-wire-compression 1 --packet-bytes 9000000 -- --wire-compression lz4

echo "OK: OBS plugin libobs integration test passed; cases logged under $BUILD_DIR"
