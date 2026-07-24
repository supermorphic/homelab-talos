#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/kube-system/metrics-server'
ks="$base/ks.yaml"
hr="$base/app/helmrelease.yaml"
repo="$base/app/helmrepository.yaml"
values="$base/app/values.yaml"
temp_dir="$(mktemp -d /tmp/homelab-talos-metrics-server-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$hr" "$repo" "$values" "$base/app/kustomization.yaml"; do
  [[ -f "$f" ]] || { echo "Missing metrics-server source: $f" >&2; exit 1; }
done
rg -qx '  - ./metrics-server/ks.yaml' kubernetes/apps/kube-system/kustomization.yaml || {
  echo 'Refusing: ./metrics-server/ks.yaml is not wired into the kube-system kustomization.' >&2
  exit 1
}
suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
[[ "$(yq ea -r '[.spec.dependsOn[].name] | join(",")' "$ks")" == 'cilium' ]]
[[ "$(yq -r '.spec.url' "$repo")" == 'https://kubernetes-sigs.github.io/metrics-server' ]]
[[ -n "$(yq -r '.args[] | select(. == "--kubelet-insecure-tls")' "$values")" ]]
chart_version="$(yq -r '.spec.chart.spec.version' "$hr")"
[[ -n "$chart_version" && "$chart_version" != 'null' ]]

kustomize build "$base/app" >/dev/null
printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
  helm template metrics-server metrics-server --repo https://kubernetes-sigs.github.io/metrics-server --version "$chart_version" --namespace kube-system --values "$values" >/dev/null

echo 'metrics-server source, wiring, dependency, insecure-tls flag, and pinned render passed validation.'
