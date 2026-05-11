#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec bash "${ROOT}/tests/integration/run_vtremoted_hevc_pixfmt_parity.sh" "$@"
