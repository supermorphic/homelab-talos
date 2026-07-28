#!/usr/bin/env bash
# Sonobuoy lifecycle backend. The catalog coordinator supplies the canonical run and
# cluster Lease. Publish-safe summaries and E2E JUnit fragments enter the canonical
# run; raw cluster captures are discarded on pass and retained only for failed-run
# diagnosis in ignored local-private storage.
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
repo_root="${HOMELAB_REPO_ROOT:-$(git rev-parse --show-toplevel)}"
private_root="${TEST_SONOBUOY_PRIVATE_ROOT:-$repo_root/.test-private-results}"
[[ "$private_root" == /* ]] || private_root="$repo_root/$private_root"
sonobuoy_dir="$run_dir/diagnostics/sonobuoy"
run_id="$(basename "$run_dir")"
mkdir -p "$sonobuoy_dir"
run_dir="$(cd "$run_dir" && pwd -P)"
workspace="$(mktemp -d "${TMPDIR:-/tmp}/homelab-sonobuoy.XXXXXX")"
retrieve_dir="$workspace/retrieved"
native_dir="$workspace/native"
mkdir -p "$retrieve_dir" "$native_dir"
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
  retrieved="$("$sonobuoy_bin" retrieve "$retrieve_dir" \
    --kubeconfig "$kubeconfig" 2>/dev/null)"
  retrieve_exit="$?"
  set -e
  if [[ "$retrieve_exit" -eq 0 && -f "$retrieved" ]]; then
    tarball="$retrieved"
    [[ ! -L "$tarball" ]] || return 1
    return 0
  fi
  return 1
}

retain_private_archive() {
  local resolved_root private_dir private_archive temporary_archive
  [[ -n "$tarball" && -f "$tarball" && ! -L "$tarball" ]] || return 0
  mkdir -p "$private_root"
  resolved_root="$(cd "$private_root" && pwd -P)"
  case "$resolved_root" in
    "$run_dir"|"$run_dir"/*)
      echo 'Warning: Sonobuoy private results resolve inside the canonical run; raw archive was discarded.' >&2
      return 1
      ;;
  esac
  private_dir="$resolved_root/$run_id/sonobuoy"
  private_archive="$private_dir/sonobuoy-results.tar.gz"
  mkdir -p "$private_dir"
  temporary_archive="${private_archive}.tmp.$$"
  cp "$tarball" "$temporary_archive"
  mv "$temporary_archive" "$private_archive"
  echo "Raw Sonobuoy archive retained for failed-run diagnosis: $private_archive" >&2
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
  local exit_code="$?"
  cleanup_sonobuoy >/dev/null 2>&1 || true
  if [[ "$exit_code" -ne 0 ]]; then
    retain_private_archive || true
  fi
  rm -rf -- "$workspace"
  return "$exit_code"
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
if [[ "$failed" -ne 0 ]]; then
  echo "Sonobuoy e2e reported failures ($failed); see $sonobuoy_dir." >&2
  exit 1
fi
rm -rf -- "$workspace"
trap - EXIT
echo "Sonobuoy $label passed (0 e2e failures); publish-safe evidence retained in $sonobuoy_dir."
