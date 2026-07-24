#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
source scripts/test/lib/results.sh
require_bash

[[ "$#" -eq 2 ]] || {
  echo 'Usage: run-chainsaw.sh <smoke|e2e|resilience|diagnostics> <registered-target>' >&2
  exit 2
}

tier="$1"
target="$2"
repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

kubeconfig='.kube/config'
namespace='flux-system'
confirmation_type='none'
test_dir=''
selector=''
diagnostics_only=false
lock_dir=''

mkdir -p .test-results

acquire_state_lock() {
  lock_dir='.test-results/state-changing.lock'
  mkdir "$lock_dir" 2>/dev/null || {
    echo 'Refusing concurrent state-changing test: .test-results/state-changing.lock exists.' >&2
    exit 1
  }
  trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT
}

case "$tier" in
  smoke)
    case "$target" in
      all | cluster | flux-ready)
        test_dir='tests/chainsaw/smoke/cluster'
        selector='homelab-talos/suite=default'
        ;;
      diagnostics-self-test)
        test_dir='tests/chainsaw/smoke/cluster'
        selector='homelab-talos/suite=diagnostics-self-test'
        ;;
      *)
        echo "Unknown smoke target: $target" >&2
        exit 2
        ;;
    esac
    ;;
  diagnostics)
    [[ "$target" == 'cluster' ]] || {
      echo "Unknown diagnostics target: $target" >&2
      exit 2
    }
    diagnostics_only=true
    ;;
  e2e)
    acquire_state_lock
    echo 'No E2E targets are registered yet.' >&2
    exit 2
    ;;
  resilience)
    scripts/test/safety/require-chaos-confirmation.sh "$target"
    confirmation_type='CLUSTER_CHAOS_CONFIRM'
    acquire_state_lock
    echo 'No resilience targets are registered yet.' >&2
    exit 2
    ;;
  *)
    echo "Unknown test tier: $tier" >&2
    exit 2
    ;;
esac

[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
  exit 1
}

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
short_revision="$(git rev-parse --short=12 HEAD)"
run_dir="$(mktemp -d ".test-results/${timestamp}-${short_revision}.XXXXXX")"
mkdir -p "$run_dir/logs" "$run_dir/manifests" "$run_dir/diagnostics"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cluster_version='unavailable'
if version_json="$(kubectl --kubeconfig "$kubeconfig" version --output json 2>/dev/null)"; then
  cluster_version="$(yq -r '.serverVersion.gitVersion // "unavailable"' <<<"$version_json")"
fi

if [[ "$diagnostics_only" == true ]]; then
  set +e
  scripts/test/diagnostics/collect.sh "$kubeconfig" "$run_dir/diagnostics" "$namespace"
  primary_exit_code="$?"
  set -e
  diagnostics_status='passed'
  primary_status='passed'
  [[ "$primary_exit_code" -eq 0 ]] || {
    diagnostics_status='failed'
    primary_status='failed'
  }
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  set +e
  write_environment "$run_dir" "$started_at" "$finished_at" "$tier" "$target" \
    "$namespace" "$cluster_version" "$confirmation_type"
  environment_exit_code="$?"
  set -e
  if [[ "$environment_exit_code" -ne 0 && "$primary_exit_code" -eq 0 ]]; then
    primary_exit_code=1
    primary_status='failed'
  fi
  write_summary "$run_dir" "$primary_status" "$primary_exit_code" \
    'not-applicable' "$diagnostics_status" 'not-required' 'not-required'
  echo "Diagnostics results: $run_dir"
  exit "$primary_exit_code"
fi

export KUBECONFIG="$kubeconfig"
set +e
chainsaw test "$test_dir" \
  --config tests/config/chainsaw.yaml \
  --namespace "$namespace" \
  --parallel 1 \
  --selector "$selector" \
  --apply-timeout 1m \
  --assert-timeout 2m \
  --cleanup-timeout 1m \
  --delete-timeout 1m \
  --error-timeout 30s \
  --exec-timeout 1m \
  --kube-request-timeout 30s \
  --report-format JUNIT-STEP \
  --report-name junit \
  --report-path "$run_dir" \
  --no-color 2>&1 | tee "$run_dir/logs/chainsaw.log"
primary_exit_code="${PIPESTATUS[0]}"
set -e

primary_status='passed'
assertion_status='passed'
[[ "$primary_exit_code" -eq 0 ]] || {
  primary_status='failed'
  assertion_status='not-classified'
}

if [[ ! -f "$run_dir/junit.xml" ]]; then
  echo 'Chainsaw did not produce the required junit.xml report.' >&2
  primary_exit_code=1
  primary_status='failed'
  assertion_status='not-classified'
else
  report_tests="$(yq --input-format xml --output-format json -r \
    '.testsuites."+@tests"' "$run_dir/junit.xml")"
  if [[ ! "$report_tests" =~ ^[1-9][0-9]*$ ]]; then
    echo "Chainsaw report is vacuous: expected at least one test, got ${report_tests}." >&2
    primary_exit_code=1
    primary_status='failed'
    assertion_status='not-classified'
  fi
fi

set +e
scripts/test/diagnostics/collect.sh "$kubeconfig" "$run_dir/diagnostics" "$namespace"
diagnostics_exit_code="$?"
set -e
diagnostics_status='passed'
[[ "$diagnostics_exit_code" -eq 0 ]] || diagnostics_status='failed'

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
set +e
write_environment "$run_dir" "$started_at" "$finished_at" "$tier" "$target" \
  "$namespace" "$cluster_version" "$confirmation_type"
environment_exit_code="$?"
set -e
if [[ "$environment_exit_code" -ne 0 && "$primary_exit_code" -eq 0 ]]; then
  primary_exit_code=1
  primary_status='failed'
fi
write_summary "$run_dir" "$primary_status" "$primary_exit_code" \
  "$assertion_status" "$diagnostics_status" 'not-required' 'not-required'

echo "Chainsaw results: $run_dir"
exit "$primary_exit_code"
