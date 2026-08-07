#!/usr/bin/env bash
set -euo pipefail

if (($# != 1)); then
	echo 'usage: preflight.sh <kubeconfig>' >&2
	exit 64
fi

kubeconfig="$1"
namespace='media'
expected_api='https://192.168.90.20:6443'
# 115GiB. The ephemeral partition is 149GiB total, so the previous 200GiB floor
# could never pass. See docs/decisions/2026-08-06-encode-benchmark-storage-contract-amendment.md.
minimum_available_bytes=123480309760

[[ -f "$kubeconfig" ]] || {
	echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
	exit 1
}
api_server="$(kubectl --kubeconfig "$kubeconfig" config view --minify \
	--output jsonpath='{.clusters[0].cluster.server}')"
[[ "$api_server" == "$expected_api" ]] || {
	echo "Refusing benchmark preflight: kubeconfig targets $api_server, not $expected_api." >&2
	exit 1
}

plex_pods="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get pods \
	--selector app.kubernetes.io/name=plex --output json)"
plex_nodes="$(yq -p=json -r '.items[] | select(.status.phase == "Running") | .spec.nodeName // ""' <<<"$plex_pods" | sort -u)"
[[ -n "$plex_nodes" ]] || {
	echo 'Plex has no Running pod with a scheduled node.' >&2
	exit 1
}

pvc="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get pvc media-data --output json)"
[[ "$(yq -p=json -r '.status.phase // ""' <<<"$pvc")" == 'Bound' ]] || {
	echo 'media-data PVC is not Bound.' >&2
	exit 1
}

kustomization="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get \
	kustomization encode-benchmark --output json)"
ready="$(yq -p=json -r '[(.status.conditions // [])[] | select(.type == "Ready") | .status][0] // ""' <<<"$kustomization")"
suspended="$(yq -p=json -r '.spec.suspend // false' <<<"$kustomization")"
[[ "$ready" == 'True' && "$suspended" == 'false' ]] || {
	echo 'encode-benchmark Kustomization is not Ready and unsuspended.' >&2
	exit 1
}

nodes="$(kubectl --kubeconfig "$kubeconfig" get nodes --output json)"
all_pods="$(kubectl --kubeconfig "$kubeconfig" get pods --all-namespaces --output json)"
eligible=0
while IFS= read -r node_json; do
	[[ -n "$node_json" ]] || continue
	name="$(yq -p=json -r '.metadata.name' <<<"$node_json")"
	allocatable="$(yq -p=json -r '.status.allocatable."gpu.intel.com/i915" // "0"' <<<"$node_json")"
	[[ "$allocatable" =~ ^[0-9]+$ ]] || allocatable=0
	used="$(NODE_NAME="$name" jq -r '
		[
			.items[]
			| select(.spec.nodeName == env.NODE_NAME)
			| select(.status.phase != "Succeeded" and .status.phase != "Failed")
			| .spec.containers[]?.resources.requests."gpu.intel.com/i915" // "0"
			| tonumber
		] | add // 0
	' <<<"$all_pods")"
	free=$((allocatable - used))
	summary="$(kubectl --kubeconfig "$kubeconfig" get \
		--raw "/api/v1/nodes/$name/proxy/stats/summary")"
	available="$(yq -p=json -r '.node.fs.availableBytes // 0' <<<"$summary")"
	[[ "$available" =~ ^[0-9]+$ ]] || available=0
	reasons=()
	if rg -Fxq "$name" <<<"$plex_nodes"; then reasons+=(plex-node); fi
	if ((allocatable < 1)); then
		reasons+=(i915-not-advertised)
	elif ((free < 1)); then
		reasons+=(i915-slot-not-free)
	fi
	if ((available < minimum_available_bytes)); then reasons+=(free-nvme-below-115Gi); fi
	if ((${#reasons[@]} == 0)); then
		printf '%s PASS i915-allocatable=%s i915-used=%s i915-free=%s node.fs.availableBytes=%s\n' \
			"$name" "$allocatable" "$used" "$free" "$available"
		((eligible += 1))
	else
		printf '%s FAIL %s i915-allocatable=%s i915-used=%s i915-free=%s node.fs.availableBytes=%s\n' \
			"$name" "$(
				IFS=,
				echo "${reasons[*]}"
			)" "$allocatable" "$used" "$free" "$available"
	fi
done < <(yq -p=json -o=json -I=0 '.items[]' <<<"$nodes")

((eligible > 0)) || {
	echo 'No eligible non-Plex benchmark node has one free i915 slot and 115Gi actual free NVMe.' >&2
	exit 1
}
printf 'encode-benchmark preflight passed: eligible_nodes=%s pvc=Bound kustomization=Ready\n' "$eligible"
