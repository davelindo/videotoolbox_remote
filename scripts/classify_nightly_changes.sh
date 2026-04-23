#!/usr/bin/env bash
set -euo pipefail

base_ref="${1:?usage: bash scripts/classify_nightly_changes.sh <base-ref> <head-ref>}"
head_ref="${2:?usage: bash scripts/classify_nightly_changes.sh <base-ref> <head-ref>}"

ffmpeg=false
vtremoted=false
obs_plugin=false
docs=false
ci=false
publishable=false
nightly_exists=true
nightly_commit=""

mark_ffmpeg_changed() {
    ffmpeg=true
}

mark_vtremoted_changed() {
    vtremoted=true
}

mark_obs_plugin_changed() {
    obs_plugin=true
}

mark_docs_changed() {
    docs=true
}

mark_ci_changed() {
    ci=true
}

mark_publishable_changed() {
    publishable=true
}

mark_build_system_changed() {
    mark_ffmpeg_changed
    mark_vtremoted_changed
    mark_obs_plugin_changed
    mark_publishable_changed
}

mark_bootstrap_change() {
    nightly_exists=false
    mark_ffmpeg_changed
    mark_vtremoted_changed
    mark_obs_plugin_changed
    mark_docs_changed
    mark_ci_changed
    mark_publishable_changed
}

if ! git rev-parse -q --verify "${base_ref}^{commit}" >/dev/null; then
    mark_bootstrap_change
else
    nightly_commit="$(git rev-parse "${base_ref}^{commit}")"

    while IFS= read -r path; do
        [[ -z "${path}" ]] && continue

        case "${path}" in
            ffmpeg/*)
                mark_ffmpeg_changed
                mark_publishable_changed
                ;;
            vtremoted/*)
                mark_vtremoted_changed
                mark_publishable_changed
                ;;
            Makefile)
                mark_build_system_changed
                ;;
            .github/workflows/ci.yml)
                mark_ci_changed
                mark_publishable_changed
                ;;
            docs/*|README.md)
                mark_docs_changed
                ;;
            obs-plugin/*)
                mark_obs_plugin_changed
                ;;
            tests/integration/run_all.sh|\
            tests/integration/run_obs_plugin_client_mock.sh|\
            tests/integration/run_obs_plugin_integration.sh|\
            tests/integration/obs_plugin_client_smoke.cpp|\
            tests/integration/obs_plugin_integration.cpp|\
            tests/integration/README.md)
                mark_ffmpeg_changed
                mark_obs_plugin_changed
                ;;
            tests/integration/obs_plugin_test_stubs/*|tests/integration/mock_vtremoted/mock_vtremoted.py)
                mark_ffmpeg_changed
                mark_obs_plugin_changed
                ;;
            tests/integration/*)
                mark_ffmpeg_changed
                ;;
        esac
    done < <(git diff --name-only "${base_ref}" "${head_ref}")
fi

cat <<EOF
nightly_exists=${nightly_exists}
nightly_commit=${nightly_commit}
ffmpeg=${ffmpeg}
vtremoted=${vtremoted}
obs_plugin=${obs_plugin}
docs=${docs}
ci=${ci}
publishable=${publishable}
EOF
