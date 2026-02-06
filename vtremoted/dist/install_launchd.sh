#!/usr/bin/env bash
set -euo pipefail

# Deprecated wrapper kept for backwards compatibility with older instructions.
#
# Source of truth lives at: vtremoted/install_launchd.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "${ROOT}/install_launchd.sh" "$@"
