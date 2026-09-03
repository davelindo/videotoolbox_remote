#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-or-later
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
destdir=${DESTDIR:-/}
source_prefix="$script_dir/opt/vtremote-vaapi"
target_parent="$destdir/opt"
target="$target_parent/vtremote-vaapi"

if [ ! -f "$source_prefix/lib/dri/vtremote_drv_video.so" ]; then
    echo "bundle payload is missing: $source_prefix" >&2
    exit 1
fi
if [ -e "$target" ]; then
    echo "refusing to replace existing installation: $target" >&2
    echo "move it aside or remove it explicitly, then run this installer again" >&2
    exit 1
fi

mkdir -p "$target_parent"
cp -a "$source_prefix" "$target"

cat <<DONE
Installed VTRemote VA-API into:
  $target

Application environment:
  LIBVA_DRIVERS_PATH=/opt/vtremote-vaapi/lib/dri
  LIBVA_DRIVER_NAME=vtremote
  VTREMOTE_HOST=mac-private-ip:5555
  VTREMOTE_WIRE_COMPRESSION=auto

The host must expose an accessible DRM render node. For vgem:
  sudo modprobe vgem
DONE
