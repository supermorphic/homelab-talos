#!/usr/bin/env bash
set -euo pipefail

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/homelab-sonobuoy-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
run_dir="$fixture_root/run"
fragment_dir="$run_dir/diagnostics/fragments"
archive_root="$fixture_root/archive/plugins/e2e/results/global"
mkdir -p "$fragment_dir" "$archive_root"
touch "$fixture_root/kubeconfig"
printf '%s\n' \
  '<testsuites><testsuite name="sonobuoy">' \
  '<testcase classname="e2e" name="fixture"/></testsuite></testsuites>' \
  >"$archive_root/junit_01.xml"
archive="$fixture_root/sonobuoy.tar.gz"
tar -czf "$archive" -C "$fixture_root/archive" .
calls="$fixture_root/sonobuoy-calls"

FAKE_SONOBUOY_ARCHIVE="$archive" \
FAKE_SONOBUOY_CALLS="$calls" \
TEST_SONOBUOY_BIN=tests/fixtures/result-coordinator/fake-sonobuoy.sh \
TEST_KUBECTL_BIN=tests/fixtures/result-coordinator/fake-kubectl.sh \
HOMELAB_TEST_RUN_DIR="$run_dir" \
TEST_RESULT_FRAGMENT_DIR="$fragment_dir" \
  scripts/test/run-sonobuoy.sh quick "$fixture_root/kubeconfig" >/dev/null

rg -q --fixed-strings \
  "run --mode quick --plugin e2e --timeout 900 --wait=20 --kubeconfig $fixture_root/kubeconfig " \
  "$calls"
[[ -f "$run_dir/diagnostics/sonobuoy/summary.txt" ]]
[[ -f "$run_dir/diagnostics/sonobuoy/e2e-summary.txt" ]]
[[ -f "$run_dir/diagnostics/sonobuoy/sonobuoy-results.tar.gz" ]]
mapfile -t reports < <(find "$fragment_dir" -type f -name '*.xml')
[[ "${#reports[@]}" -eq 1 ]]
read_junit_counts_output="$(
  source scripts/test/lib/results.sh
  read_junit_counts "${reports[0]}"
)"
[[ "$read_junit_counts_output" == '1 0 0 0 1' ]]

echo 'Sonobuoy canonical extraction tests passed.'
