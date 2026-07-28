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
[[ ! -e "$private_root" ]]
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

# A Sonobuoy assertion failure retains the raw archive privately while keeping the
# failed canonical evidence publish-safe.
failed_run_dir="$fixture_root/failed-run"
failed_fragment_dir="$failed_run_dir/diagnostics/fragments"
mkdir -p "$failed_fragment_dir"
set +e
FAKE_SONOBUOY_ARCHIVE="$archive" \
FAKE_SONOBUOY_FAILED=1 \
TEST_SONOBUOY_BIN=tests/fixtures/result-coordinator/fake-sonobuoy.sh \
TEST_KUBECTL_BIN=tests/fixtures/result-coordinator/fake-kubectl.sh \
TEST_SONOBUOY_PRIVATE_ROOT="$private_root" \
HOMELAB_TEST_RUN_DIR="$failed_run_dir" \
TEST_RESULT_FRAGMENT_DIR="$failed_fragment_dir" \
  scripts/test/run-sonobuoy.sh quick "$fixture_root/kubeconfig" \
  >"$fixture_root/failed.log" 2>&1
failed_exit="$?"
set -e
[[ "$failed_exit" -eq 1 ]]
failed_private="$private_root/failed-run/sonobuoy/sonobuoy-results.tar.gz"
[[ -f "$failed_private" ]]
rg -q \
  'Raw Sonobuoy archive retained for failed-run diagnosis: .*/failed-run/sonobuoy/sonobuoy-results\.tar\.gz$' \
  "$fixture_root/failed.log"
[[ ! -e "$failed_run_dir/diagnostics/sonobuoy/sonobuoy-results.tar.gz" ]]
[[ ! -e "$failed_run_dir/diagnostics/sonobuoy/native" ]]
failed_scan="$fixture_root/failed-canonical-gitleaks.log"
if ! gitleaks dir --redact --no-banner --max-archive-depth 1 \
  "$failed_run_dir" >"$failed_scan" 2>&1; then
  echo 'Failed Sonobuoy run did not keep its canonical evidence publish-safe.' >&2
  sed -n '1,120p' "$failed_scan" >&2
  exit 1
fi

# A broken native archive follows the same private-retention boundary.
broken_archive_root="$fixture_root/broken-archive"
mkdir -p "$broken_archive_root/podlogs"
cp "$archive_logs/cilium-agent.txt" "$broken_archive_root/podlogs/cilium-agent.txt"
broken_archive="$fixture_root/broken-sonobuoy.tar.gz"
tar -czf "$broken_archive" -C "$broken_archive_root" .
broken_run_dir="$fixture_root/broken-run"
broken_fragment_dir="$broken_run_dir/diagnostics/fragments"
mkdir -p "$broken_fragment_dir"
set +e
FAKE_SONOBUOY_ARCHIVE="$broken_archive" \
TEST_SONOBUOY_BIN=tests/fixtures/result-coordinator/fake-sonobuoy.sh \
TEST_KUBECTL_BIN=tests/fixtures/result-coordinator/fake-kubectl.sh \
TEST_SONOBUOY_PRIVATE_ROOT="$private_root" \
HOMELAB_TEST_RUN_DIR="$broken_run_dir" \
TEST_RESULT_FRAGMENT_DIR="$broken_fragment_dir" \
  scripts/test/run-sonobuoy.sh quick "$fixture_root/kubeconfig" \
  >"$fixture_root/broken.log" 2>&1
broken_exit="$?"
set -e
[[ "$broken_exit" -eq 2 ]]
broken_private="$private_root/broken-run/sonobuoy/sonobuoy-results.tar.gz"
[[ -f "$broken_private" ]]
rg -q \
  'Raw Sonobuoy archive retained for failed-run diagnosis: .*/broken-run/sonobuoy/sonobuoy-results\.tar\.gz$' \
  "$fixture_root/broken.log"
[[ ! -e "$broken_run_dir/diagnostics/sonobuoy/sonobuoy-results.tar.gz" ]]
[[ ! -e "$broken_run_dir/diagnostics/sonobuoy/native" ]]
broken_scan="$fixture_root/broken-canonical-gitleaks.log"
if ! gitleaks dir --redact --no-banner --max-archive-depth 1 \
  "$broken_run_dir" >"$broken_scan" 2>&1; then
  echo 'Broken Sonobuoy run did not keep its canonical evidence publish-safe.' >&2
  sed -n '1,120p' "$broken_scan" >&2
  exit 1
fi

private_scan="$fixture_root/private-gitleaks.log"
if gitleaks dir --redact --no-banner --max-archive-depth 1 \
  "$private_root/failed-run" >"$private_scan" 2>&1; then
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
[[ ! -e "$standalone_private" ]]
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
