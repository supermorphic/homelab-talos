#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 3 ]] || {
  echo 'Usage: collect.sh <kubeconfig> <output-directory> <namespace>' >&2
  exit 2
}

kubeconfig="$1"
output_dir="$2"
namespace="$3"
status=0

mkdir -p "$output_dir"

kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
  get kustomizations.kustomize.toolkit.fluxcd.io --output wide \
  >"$output_dir/flux-kustomizations.txt" 2>&1 || status=1

kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
  get kustomization.kustomize.toolkit.fluxcd.io cluster-apps --output yaml \
  >"$output_dir/cluster-apps.yaml" 2>&1 || status=1

kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
  get pods --output wide \
  >"$output_dir/pods.txt" 2>&1 || status=1

kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
  get events --sort-by=.metadata.creationTimestamp \
  >"$output_dir/events.txt" 2>&1 || status=1

exit "$status"
