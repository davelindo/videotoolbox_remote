#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 ffmpeg|vtremoted|vaapi-driver ARTIFACT.tar.gz

Unpacks a packaged release artifact and verifies the expected executable and
feature surface are present. This intentionally tests the tarball contents,
not the build directory.
EOF
}

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 1
fi

kind="$1"
artifact="$2"

if [[ ! -f "$artifact" ]]; then
  echo "artifact not found: $artifact" >&2
  exit 1
fi

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/vtremote-artifact-smoke.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

tar_args=(-xzf "$artifact" -C "$tmpdir")
if tar --help 2>&1 | grep -q -- '--no-same-owner'; then
  tar_args=(--no-same-owner --no-same-permissions "${tar_args[@]}")
fi
tar "${tar_args[@]}"

grep_feature() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  if ! grep -Eq "$pattern" "$file"; then
    echo "missing $label in $artifact" >&2
    cat "$file" >&2
    exit 1
  fi
}

case "$kind" in
  ffmpeg)
    ffmpeg_bin=""
    if [[ -x "$tmpdir/ffmpeg" ]]; then
      ffmpeg_bin="$tmpdir/ffmpeg"
    elif [[ -x "$tmpdir/ffmpeg.exe" ]]; then
      ffmpeg_bin="$tmpdir/ffmpeg.exe"
    else
      echo "ffmpeg executable not found in $artifact" >&2
      find "$tmpdir" -maxdepth 2 -type f -print >&2
      exit 1
    fi

    "$ffmpeg_bin" -hide_banner -version >/dev/null
    "$ffmpeg_bin" -hide_banner -filters >"$tmpdir/filters.txt"
    "$ffmpeg_bin" -hide_banner -encoders >"$tmpdir/encoders.txt"
    "$ffmpeg_bin" -hide_banner -decoders >"$tmpdir/decoders.txt"
    "$ffmpeg_bin" -hide_banner -bsfs >"$tmpdir/bsfs.txt"

    grep_feature "psnr filter" '(^|[[:space:]])psnr([[:space:]]|$)' "$tmpdir/filters.txt"
    grep_feature "ssim filter" '(^|[[:space:]])ssim([[:space:]]|$)' "$tmpdir/filters.txt"
    grep_feature "libvmaf filter" '(^|[[:space:]])libvmaf([[:space:]]|$)' "$tmpdir/filters.txt"
    grep_feature "h264_videotoolbox_remote encoder" '(^|[[:space:]])h264_videotoolbox_remote([[:space:]]|$)' "$tmpdir/encoders.txt"
    grep_feature "hevc_videotoolbox_remote encoder" '(^|[[:space:]])hevc_videotoolbox_remote([[:space:]]|$)' "$tmpdir/encoders.txt"
    grep_feature "h264_videotoolbox_remote decoder" '(^|[[:space:]])h264_videotoolbox_remote([[:space:]]|$)' "$tmpdir/decoders.txt"
    grep_feature "hevc_videotoolbox_remote decoder" '(^|[[:space:]])hevc_videotoolbox_remote([[:space:]]|$)' "$tmpdir/decoders.txt"
    grep_feature "vtremote_transcode bsf" '(^|[[:space:]])vtremote_transcode([[:space:]]|$)' "$tmpdir/bsfs.txt"
    ;;

  vtremoted)
    vtremoted_bin="$tmpdir/vtremoted/vtremoted"
    if [[ ! -x "$vtremoted_bin" ]]; then
      echo "vtremoted executable not found in $artifact" >&2
      find "$tmpdir" -maxdepth 3 -type f -print >&2
      exit 1
    fi

    if ! command -v otool >/dev/null 2>&1; then
      echo "otool is required to smoke-test vtremoted release artifacts" >&2
      exit 1
    fi
    if otool -L "$vtremoted_bin" | grep -Eq '/(opt/homebrew|usr/local)/(Cellar|opt|lib)/'; then
      echo "vtremoted artifact must not require absolute Homebrew dylibs" >&2
      otool -L "$vtremoted_bin" >&2
      exit 1
    fi

    if ! command -v vtool >/dev/null 2>&1; then
      echo "vtool is required to smoke-test vtremoted release artifacts" >&2
      exit 1
    fi
    minos="$(vtool -show-build "$vtremoted_bin" 2>/dev/null | awk '/minos / { print $2; exit }')"
    if [[ "${minos}" != "13.0" ]]; then
      echo "expected vtremoted minimum macOS 13.0, got ${minos:-<unknown>}" >&2
      vtool -show-build "$vtremoted_bin" >&2 || true
      exit 1
    fi

    "$vtremoted_bin" --version | grep -Eq '^vtremoted [0-9]+\.[0-9]+\.[0-9]+'
    "$vtremoted_bin" --help | grep -q -- '--listen HOST:PORT'
    ;;

  vaapi-driver)
    prefix="$tmpdir/vtremote-vaapi/opt/vtremote-vaapi"
    driver="$prefix/lib/dri/vtremote_drv_video.so"
    probe="$prefix/bin/vtremote-probe"
    sdk="$prefix/lib/libvtremote_client.a"
    header="$prefix/include/vtremote/client.h"
    [[ -f "$driver" && -x "$probe" && -f "$sdk" && -f "$header" ]] || {
      echo "VA-API runtime or static SDK payload missing from $artifact" >&2
      find "$tmpdir" -maxdepth 6 -type f -print >&2
      exit 1
    }
    [[ -L "$prefix/lib/dri/vgem_drv_video.so" ]] || {
      echo "vgem driver alias missing from $artifact" >&2
      exit 1
    }
    [[ -L "$prefix/lib/dri/iHD_drv_video.so" ]] || {
      echo "isolated Plex iHD alias missing from $artifact" >&2
      exit 1
    }
    "$probe" --version | grep -Eq '^vtremote-probe [0-9A-Za-z._+-]+'
    if readelf -d "$driver" | grep -q 'Shared library: \[libva'; then
      echo "VA driver must not link to libva" >&2
      readelf -d "$driver" >&2
      exit 1
    fi
    exports="$(nm -D --defined-only "$driver" | awk '{print $3}' | sed '/^$/d')"
    if [[ "$exports" != "__vaDriverInit_1_22" ]]; then
      echo "unexpected VA driver exports:" >&2
      printf '%s\n' "$exports" >&2
      exit 1
    fi
    for runtime_binary in "$driver" "$probe"; do
      max_glibc="$(readelf --version-info "$runtime_binary" | \
        sed -n 's/.*Name: GLIBC_\([^[:space:]]*\).*/\1/p' | sort -V | tail -n1)"
      if [[ -n "$max_glibc" && "$(printf '2.17\n%s\n' "$max_glibc" | sort -V | tail -n1)" != "2.17" ]]; then
        echo "$(basename "$runtime_binary") requires GLIBC_$max_glibc; release ceiling is GLIBC_2.17" >&2
        exit 1
      fi
    done
    ;;

  *)
    usage >&2
    exit 1
    ;;
esac

echo "OK: $kind artifact smoke passed for $artifact"
