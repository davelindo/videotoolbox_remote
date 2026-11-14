#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ccache() {
  case "$1" in
    --show-stats) return 0 ;;
    --print-stats) printf '%s\n' "$MOCK_CCACHE_STATS" ;;
    *) return 2 ;;
  esac
}
export -f ccache

for stats in 'cache_miss 1' 'direct_cache_hit 2' 'preprocessed_cache_hit 3'; do
  MOCK_CCACHE_STATS="$stats" bash "$repo_root/scripts/check_ccache.sh"
done
for stats in '' 'cache_miss 0' 'called_for_link 20'; do
  if MOCK_CCACHE_STATS="$stats" bash "$repo_root/scripts/check_ccache.sh" >/dev/null 2>&1; then
    echo 'expected an unused compiler cache to fail verification' >&2
    exit 1
  fi
done
echo 'ok: compiler cache verification accepts compilation hits/misses and rejects bypassed caches'
