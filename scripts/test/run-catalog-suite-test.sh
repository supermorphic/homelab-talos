#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/homelab-catalog-runner-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
mkdir "$fixture_root/bin"
TEST_FIXTURE_REAL_UV="$(command -v uv)"
export TEST_FIXTURE_REAL_UV
export TEST_FIXTURE_ACCESS_TRACE="$fixture_root/access-trace"
export TEST_FIXTURE_ACCESS_ROOT="$fixture_root"
cp tests/fixtures/test-access/fake-uv.sh "$fixture_root/bin/uv"
cp tests/fixtures/result-coordinator/fake-kubectl.sh "$fixture_root/bin/kubectl"
real_mise="$(command -v mise)"
export TEST_FIXTURE_REAL_MISE="$real_mise"
cat >"$fixture_root/bin/mise" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == 'exec -- just talos readerconfig' ]]; then
  printf '%s\n' 'reader-bootstrap' >>"$TEST_FIXTURE_ACCESS_TRACE"
  exit
fi
exec "$TEST_FIXTURE_REAL_MISE" "$@"
STUB
cat >"$fixture_root/bin/talosctl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2" == 'config info' && "$3" == --talosconfig && "$5 $6" == '--output json' ]] || exit 64
[[ "$4" == "$(git rev-parse --show-toplevel)/.talos/config" ]] || exit 65
printf '%s\n' '{"roles":["os:reader"]}'
STUB
chmod +x "$fixture_root/bin/mise" "$fixture_root/bin/talosctl"
export PATH="$fixture_root/bin:$PATH"
touch "$fixture_root/kubeconfig"
run_id_file="$fixture_root/passed.run-id"

TEST_RESULTS_ROOT="$fixture_root/passed" \
TEST_KUBECONFIG='' \
TEST_EXECUTION_ORIGIN=agent \
TEST_RUN_ID_FILE="$run_id_file" \
  scripts/test/run-catalog-suite.sh verification.metrics-server -- true >/dev/null
mapfile -t passed_runs < <(find "$fixture_root/passed" -mindepth 1 -maxdepth 1 -type d)
[[ "${#passed_runs[@]}" -eq 1 ]]
[[ "$(cat "$run_id_file")" == "$(basename "${passed_runs[0]}")" ]]
[[ "$(yq -r '.result' "${passed_runs[0]}/summary.json")" == 'passed' ]]
[[ "$(yq -r '.junit.tests' "${passed_runs[0]}/summary.json")" == '6' ]]
[[ ! -f "$fixture_root/private/$(basename "${passed_runs[0]}")/config" ]]

set +e
TEST_RESULTS_ROOT="$fixture_root/failed" \
TEST_KUBECONFIG='' \
TEST_EXECUTION_ORIGIN=agent \
  scripts/test/run-catalog-suite.sh verification.metrics-server -- \
    bash -c 'exit 7' >/dev/null 2>&1
failure_exit="$?"
set -e
[[ "$failure_exit" -eq 7 ]]
mapfile -t failed_runs < <(find "$fixture_root/failed" -mindepth 1 -maxdepth 1 -type d)
[[ "${#failed_runs[@]}" -eq 1 ]]
[[ "$(yq -r '.result' "${failed_runs[0]}/summary.json")" == 'failed' ]]
[[ "$(yq -r '.junit.failures' "${failed_runs[0]}/summary.json")" == '1' ]]

set +e
TEST_RESULTS_ROOT="$fixture_root/refused" \
TEST_KUBECONFIG='' \
  scripts/test/run-catalog-suite.sh test.cilium-connectivity -- true \
  >/dev/null 2>&1
confirmation_exit="$?"
set -e
[[ "$confirmation_exit" -eq 1 ]]
[[ ! -e "$fixture_root/refused" ]]

set +e
# PPID must expand in the child shell, not this fixture.
# shellcheck disable=SC2016
TEST_RESULTS_ROOT="$fixture_root/interrupted" \
TEST_KUBECONFIG='' \
TEST_EXECUTION_ORIGIN=agent \
  scripts/test/run-catalog-suite.sh verification.metrics-server -- \
    bash -c 'kill -TERM "$PPID"; sleep 1' >/dev/null 2>&1
