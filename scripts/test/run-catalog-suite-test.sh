#!/usr/bin/env bash
set -euo pipefail

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/homelab-catalog-runner-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
touch "$fixture_root/kubeconfig"

TEST_RESULTS_ROOT="$fixture_root/passed" \
TEST_KUBECONFIG="$fixture_root/kubeconfig" \
TEST_EXECUTION_ORIGIN=agent \
  scripts/test/run-catalog-suite.sh verification.metrics-server -- true >/dev/null
mapfile -t passed_runs < <(find "$fixture_root/passed" -mindepth 1 -maxdepth 1 -type d)
[[ "${#passed_runs[@]}" -eq 1 ]]
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

echo 'Single-suite result coordinator tests passed.'
