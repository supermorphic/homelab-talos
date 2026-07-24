#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/monitoring/gatus'
ks="$base/ks.yaml"
values="$base/app/values.yaml"
hr="$base/app/helmrelease.yaml"
repo="$base/app/helmrepository.yaml"
route="$base/app/httproute.yaml"
ns="$base/app/namespace.yaml"
temp_dir="$(mktemp -d /tmp/homelab-talos-gatus-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$values" "$hr" "$repo" "$route" "$ns" "$base/app/kustomization.yaml"; do
  [[ -f "$f" ]] || { echo "Missing Phase 10 Gatus source: $f" >&2; exit 1; }
done
rg -qx '  - ./gatus/ks.yaml' kubernetes/apps/monitoring/kustomization.yaml || {
  echo 'Refusing: ./gatus/ks.yaml is not listed in kubernetes/apps/monitoring/kustomization.yaml.' >&2
  exit 1
}

suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
[[ "$(yq -r '.metadata.labels."gateway.supermorphic.com/access"' "$ns")" == 'internal' ]]
[[ "$(yq ea -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'cilium,internal-gateway' ]]
chart_version="$(yq -r '.spec.chart.spec.version' "$hr")"
[[ -n "$chart_version" && "$chart_version" != 'null' ]]
[[ "$(yq -r '.spec.url' "$repo")" == 'https://twin.github.io/helm-charts' ]]
[[ "$(yq -r '.config.storage.type' "$values")" == 'memory' ]]
[[ "$(yq -r '.spec.hostnames[0]' "$route")" == 'gatus.lab.supermorphic.com' ]]
[[ "$(yq -r '.spec.parentRefs[0].name' "$route")" == 'internal' ]]

kustomize build "$base/app" >/dev/null
printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
  helm template gatus gatus --repo https://twin.github.io/helm-charts --version "$chart_version" --namespace gatus --values "$values" >/dev/null

echo 'Phase 10 Gatus source, wiring, namespace label, values, HTTPRoute, and pinned chart render passed validation.'
