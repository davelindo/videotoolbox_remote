#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

container="${PLEX_CONTAINER:-plex}"
transcoder="/usr/lib/plexmediaserver/Plex Transcoder"
width=320
height=180
frames=96
session="$(date +%s)-$$"
host_work_dir=""
container_artifacts=()
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

cleanup() {
  if ((${#container_artifacts[@]} != 0)); then
    docker exec "$container" rm -f -- "${container_artifacts[@]}" \
      >/dev/null 2>&1 || true
  fi
  [[ -z "$host_work_dir" ]] || rm -rf -- "$host_work_dir"
}
trap cleanup EXIT INT TERM

make_source() {
  local variant=$1
  local output=$2

  case "$variant" in
    h264)
      ffmpeg -hide_banner -loglevel error -f lavfi \
        -i "testsrc2=size=${width}x${height}:rate=24" -frames:v "$frames" \
        -c:v libx264 -pix_fmt yuv420p -movflags +faststart -y "$output"
      ;;
    hevc10)
      ffmpeg -hide_banner -loglevel error -f lavfi \
        -i "testsrc2=size=${width}x${height}:rate=24" -frames:v "$frames" \
        -c:v libx265 -pix_fmt yuv420p10le -tag:v hvc1 \
        -x265-params log-level=error -movflags +faststart -y "$output"
      ;;
    *)
      echo "unsupported source variant: $variant" >&2
      return 2
      ;;
  esac
}

run_case() {
  local name=$1
  local source_variant=$2
  local input_codec=$3
  local output_encoder=$4
  local expected_codec=$5
  local expected_profile=$6
  local host_input="$host_work_dir/${name}-input.mp4"
  local container_input="/transcode/vtremote-${session}-${name}-input.mp4"
  local container_output_pattern="/transcode/vtremote-${session}-${name}-output-%03d.ts"
  local host_output_dir="$host_work_dir/${name}-outputs"
  local before
  local after
  local decoded_frames=0
  local dimensions=""
  local output_codec=""
  local output_profile=""
  local source_profile=""
  local source_pixel_format=""
  local segment_frames
  local first_flags
  local container_output
  local host_output
  local encoder_options=(-profile:0 "$expected_profile")
  local container_outputs=()

  if [[ "$output_encoder" == h264_vaapi ]]; then
    encoder_options+=(-level:0 4.1 -coder:0 cabac)
  fi

  mkdir -p "$host_output_dir"
  make_source "$source_variant" "$host_input"
  if [[ "$source_variant" == hevc10 ]]; then
    source_profile=$(ffprobe -v error -select_streams v:0 \
      -show_entries stream=profile \
      -of default=noprint_wrappers=1:nokey=1 "$host_input" | sed -n '1p')
    source_pixel_format=$(ffprobe -v error -select_streams v:0 \
      -show_entries stream=pix_fmt \
      -of default=noprint_wrappers=1:nokey=1 "$host_input" | sed -n '1p')
    if [[ "$source_profile" != "Main 10" ||
          "$source_pixel_format" != "yuv420p10le" ]]; then
      echo "$name source is not HEVC Main10: profile=${source_profile:-unknown} pix_fmt=${source_pixel_format:-unknown}" >&2
      return 1
    fi
  fi
  docker exec -i "$container" sh -c 'cat > "$1"' sh "$container_input" \
    < "$host_input"
  container_artifacts+=("$container_input")
  before=$(audit_count)

  docker exec "${remote_environment[@]}" "$container" "$transcoder" \
    -hide_banner -loglevel warning \
    -codec:0 "$input_codec" \
    -hwaccel:0 vaapi -hwaccel_output_format:0 vaapi \
    -hwaccel_device:0 vaapi \
    -i "$container_input" \
    -init_hw_device vaapi=vaapi:/dev/dri/renderD128,driver=iHD \
    -filter_hw_device vaapi \
    -filter_complex \
      "[0:0]scale=w=160:h=90:force_divisible_by=4[0];[0]format=pix_fmts=nv12[1];[1]hwupload[2]" \
    -map '[2]' -codec:0 "$output_encoder" \
    -b:0 500000 -maxrate:0 600000 -bufsize:0 1200000 \
    -rc_mode:0 VBR -g:0 24 -bf:0 0 -r:0 24 \
    "${encoder_options[@]}" \
    -force_key_frames:0 'expr:gte(t,n_forced*1)' \
    -an -y -f ssegment -segment_time 1 -reset_timestamps 1 \
    "$container_output_pattern"

  while IFS= read -r container_output; do
    [[ -z "$container_output" ]] || container_outputs+=("$container_output")
  done < <(docker exec "$container" sh -c \
    'for path in /transcode/"$1"-output-*.ts; do test ! -f "$path" || printf "%s\n" "$path"; done' \
    sh "vtremote-${session}-${name}")
  container_artifacts+=("${container_outputs[@]}")
  if ((${#container_outputs[@]} < 3)); then
    echo "$name produced fewer than three segments" >&2
    return 1
  fi

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
    output_codec=$(ffprobe -v error -select_streams v:0 \
      -show_entries stream=codec_name \
      -of default=noprint_wrappers=1:nokey=1 "$host_output" | sed -n '1p')
    output_profile=$(ffprobe -v error -select_streams v:0 \
      -show_entries stream=profile \
      -of default=noprint_wrappers=1:nokey=1 "$host_output" | sed -n '1p')
    first_flags=$(ffprobe -v error -select_streams v:0 -read_intervals '%+#1' \
      -show_entries packet=flags -of csv=p=0 "$host_output" | sed -n '1p')
    if [[ -z "$segment_frames" || "$segment_frames" == "0" ||
          "$dimensions" != "160x90" || "$output_codec" != "$expected_codec" ||
          "$output_profile" != "$expected_profile" || "$first_flags" != *K* ]]; then
      echo "$name segment validation failed: file=$(basename "$host_output") frames=${segment_frames:-0} dimensions=${dimensions:-unknown} codec=${output_codec:-unknown} profile=${output_profile:-unknown} first_flags=${first_flags:-unknown}" >&2
      return 1
    fi
    decoded_frames=$((decoded_frames + segment_frames))
  done
  if ((decoded_frames != frames)); then
    echo "$name frame mismatch: expected=$frames actual=$decoded_frames" >&2
    return 1
  fi
  after=$(audit_count)
  if ((after <= before)); then
    echo "$name decoded media, but no remote-transcode handshake was audited" >&2
    return 1
  fi

  printf 'OK: %s frames=%s segments=%s dimensions=%s codec=%s profile=%s remote_sessions=%s\n' \
    "$name" "$decoded_frames" "${#container_outputs[@]}" "$dimensions" \
    "$output_codec" "$output_profile" "$((after - before))"
}

host_work_dir=$(mktemp -d "${TMPDIR:-/tmp}/vtremote-plex-smoke.XXXXXX")
run_case h264-to-h264 h264 h264 h264_vaapi h264 High
run_case hevc-main10-to-h264 hevc10 hevc h264_vaapi h264 High
run_case h264-to-hevc h264 h264 hevc_vaapi hevc Main
