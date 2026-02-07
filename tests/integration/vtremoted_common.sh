#!/usr/bin/env bash
# Shared helpers for starting/stopping vtremoted in integration tests.

vtremote_pick_free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

vtremote_start_server() {
  local log_file="${1:-/tmp/vtremoted.log}"
  local retries="${VTREMOTE_BIND_RETRIES:-3}"
  local attempts=0
  local port="${VTREMOTE_PORT:-}"
  local token="${VTREMOTE_TOKEN:-}"
  local use_existing="${VTREMOTE_USE_EXISTING:-}"
  local remote_host="${VTREMOTE_HOST:-}"

  wait_for_listen_by_pid() {
    local pid="$1"
    local port="$2"
    # If lsof is available, verify the *child pid* owns the listening socket.
    if command -v lsof >/dev/null 2>&1; then
      for _ in $(seq 1 20); do
        if ! kill -0 "$pid" 2>/dev/null; then
          return 1
        fi
        if lsof -nP -a -p "$pid" -iTCP:${port} -sTCP:LISTEN >/dev/null 2>&1; then
          return 0
        fi
        sleep 0.1
      done
      return 1
    fi

    # Fallback: no lsof. Give the process a moment to fail fast (e.g. bind errors),
    # then treat "still alive" as good enough for local tests.
    sleep 0.3
    kill -0 "$pid" 2>/dev/null
  }

  if [[ -z "${VTREMOTED:-}" ]]; then
    echo "VTREMOTED not set (path to vtremoted binary)" >&2
    return 1
  fi
  if [[ ! -x "$VTREMOTED" ]]; then
    echo "vtremoted not found at $VTREMOTED (build it or set VTREMOTED)" >&2
    return 1
  fi

  if [[ -n "$use_existing" ]]; then
    if [[ -z "$port" ]]; then
      port=5555
    fi
    VTREMOTE_PORT="$port"
    VTREMOTE_HOST="${remote_host:-127.0.0.1}"
    VTREMOTE_SERVER_LOG="$log_file"
    return 0
  fi

  while (( attempts < retries )); do
    attempts=$((attempts + 1))
    if [[ -z "$port" ]]; then
      port="$(vtremote_pick_free_port)"
    fi
    VTREMOTE_PORT="$port"
    VTREMOTE_HOST="127.0.0.1"
    : >"$log_file"
    if [[ -n "$token" ]]; then
      "$VTREMOTED" --listen "127.0.0.1:${port}" --token "$token" >"$log_file" 2>&1 &
    else
      "$VTREMOTED" --listen "127.0.0.1:${port}" >"$log_file" 2>&1 &
    fi
    SERVER_PID=$!
    VTREMOTE_SERVER_PID=$SERVER_PID
    VTREMOTE_SERVER_LOG="$log_file"

    # Ensure we started *our* vtremoted, not some existing process that already had the port.
    if ! wait_for_listen_by_pid "$SERVER_PID" "$port"; then
      kill "$SERVER_PID" 2>/dev/null || true
      wait "$SERVER_PID" 2>/dev/null || true
      port=""
      continue
    fi

    if command -v rg >/dev/null 2>&1; then
      rg -n "bind failed" "$log_file" >/dev/null 2>&1 && bind_failed=1 || bind_failed=0
    else
      grep -n "bind failed" "$log_file" >/dev/null 2>&1 && bind_failed=1 || bind_failed=0
    fi
    if [[ "${bind_failed:-0}" -eq 1 ]]; then
      kill "$SERVER_PID" 2>/dev/null || true
      wait "$SERVER_PID" 2>/dev/null || true
      port=""
      continue
    fi
    return 0
  done

  echo "vtremoted failed to bind after ${attempts} attempts" >&2
  return 1
}

vtremote_stop_server() {
  if [[ -n "${VTREMOTE_USE_EXISTING:-}" ]]; then
    return 0
  fi
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}

vtremote_restart_server() {
  vtremote_stop_server
  VTREMOTE_PORT=""
  vtremote_start_server "$@"
}
