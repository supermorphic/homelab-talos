#!/usr/bin/env bash
# Sonobuoy lifecycle backend. The catalog coordinator supplies the canonical run and
# cluster Lease; this script retains the archive and exports its E2E JUnit fragments.
set -euo pipefail

source scripts/test/lib/results.sh

[[ "$#" -eq 2 ]] || {
  echo 'Usage: run-sonobuoy.sh <quick|certified> <kubeconfig>' >&2
  exit 2
}
mode="$1"
kubeconfig="$2"
sonobuoy_bin="${TEST_SONOBUOY_BIN:-sonobuoy}"
kubectl_bin="${TEST_KUBECTL_BIN:-kubectl}"
case "$mode" in
  quick)
    sono_mode='quick'
    label='quick validation subset (NOT upstream conformance)'
    aggregator_timeout_seconds=900
    cli_wait_minutes=20
    ;;
  certified)
    sono_mode='certified-conformance'
    label='certified upstream Kubernetes conformance'
    aggregator_timeout_seconds=10800
    cli_wait_minutes=190
    ;;
  *) exit 2 ;;
esac

[[ -f "$kubeconfig" ]] || exit 1
run_dir="${HOMELAB_TEST_RUN_DIR:?canonical result coordinator is required}"
fragment_dir="${TEST_RESULT_FRAGMENT_DIR:?JUnit fragment directory is required}"
sonobuoy_dir="$run_dir/diagnostics/sonobuoy"
native_dir="$sonobuoy_dir/native"
mkdir -p "$sonobuoy_dir" "$native_dir"
tarball=''
cleanup_required=false

record_harness_error() {
  local case_name="$1"
  write_result_case_junit "$fragment_dir/sonobuoy-${case_name}.xml" \
    "conformance.$mode" "$case_name" broken 0
}

record_cleanup_status() {
  local status="$1"
  STATUS="$status" yq --null-input --output-format json \
    '{"status": strenv(STATUS), "phase": "sonobuoy-teardown"}' \
    >"$run_dir/recovery.json"
}

retrieve_results() {
  local retrieved
  set +e
  retrieved="$("$sonobuoy_bin" retrieve "$sonobuoy_dir" \
    --kubeconfig "$kubeconfig" 2>/dev/null)"
  retrieve_exit="$?"
  set -e
  if [[ "$retrieve_exit" -eq 0 && -f "$retrieved" ]]; then
    tarball="$retrieved"
    return 0
  fi
  return 1
}

cleanup_sonobuoy() {
  local cleanup_exit=0
  if [[ "$cleanup_required" == 'true' ]]; then
    [[ -n "$tarball" ]] || retrieve_results || true
    set +e
    "$sonobuoy_bin" delete --wait --kubeconfig "$kubeconfig"
    cleanup_exit="$?"
    set -e
    cleanup_required=false
  fi
  if [[ "$cleanup_exit" -ne 0 ]]; then
    record_cleanup_status failed
    record_harness_error cleanup
    return 1
  fi
  record_cleanup_status passed
}

finalize_on_exit() {
  cleanup_sonobuoy >/dev/null 2>&1 || true
}
trap finalize_on_exit EXIT

if "$kubectl_bin" --kubeconfig "$kubeconfig" \
  get namespace sonobuoy >/dev/null 2>&1; then
  echo 'A sonobuoy namespace already exists; delete the prior run before starting another.' >&2
  record_harness_error preflight
  exit 2
fi

echo "Running Sonobuoy: $label (mode=$sono_mode)."
cleanup_required=true
set +e
"$sonobuoy_bin" run \
  --mode "$sono_mode" \
  --plugin e2e \
  --timeout "$aggregator_timeout_seconds" \
  --wait="$cli_wait_minutes" \
  --kubeconfig "$kubeconfig"
run_exit="$?"
set -e
if [[ "$run_exit" -ne 0 ]]; then
  retrieve_results || true
  record_harness_error execution
  exit "$run_exit"
fi

if ! retrieve_results; then
  echo 'Sonobuoy completed but its result archive could not be retrieved.' >&2
  record_harness_error retrieval
  exit 2
fi
echo "Retrieved results: $tarball"
"$sonobuoy_bin" results "$tarball" | tee "$sonobuoy_dir/summary.txt"

if tar -tzf "$tarball" | awk '
  /^\// || /(^|\/)\.\.($|\/)/ { unsafe = 1 }
  END { exit unsafe ? 0 : 1 }
'; then
  echo 'Sonobuoy archive contains an unsafe member path.' >&2
  record_harness_error archive-safety
  exit 2
fi
tar -xzf "$tarball" -C "$native_dir"

fragment_count=0
while IFS= read -r candidate; do
  if read_junit_counts "$candidate" >/dev/null 2>&1; then
    fragment_count=$((fragment_count + 1))
    cp "$candidate" \
      "$fragment_dir/sonobuoy-e2e-$(printf '%04d' "$fragment_count").xml"
  fi
done < <(find "$native_dir" -type f -name '*.xml' -print | LC_ALL=C sort)
if [[ "$fragment_count" -eq 0 ]]; then
  echo 'Sonobuoy archive contained no non-vacuous JUnit report.' >&2
  record_harness_error junit-extraction
  exit 2
fi

set +e
plugin_results="$("$sonobuoy_bin" results "$tarball" --plugin e2e)"
results_exit="$?"
set -e
printf '%s\n' "$plugin_results" | tee "$sonobuoy_dir/e2e-summary.txt"
if [[ "$results_exit" -ne 0 ]]; then
  record_harness_error result-inspection
  exit 2
fi
failed="$(printf '%s\n' "$plugin_results" |
  rg -o 'Failed: [0-9]+' | rg -o '[0-9]+' || true)"
[[ "$failed" =~ ^[0-9]+$ ]] || {
  echo 'Could not determine Sonobuoy E2E failure count.' >&2
  record_harness_error result-inspection
  exit 2
}

if ! cleanup_sonobuoy; then
  exit 2
fi
trap - EXIT
if [[ "$failed" -ne 0 ]]; then
  echo "Sonobuoy e2e reported failures ($failed); see $sonobuoy_dir." >&2
  exit 1
fi
echo "Sonobuoy $label passed (0 e2e failures); archive retained in $sonobuoy_dir."
