#!/usr/bin/env bash
set -euo pipefail

LABEL="${LABEL:-com.davelindon.vtremoted}"
LISTEN="${LISTEN:-127.0.0.1:5555}"
TOKEN="${TOKEN:-}"
TOKEN_FILE="${TOKEN_FILE:-}"
TOKEN_ENV="${TOKEN_ENV:-}"
LOG_LEVEL="${LOG_LEVEL:-1}"
BIN="${BIN:-/usr/local/bin/vtremoted}"
MAX_SESSIONS="${MAX_SESSIONS:-}"
HANDSHAKE_TIMEOUT="${HANDSHAKE_TIMEOUT:-}"
IDLE_TIMEOUT="${IDLE_TIMEOUT:-}"
MAX_MESSAGE_BYTES="${MAX_MESSAGE_BYTES:-}"
SYSTEM=0
UNINSTALL=0

usage() {
  cat <<EOF
Usage: $0 [--bin /path/to/vtremoted] [--listen host:port] [--token TOKEN] [--log-level N] [--system] [--uninstall]
          [--token-file PATH] [--token-env VAR] [--max-sessions N] [--handshake-timeout S] [--idle-timeout S] [--max-message-bytes N]

Defaults:
  --bin       $BIN
  --listen    $LISTEN
  --log-level $LOG_LEVEL
  --token     (empty; auth disabled)

Environment overrides:
  LABEL, LISTEN, TOKEN, TOKEN_FILE, TOKEN_ENV, LOG_LEVEL, BIN, MAX_SESSIONS, HANDSHAKE_TIMEOUT, IDLE_TIMEOUT, MAX_MESSAGE_BYTES
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin) BIN="$2"; shift 2 ;;
    --listen) LISTEN="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --token-file) TOKEN_FILE="$2"; shift 2 ;;
    --token-env) TOKEN_ENV="$2"; shift 2 ;;
    --max-sessions) MAX_SESSIONS="$2"; shift 2 ;;
    --handshake-timeout) HANDSHAKE_TIMEOUT="$2"; shift 2 ;;
    --idle-timeout) IDLE_TIMEOUT="$2"; shift 2 ;;
    --max-message-bytes) MAX_MESSAGE_BYTES="$2"; shift 2 ;;
    --log-level) LOG_LEVEL="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --system) SYSTEM=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

# If running as root, default to system domain unless explicitly set otherwise.
if [[ "$SYSTEM" -eq 0 && "${EUID:-$(id -u)}" -eq 0 ]]; then
  SYSTEM=1
fi

if [[ "$SYSTEM" -eq 1 ]]; then
  PLIST_DIR="/Library/LaunchDaemons"
  DOMAIN="system"
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    SUDO=""
  else
    SUDO="sudo"
    echo "Installing system LaunchDaemon; sudo may prompt for permission." >&2
  fi
else
  PLIST_DIR="${HOME}/Library/LaunchAgents"
  DOMAIN="gui/${UID}"
  SUDO=""
fi

PLIST="${PLIST_DIR}/${LABEL}.plist"
if [[ "$SYSTEM" -eq 1 ]]; then
  LOG_DIR="/Library/Logs"
else
  LOG_DIR="${HOME}/Library/Logs"
fi
STDOUT_LOG="${LOG_DIR}/vtremoted.log"
STDERR_LOG="${LOG_DIR}/vtremoted.err.log"

if [[ "$UNINSTALL" -eq 1 ]]; then
  $SUDO launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true
  $SUDO rm -f "$PLIST"
  echo "Removed $PLIST"
  exit 0
fi

if [[ ! -x "$BIN" ]]; then
  echo "vtremoted not found at $BIN (use --bin or install it first)" >&2
  exit 1
fi

$SUDO mkdir -p "$PLIST_DIR" "$LOG_DIR"

ARGS=( "$BIN" "--listen" "$LISTEN" "--log-level" "$LOG_LEVEL" )
if [[ -n "$TOKEN" ]]; then
  ARGS+=( "--token" "$TOKEN" )
fi
if [[ -n "$TOKEN_FILE" ]]; then
  ARGS+=( "--token-file" "$TOKEN_FILE" )
fi
if [[ -n "$TOKEN_ENV" ]]; then
  ARGS+=( "--token-env" "$TOKEN_ENV" )
fi
if [[ -n "$MAX_SESSIONS" ]]; then
  ARGS+=( "--max-sessions" "$MAX_SESSIONS" )
fi
if [[ -n "$HANDSHAKE_TIMEOUT" ]]; then
  ARGS+=( "--handshake-timeout" "$HANDSHAKE_TIMEOUT" )
fi
if [[ -n "$IDLE_TIMEOUT" ]]; then
  ARGS+=( "--idle-timeout" "$IDLE_TIMEOUT" )
fi
if [[ -n "$MAX_MESSAGE_BYTES" ]]; then
  ARGS+=( "--max-message-bytes" "$MAX_MESSAGE_BYTES" )
fi

{
  echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
  echo "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">"
  echo "<plist version=\"1.0\">"
  echo "<dict>"
  echo "  <key>Label</key><string>${LABEL}</string>"
  echo "  <key>ProgramArguments</key>"
  echo "  <array>"
  for a in "${ARGS[@]}"; do
    echo "    <string>${a}</string>"
  done
  echo "  </array>"
  echo "  <key>RunAtLoad</key><true/>"
  echo "  <key>KeepAlive</key><true/>"
  echo "  <key>StandardOutPath</key><string>${STDOUT_LOG}</string>"
  echo "  <key>StandardErrorPath</key><string>${STDERR_LOG}</string>"
  echo "</dict>"
  echo "</plist>"
} | $SUDO tee "$PLIST" >/dev/null

$SUDO launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true
$SUDO launchctl bootstrap "$DOMAIN" "$PLIST"
$SUDO launchctl kickstart -k "$DOMAIN/$LABEL"

echo "Installed launchd service: $LABEL"
echo "  domain: $DOMAIN"
echo "  binary: $BIN"
echo "  plist: $PLIST"
echo "  logs:  $STDOUT_LOG / $STDERR_LOG"
echo
echo "Verify with:"
echo "  launchctl print \"$DOMAIN/$LABEL\""
echo "  pgrep -fl vtremoted"
echo "  lsof -nP -iTCP:${LISTEN##*:} -sTCP:LISTEN"
