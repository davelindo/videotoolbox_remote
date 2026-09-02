#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-or-later
set -eu

if [ ! -d /dev/dri ]; then
    echo "/dev/dri does not exist; attempting to load vgem" >&2
    if command -v modprobe >/dev/null 2>&1; then
        modprobe vgem
    fi
fi

found=0
for node in /dev/dri/renderD*; do
    [ -e "$node" ] || continue
    found=1
    ls -l "$node"
done
if [ "$found" -eq 0 ]; then
    echo "no DRM render node found; check CONFIG_DRM_VGEM or expose a physical GPU node" >&2
    exit 1
fi
