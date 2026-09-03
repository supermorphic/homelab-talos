#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/homelab-catalog-runner-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
touch "$fixture_root/kubeconfig"
run_id_file="$fixture_root/passed.run-id"

TEST_RESULTS_ROOT="$fixture_root/passed" \
TEST_KUBECONFIG="$fixture_root/kubeconfig" \
TEST_EXECUTION_ORIGIN=agent \
TEST_RUN_ID_FILE="$run_id_file" \
  scripts/test/run-catalog-suite.sh verification.metrics-server -- true >/dev/null
mapfile -t passed_runs < <(find "$fixture_root/passed" -mindepth 1 -maxdepth 1 -type d)
[[ "${#passed_runs[@]}" -eq 1 ]]
[[ "$(cat "$run_id_file")" == "$(basename "${passed_runs[0]}")" ]]
[[ "$(yq -r '.result' "${passed_runs[0]}/summary.json")" == 'passed' ]]
[[ "$(yq -r '.junit.tests' "${passed_runs[0]}/summary.json")" == '6' ]]

set +e
TEST_RESULTS_ROOT="$fixture_root/failed" \
TEST_KUBECONFIG="$fixture_root/kubeconfig" \
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
TEST_KUBECONFIG="$fixture_root/kubeconfig" \
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
TEST_KUBECONFIG="$fixture_root/kubeconfig" \
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
[[ "$(yq -r '.junit.errors' "${interrupted_runs[0]}/summary.json")" == '1' ]]

lease_state="$fixture_root/campaign-lease.json"
healthy_nodes="$fixture_root/healthy-nodes.json"
blocked_nodes="$fixture_root/blocked-nodes.json"
cat >"$healthy_nodes" <<'EOF'
{"items":[{"metadata":{"name":"nuc1"},"spec":{"unschedulable":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"nuc2"},"spec":{"unschedulable":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}
EOF
cat >"$blocked_nodes" <<'EOF'
{"items":[{"metadata":{"name":"nuc1"},"spec":{"unschedulable":false},"status":{"conditions":[{"type":"Ready","status":"False"}]}},{"metadata":{"name":"nuc2"},"spec":{"unschedulable":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}
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
CILIUM_CONNECTIVITY_CONFIRM=test:cilium-connectivity \
CAMPAIGN_TEST_LEASE_STATE="$lease_state" \
TEST_LEASE_KUBECTL="$repo_root/tests/fixtures/campaign/fake-lease-kubectl.sh" \
NODE_LIFECYCLE_KUBECTL="$repo_root/tests/fixtures/node-lifecycle/fake-kubectl.sh" \
NODE_LIFECYCLE_TEST_NODES="$healthy_nodes" \
TEST_CAMPAIGN_LEASE_HOLDER=campaign:fixture \
TEST_RESULTS_ROOT="$fixture_root/joined" \
TEST_KUBECONFIG="$fixture_root/kubeconfig" \
TEST_EXECUTION_ORIGIN=agent \
  scripts/test/run-catalog-suite.sh test.cilium-connectivity -- true >/dev/null
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
NODE_LIFECYCLE_KUBECTL="$repo_root/tests/fixtures/node-lifecycle/fake-kubectl.sh" \
NODE_LIFECYCLE_TEST_NODES="$blocked_nodes" \
TEST_CAMPAIGN_LEASE_HOLDER=campaign:fixture \
TEST_RESULTS_ROOT="$fixture_root/lifecycle-blocked" \
TEST_KUBECONFIG="$fixture_root/kubeconfig" \
TEST_EXECUTION_ORIGIN=agent \
  scripts/test/run-catalog-suite.sh test.cilium-connectivity -- \
    touch "$blocked_marker" >/dev/null 2>&1
blocked_exit="$?"
set -e
[[ "$blocked_exit" -ne 0 ]]
[[ ! -e "$blocked_marker" ]]

echo 'Single-suite result coordinator tests passed.'
