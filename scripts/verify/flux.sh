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
kc=(kubectl --kubeconfig "$kubeconfig")
flux_context_args=()
if [[ -n "${RECOVERY_KUBE_CONTEXT:-}" ]]; then
  kc+=(--context "$RECOVERY_KUBE_CONTEXT")
  flux_context_args=(--context "$RECOVERY_KUBE_CONTEXT")
fi

flux check --kubeconfig "$kubeconfig" "${flux_context_args[@]}"
for deployment in source-controller kustomize-controller helm-controller notification-controller; do
  available="$("${kc[@]}" --namespace flux-system get deployment "$deployment" --output jsonpath='{.status.availableReplicas}')"
  [[ "$available" == '1' ]] || {
    echo "$deployment does not have exactly one available replica." >&2
    exit 1
  }
done

source_json="$("${kc[@]}" --namespace flux-system get gitrepository flux-system --output json)"
[[ "$(yq -r '.spec.url' - <<<"$source_json")" == "$expected_url" ]]
[[ "$(yq -r '.spec.ref.branch' - <<<"$source_json")" == 'main' ]]
[[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$source_json")" == 'True' ]]
artifact_revision="$(yq -r '.status.artifact.revision' - <<<"$source_json")"
if [[ -n "${RECOVERY_SOURCE_REVISION:-}" ]]; then
  expected_revision="$RECOVERY_SOURCE_REVISION"
else
  expected_revision="$(git ls-remote --exit-code origin refs/heads/main | awk '{print $1}')"
fi
[[ "$artifact_revision" == *"$expected_revision" ]] || {
  echo "Flux artifact $artifact_revision has not reconciled the expected revision $expected_revision." >&2
  exit 1
}

for name in flux-system cluster-apps cilium flux-canary; do
  "${kc[@]}" --namespace flux-system wait \
    --for=condition=Ready "kustomization/$name" --timeout=10m
  state="$("${kc[@]}" --namespace flux-system get kustomization "$name" --output json)"
  [[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$state")" == 'True' ]] || {
    echo "Flux Kustomization $name is not Ready." >&2
    exit 1
  }
  [[ "$(yq -r '.spec.suspend // false' - <<<"$state")" == 'false' ]]
done

cilium_source="$("${kc[@]}" --namespace kube-system get ocirepository cilium --output json)"
[[ -n "$(yq -r '.spec.ref.tag' - <<<"$cilium_source")" ]]
[[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$cilium_source")" == 'True' ]]
cilium_release="$("${kc[@]}" --namespace kube-system get helmrelease cilium --output json)"
[[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$cilium_release")" == 'True' ]]
[[ "$(yq -r '.spec.releaseName' - <<<"$cilium_release")" == 'cilium' ]]

if [[ -n "${RECOVERY_MODE:-}" ]]; then
  scripts/verify/cilium-postflight.sh "$kubeconfig" "$RECOVERY_KUBE_CONTEXT" \
    "$RECOVERY_TALOSCONFIG" "$RECOVERY_TALOS_CONTEXT" "$RECOVERY_TALOS_ENDPOINTS"
else
  just kube cilium-postflight
fi
echo 'Flux verification passed: source and controller reconciliation, canary readiness, and Cilium ownership are healthy.'
