#!/usr/bin/env bash
set -euo pipefail

source scripts/test/lib/catalog.sh

repo_root="$(git rev-parse --show-toplevel)"
runner='scripts/test/run-live-suite.sh'
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
expect_dispatch_rejection 'integration rejects a scenario argument' integration media-hardlink extra

# Positive registration is checked through the authoritative catalog so this offline
# test never crosses the kubeconfig guard and contacts a live cluster.
smoke_entry="$(catalog_dispatch_entry "$catalog" smoke media qbit-manage)"
[[ "$(yq -r '.dispatch.path' - <<<"$smoke_entry")" == 'tests/chainsaw/smoke/media/qbit-manage' ]]
[[ "$(yq -r '.dispatch.selector' - <<<"$smoke_entry")" == 'homelab-talos/suite=qbit-manage' ]]

e2e_entry="$(catalog_dispatch_entry "$catalog" e2e qbit-manage-policy '')"
[[ "$(yq -r '.dispatch.path' - <<<"$e2e_entry")" == 'scripts/test/scenarios/qbit_manage_policy.py' ]]
[[ "$(yq -r '.dispatch.mode' - <<<"$e2e_entry")" == 'direct' ]]
[[ "$(yq -r '.confirmation.variable' - <<<"$e2e_entry")" == 'CLUSTER_E2E_CONFIRM' ]]

integration_entry="$(catalog_dispatch_entry "$catalog" integration media-hardlink '')"
[[ "$(yq -r '.dispatch.runtime' - <<<"$integration_entry")" == 'bash' ]]

if catalog_dispatch_entry "$catalog" resilience plex-node-reboot '' >/dev/null 2>&1; then
  echo 'Retired plex-node-reboot dispatch remains registered.' >&2
  exit 1
fi

n8n_persistence_entry="$(
  catalog_dispatch_entry "$catalog" resilience n8n-persistence ''
)"
[[ "$(yq -r '.metadata.id' - <<<"$n8n_persistence_entry")" == \
  'test.n8n-persistence' ]]
[[ "$(yq -r '.dispatch.path' - <<<"$n8n_persistence_entry")" == \
  'scripts/test/scenarios/n8n-persistence.sh' ]]

report_persistence_entry="$(
  catalog_dispatch_entry "$catalog" resilience test-reports-persistence ''
)"
[[ "$(yq -r '.dispatch.mode' - <<<"$report_persistence_entry")" == 'chainsaw' ]]
[[ "$(yq -r '.confirmation.variable' - <<<"$report_persistence_entry")" == \
  'CLUSTER_CHAOS_CONFIRM' ]]

rg -Fq 'catalog_dispatch_entry "$catalog" "$tier" "$target" "$scenario"' "$runner"
rg -Fq 'scripts/test/run-catalog-suite.sh "$suite_id"' "$runner"
rg -Fq 'scripts/test/run-chainsaw.sh "$tier" "$target"' "$runner"
if rg -Fq '.test-results/state-changing.lock' "$runner"; then
  echo 'Live dispatch still uses a checkout-local state-changing lock.' >&2
  exit 1
fi

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/live-dispatch-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
mkdir -p "$fixture_root/scripts/test/lib" "$fixture_root/tests"
cp scripts/test/run-live-suite.sh "$fixture_root/scripts/test/run-live-suite.sh"
cp scripts/lib/common.sh "$fixture_root/scripts/lib-common.sh"
cp scripts/test/lib/catalog.sh "$fixture_root/scripts/test/lib/catalog.sh"
cp tests/catalog.yaml "$fixture_root/tests/catalog.yaml"
mkdir -p "$fixture_root/scripts/lib"
mv "$fixture_root/scripts/lib-common.sh" "$fixture_root/scripts/lib/common.sh"
cat >"$fixture_root/scripts/test/run-catalog-suite.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"${DISPATCH_TEST_CALLS:?}"
EOF
chmod +x "$fixture_root/scripts/test/run-catalog-suite.sh"
mkdir -p "$fixture_root/bin"
touch "$fixture_root/kubeconfig"
cat >"$fixture_root/blocked-nodes.json" <<'EOF'
{"items":[{"metadata":{"name":"nuc1"},"spec":{"unschedulable":false},"status":{"conditions":[{"type":"Ready","status":"False"}]}},{"metadata":{"name":"nuc2"},"spec":{"unschedulable":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"nuc3"},"spec":{"unschedulable":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}
EOF
cat >"$fixture_root/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *' config view --minify '*) printf '%s' fixture-cluster ;;
  *' config current-context '*) printf '%s\n' fixture ;;
  *' get nodes --output json '*)
    [[ " $* " == *' --context fixture '* ]] || exit 65
    cat "${DISRUPTION_TEST_NODES:?}"
    ;;
  *) echo "unexpected Chainsaw admission call: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$fixture_root/bin/kubectl"
NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)" \
  mise exec -- yq -n -o=json '{
    "apiVersion":"coordination.k8s.io/v1",
    "kind":"Lease",
    "metadata":{"name":"homelab-test-run-lock","namespace":"flux-system","resourceVersion":"1"},
    "spec":{"holderIdentity":"campaign:fixture","leaseDurationSeconds":90,"acquireTime":strenv(NOW),"renewTime":strenv(NOW)}
  }' >"$fixture_root/lease.json"
chainsaw_calls="$fixture_root/chainsaw-calls"
cat >"$fixture_root/bin/chainsaw" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CHAINSAW_TEST_CALLS:?}"
EOF
chmod +x "$fixture_root/bin/chainsaw"
set +e
PATH="$fixture_root/bin:$PATH" \
CLUSTER_CHAOS_CONFIRM=chaos:qbittorrent-vpn-disconnect \
CAMPAIGN_TEST_LEASE_STATE="$fixture_root/lease.json" \
TEST_LEASE_KUBECTL="$repo_root/tests/fixtures/campaign/fake-lease-kubectl.sh" \
TEST_CAMPAIGN_LEASE_HOLDER=campaign:fixture \
DISRUPTION_TEST_NODES="$fixture_root/blocked-nodes.json" \
TEST_RESULTS_ROOT="$fixture_root/chainsaw-results" \
TEST_KUBECONFIG="$fixture_root/kubeconfig" \
TEST_EXECUTION_ORIGIN=agent \
CHAINSAW_TEST_CALLS="$chainsaw_calls" \
  scripts/test/run-chainsaw.sh resilience qbittorrent-vpn-disconnect \
  >"$fixture_root/chainsaw.log" 2>&1
chainsaw_exit="$?"
set -e
[[ "$chainsaw_exit" -ne 0 ]]
if [[ -f "$chainsaw_calls" ]] && rg -q '^test ' "$chainsaw_calls"; then
  cat "$fixture_root/chainsaw.log" >&2
  echo 'Chainsaw ran after disruption admission failed.' >&2
  exit 1
fi
