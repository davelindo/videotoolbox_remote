#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

container="${PLEX_CONTAINER:-plex}"
transcoder="/usr/lib/plexmediaserver/Plex Transcoder"
width=320
height=180
frames=24
session="$(date +%s)-$$"
host_input=""
host_output=""
container_input="/transcode/vtremote-${session}-input.mp4"
container_output="/transcode/vtremote-${session}-output.ts"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 2; }
command -v ffmpeg >/dev/null || { echo "ffmpeg is required" >&2; exit 2; }
command -v ffprobe >/dev/null || { echo "ffprobe is required" >&2; exit 2; }
docker inspect "$container" >/dev/null
docker exec "$container" test -x "$transcoder"
docker exec "$container" test -r \
  "${VTREMOTE_PLEX_BSF_LIBRARY:-/opt/vtremote-vaapi/lib/vtremote-plex-bsf.so}"

audit_count() {
  docker exec "$container" sh -c \
    'audit=${VTREMOTE_PLEX_AUDIT_FILE:-/dev/shm/plex/vtremote-plex-wrapper.log};
     if [ -f "$audit" ]; then wc -l < "$audit"; else printf "0\n"; fi' |
    tr -d ' '
}

before=$(audit_count)

cleanup() {
  docker exec "$container" rm -f -- "$container_input" "$container_output" \
    >/dev/null 2>&1 || true
  [[ -z "$host_input" ]] || rm -f -- "$host_input"
  [[ -z "$host_output" ]] || rm -f -- "$host_output"
}
trap cleanup EXIT INT TERM

host_input=$(mktemp "${TMPDIR:-/tmp}/vtremote-plex-input.XXXXXX.mp4")
host_output=$(mktemp "${TMPDIR:-/tmp}/vtremote-plex-output.XXXXXX.ts")
ffmpeg -hide_banner -loglevel error -f lavfi \
  -i "testsrc2=size=${width}x${height}:rate=24" -frames:v "$frames" \
  -c:v libx264 -pix_fmt yuv420p -movflags +faststart -y "$host_input"
docker cp "$host_input" "$container:$container_input" >/dev/null

docker exec "$container" "$transcoder" \
  -hide_banner -loglevel warning \
  -codec:0 h264 \
  -hwaccel:0 vaapi -hwaccel_output_format:0 vaapi \
  -hwaccel_device:0 vaapi \
  -i "$container_input" \
  -init_hw_device vaapi=vaapi:/dev/dri/renderD128,driver=iHD \
  -filter_hw_device vaapi \
  -filter_complex \
    "[0:0]hwupload[0];[0]scale_vaapi=w=160:h=90:format=nv12[1];[1]hwupload[2]" \
  -map '[2]' -codec:0 h264_vaapi -b:0 500000 -maxrate:0 600000 \
  -bufsize:0 1200000 -g:0 24 -bf:0 0 -an -y -f mpegts \
  "$container_output"

docker cp "$container:$container_output" "$host_output" >/dev/null
decoded_frames=$(ffprobe -v error -select_streams v:0 -count_frames \
  -show_entries stream=nb_read_frames -of default=noprint_wrappers=1:nokey=1 \
  "$host_output" | sed -n '/^[0-9][0-9]*$/ { p; q; }')
dimensions=$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height -of csv=p=0:s=x "$host_output" |
  sed -n '1p')
if [[ "$decoded_frames" != "$frames" || "$dimensions" != "160x90" ]]; then
  echo "remote transcode validation failed: frames=${decoded_frames:-0} dimensions=${dimensions:-unknown}" >&2
  exit 1
fi
after=$(audit_count)
if ((after <= before)); then
  echo "media decoded, but no remote-transcode handshake was audited" >&2
  exit 1
fi

printf 'OK: Plex Transcoder remote decode/scale/encode frames=%s dimensions=%s remote_sessions=%s\n' \
  "$decoded_frames" "$dimensions" "$((after - before))"
