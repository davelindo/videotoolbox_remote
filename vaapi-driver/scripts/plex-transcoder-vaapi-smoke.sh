#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

container="${PLEX_CONTAINER:-plex}"
render_device="${RENDER_DEVICE:-/dev/dri/renderD128}"
transcoder="/usr/lib/plexmediaserver/Plex Transcoder"
probe="/opt/vtremote-vaapi/bin/vtremote-probe"
width=320
height=180
frames=30
session="$(date +%s)-$$"
created=()

command -v docker >/dev/null || { echo "docker is required" >&2; exit 2; }
docker inspect "$container" >/dev/null
docker exec "$container" test -x "$transcoder"
docker exec "$container" test -c "$render_device"

remote_host=$(docker exec "$container" printenv VTREMOTE_HOST)
if [[ -z "$remote_host" ]]; then
  echo "VTREMOTE_HOST is not set in $container" >&2
  exit 2
fi

cleanup() {
  if ((${#created[@]})); then
    docker exec "$container" rm -f -- "${created[@]}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

docker exec "$container" "$probe" --host "$remote_host" --codec h264 >/dev/null

run_case() {
  local label=$1
  local codec=$2
  local pixel_format=$3
  local frame_bytes=$4
  local muxer=$5
  local profile=$6
  local input="/transcode/vtremote-vaapi-${session}-${label}.raw"
  local output="/transcode/vtremote-vaapi-${session}-${label}.${muxer}"
  local size

  created+=("$input" "$output")
  docker exec "$container" dd if=/dev/zero of="$input" \
    bs="$frame_bytes" count="$frames" status=none
  docker exec "$container" "$transcoder" \
    -hide_banner -loglevel warning \
    -init_hw_device "vaapi=remote:${render_device}" \
    -filter_hw_device remote \
    -f rawvideo -pix_fmt "$pixel_format" \
    -video_size "${width}x${height}" -framerate 30 -i "$input" \
    -vf hwupload -an -frames:v "$frames" \
    -c:v "$codec" -profile:v "$profile" -b:v 1M -bf 0 -g 30 \
    -y -f "$muxer" "$output"
  size=$(docker exec "$container" stat -c %s "$output")
  if ((size < 32)); then
    echo "$label produced an empty or truncated bitstream ($size bytes)" >&2
    exit 1
  fi
  printf 'ok: %-11s frames=%d bytes=%d\n' "$label" "$frames" "$size"
}

nv12_frame_bytes=$((width * height * 3 / 2))
p010_frame_bytes=$((width * height * 3))

run_case h264 h264_vaapi nv12 "$nv12_frame_bytes" h264 high
run_case hevc-main hevc_vaapi nv12 "$nv12_frame_bytes" hevc main
run_case hevc-main10 hevc_vaapi p010le "$p010_frame_bytes" hevc main10

echo "OK: Plex Transcoder VA-API remote encode smoke passed without a claimed server"
