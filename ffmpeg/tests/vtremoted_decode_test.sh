#!/bin/sh
set -eu

# Requirements:
# - python3 available
# - ffmpeg binary available in current dir or $FFMPEG_BIN

FFMPEG_BIN=${FFMPEG_BIN:-./ffmpeg}
SERVER_TOKEN="secret_test_token"
DEC_SERVER_ADDR=""

if [ ! -x "$FFMPEG_BIN" ]; then
  # Fallback to looking in PATH
  if command -v ffmpeg >/dev/null 2>&1; then
      FFMPEG_BIN=ffmpeg
  else
      echo "ffmpeg binary not found at $FFMPEG_BIN" >&2
      exit 1
  fi
fi

free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

# Find free port for decoder mock server
if [ -z "$DEC_SERVER_ADDR" ]; then
  PORT=$(free_port)
  DEC_SERVER_ADDR="127.0.0.1:${PORT}"
fi

MOCK_SCRIPT="$(dirname "$0")/mock_vtremoted.py"
TMP_H264="$(mktemp -t vtremoted-decode.XXXXXX.h264)"

cleanup() {
  rm -f "$TMP_H264"
  if [ -n "${DEC_SERVER_PID:-}" ]; then
    kill "$DEC_SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Generate a small H.264 Annex B sample (single-frame baseline).
python3 - "$TMP_H264" <<'PY'
import base64
import sys

data = base64.b64decode(
    "AAAAAWdCwArclsBEAAADAAQAAAMACjxIngAAAAFozg/IAAABBgX//03cRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MCByZWY9MSBkZWJsb2NrPTA6MDowIGFuYWx5c2U9MDowIG1lPWRpYSBzdWJtZT0wIHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTAgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0wIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PTAgdGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTEga2V5aW50X21pbj0xIHNjZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0wAIAAAAFliIQ6DGAA7EMUeFJljtf6KgmBngBWmwZjG2oQECGRAQIwAHIy8KaogzCUBKL/8OAATAAIZHAANgACA0Z0YWgpCGlW1I3j/9pC9OPynUvj1v/w4CAjFOCXCjeIdKerw4CAjAKgGg7not4ESx/31KDTCjOI9K+r1OF8cHU5Y71ekAAJ8ZjEU0G9v3yQABxzHbnAGVfvgQAAgHAAIAUKhBAHGDgAG7GUaJUovhji3Yw5v0AUnixiR/4wLEo//0gAMfGGqYN0gAzAK5oSZZy0iDOVyIFgSzgh9MyqARFSFf3sYDnNXCybtf/cF8AHD4pZZYHqlWQW55KWoNRwACwAAgHmQHaAJhQGrm2rgzJgpxZJ2krOLIQAAEAGAzk5BAAgApkeAZkgAAQAQZ0sAJQvRST2EU3jktoiBs4UKQXcEfV6iMNA7vcWAQ76vYABqGIcQrCQFrkET0AEdxnuDyDtVgXmEodyHFAEKer1OEpRRfECRL1egAR3GocHkFKrYAPCsc3raClyHDwQQABAGcAAICARAHh8UYg2xHscHRm9cEbW9AI5tAiKItkYoIpCf3/7AaY5TqQD5MlfvurMT25whPWvjxvg2ssmg6WzmBrnR7XAsxX/rgRVMxLCjJiY4MOHAAEAYKAAIGdBwEBGHgFgcBARg4BY/8cBARg4BYHAQEYOAWPEABAAkQAAoAAIA8mEPcLADoFQh7g4AdAgI4q4IAAXLAOEcVcHAALlgF3HgAHSAA4AAgIpnvALEQAsf/EALEQAseIQABAoiEAAQG4gABYCQEAAJBYDgAFgJAcAAkFgSAEPcEAAQEgUAEPcHAAQEhA="
)

with open(sys.argv[1], "wb") as handle:
    handle.write(data)
PY

# Start mock decoder server
python3 "$MOCK_SCRIPT" --listen "$DEC_SERVER_ADDR" --token "$SERVER_TOKEN" --once >/dev/null 2>&1 &
DEC_SERVER_PID=$!
sleep 0.2

# Run ffmpeg decode
"$FFMPEG_BIN" -v error -c:v h264_videotoolbox_remote \
  -vt_remote_host "$DEC_SERVER_ADDR" -vt_remote_token "$SERVER_TOKEN" \
  -vt_remote_wire_compression 0 \
  -i "$TMP_H264" -f null -

echo "OK"
