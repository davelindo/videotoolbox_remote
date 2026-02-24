#!/usr/bin/env bash
set -euo pipefail

# Run the standard integration suite in order.
# Optional env toggles:
#   VTREMOTE_SKIP_SPEED=1     skip speed tests
#   VTREMOTE_RUN_MATRIX=1     include speed matrix runner
#   VTREMOTE_RUN_BENCH=1      include bench_vtremote.sh
#   VTREMOTE_RUN_LONG=1       include long vtremote_transcode test (10min by default)
#   VTREMOTE_RUN_OBS_PLUGIN=1 include obs-plugin client protocol smoke test
#   VTREMOTE_RUN_OPTION_PARITY=1 include local-vs-remote encoder option parity check

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

export FFMPEG_BIN="${FFMPEG_BIN:-${ROOT}/ffmpeg/ffmpeg}"
export FFMPEG="${FFMPEG:-${ROOT}/ffmpeg/ffmpeg}"
export FFPROBE_BIN="${FFPROBE_BIN:-${ROOT}/ffmpeg/ffprobe}"
export FFPROBE="${FFPROBE:-${ROOT}/ffmpeg/ffprobe}"

# Prefer the newest vtremoted binary (debug vs release) unless explicitly overridden.
if [[ -z "${VTREMOTED:-}" ]]; then
  VTREMOTED_DEBUG="${ROOT}/vtremoted/.build/debug/vtremoted"
  VTREMOTED_RELEASE="${ROOT}/vtremoted/.build/release/vtremoted"
  if [[ -x "$VTREMOTED_RELEASE" && -x "$VTREMOTED_DEBUG" ]]; then
    if [[ "$VTREMOTED_RELEASE" -nt "$VTREMOTED_DEBUG" ]]; then
      export VTREMOTED="$VTREMOTED_RELEASE"
    else
      export VTREMOTED="$VTREMOTED_DEBUG"
    fi
  elif [[ -x "$VTREMOTED_RELEASE" ]]; then
    export VTREMOTED="$VTREMOTED_RELEASE"
  else
    export VTREMOTED="$VTREMOTED_DEBUG"
  fi
fi

echo "Using vtremoted: ${VTREMOTED}"

run_step() {
  local name="$1"; shift
  echo "STEP: ${name}"
  "$@"
}

run_step "mock_roundtrip"      bash "${ROOT}/tests/integration/run_mock_roundtrip.sh"
run_step "mock_pts_dts"        bash "${ROOT}/tests/integration/run_mock_pts_dts_semantics.sh"
run_step "mock_transcode_pts_dts" bash "${ROOT}/tests/integration/run_mock_transcode_pts_dts_semantics.sh"
run_step "mock_decode"         bash "${ROOT}/tests/integration/run_mock_decode.sh"
if [[ "${VTREMOTE_RUN_OBS_PLUGIN:-0}" != "0" ]]; then
  run_step "obs_plugin_client_mock" bash "${ROOT}/tests/integration/run_obs_plugin_client_mock.sh"
fi
run_step "complex_chain"       bash "${ROOT}/tests/integration/run_complex_chain_test.sh"
run_step "vtremoted_roundtrip" bash "${ROOT}/tests/integration/run_vtremoted_roundtrip.sh"
run_step "vtremoted_decode"    bash "${ROOT}/tests/integration/run_vtremoted_decode.sh"
run_step "transcode_test"      bash "${ROOT}/tests/integration/run_transcode_test.sh"
if [[ "${VTREMOTE_RUN_OPTION_PARITY:-0}" != "0" ]]; then
  run_step "option_surface_parity" bash "${ROOT}/tests/integration/run_option_surface_parity.sh"
fi

if [[ "${VTREMOTE_SKIP_SPEED:-0}" == "0" ]]; then
  run_step "speed_decode_async"  bash "${ROOT}/tests/integration/run_speed_decode_async.sh"
  if [[ "${VTREMOTE_RUN_MATRIX:-0}" != "0" ]]; then
    run_step "speed_decode_matrix" bash "${ROOT}/tests/integration/run_speed_decode_matrix.sh"
  fi
fi

if [[ "${VTREMOTE_RUN_BENCH:-0}" != "0" ]]; then
  run_step "bench_vtremote" bash "${ROOT}/tests/integration/bench_vtremote.sh"
fi

if [[ "${VTREMOTE_RUN_LONG:-0}" != "0" ]]; then
  run_step "vtremoted_transcode_bsf_long" bash "${ROOT}/tests/integration/run_vtremoted_transcode_bsf_long.sh"
fi

echo "OK: all integration tests passed"
