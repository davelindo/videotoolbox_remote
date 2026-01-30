#!/usr/bin/env bash
set -euo pipefail

# Run the standard integration suite in order.
# Optional env toggles:
#   VTREMOTE_SKIP_SPEED=1     skip speed tests
#   VTREMOTE_RUN_MATRIX=1     include speed matrix runner
#   VTREMOTE_RUN_BENCH=1      include bench_vtremote.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

export FFMPEG_BIN="${FFMPEG_BIN:-${ROOT}/ffmpeg/ffmpeg}"
export FFMPEG="${FFMPEG:-${ROOT}/ffmpeg/ffmpeg}"
export FFPROBE_BIN="${FFPROBE_BIN:-${ROOT}/ffmpeg/ffprobe}"
export FFPROBE="${FFPROBE:-${ROOT}/ffmpeg/ffprobe}"
export VTREMOTED="${VTREMOTED:-${ROOT}/vtremoted/.build/debug/vtremoted}"

run_step() {
  local name="$1"; shift
  echo "STEP: ${name}"
  "$@"
}

run_step "mock_roundtrip"      bash "${ROOT}/tests/integration/run_mock_roundtrip.sh"
run_step "complex_chain"       bash "${ROOT}/tests/integration/run_complex_chain_test.sh"
run_step "vtremoted_roundtrip" bash "${ROOT}/tests/integration/run_vtremoted_roundtrip.sh"
run_step "vtremoted_decode"    bash "${ROOT}/tests/integration/run_vtremoted_decode.sh"
run_step "transcode_test"      bash "${ROOT}/tests/integration/run_transcode_test.sh"

if [[ "${VTREMOTE_SKIP_SPEED:-0}" == "0" ]]; then
  run_step "speed_decode_async"  bash "${ROOT}/tests/integration/run_speed_decode_async.sh"
  if [[ "${VTREMOTE_RUN_MATRIX:-0}" != "0" ]]; then
    run_step "speed_decode_matrix" bash "${ROOT}/tests/integration/run_speed_decode_matrix.sh"
  fi
fi

if [[ "${VTREMOTE_RUN_BENCH:-0}" != "0" ]]; then
  run_step "bench_vtremote" bash "${ROOT}/tests/integration/bench_vtremote.sh"
fi

echo "OK: all integration tests passed"
