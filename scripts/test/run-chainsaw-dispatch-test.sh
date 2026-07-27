#!/usr/bin/env bash
set -euo pipefail

source scripts/test/lib/catalog.sh

runner='scripts/test/run-chainsaw.sh'
catalog='tests/catalog.yaml'

expect_dispatch_rejection() {
  local description="$1"
  shift
  local exit_code

  set +e
  "$runner" "$@" >/dev/null 2>&1
  exit_code="$?"
  set -e

  [[ "$exit_code" -eq 2 ]] || {
    echo "${description}: expected dispatch exit 2, got ${exit_code}." >&2
    exit 1
  }
}

expect_dispatch_rejection 'all is not a registered smoke target' smoke all
expect_dispatch_rejection 'scenario cannot occupy the target axis' smoke flux-ready
expect_dispatch_rejection 'self-test cannot occupy the target axis' smoke diagnostics-self-test
expect_dispatch_rejection 'unknown smoke scenario is rejected' smoke cluster unknown-scenario
expect_dispatch_rejection 'media target requires a scenario' smoke media
expect_dispatch_rejection 'unknown media smoke scenario is rejected' smoke media unknown-scenario
expect_dispatch_rejection 'unknown platform smoke scenario is rejected' smoke platform unknown-scenario
expect_dispatch_rejection 'diagnostics rejects a scenario argument' diagnostics cluster flux-ready
expect_dispatch_rejection 'smoke requires an explicit target' smoke
expect_dispatch_rejection 'resilience rejects a scenario argument' resilience qbittorrent-vpn-disconnect extra
expect_dispatch_rejection 'e2e rejects a scenario argument' e2e media-hardlink extra

# Positive registration is checked through the authoritative catalog so this offline
# test never crosses the kubeconfig guard and contacts a live cluster.
smoke_entry="$(catalog_dispatch_entry "$catalog" smoke media qbit-manage)"
[[ "$(yq -r '.dispatch.path' - <<<"$smoke_entry")" == 'tests/chainsaw/smoke/media/qbit-manage' ]]
[[ "$(yq -r '.dispatch.selector' - <<<"$smoke_entry")" == 'homelab-talos/suite=qbit-manage' ]]

e2e_entry="$(catalog_dispatch_entry "$catalog" e2e qbit-manage-policy '')"
[[ "$(yq -r '.dispatch.path' - <<<"$e2e_entry")" == 'tests/chainsaw/e2e/qbit-manage-policy' ]]
[[ "$(yq -r '.confirmation.variable' - <<<"$e2e_entry")" == 'CLUSTER_E2E_CONFIRM' ]]

rg -Fq 'catalog_dispatch_entry "$catalog" "$tier" "$target" "$scenario"' "$runner"
rg -Fq 'scripts/test/safety/require-e2e-confirmation.sh "$target"' "$runner"
rg -Fq 'acquire_state_lock' "$runner"
