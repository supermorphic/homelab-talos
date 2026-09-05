#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/storage/csi-driver-smb'
ks="$base/ks.yaml"
hr="$base/app/helmrelease.yaml"
repo="$base/app/helmrepository.yaml"
values="$base/app/values.yaml"
chart_repo='https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/charts'
temp_dir="$(mktemp -d /tmp/homelab-talos-csi-smb-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$hr" "$repo" "$values" "$base/app/namespace.yaml" "$base/app/kustomization.yaml"; do
  [[ -f "$f" ]] || { echo "Missing SMB CSI driver source: $f" >&2; exit 1; }
done

rg -qx '  - ./csi-driver-smb/ks.yaml' kubernetes/apps/storage/kustomization.yaml || {
  echo 'Refusing: ./csi-driver-smb/ks.yaml is not wired into kubernetes/apps/storage/kustomization.yaml.' >&2
  exit 1
}

suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
[[ "$(yq -r '.spec.dependsOn[].name' "$ks")" == 'cilium' ]]
[[ "$(yq -r '.metadata.labels."pod-security.kubernetes.io/enforce"' "$base/app/namespace.yaml")" == 'privileged' ]]

chart_version="$(yq -r '.spec.chart.spec.version' "$hr")"
[[ -n "$chart_version" && "$chart_version" != 'null' ]]
[[ "$(yq -r '.spec.url' "$repo")" == "$chart_repo" ]]

kustomize build "$base/app" >/dev/null

printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
  helm template csi-driver-smb csi-driver-smb --repo "$chart_repo" --version "$chart_version" --namespace csi-driver-smb --values "$values" >"$temp_dir/render.yaml"
rg -q 'smb\.csi\.k8s\.io' "$temp_dir/render.yaml"

# Talos nodes are Linux-only. Check the rendered workloads so a chart default
# cannot silently restore the unused Windows plugin or remove the Linux plugin.
[[ "$(yq ea -r '[select(.kind == "DaemonSet") | .metadata.name + ":" + .spec.template.spec.nodeSelector."kubernetes.io/os"] | join(",")' "$temp_dir/render.yaml")" == 'csi-smb-node:linux' ]] || {
  echo 'SMB CSI must render only the Linux csi-smb-node DaemonSet.' >&2
  exit 1
}
[[ "$(yq ea -r '[select(.kind == "Deployment") | .metadata.name] | join(",")' "$temp_dir/render.yaml")" == 'csi-smb-controller' ]] || {
  echo 'SMB CSI must retain its controller Deployment.' >&2
  exit 1
}

echo "csi-driver-smb $chart_version source, wiring, dependency, and pinned render passed validation."
