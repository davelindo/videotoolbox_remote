#!/usr/bin/env bash
set -euo pipefail

ccache --show-stats
ccache --print-stats | awk '
  $1 == "cache_miss" || $1 == "direct_cache_hit" || $1 == "preprocessed_cache_hit" {
    calls += $2
  }
  END {
    if (calls == 0) {
      print "ERROR: no compilations passed through ccache" > "/dev/stderr"
      exit 1
    }
  }
'
