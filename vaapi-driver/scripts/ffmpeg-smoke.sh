#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-or-later
set -eu

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "usage: $0 DRIVER_DIR RENDER_NODE VTREMOTE_HOST [h264|hevc|hevc10]" >&2
    exit 2
fi

driver_dir=$1
render_node=$2
endpoint=$3
codec=${4:-h264}
output=${TMPDIR:-/tmp}/vtremote-vaapi-smoke-$$.mkv
trap 'rm -f "$output"' EXIT INT TERM

case "$codec" in
    h264) encoder=h264_vaapi; pixel=nv12; profile_args= ;;
    hevc) encoder=hevc_vaapi; pixel=nv12; profile_args= ;;
    hevc10) encoder=hevc_vaapi; pixel=p010le; profile_args='-profile:v main10' ;;
    *) echo "unknown codec mode: $codec" >&2; exit 2 ;;
esac

export LIBVA_DRIVER_NAME=vtremote
export LIBVA_DRIVERS_PATH=$driver_dir
export VTREMOTE_HOST=$endpoint

# shellcheck disable=SC2086
ffmpeg -hide_banner -loglevel verbose \
    -init_hw_device "vaapi=remote:${render_node}" \
    -filter_hw_device remote \
    -f lavfi -i 'testsrc2=size=640x360:rate=30:duration=1' \
    -vf "format=${pixel},hwupload" \
    -c:v "$encoder" $profile_args -bf 0 -b:v 3M \
    -an -y "$output"

echo "smoke encode succeeded: $codec via $endpoint"
