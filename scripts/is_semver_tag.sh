#!/usr/bin/env bash
set -euo pipefail

tag="${1:-}"

[[ "${tag}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
