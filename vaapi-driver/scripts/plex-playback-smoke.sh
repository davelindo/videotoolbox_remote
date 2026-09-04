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
command -v ffprobe >/dev/null || { echo "ffprobe is required" >&2; exit 2; }
docker inspect "$container" >/dev/null

wrapper_audit_count() {
  docker exec "$container" sh -c \
    'audit=${VTREMOTE_PLEX_AUDIT_FILE:-/dev/shm/plex/vtremote-plex-wrapper.log};
     if [ -f "$audit" ]; then wc -l < "$audit"; else printf "0\n"; fi' \
    | tr -d ' '
}

before=$(wrapper_audit_count)
session="vtremote-vaapi-smoke-$(date +%s)-$$"
query="path=%2Flibrary%2Fmetadata%2F${rating_key}&mediaIndex=0&partIndex=0&protocol=hls&fastSeek=1&directPlay=0&directStream=0&subtitleSize=100&audioBoost=100&location=lan&maxVideoBitrate=2000&videoQuality=60&videoResolution=1280x720&session=${session}&hasMDE=1&X-Plex-Client-Profile-Name=Chrome"
plex_headers=(
  -H "X-Plex-Token: $plex_token"
  -H "X-Plex-Client-Identifier: $session"
  -H "X-Plex-Session-Identifier: $session"
  -H "X-Plex-Client-Profile-Name: Chrome"
  -H "X-Plex-Product: Plex Web"
  -H "X-Plex-Version: 4.141.0"
  -H "X-Plex-Platform: Chrome"
  -H "X-Plex-Platform-Version: 140.0"
  -H "X-Plex-Device: Linux"
  -H "X-Plex-Device-Name: VTRemote VA-API Smoke"
  -H "X-Plex-Provides: player"
)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/vtremote-plex-smoke.XXXXXX")
cleanup() {
  curl -fsS --max-time 10 "${plex_headers[@]}" \
    "${plex_url%/}/video/:/transcode/universal/stop?session=${session}" \
    >/dev/null 2>&1 || true
  rm -rf "$work_dir"
}
trap cleanup EXIT INT TERM

decision="$work_dir/decision.xml"
curl -fsS --max-time 90 "${plex_headers[@]}" \
  "${plex_url%/}/video/:/transcode/universal/decision?${query}" -o "$decision"
grep -q '<MediaContainer' "$decision" || {
  echo "Plex did not return a playback decision" >&2
  exit 1
}

url="${plex_url%/}/video/:/transcode/universal/start.m3u8?${query}"

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

decoded_frames=$(ffprobe -v error -select_streams v:0 -count_frames \
  -show_entries stream=nb_read_frames -of default=noprint_wrappers=1:nokey=1 \
  "$segment" | sed -n '/^[0-9][0-9]*$/ { p; q; }')
if [[ -z "$decoded_frames" ]] || (( decoded_frames < 1 )); then
  echo "Plex returned a segment without decodable video frames" >&2
  exit 1
fi
output_codec=$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 \
  "$segment" | sed -n '1p')
if [[ "$output_codec" != h264 ]]; then
  echo "Plex returned ${output_codec:-unknown} video; expected h264" >&2
  exit 1
fi

after=$(wrapper_audit_count)
if (( after <= before )); then
  echo "Plex returned media, but the VTRemote Plex wrapper was not used" >&2
  exit 1
fi

printf 'OK: Plex playback transcode session=%s segment_bytes=%s decoded_frames=%s codec=%s wrapper_uses=%s\n' \
  "$session" "$size" "$decoded_frames" "$output_codec" "$((after - before))"
