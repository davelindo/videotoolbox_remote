#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
package="${repo_root}/vtremoted/Package.swift"

if ! grep -F '.macOS(.v13)' "${package}" >/dev/null; then
  echo "expected vtremoted Package.swift to declare macOS v13 minimum" >&2
  exit 1
fi

if grep -Eq '(^|[^[:alnum:]_])(CLZ4|CZstd)([^[:alnum:]_]|$)' "${package}" >/dev/null; then
  echo "Package.swift must not reintroduce CLZ4/CZstd system library targets" >&2
  exit 1
fi

if find "${repo_root}/vtremoted/Sources" -maxdepth 1 -type d \( -name CLZ4 -o -name CZstd \) | grep -q .; then
  echo "CLZ4/CZstd system library source directories must not be reintroduced" >&2
  exit 1
fi

echo "ok"
