#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-or-later
set -eu

prefix=/opt/vtremote-vaapi
build_dir=
plex_alias=0
run_tests=1
build_type=Release

usage() {
    cat <<USAGE
usage: $0 [--prefix PATH] [--build-dir PATH] [--plex-alias] [--no-test]

Build and install vtremote-vaapi into an isolated prefix.  The optional Plex
alias is created only inside PREFIX/lib/dri and never overwrites the system iHD.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix) prefix=$2; shift 2 ;;
        --build-dir) build_dir=$2; shift 2 ;;
        --plex-alias) plex_alias=1; shift ;;
        --no-test) run_tests=0; shift ;;
        --debug) build_type=Debug; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
repo_dir=$(CDPATH= cd -- "$source_dir/.." && pwd)
if [ -n "${VERSION:-}" ]; then
    version=$VERSION
elif [ -f "$source_dir/VERSION" ]; then
    version=$(sed -n '1p' "$source_dir/VERSION")
else
    version=$(git -C "$repo_dir" describe --tags --always --dirty 2>/dev/null || printf dev)
fi
version=${version#v}
if [ -z "$build_dir" ]; then
    build_dir="$source_dir/build-install"
fi

cmake -S "$source_dir" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE="$build_type" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DVTREMOTE_VERSION="$version" \
    -DVTREMOTE_INSTALL_VGEM_ALIAS=ON \
    -DVTREMOTE_INSTALL_IHD_ALIAS=$([ "$plex_alias" -eq 1 ] && echo ON || echo OFF)
cmake --build "$build_dir" --parallel
if [ "$run_tests" -eq 1 ]; then
    (cd "$build_dir" && ctest --output-on-failure)
fi
cmake --install "$build_dir"

driver=$(find "$prefix" -type f -name vtremote_drv_video.so -print -quit)
if [ -z "$driver" ]; then
    echo "installed driver was not found under $prefix" >&2
    exit 1
fi


cat <<DONE
installed: $driver

Set these in the application environment:
  LIBVA_DRIVER_NAME=vtremote
  LIBVA_DRIVERS_PATH=$(dirname "$driver")
  VTREMOTE_HOST=mac-private-ip:5555
  VTREMOTE_WIRE_COMPRESSION=auto

A real, accessible DRM render node is also required.  For a virtual node:
  sudo modprobe vgem
DONE
