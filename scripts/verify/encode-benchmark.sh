#!/usr/bin/env bash
set -euo pipefail

if (($# != 1)); then
	echo 'usage: encode-benchmark.sh <kubeconfig>' >&2
	exit 64
fi

kubeconfig="$1"
expected_api='https://192.168.90.20:6443'
[[ -f "$kubeconfig" ]] || {
	echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
	exit 1
}
api_server="$(kubectl --kubeconfig "$kubeconfig" config view --minify \
	--output jsonpath='{.clusters[0].cluster.server}')"
[[ "$api_server" == "$expected_api" ]] || {
	echo "Refusing encode-benchmark verification: kubeconfig targets $api_server, not $expected_api." >&2
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

priority="$(kubectl --kubeconfig "$kubeconfig" get priorityclass encode-benchmark-background --output json)"
[[ "$(yq -p=json -r '.metadata.name // ""' <<<"$priority")" == 'encode-benchmark-background' &&
"$(yq -p=json -r '.value // ""' <<<"$priority")" == '-10' ]] || {
	echo 'encode-benchmark PriorityClass is missing or malformed.' >&2
	exit 1
}

configmaps="$(kubectl --kubeconfig "$kubeconfig" --namespace media get configmaps --output json)"
samples_count="$(yq -p=json -r '[.items[] | select(.metadata.name == "encode-benchmark-samples")] | length' <<<"$configmaps")"
scripts_count="$(yq -p=json -r '[.items[] | select(.metadata.name | test("^encode-benchmark-scripts-[a-z0-9]{10}$"))] | length' <<<"$configmaps")"
[[ "$samples_count" == '1' && "$scripts_count" == '1' ]] || {
	echo 'encode-benchmark ConfigMaps are missing or ambiguous.' >&2
	exit 1
}

rule="$(kubectl --kubeconfig "$kubeconfig" --namespace media get prometheusrule encode-benchmark --output json)"
[[ "$(yq -p=json -r '.metadata.name // ""' <<<"$rule")" == 'encode-benchmark' ]] || {
	echo 'encode-benchmark PrometheusRule is missing.' >&2
	exit 1
}

persistent="$(kubectl --kubeconfig "$kubeconfig" --namespace media get \
	deployment,statefulset,daemonset,cronjob \
	--selector app.kubernetes.io/name=encode-benchmark --output json)"
[[ "$(yq -p=json -r '.items | length' <<<"$persistent")" == '0' ]] || {
	echo 'persistent encode-benchmark workload exists.' >&2
	exit 1
}

plex_pods="$(kubectl --kubeconfig "$kubeconfig" --namespace media get pods \
	--selector app.kubernetes.io/name=plex --output json)"
benchmark_pods="$(kubectl --kubeconfig "$kubeconfig" --namespace media get pods \
	--selector app.kubernetes.io/name=encode-benchmark --output json)"
plex_nodes="$(yq -p=json -r '.items[] | select(.status.phase == "Running") | .spec.nodeName // ""' <<<"$plex_pods" | sort -u)"
while IFS= read -r pod_node; do
	[[ -n "$pod_node" ]] || continue
	if rg -Fxq "$pod_node" <<<"$plex_nodes"; then
		echo "benchmark pod is co-resident with Plex on node $pod_node" >&2
		exit 1
	fi
done < <(yq -p=json -r '.items[] | select(.status.phase == "Pending" or .status.phase == "Running") | .spec.nodeName // ""' <<<"$benchmark_pods")

printf 'encode-benchmark verification passed: Kustomization Ready, inert inputs present, no persistent workload, and active benchmark pods separated from Plex.\n'
