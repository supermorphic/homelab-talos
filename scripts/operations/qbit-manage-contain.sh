#!/usr/bin/env bash
set -euo pipefail

# Operator-only incident transaction. `stop` freezes the owners and stops the
# scheduler; `finalize` restores broad reconciliation after a reviewed Git
# suspension reaches the Flux artifact. Neither phase changes qBittorrent.

kubeconfig="${kubeconfig:-}"
expected_revision="${expected_revision:-}"
finalize_resumed=false

live_field() {
  local namespace="$1" resource="$2" field="$3"
  kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
    get "$resource" --output "jsonpath={$field}"
}

assert_suspend_state() {
  local namespace="$1" resource="$2" expected="$3" generation
  [[ "$(live_field "$namespace" "$resource" '.spec.suspend')" == "$expected" ]] || {
    echo "$namespace/$resource has an unexpected suspension state." >&2
    return 1
  }
  generation="$(live_field "$namespace" "$resource" '.metadata.generation')"
  [[ "$generation" =~ ^[1-9][0-9]*$ ]] || return 1
  kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" wait "$resource" \
    --for="jsonpath={.status.observedGeneration}=${generation}" --timeout=2m || return 1
  [[ "$(live_field "$namespace" "$resource" '.metadata.generation')" == "$generation" ]] || return 1
  [[ "$(live_field "$namespace" "$resource" '.status.observedGeneration')" == "$generation" ]] || return 1
  [[ "$(live_field "$namespace" "$resource" '.spec.suspend')" == "$expected" ]] || return 1
}

assert_revision() {
  local actual="$1"
  [[ "$actual" == "main@sha1:$expected_revision" ]] || {
    echo "Flux revision does not match selected origin/main commit $expected_revision." >&2
    return 1
  }
}

assert_workload_stopped() {
  [[ "$(live_field media deployment/qbit-manage '.spec.replicas')" == '0' ]] || return 1
  [[ -z "$(kubectl --kubeconfig "$kubeconfig" --namespace media get pod \
    --selector app.kubernetes.io/name=qbit-manage --output name)" ]] || return 1
}

assert_qbittorrent_running() {
  local ready
  ready="$(live_field media deployment/qbittorrent '.status.readyReplicas')"
  [[ "$ready" =~ ^[1-9][0-9]*$ ]] || {
    echo 'qBittorrent/Gluetun has no ready replica; check it separately.' >&2
    return 1
  }
}

contain_stop() {
  local name
  for name in flux-system cluster-apps qbit-manage; do
    flux suspend kustomization "$name" --namespace flux-system --kubeconfig "$kubeconfig" || return 1
    assert_suspend_state flux-system "kustomization/$name" true || return 1
  done
  flux suspend helmrelease qbit-manage --namespace media --kubeconfig "$kubeconfig" || return 1
  assert_suspend_state media helmrelease/qbit-manage true || return 1
  kubectl --kubeconfig "$kubeconfig" --namespace media scale deployment/qbit-manage --replicas=0 || return 1
  if [[ -n "$(kubectl --kubeconfig "$kubeconfig" --namespace media get pod \
    --selector app.kubernetes.io/name=qbit-manage --output name)" ]]; then
    kubectl --kubeconfig "$kubeconfig" --namespace media wait --for=delete pod \
      --selector app.kubernetes.io/name=qbit-manage --timeout=2m || return 1
  fi
  assert_workload_stopped || return 1
  assert_qbittorrent_running || return 1
  echo 'qbit_manage is stopped. Keep the broad Flux freeze until the reviewed Git suspension is merged; then run finalize.'
}

