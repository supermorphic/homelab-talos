#!/usr/bin/env bash
set -euo pipefail

source scripts/test/lib/results.sh

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/homelab-sonobuoy-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
run_dir="$fixture_root/run"
fragment_dir="$run_dir/diagnostics/fragments"
archive_root="$fixture_root/archive/plugins/e2e/results/global"
archive_logs="$fixture_root/archive/podlogs/kube-system/cilium-fixture/logs"
mkdir -p "$fragment_dir" "$archive_root" "$archive_logs"
touch "$fixture_root/kubeconfig"
printf '%s\n' \
  '<testsuites><testsuite name="sonobuoy">' \
  '<testcase classname="e2e" name="fixture"/></testsuite></testsuites>' \
  >"$archive_root/junit_01.xml"
first='A1b2C3d4E5f6G7h8I9j0'
second='K1l2M3n4O5p6Q7r8'
printf 'api_%s = "%s%s"\n' key "$first" "$second" \
  >"$archive_logs/cilium-agent.txt"
archive="$fixture_root/sonobuoy.tar.gz"
tar -czf "$archive" -C "$fixture_root/archive" .
calls="$fixture_root/sonobuoy-calls"
private_root="$fixture_root/private"

FAKE_SONOBUOY_ARCHIVE="$archive" \
FAKE_SONOBUOY_CALLS="$calls" \
TEST_SONOBUOY_BIN=tests/fixtures/result-coordinator/fake-sonobuoy.sh \
TEST_KUBECTL_BIN=tests/fixtures/result-coordinator/fake-kubectl.sh \
TEST_SONOBUOY_PRIVATE_ROOT="$private_root" \
HOMELAB_TEST_RUN_DIR="$run_dir" \
TEST_RESULT_FRAGMENT_DIR="$fragment_dir" \
  scripts/test/run-sonobuoy.sh quick "$fixture_root/kubeconfig" >/dev/null

rg -q --fixed-strings \
  "run --mode quick --plugin e2e --timeout 900 --wait=20 --kubeconfig $fixture_root/kubeconfig " \
  "$calls"
[[ -f "$run_dir/diagnostics/sonobuoy/summary.txt" ]]
[[ -f "$run_dir/diagnostics/sonobuoy/e2e-summary.txt" ]]
[[ ! -e "$run_dir/diagnostics/sonobuoy/sonobuoy-results.tar.gz" ]]
[[ ! -e "$run_dir/diagnostics/sonobuoy/native" ]]
[[ -f "$private_root/run/sonobuoy/sonobuoy-results.tar.gz" ]]
mapfile -t reports < <(find "$fragment_dir" -type f -name '*.xml')
[[ "${#reports[@]}" -eq 1 ]]
read_junit_counts_output="$(
  read_junit_counts "${reports[0]}"
)"
[[ "$read_junit_counts_output" == '1 0 0 0 1' ]]

canonical_scan="$fixture_root/canonical-gitleaks.log"
if ! gitleaks dir --redact --no-banner --max-archive-depth 1 \
  "$run_dir" >"$canonical_scan" 2>&1; then
  echo 'Publish-safe Sonobuoy fixture failed its canonical evidence scan.' >&2
  sed -n '1,120p' "$canonical_scan" >&2
  exit 1
fi
private_scan="$fixture_root/private-gitleaks.log"
if gitleaks dir --redact --no-banner --max-archive-depth 1 \
  "$private_root" >"$private_scan" 2>&1; then
  echo 'Private Sonobuoy fixture unexpectedly passed its intentional leak scan.' >&2
  exit 1
fi
rg -q 'leaks found: 1' "$private_scan"

# Exercise the operator's standalone `just kube conformance` implementation through
# the real canonical coordinator. This acquires and releases its own fake Lease rather
# than joining a campaign Lease.
standalone_results="$fixture_root/standalone-results"
standalone_private="$fixture_root/standalone-private"
standalone_reports="$fixture_root/standalone-reports"
standalone_run_id_file="$fixture_root/standalone.run-id"
lease_state="$fixture_root/standalone-lease.json"
FAKE_SONOBUOY_ARCHIVE="$archive" \
FAKE_TEST_LEASE_STATE="$lease_state" \
TEST_LEASE_KUBECTL="$PWD/tests/fixtures/result-coordinator/fake-lease-kubectl.sh" \
TEST_SONOBUOY_BIN=tests/fixtures/result-coordinator/fake-sonobuoy.sh \
TEST_KUBECTL_BIN=tests/fixtures/result-coordinator/fake-kubectl.sh \
TEST_SONOBUOY_PRIVATE_ROOT="$standalone_private" \
TEST_RESULTS_ROOT="$standalone_results" \
TEST_KUBECONFIG="$fixture_root/kubeconfig" \
TEST_EXECUTION_ORIGIN=agent \
TEST_RUN_ID_FILE="$standalone_run_id_file" \
  scripts/test/run-conformance.sh "$fixture_root/kubeconfig" >/dev/null

standalone_run_id="$(cat "$standalone_run_id_file")"
standalone_run="$standalone_results/$standalone_run_id"
[[ "$(yq -r '.result' "$standalone_run/summary.json")" == 'passed' ]]
[[ "$(yq -r '.phases.cleanup.status' "$standalone_run/summary.json")" == 'passed' ]]
[[ "$(yq -r '.spec.holderIdentity // ""' "$lease_state")" == '' ]]
[[ -f "$standalone_private/$standalone_run_id/sonobuoy/sonobuoy-results.tar.gz" ]]
[[ ! -e "$standalone_run/diagnostics/sonobuoy/native" ]]
standalone_scan="$fixture_root/standalone-gitleaks.log"
if ! gitleaks dir --redact --no-banner --max-archive-depth 1 \
  "$standalone_run" >"$standalone_scan" 2>&1; then
  echo 'Standalone Sonobuoy run failed its canonical evidence scan.' >&2
  sed -n '1,120p' "$standalone_scan" >&2
  exit 1
fi
TEST_RESULTS_ROOT="$standalone_results" \
TEST_REPORTS_ROOT="$standalone_reports" \
  scripts/test/generate-allure-report.sh "$standalone_run_id" >/dev/null
[[ -f "$standalone_reports/$standalone_run_id/awesome/index.html" ]]

echo 'Sonobuoy publish-safe extraction and standalone conformance tests passed.'
