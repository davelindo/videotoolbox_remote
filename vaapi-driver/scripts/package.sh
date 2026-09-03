#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-or-later
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
repo_dir=$(CDPATH= cd -- "$source_dir/.." && pwd)
metadata_dir=$repo_dir
if [ ! -f "$metadata_dir/LICENSE.md" ]; then metadata_dir=$source_dir; fi
if [ -n "${VERSION:-}" ]; then
    version=$VERSION
elif [ -f "$source_dir/VERSION" ]; then
    version=$(sed -n '1p' "$source_dir/VERSION")
else
    version=$(git -C "$repo_dir" describe --tags --always --dirty 2>/dev/null || printf dev)
fi
version=${version#v}
architecture=$(uname -m)
if [ "$architecture" != x86_64 ]; then
    echo "release bundles support Linux x86_64 only (found $architecture)" >&2
    exit 1
fi
if [ -z "${VTREMOTE_PLEX_FFMPEG_SOURCE_DIR:-}" ]; then
    echo "VTREMOTE_PLEX_FFMPEG_SOURCE_DIR is required for complete release bundles" >&2
    exit 1
fi
out_dir=${OUT_DIR:-$source_dir/dist}
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/vtremote-vaapi-package.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT INT TERM
build_dir="$work_dir/build"
stage="$work_dir/vtremote-vaapi"

mkdir -p "$out_dir" "$stage"
cmake -S "$source_dir" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/opt/vtremote-vaapi \
    -DVTREMOTE_VERSION="$version" \
    -DVTREMOTE_WARNINGS_AS_ERRORS=ON \
    -DVTREMOTE_INSTALL_VGEM_ALIAS=ON \
    -DVTREMOTE_INSTALL_IHD_ALIAS=ON \
    -DVTREMOTE_PLEX_FFMPEG_SOURCE_DIR="$VTREMOTE_PLEX_FFMPEG_SOURCE_DIR"
cmake --build "$build_dir" --parallel
(cd "$build_dir" && ctest --output-on-failure)
DESTDIR="$stage" cmake --install "$build_dir"

mkdir -p "$stage/docs"
cp "$source_dir/README.md" "$source_dir/THIRD_PARTY_NOTICES.md" "$stage/docs/"
cp "$metadata_dir/LICENSE.md" "$metadata_dir/COPYING.LGPLv2.1" \
   "$metadata_dir/SECURITY.md" "$metadata_dir/CHANGELOG.md" "$stage/docs/"
cp -R "$source_dir/docs/." "$stage/docs/"
cp "$source_dir/packaging/install-binary.sh" "$stage/install-binary.sh"
cp "$source_dir/packaging/BINARY-INSTALL.md" "$stage/INSTALL.md"
chmod +x "$stage/install-binary.sh"
printf '%s\n' "$version" > "$stage/VERSION"

(
    cd "$stage"
    find . -type f ! -name SHA256SUMS -exec sha256sum {} + | sort > SHA256SUMS
)

artifact="$out_dir/vtremote-vaapi-linux-$architecture.tar.gz"
tar -C "$work_dir" -czf "$artifact" vtremote-vaapi
(cd "$out_dir" && sha256sum "$(basename "$artifact")") > "$artifact.sha256"
printf '%s\n' "$artifact"