_contain_finalize() {
  [[ "$(yq -r '.spec.suspend' kubernetes/apps/media/qbit-manage/ks.yaml)" == 'true' ]] || {
    echo 'Refusing finalization: Git does not suspend qbit_manage.' >&2
    return 1
  }
  local name
  for name in flux-system cluster-apps qbit-manage; do
    assert_suspend_state flux-system "kustomization/$name" true || return 1
  done
  assert_suspend_state media helmrelease/qbit-manage true || return 1
  assert_workload_stopped || return 1

  flux reconcile source git flux-system --namespace flux-system --kubeconfig "$kubeconfig" || return 1
  assert_revision "$(live_field flux-system gitrepository/flux-system '.status.artifact.revision')" || return 1
  # Recheck safety-critical live state directly before broad reconciliation resumes.
  assert_suspend_state flux-system kustomization/flux-system true || return 1
  assert_suspend_state flux-system kustomization/cluster-apps true || return 1
  assert_suspend_state flux-system kustomization/qbit-manage true || return 1
  assert_suspend_state media helmrelease/qbit-manage true || return 1
  assert_workload_stopped || return 1

  finalize_resumed=true
  flux resume kustomization flux-system --namespace flux-system --kubeconfig "$kubeconfig" || return 1
  assert_revision "$(live_field flux-system kustomization/flux-system '.status.lastAppliedRevision')" || return 1
  flux resume kustomization cluster-apps --namespace flux-system --kubeconfig "$kubeconfig" || return 1
  flux reconcile kustomization cluster-apps --namespace flux-system --kubeconfig "$kubeconfig" --timeout 10m || return 1
  kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
    kustomization/flux-system kustomization/cluster-apps --for=condition=Ready --timeout=10m || return 1
  for name in flux-system cluster-apps; do
    assert_suspend_state flux-system "kustomization/$name" false || return 1
    assert_revision "$(live_field flux-system "kustomization/$name" '.status.lastAppliedRevision')" || return 1
  done
  assert_suspend_state flux-system kustomization/qbit-manage true || return 1
  assert_suspend_state media helmrelease/qbit-manage true || return 1
  assert_workload_stopped || return 1
  assert_qbittorrent_running || return 1
}

contain_finalize() {
  finalize_resumed=false
  if _contain_finalize; then
    echo 'Broad Flux reconciliation is active at the selected revision; qbit_manage remains stopped.'
  else
    # Only restore the freeze if this invocation began resuming an owner.
    # Failed preconditions must not themselves change the owner freeze.
    if [[ "$finalize_resumed" == true ]]; then
      if ! contain_stop >&2; then
        echo 'Finalization failed and containment could not be proved. Escalate immediately.' >&2
      else
        echo 'Finalization failed. The ownership chain is frozen; investigate before retrying.' >&2
      fi
    else
      echo 'Finalization preconditions failed; no owner was resumed.' >&2
    fi
    return 1
  fi
}

main() {
  [[ "$#" -eq 2 && ( "$1" == stop || "$1" == finalize ) ]] || {
    echo 'Usage: qbit-manage-contain.sh <stop|finalize> <operator-kubeconfig>' >&2
    return 2
  }
  local phase="$1"
  kubeconfig="$2"
  [[ -f "$kubeconfig" ]] || { echo 'Missing operator kubeconfig.' >&2; return 1; }
  [[ "${QBIT_MANAGE_CONTAIN_CONFIRM:-}" == "contain:qbit-manage:$phase" ]] || {
    echo "Set QBIT_MANAGE_CONTAIN_CONFIRM='contain:qbit-manage:$phase' to run this operator action." >&2
    return 1
  }
  local git_dir git_common remote_head
  git_dir="$(git rev-parse --path-format=absolute --git-dir)"
  git_common="$(git rev-parse --path-format=absolute --git-common-dir)"
  [[ "$git_dir" == "$git_common" ]] || {
    echo 'Run containment from the authorized primary checkout.' >&2
    return 1
  }
  # shellcheck source=scripts/lib/rollout.sh
  source scripts/lib/rollout.sh
  require_deployed_source 'qbit_manage containment' \
    scripts/operations/qbit-manage-contain.sh kubernetes/mod.just \
    kubernetes/apps/media/qbit-manage/ks.yaml || return 1
  remote_head="$(git ls-remote --exit-code origin refs/heads/main | cut -f1)"
  expected_revision="$(git rev-parse HEAD)"
  [[ "$expected_revision" == "$remote_head" ]] || {
    echo 'Update the clean primary checkout to the exact published origin/main commit.' >&2
    return 1
  }
  [[ "$(kubectl --kubeconfig "$kubeconfig" auth can-i patch kustomizations.kustomize.toolkit.fluxcd.io --namespace flux-system)" == 'yes' ]] || {
    echo 'Containment requires the operator Kubernetes credential.' >&2
    return 1
  }
  if [[ "$phase" == stop ]]; then contain_stop; else contain_finalize; fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
