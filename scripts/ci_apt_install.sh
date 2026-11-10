#!/usr/bin/env bash
set -euo pipefail

. /etc/os-release
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ci_apt_sources="$script_dir/ci-apt/${VERSION_CODENAME:?Ubuntu suite is required}-$(dpkg --print-architecture).list"
if [[ ! -r "$ci_apt_sources" ]]; then
  echo "No package sources for this CI platform" >&2
  exit 2
fi
ci_apt_source_parts="$(mktemp -d)"
trap 'rmdir "$ci_apt_source_parts"' EXIT

# Supply repository configuration to apt without changing the runner's sources.
ci_apt_options=(-o "Dir::Etc::sourcelist=$ci_apt_sources"
                -o "Dir::Etc::sourceparts=$ci_apt_source_parts" -o Acquire::Retries=3)
apt-get "${ci_apt_options[@]}" update
apt-get "${ci_apt_options[@]}" install -y "$@"
