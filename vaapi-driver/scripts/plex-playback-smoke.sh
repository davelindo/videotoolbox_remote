#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

plex_url="${PLEX_URL:-http://127.0.0.1:32400}"
plex_token="${PLEX_TOKEN:?set PLEX_TOKEN}"
rating_key="${PLEX_RATING_KEY:?set PLEX_RATING_KEY}"
container="${PLEX_CONTAINER:-plex}"

if [[ ! "$rating_key" =~ ^[0-9]+$ ]]; then
  echo "PLEX_RATING_KEY must be numeric" >&2
  exit 2
fi
command -v curl >/dev/null || { echo "curl is required" >&2; exit 2; }
command -v docker >/dev/null || { echo "docker is required" >&2; exit 2; }
docker inspect "$container" >/dev/null

driver_log_count() {
  {
    docker logs --tail 10000 "$container" 2>&1 || true
    docker exec "$container" sh -c \
      'grep -R -h -E "connected context|VTRemote VA-API driver" "/config/Library/Application Support/Plex Media Server/Logs" 2>/dev/null || true'
  } | grep -c -E 'connected context|VTRemote VA-API driver' || true
}

before=$(driver_log_count)
session="vtremote-vaapi-smoke-$(date +%s)-$$"
query="path=%2Flibrary%2Fmetadata%2F${rating_key}&mediaIndex=0&partIndex=0&protocol=hls&fastSeek=1&directPlay=0&directStream=0&subtitleSize=100&audioBoost=100&location=lan&maxVideoBitrate=2000&videoQuality=60&videoResolution=1280x720&session=${session}"
url="${plex_url%/}/video/:/transcode/universal/start.m3u8?${query}"
plex_headers=(
  -H "X-Plex-Token: $plex_token"
  -H "X-Plex-Client-Identifier: $session"
  -H "X-Plex-Product: Plex Web"
  -H "X-Plex-Version: 4.141.0"
  -H "X-Plex-Platform: Chrome"
  -H "X-Plex-Platform-Version: 140.0"
  -H "X-Plex-Device: Linux"
  -H "X-Plex-Device-Name: VTRemote VA-API Smoke"
  -H "X-Plex-Provides: player"
)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/vtremote-plex-smoke.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

playlist="$work_dir/playlist.m3u8"
for depth in 1 2 3; do
  curl -fsS --max-time 90 "${plex_headers[@]}" "$url" -o "$playlist"
  grep -q '^#EXTM3U' "$playlist" || { echo "Plex did not return an HLS playlist" >&2; exit 1; }
  next=$(sed -n '/^[^#[:space:]]/ { p; q; }' "$playlist")
  [[ -n "$next" ]] || { echo "Plex playlist contains no media URI" >&2; exit 1; }
  if [[ "$next" == http://* || "$next" == https://* ]]; then
    url="$next"
  elif [[ "$next" == /* ]]; then
    url="${plex_url%/}${next}"
  else
    url="${url%%\?*}"
    url="${url%/*}/${next}"
  fi
  if [[ "$next" != *.m3u8* ]]; then
    break
  fi
done

segment="$work_dir/segment.bin"
curl -fsS --max-time 90 "${plex_headers[@]}" "$url" -o "$segment"
size=$(wc -c < "$segment" | tr -d ' ')
if (( size < 32 )); then
  echo "Plex returned an empty or truncated media segment ($size bytes)" >&2
  exit 1
fi

after=$(driver_log_count)
if (( after <= before )); then
  echo "Plex returned media, but no new VTRemote VA-API driver log entry was observed" >&2
  echo "Confirm VTREMOTE_LOG=1 and inspect the Plex Transcoder log" >&2
  exit 1
fi

printf 'OK: Plex playback transcode session=%s segment_bytes=%s driver_log_entries=%s\n' \
  "$session" "$size" "$((after - before))"
