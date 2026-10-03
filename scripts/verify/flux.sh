#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -ge 1 && "$#" -le 2 ]] || {
	echo 'Usage: flux.sh <kubeconfig> [expected-main-sha]' >&2
	exit 2
}

kubeconfig="$1"
expected_url='https://forgejo.infra.supermorphic.com/supermorphic/homelab-talos.git'
[[ "$(git remote get-url origin)" == "$expected_url" ]] || {
	echo "Flux verification requires origin $expected_url." >&2
	exit 1
}
remote_head="${2:-}"
if [[ -z "$remote_head" ]]; then
	remote_head="$(git ls-remote --exit-code origin refs/heads/main | awk '{print $1}')"
fi
[[ "$remote_head" =~ ^[0-9a-f]{40}$ ]] || {
	echo 'Expected a full main commit SHA.' >&2
	exit 1
}
expected_revision="main@sha1:$remote_head"

require_current_ready() {
	local state="$1" label="$2"
	# $generation belongs to yq, not the shell.
	# shellcheck disable=SC2016
	[[ "$(yq -r '.metadata.generation as $generation | [(.status.observedGeneration == $generation),
    ([.status.conditions[] | select(.type == "Ready" and .status == "True" and
      .observedGeneration == $generation)] | length == 1)] | all' - <<<"$state")" == 'true' ]] || {
		echo "$label has not reported Ready for its current generation." >&2
		return 1
	}
}

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
[[ "$(yq -r '.spec.ref | keys | join(",")' - <<<"$source_json")" == 'branch' ]]
[[ "$(yq -r '.spec.secretRef.name' - <<<"$source_json")" == 'flux-system-forgejo' ]]
[[ "$(yq -r '.spec.suspend // false' - <<<"$source_json")" == 'false' ]]
require_current_ready "$source_json" 'Flux source'
artifact_revision="$(yq -r '.status.artifact.revision' - <<<"$source_json")"
[[ "$artifact_revision" == "$expected_revision" ]] || {
	echo "Flux artifact $artifact_revision has not reconciled Forgejo main at $remote_head." >&2
	exit 1
}

for name in flux-system cluster-apps cilium flux-canary; do
	kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
		--for=condition=Ready "kustomization/$name" --timeout=10m
	state="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$name" --output json)"
	require_current_ready "$state" "Flux Kustomization $name"
	[[ "$(yq -r '.spec.suspend // false' - <<<"$state")" == 'false' ]]
	[[ "$(yq -r '.spec.sourceRef.kind' - <<<"$state")" == 'GitRepository' ]]
	[[ "$(yq -r '.spec.sourceRef.name' - <<<"$state")" == 'flux-system' ]]
	[[ "$(yq -r '.spec.sourceRef.namespace // "flux-system"' - <<<"$state")" == 'flux-system' ]]
	[[ "$(yq -r '.status.lastAppliedRevision' - <<<"$state")" == "$expected_revision" ]]
	if [[ "$name" == 'flux-system' ]]; then
		[[ "$(yq -r '.spec.path' - <<<"$state")" == './kubernetes/flux/clusters/prod' ]]
	elif [[ "$name" == 'cluster-apps' ]]; then
		[[ "$(yq -r '.spec.path' - <<<"$state")" == './kubernetes/apps' ]]
	fi
done

# Check every active application consuming this source, including unchanged apps.
kustomizations="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomizations --output json)"
while IFS= read -r state; do
	name="$(yq -r '.metadata.name' - <<<"$state")"
	require_current_ready "$state" "Flux Kustomization $name"
	[[ "$(yq -r '.status.lastAppliedRevision' - <<<"$state")" == "$expected_revision" ]] || {
		echo "Flux Kustomization $name has not applied $expected_revision." >&2
		exit 1
	}
done < <(yq -o=json -I=0 '.items[] | select(.spec.sourceRef.kind == "GitRepository" and
  .spec.sourceRef.name == "flux-system" and (.spec.sourceRef.namespace // "flux-system") == "flux-system" and
  (.spec.suspend // false) == false)' - <<<"$kustomizations")

cilium_source="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get ocirepository cilium --output json)"
[[ -n "$(yq -r '.spec.ref.tag' - <<<"$cilium_source")" ]]
[[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$cilium_source")" == 'True' ]]
cilium_release="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get helmrelease cilium --output json)"
[[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$cilium_release")" == 'True' ]]
[[ "$(yq -r '.spec.releaseName' - <<<"$cilium_release")" == 'cilium' ]]

just kube cilium-postflight
echo 'Flux verification passed: source and controller reconciliation, canary readiness, and Cilium ownership are healthy.'
