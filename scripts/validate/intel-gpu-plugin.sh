#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/kube-system/intel-gpu-plugin'
ks="$base/ks.yaml"
ds="$base/app/daemonset.yaml"
bootstrap='.just/bootstrap.just'

for f in "$ks" "$ds" "$base/app/kustomization.yaml"; do
  [[ -f "$f" ]] || { echo "Missing Intel GPU plugin source: $f" >&2; exit 1; }
done

rg -qx '  - ./intel-gpu-plugin/ks.yaml' kubernetes/apps/kube-system/kustomization.yaml || {
  echo 'Refusing: ./intel-gpu-plugin/ks.yaml is not wired into kubernetes/apps/kube-system/kustomization.yaml.' >&2
  exit 1
}
rg -Fq 'source staged with suspend=true' "$bootstrap" || {
  echo 'Intel GPU bootstrap must describe its suspended source staging.' >&2
  exit 1
}
rg -Fq 'Plex already declares its gpu.intel.com/i915 request; reconcile Plex only after the' \
  "$bootstrap" || {
  echo 'Intel GPU bootstrap must preserve the current Plex dependency order.' >&2
  exit 1
}
! rg -Fq 'BEFORE adding the gpu.intel.com/i915 request to Plex' "$bootstrap" || {
  echo 'Intel GPU bootstrap must not tell the operator to add the existing Plex request later.' >&2
  exit 1
}

suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
[[ "$(yq -r '.spec.dependsOn[].name' "$ks")" == 'cilium' ]]

[[ "$(yq -r '.kind' "$ds")" == 'DaemonSet' ]]
[[ "$(yq -r '.metadata.namespace' "$ds")" == 'kube-system' ]]
image="$(yq -r '.spec.template.spec.containers[0].image' "$ds")"
[[ "$image" == intel/intel-gpu-plugin:* ]]
[[ "$image" != *:latest ]]

kustomize build "$base/app" >/dev/null

echo "intel-gpu-plugin ($image) source, wiring, dependency, and DaemonSet manifest passed validation."
