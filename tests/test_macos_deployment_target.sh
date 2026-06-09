#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
makefile="${repo_root}/Makefile"

if ! grep -F 'MACOSX_DEPLOYMENT_TARGET ?= 13.0' "${makefile}" >/dev/null; then
  echo "expected default MACOSX_DEPLOYMENT_TARGET to remain 13.0" >&2
  exit 1
fi

if grep -F 'MACOSX_DEPLOYMENT_TARGET ?= $(if $(MACOSX_SDK_VERSION)' "${makefile}" >/dev/null; then
  echo "deployment target must not default to the installed SDK version" >&2
  exit 1
fi

if ! grep -F 'export MACOSX_DEPLOYMENT_TARGET="$(MACOSX_DEPLOYMENT_TARGET)"' "${makefile}" >/dev/null; then
  echo "expected build-vtremoted to export MACOSX_DEPLOYMENT_TARGET" >&2
  exit 1
fi

vtremoted_bin="${repo_root}/vtremoted/.build/release/vtremoted"
if [[ -x "${vtremoted_bin}" ]]; then
  if ! command -v vtool >/dev/null 2>&1; then
    echo "vtool is required to verify the built vtremoted deployment target" >&2
    exit 1
  fi
  minos="$(vtool -show-build "${vtremoted_bin}" 2>/dev/null | awk '/minos / { print $2; exit }')"
  if [[ "${minos}" != "13.0" ]]; then
    echo "expected built vtremoted minimum macOS 13.0, got ${minos:-<unknown>}" >&2
    vtool -show-build "${vtremoted_bin}" >&2 || true
    exit 1
  fi
fi

echo "ok"
