#!/usr/bin/env bash
# Wait without opening a connection: a probe consumes a --once mock session.

vtremote_wait_mock_ready() {
  local pid="$1"
  local ready_file="$2"
  local server_log="$3"
  local deadline=$((SECONDS + 10))

  while [[ ! -s "$ready_file" ]]; do
    if ! kill -0 "$pid" 2>/dev/null || ((SECONDS >= deadline)); then
      echo "mock server failed to become ready; logs at ${server_log}" >&2
      cat "$server_log" >&2
      return 1
    fi
    sleep 0.05
  done
  cat "$ready_file"
}

vtremote_stop_mock() {
  local pid="${1:-}"
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}
