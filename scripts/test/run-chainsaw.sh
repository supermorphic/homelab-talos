#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
source scripts/test/lib/results.sh
require_bash

[[ "$#" -ge 2 && "$#" -le 3 ]] || {
  echo 'Usage: run-chainsaw.sh <smoke|e2e|resilience|diagnostics> <registered-target> [registered-scenario]' >&2
  exit 2
}

tier="$1"
target="$2"
scenario="${3:-}"
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
      cluster)
        case "$scenario" in
          '')
            test_dir='tests/chainsaw/smoke/cluster'
            selector='homelab-talos/suite=default'
            ;;
          flux-ready)
            test_dir='tests/chainsaw/smoke/cluster/flux-ready'
            selector='homelab-talos/suite=default'
            ;;
          diagnostics-self-test)
            test_dir='tests/chainsaw/smoke/cluster/diagnostics-self-test'
            selector='homelab-talos/suite=diagnostics-self-test'
            ;;
          *)
            echo "Unknown smoke scenario for target ${target}: $scenario" >&2
            exit 2
            ;;
        esac
        ;;
      media)
        case "$scenario" in
          qbittorrent)
            test_dir='tests/chainsaw/smoke/media/qbittorrent'
            selector='homelab-talos/suite=qbittorrent'
            ;;
          *)
            echo "Unknown smoke scenario for target ${target}: $scenario" >&2
            exit 2
            ;;
        esac
        ;;
      platform)
        # Read-only per-subsystem platform readiness. Scenarios are an EXPLICIT registry (not
        # filesystem discovery): a bare `platform` runs every suite carrying suite=platform;
        # a named scenario runs only that subsystem's dir. Add a scenario here + its dir to
        # register it — a stray directory never auto-runs.
        selector='homelab-talos/suite=platform'
        case "$scenario" in
          '')
            test_dir='tests/chainsaw/smoke/platform'
            ;;
          cluster|flux|gateway|dns|cilium|longhorn|portainer|smb)
            test_dir="tests/chainsaw/smoke/platform/${scenario}"
            ;;
          *)
            echo "Unknown smoke scenario for target ${target}: $scenario" >&2
            exit 2
            ;;
        esac
        ;;
      *)
        echo "Unknown smoke target: $target" >&2
        exit 2
        ;;
    esac
    ;;
  diagnostics)
    [[ -z "$scenario" ]] || {
      echo "The diagnostics tier does not accept a scenario: $scenario" >&2
      exit 2
    }
    [[ "$target" == 'cluster' ]] || {
      echo "Unknown diagnostics target: $target" >&2
      exit 2
    }
    diagnostics_only=true
    ;;
  e2e)
    [[ -z "$scenario" ]] || {
      echo "The E2E tier does not accept a scenario: $scenario" >&2
      exit 2
    }
    acquire_state_lock
    case "$target" in
      media-hardlink)
        test_dir='tests/chainsaw/e2e/media-hardlink'
        selector='homelab-talos/suite=media-hardlink'
        ;;
      *)
        echo "Unknown e2e target: $target" >&2
        exit 2
        ;;
    esac
    ;;
  resilience)
    [[ -z "$scenario" ]] || {
      echo "The resilience tier does not accept a scenario: $scenario" >&2
      exit 2
    }
    scripts/test/safety/require-chaos-confirmation.sh "$target"
    confirmation_type='CLUSTER_CHAOS_CONFIRM'
    acquire_state_lock
    case "$target" in
      qbittorrent-vpn-disconnect)
        test_dir='tests/chainsaw/resilience/qbittorrent-vpn-disconnect'
        selector='homelab-talos/suite=qbittorrent-vpn-disconnect'
        ;;
      cleanup-failure-self-test)
        test_dir='tests/chainsaw/resilience/cleanup-failure-self-test'
        selector='homelab-talos/suite=cleanup-failure-self-test'
        ;;
      qbittorrent-pod-recreation)
        test_dir='tests/chainsaw/resilience/qbittorrent-pod-recreation'
        selector='homelab-talos/suite=qbittorrent-pod-recreation'
        ;;
      plex-cross-node-reschedule)
        test_dir='tests/chainsaw/resilience/plex-cross-node-reschedule'
        selector='homelab-talos/suite=plex-cross-node-reschedule'
        ;;
      plex-node-reboot)
        test_dir='tests/chainsaw/resilience/plex-node-reboot'
        selector='homelab-talos/suite=plex-node-reboot'
        ;;
      *)
        echo "Unknown resilience target: $target" >&2
        exit 2
        ;;
    esac
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
    "$scenario" "$namespace" "$cluster_version" "$confirmation_type"
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
# Resilience scenarios write recovery.json here so the runner can record the recovery
# outcome separately from the primary assertion (Phase-3 "reports failure separately").
# Chainsaw runs script ops from its own working directory, so export the run dir as an
# ABSOLUTE path (works regardless of a script op's cwd) and the repo root for scenarios
# that invoke repo-relative guard/orchestrator scripts.
run_dir_abs="$(cd "$run_dir" && pwd)"
export HOMELAB_TEST_RUN_DIR="$run_dir_abs"
export HOMELAB_REPO_ROOT="$repo_root"
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
  "$scenario" "$namespace" "$cluster_version" "$confirmation_type"
environment_exit_code="$?"
set -e
if [[ "$environment_exit_code" -ne 0 && "$primary_exit_code" -eq 0 ]]; then
  primary_exit_code=1
  primary_status='failed'
fi
# Resilience scenarios drive recovery in a cleanup/finally block and record its outcome
# in recovery.json; surface it as a SEPARATE cleanup/recovery status without touching the
# primary assertion. Other tiers never mutate, so their recovery is not-required.
cleanup_status='not-required'
recovery_status='not-required'
if [[ "$tier" == 'resilience' ]]; then
  recovery_status="$(resilience_recovery_status "$run_dir")"
  cleanup_status="$recovery_status"
fi
write_summary "$run_dir" "$primary_status" "$primary_exit_code" \
  "$assertion_status" "$diagnostics_status" "$cleanup_status" "$recovery_status"

echo "Chainsaw results: $run_dir"
exit "$primary_exit_code"
