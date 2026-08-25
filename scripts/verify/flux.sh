#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 3 ]] || {
  echo 'Usage: flux.sh <kubeconfig> <github_owner> <github_repository>' >&2
  exit 2
}

kubeconfig="$1"
github_owner="$2"
github_repository="$3"
expected_url="ssh://git@ssh.github.com:443/${github_owner}/${github_repository}"

flux check --kubeconfig "$kubeconfig"
for deployment in source-controller kustomize-controller helm-controller notification-controller; do
  available="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get deployment "$deployment" --output jsonpath='{.status.availableReplicas}')"
  [[ "$available" == '1' ]] || {
    echo "$deployment does not have exactly one available replica." >&2
    exit 1
  }
done

source_json="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get gitrepository flux-system --output json)"
[[ "$(yq -r '.spec.url' - <<<"$source_json")" == "$expected_url" ]]
[[ "$(yq -r '.spec.ref.branch' - <<<"$source_json")" == 'main' ]]
[[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$source_json")" == 'True' ]]
remote_head="$(git ls-remote --exit-code origin refs/heads/main | awk '{print $1}')"
artifact_revision="$(yq -r '.status.artifact.revision' - <<<"$source_json")"
[[ "$artifact_revision" == *"$remote_head" ]] || {
  echo "Flux artifact $artifact_revision has not reconciled origin/main at $remote_head." >&2
  exit 1
}

for name in flux-system cluster-apps cilium flux-canary; do
  kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
    --for=condition=Ready "kustomization/$name" --timeout=10m
  state="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$name" --output json)"
  [[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$state")" == 'True' ]] || {
    echo "Flux Kustomization $name is not Ready." >&2
    exit 1
  }
  [[ "$(yq -r '.spec.suspend // false' - <<<"$state")" == 'false' ]]
done

cilium_source="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get ocirepository cilium --output json)"
[[ -n "$(yq -r '.spec.ref.tag' - <<<"$cilium_source")" ]]
[[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$cilium_source")" == 'True' ]]
cilium_release="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get helmrelease cilium --output json)"
[[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$cilium_release")" == 'True' ]]
[[ "$(yq -r '.spec.releaseName' - <<<"$cilium_release")" == 'cilium' ]]

just kube cilium-postflight
echo 'Flux verification passed: source and controller reconciliation, canary readiness, and Cilium ownership are healthy.'
