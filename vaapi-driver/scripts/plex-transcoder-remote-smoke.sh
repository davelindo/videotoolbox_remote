#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

container="${PLEX_CONTAINER:-plex}"
transcoder="/usr/lib/plexmediaserver/Plex Transcoder"
width=320
height=180
frames=96
session="$(date +%s)-$$"
host_input=""
host_output_dir=""
container_input="/transcode/vtremote-${session}-input.mp4"
container_output_pattern="/transcode/vtremote-${session}-output-%03d.ts"
container_outputs=()
remote_environment=()

if [[ -n "${VTREMOTE_HOST:-}" ]]; then
  remote_environment+=(-e "VTREMOTE_HOST=$VTREMOTE_HOST")
fi
if [[ -n "${VTREMOTE_PORT:-}" ]]; then
  remote_environment+=(-e "VTREMOTE_PORT=$VTREMOTE_PORT")
fi
if [[ -n "${VTREMOTE_TOKEN:-}" ]]; then
  remote_environment+=(-e "VTREMOTE_TOKEN=$VTREMOTE_TOKEN")
fi

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
  docker exec "$container" rm -f -- "$container_input" \
    "${container_outputs[@]}" >/dev/null 2>&1 || true
  [[ -z "$host_input" ]] || rm -f -- "$host_input"
  [[ -z "$host_output_dir" ]] || rm -rf -- "$host_output_dir"
}
trap cleanup EXIT INT TERM

host_input=$(mktemp "${TMPDIR:-/tmp}/vtremote-plex-input.XXXXXX.mp4")
host_output_dir=$(mktemp -d "${TMPDIR:-/tmp}/vtremote-plex-output.XXXXXX")
ffmpeg -hide_banner -loglevel error -f lavfi \
  -i "testsrc2=size=${width}x${height}:rate=24" -frames:v "$frames" \
  -c:v libx264 -pix_fmt yuv420p -movflags +faststart -y "$host_input"
docker exec -i "$container" sh -c 'cat > "$1"' sh "$container_input" \
  < "$host_input"

docker exec "${remote_environment[@]}" "$container" "$transcoder" \
  -hide_banner -loglevel warning \
  -codec:0 h264 \
  -hwaccel:0 vaapi -hwaccel_output_format:0 vaapi \
  -hwaccel_device:0 vaapi \
  -i "$container_input" \
  -init_hw_device vaapi=vaapi:/dev/dri/renderD128,driver=iHD \
  -filter_hw_device vaapi \
  -filter_complex \
    "[0:0]scale=w=160:h=90:force_divisible_by=4[0];[0]format=pix_fmts=nv12[1];[1]hwupload[2]" \
  -map '[2]' -codec:0 h264_vaapi -b:0 500000 -maxrate:0 600000 \
  -bufsize:0 1200000 -g:0 24 -bf:0 0 -r:0 24 \
  -force_key_frames:0 'expr:gte(t,n_forced*1)' \
  -an -y -f ssegment -segment_time 1 -reset_timestamps 1 \
  "$container_output_pattern"

while IFS= read -r output; do
  [[ -z "$output" ]] || container_outputs+=("$output")
done < <(docker exec "$container" sh -c \
  'for path in /transcode/"$1"-output-*.ts; do test ! -f "$path" || printf "%s\n" "$path"; done' \
  sh "vtremote-${session}")
if ((${#container_outputs[@]} < 3)); then
  echo "remote transcode validation produced fewer than three segments" >&2
  exit 1
fi

decoded_frames=0
for container_output in "${container_outputs[@]}"; do
  host_output="$host_output_dir/$(basename "$container_output")"
  docker exec "$container" sh -c 'cat -- "$1"' sh "$container_output" \
    > "$host_output"
  segment_frames=$(ffprobe -v error -select_streams v:0 -count_frames \
    -show_entries stream=nb_read_frames \
    -of default=noprint_wrappers=1:nokey=1 "$host_output" |
    sed -n '/^[0-9][0-9]*$/ { p; q; }')
  dimensions=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height -of csv=p=0:s=x "$host_output" |
    sed -n '1p')
  first_flags=$(ffprobe -v error -select_streams v:0 -read_intervals '%+#1' \
    -show_entries packet=flags -of csv=p=0 "$host_output" | sed -n '1p')
  if [[ -z "$segment_frames" || "$segment_frames" == "0" ||
        "$dimensions" != "160x90" || "$first_flags" != *K* ]]; then
    echo "remote segment validation failed: file=$(basename "$host_output") frames=${segment_frames:-0} dimensions=${dimensions:-unknown} first_flags=${first_flags:-unknown}" >&2
    exit 1
  fi
  decoded_frames=$((decoded_frames + segment_frames))
done
if ((decoded_frames != frames)); then
  echo "remote transcode frame mismatch: expected=$frames actual=$decoded_frames" >&2
  exit 1
fi
after=$(audit_count)
if ((after <= before)); then
  echo "media decoded, but no remote-transcode handshake was audited" >&2
  exit 1
fi

printf 'OK: Plex Transcoder remote decode/scale/encode frames=%s segments=%s dimensions=%s remote_sessions=%s\n' \
  "$decoded_frames" "${#container_outputs[@]}" "$dimensions" "$((after - before))"
