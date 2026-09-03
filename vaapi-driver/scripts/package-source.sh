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
out_dir=${OUT_DIR:-$source_dir/dist}
name="vtremote-vaapi-$version-source"
stage=$(mktemp -d "${TMPDIR:-/tmp}/vtremote-vaapi-source.XXXXXX")
trap 'rm -rf "$stage"' EXIT INT TERM

mkdir -p "$out_dir" "$stage/$name"
(
    cd "$source_dir"
    tar --exclude='./build*' --exclude='./dist' --exclude='*/__pycache__' \
        --exclude='*.pyc' --exclude='*.o' --exclude='*.a' --exclude='*.so' \
        --exclude='*.tar.gz' -cf - .
) | tar -C "$stage/$name" -xf -
cp "$metadata_dir/LICENSE.md" "$metadata_dir/COPYING.LGPLv2.1" \
   "$metadata_dir/SECURITY.md" "$metadata_dir/CHANGELOG.md" "$stage/$name/"
printf '%s\n' "$version" > "$stage/$name/VERSION"

epoch=${SOURCE_DATE_EPOCH:-$(git -C "$repo_dir" show -s --format=%ct HEAD 2>/dev/null || date +%s)}
artifact="$out_dir/$name.tar.gz"
if tar --help 2>&1 | grep -q -- '--sort'; then
    tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
        -C "$stage" -czf "$artifact" "$name"
else
    tar -C "$stage" -czf "$artifact" "$name"
fi
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$out_dir" && sha256sum "$(basename "$artifact")") > "$artifact.sha256"
else
    (cd "$out_dir" && shasum -a 256 "$(basename "$artifact")") > "$artifact.sha256"
fi
printf '%s\n' "$artifact"