signal_exit="$?"
set -e
[[ "$signal_exit" -eq 143 ]]
mapfile -t interrupted_runs < <(
  find "$fixture_root/interrupted" -mindepth 1 -maxdepth 1 -type d
)
[[ "${#interrupted_runs[@]}" -eq 1 ]]
[[ "$(yq -r '.result' "${interrupted_runs[0]}/summary.json")" == 'broken' ]]
[[ "$(yq -r '.junit.errors' "${interrupted_runs[0]}/summary.json")" -ge 1 ]]
[[ "$(yq -r '.phases.primary.exit_code' "${interrupted_runs[0]}/summary.json")" == 143 ]]
[[ "$(yq -r '.phases.assertion.status' "${interrupted_runs[0]}/summary.json")" == not-classified ]]

lease_state="$fixture_root/campaign-lease.json"
healthy_nodes="$fixture_root/healthy-nodes.json"
blocked_nodes="$fixture_root/blocked-nodes.json"
cat >"$healthy_nodes" <<'EOF'
{"items":[{"metadata":{"name":"nuc1"},"spec":{"unschedulable":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"nuc2"},"spec":{"unschedulable":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}
EOF
cat >"$blocked_nodes" <<'EOF'
{"items":[{"metadata":{"name":"nuc1","annotations":{"homelab.supermorphic.com/node-lifecycle":""}},"spec":{"unschedulable":true},"status":{"conditions":[{"type":"Ready","status":"False"}]}},{"metadata":{"name":"nuc2"},"spec":{"unschedulable":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}
EOF
NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)" \
  yq --null-input --output-format json '{
    "apiVersion": "coordination.k8s.io/v1",
    "kind": "Lease",
    "metadata": {
      "name": "homelab-test-run-lock",
      "namespace": "flux-system",
      "resourceVersion": "1"
    },
    "spec": {
      "holderIdentity": "campaign:fixture",
      "leaseDurationSeconds": 90,
      "acquireTime": strenv(NOW),
      "renewTime": strenv(NOW)
    }
  }' >"$lease_state"
# shellcheck disable=SC2016  # Expansion must occur in the child command.
CILIUM_CONNECTIVITY_CONFIRM=test:cilium-connectivity \
CAMPAIGN_TEST_LEASE_STATE="$lease_state" \
TEST_LEASE_KUBECTL="$repo_root/tests/fixtures/campaign/fake-lease-kubectl.sh" \
DISRUPTION_KUBECTL="$repo_root/tests/fixtures/disruption-admission/fake-kubectl.sh" \
DISRUPTION_TEST_NODES="$healthy_nodes" \
TEST_CAMPAIGN_LEASE_HOLDER=campaign:fixture \
TEST_RESULTS_ROOT="$fixture_root/joined" \
TEST_KUBECONFIG='' \
TEST_EXECUTION_ORIGIN=agent \
  scripts/test/run-catalog-suite.sh test.cilium-connectivity -- \
    bash -c '[[ "$HOMELAB_DISRUPTION_LEASE_HOLDER" == "campaign:fixture" ]]' >/dev/null
mapfile -t joined_runs < <(find "$fixture_root/joined" -mindepth 1 -maxdepth 1 -type d)
[[ "${#joined_runs[@]}" -eq 1 ]]
[[ "$(yq -r '.result' "${joined_runs[0]}/summary.json")" == 'passed' ]]
[[ "$(yq -r '.phases.cleanup.status' "${joined_runs[0]}/summary.json")" == 'passed' ]]
[[ "$(yq -r '.spec.holderIdentity' "$lease_state")" == 'campaign:fixture' ]]

blocked_marker="$fixture_root/blocked-command-ran"
set +e
CILIUM_CONNECTIVITY_CONFIRM=test:cilium-connectivity \
CAMPAIGN_TEST_LEASE_STATE="$lease_state" \
TEST_LEASE_KUBECTL="$repo_root/tests/fixtures/campaign/fake-lease-kubectl.sh" \
DISRUPTION_KUBECTL="$repo_root/tests/fixtures/disruption-admission/fake-kubectl.sh" \
DISRUPTION_TEST_NODES="$blocked_nodes" \
TEST_CAMPAIGN_LEASE_HOLDER=campaign:fixture \
TEST_RESULTS_ROOT="$fixture_root/lifecycle-blocked" \
TEST_KUBECONFIG='' \
TEST_EXECUTION_ORIGIN=agent \
  scripts/test/run-catalog-suite.sh test.cilium-connectivity -- \
    touch "$blocked_marker" >/dev/null 2>&1
blocked_exit="$?"
set -e
[[ "$blocked_exit" -ne 0 ]]
[[ ! -e "$blocked_marker" ]]
mapfile -t blocked_runs < <(
  find "$fixture_root/lifecycle-blocked" -mindepth 1 -maxdepth 1 -type d
)
[[ "${#blocked_runs[@]}" -eq 1 ]]
[[ "$(yq -r '.result' "${blocked_runs[0]}/summary.json")" == broken ]]
[[ "$(yq -r '.spec.holderIdentity' "$lease_state")" == campaign:fixture ]]

cat >"$fixture_root/admission-then-renewal-failure" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"${REAL_DISRUPTION_KUBECTL:?}" "$@"
: >"${INJECT_LEASE_FAILURE_MARKER:?}"
EOF
chmod +x "$fixture_root/admission-then-renewal-failure"
renewal_failure_marker="$fixture_root/parent-renewal-failed"
renewal_child_marker="$fixture_root/renewal-failure-command-ran"
set +e
CILIUM_CONNECTIVITY_CONFIRM=test:cilium-connectivity \
CAMPAIGN_TEST_LEASE_STATE="$lease_state" \
TEST_LEASE_KUBECTL="$repo_root/tests/fixtures/campaign/fake-lease-kubectl.sh" \
DISRUPTION_KUBECTL="$fixture_root/admission-then-renewal-failure" \
REAL_DISRUPTION_KUBECTL="$repo_root/tests/fixtures/disruption-admission/fake-kubectl.sh" \
DISRUPTION_TEST_NODES="$healthy_nodes" \
INJECT_LEASE_FAILURE_MARKER="$renewal_failure_marker" \
TEST_CAMPAIGN_LEASE_HOLDER=campaign:fixture \
TEST_CAMPAIGN_LEASE_FAILURE_MARKER="$renewal_failure_marker" \
TEST_RESULTS_ROOT="$fixture_root/renewal-blocked" \
TEST_KUBECONFIG='' \
TEST_EXECUTION_ORIGIN=agent \
  scripts/test/run-catalog-suite.sh test.cilium-connectivity -- \
    touch "$renewal_child_marker" >/dev/null 2>&1
renewal_blocked_exit="$?"
set -e
[[ "$renewal_blocked_exit" -ne 0 ]]
[[ ! -e "$renewal_child_marker" ]]
[[ "$(yq -r '.spec.holderIdentity' "$lease_state")" == campaign:fixture ]]

cat >"$fixture_root/refuse-admission" <<'EOF'
#!/usr/bin/env bash
echo 'Read-only verification called disruption admission.' >&2
exit 88
EOF
cat >"$fixture_root/read-only-lease-kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *' config view --minify --output jsonpath={.clusters[0].name}' ]]; then
  printf 'fixture-cluster'
  exit 0
fi
: >"${READ_ONLY_LEASE_CALL_MARKER:?}"
exit 89
EOF
chmod +x "$fixture_root/refuse-admission" "$fixture_root/read-only-lease-kubectl"
read_only_marker="$fixture_root/read-only-command-ran"
read_only_lease_marker="$fixture_root/read-only-lease-called"
DISRUPTION_KUBECTL="$fixture_root/refuse-admission" \
DISRUPTION_TEST_NODES="$blocked_nodes" \
TEST_LEASE_KUBECTL="$fixture_root/read-only-lease-kubectl" \
READ_ONLY_LEASE_CALL_MARKER="$read_only_lease_marker" \
TEST_RESULTS_ROOT="$fixture_root/read-only-contained" \
TEST_KUBECONFIG='' \
TEST_EXECUTION_ORIGIN=agent \
  scripts/test/run-catalog-suite.sh verification.foundation -- \
    touch "$read_only_marker" >/dev/null
[[ -e "$read_only_marker" ]]
[[ ! -e "$read_only_lease_marker" ]]

echo 'Single-suite result coordinator tests passed.'

# An explicit unbound credential must not reach the backend or real issuance.
override_marker="$fixture_root/override-backend-ran"
set +e
TEST_RESULTS_ROOT="$fixture_root/unbound-override" \
TEST_KUBECONFIG="$fixture_root/kubeconfig" TEST_ACCESS_CONFIG='' \
  scripts/test/run-catalog-suite.sh verification.metrics-server -- \
    touch "$override_marker" >/dev/null 2>&1
override_exit="$?"
set -e
[[ "$override_exit" -ne 0 ]]
[[ ! -e "$override_marker" ]]

# Null/offline execution does not use enrollment or inherited Kubernetes access.
: >"$fixture_root/access-trace"
# Expand the selected values only inside the backend.
# shellcheck disable=SC2016
TEST_RESULTS_ROOT="$fixture_root/offline" TEST_KUBECONFIG='' \
KUBECONFIG=/synthetic/ambient-admin \
  scripts/test/run-catalog-suite.sh validation.openbao -- \
    bash -c '[[ -z "$TEST_KUBECONFIG" && "$KUBECONFIG" == /dev/null ]]' >/dev/null
if rg -q 'prepare|validate|inherit|remove' "$fixture_root/access-trace"; then exit 1; fi

# The backend receives the bound path; removal waits for canonical finalization.
# Expand the selected values only inside the backend.
# shellcheck disable=SC2016
TEST_RESULTS_ROOT="$fixture_root/bound" TEST_KUBECONFIG='' \
TEST_FIXTURE_ACCESS_FINALIZATION_ROOT="$fixture_root/bound" \
KUBECONFIG=/synthetic/ambient-admin \
  scripts/test/run-catalog-suite.sh verification.metrics-server -- \
    bash -c '[[ "$1" == "$TEST_KUBECONFIG" && "$KUBECONFIG" == "$1" && "$TEST_ACCESS_CONFIG" == "$1" && -f "$1" ]]' \
    _ @test-kubeconfig@ >/dev/null

# Rejected arguments and fixture catalogs cannot reach a backend.
for argument in .kube/config --context=diagnostic; do
  rejection_marker="$fixture_root/rejected-$RANDOM"
  set +e
  TEST_RESULTS_ROOT="$fixture_root/rejected-arguments" TEST_KUBECONFIG='' \
    scripts/test/run-catalog-suite.sh verification.metrics-server -- \
      touch "$rejection_marker" "$argument" >/dev/null 2>&1
  rejected_exit="$?"
  set -e
  [[ "$rejected_exit" -ne 0 && ! -e "$rejection_marker" ]]
done
cp tests/catalog.yaml "$fixture_root/catalog.yaml"
fixture_marker="$fixture_root/fixture-backend"
set +e
TEST_CATALOG_PATH="$fixture_root/catalog.yaml" TEST_KUBECONFIG='' \
TEST_RESULTS_ROOT="$fixture_root/rejected-catalog" \
  scripts/test/run-catalog-suite.sh verification.metrics-server -- \
    touch "$fixture_marker" >/dev/null 2>&1
fixture_exit="$?"
set -e
[[ "$fixture_exit" -ne 0 && ! -e "$fixture_marker" && ! -e "$fixture_root/rejected-catalog" ]]

# A nested observational run cannot remove or replace its parent's config.
: >"$fixture_root/access-trace"
# Expand the selected values only inside the backend.
# shellcheck disable=SC2016
TEST_RESULTS_ROOT="$fixture_root/nested" TEST_KUBECONFIG='' \
  scripts/test/run-catalog-suite.sh verification.metrics-server -- \
    bash -e -c 'parent="$TEST_ACCESS_CONFIG"; scripts/test/run-catalog-suite.sh verification.foundation -- true >/dev/null; [[ "$TEST_ACCESS_CONFIG" == "$parent" && -f "$parent" ]]' >/dev/null
[[ "$(rg -c '^prepare ' "$fixture_root/access-trace")" == 1 ]]
[[ "$(rg -c '^remove ' "$fixture_root/access-trace")" == 1 ]]

# A rejected refresh stops the backend and still removes its owned config.
check_marker="$fixture_root/check-backend"
set +e
TEST_RESULTS_ROOT="$fixture_root/check-rejected" TEST_KUBECONFIG='' \
TEST_FIXTURE_ACCESS_CHECK_FAIL=true \
  scripts/test/run-catalog-suite.sh verification.metrics-server -- \
    touch "$check_marker" >/dev/null 2>&1
check_exit="$?"
set -e
[[ "$check_exit" -ne 0 && ! -e "$check_marker" ]]
mapfile -t check_runs < <(find "$fixture_root/check-rejected" -mindepth 1 -maxdepth 1 -type d)
[[ "${#check_runs[@]}" -eq 1 ]]
[[ ! -f "$fixture_root/private/$(basename "${check_runs[0]}")/config" ]]

# Failed config removal preserves the successful primary assertion separately.
set +e
TEST_RESULTS_ROOT="$fixture_root/config-cleanup-failed" TEST_KUBECONFIG='' \
TEST_FIXTURE_ACCESS_REMOVE_FAIL=true \
  scripts/test/run-catalog-suite.sh verification.metrics-server -- true >/dev/null 2>&1
cleanup_exit="$?"
set -e
[[ "$cleanup_exit" -ne 0 ]]
mapfile -t cleanup_runs < <(find "$fixture_root/config-cleanup-failed" -mindepth 1 -maxdepth 1 -type d)
[[ "${#cleanup_runs[@]}" -eq 1 ]]
[[ "$(yq -r '.result' "${cleanup_runs[0]}/summary.json")" == broken ]]
[[ "$(yq -r '.phases.assertion.status' "${cleanup_runs[0]}/summary.json")" == passed ]]
[[ "$(yq -r '.phases.cleanup.status' "${cleanup_runs[0]}/summary.json")" == failed ]]
echo 'Catalog invocation routing and cleanup checks passed.'

# This sole self-managed suite must not turn an arbitrary command into a Lease bypass.
set +e
TEST_RESULTS_ROOT="$fixture_root/agent-invalid-entrypoint" \
TEST_KUBECONFIG='' \
  scripts/test/run-catalog-suite.sh test.agent-credentials -- true >/dev/null 2>&1
agent_invalid_exit="$?"
set -e
[[ "$agent_invalid_exit" -eq 2 ]]
[[ ! -e "$fixture_root/agent-invalid-entrypoint" ]]

# An inherited parent holder must still fail before the scenario starts, with
# an actionable explanation rather than an unexplained exit 2.
set +e
TEST_CAMPAIGN_LEASE_HOLDER=campaign:fixture \
TEST_RESULTS_ROOT="$fixture_root/agent-parent-holder" \
TEST_KUBECONFIG='' \
  scripts/test/run-catalog-suite.sh test.agent-credentials -- \
    uv run --locked python -m scripts.test.scenarios.agent_credentials \
  >"$fixture_root/agent-parent-holder.log" 2>&1
agent_parent_exit="$?"
set -e
[[ "$agent_parent_exit" -eq 2 ]]
[[ ! -e "$fixture_root/agent-parent-holder" ]]
rg -q 'manages its own Lease' "$fixture_root/agent-parent-holder.log"

# Its real entrypoint rejects absent operator authority before any broker/Lease action.
set +e
(env -u OPENBAO_OPERATOR_KUBECONFIG -u TEST_CAMPAIGN_LEASE_HOLDER \
  TEST_RESULTS_ROOT="$fixture_root/agent-no-authority" \
  TEST_KUBECONFIG='' \
  scripts/test/run-catalog-suite.sh test.agent-credentials -- \
    uv run --locked python -m scripts.test.scenarios.agent_credentials) >/dev/null 2>&1
agent_missing_authority_exit="$?"
set -e
[[ "$agent_missing_authority_exit" -eq 1 ]]
mapfile -t agent_runs < <(find "$fixture_root/agent-no-authority" -mindepth 1 -maxdepth 1 -type d)
[[ "${#agent_runs[@]}" -eq 1 ]]
[[ "$(yq -r '.result' "${agent_runs[0]}/summary.json")" == 'failed' ]]

# Typed catalog dispatch uses --no-dev and the file path, as test record does.
set +e
(env -u OPENBAO_OPERATOR_KUBECONFIG -u TEST_CAMPAIGN_LEASE_HOLDER \
  TEST_RESULTS_ROOT="$fixture_root/agent-typed-dispatch" \
  TEST_KUBECONFIG='' \
  scripts/test/run-live-suite.sh integration openbao workstation-profiles-lifecycles-callers) >/dev/null 2>&1
agent_typed_exit="$?"
set -e
printf 'Typed agent dispatch authority rejection: %s\n' "$agent_typed_exit"
[[ "$agent_typed_exit" -eq 1 ]]
