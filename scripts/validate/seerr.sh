#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/media/seerr'
ks="$base/ks.yaml"; hr="$base/app/helmrelease.yaml"; values="$base/app/values.yaml"; route="$base/app/httproute.yaml"
oci='kubernetes/apps/media/namespace/app/ocirepository.yaml'
temp_dir="$(mktemp -d /tmp/homelab-talos-seerr-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$hr" "$values" "$route" "$base/app/kustomization.yaml" "$oci"; do
  [[ -f "$f" ]] || { echo "Missing Phase 14 Seerr source: $f" >&2; exit 1; }
done
rg -qx '  - ./seerr/ks.yaml' kubernetes/apps/media/kustomization.yaml || {
  echo 'Refusing: ./seerr/ks.yaml is not wired into kubernetes/apps/media/kustomization.yaml.' >&2
  exit 1
}

suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
[[ "$(yq -r '.spec.decryption // "none"' "$ks")" == 'none' ]] || { echo 'seerr ks.yaml must not declare decryption (no secrets).' >&2; exit 1; }
[[ "$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'internal-gateway,media' ]]
[[ "$(yq -r '.spec.chartRef.name' "$hr")" == 'app-template' ]]

[[ "$(yq -r '.controllers.seerr.strategy' "$values")" == 'Recreate' ]]
[[ "$(yq -r '.controllers.seerr.containers.app.image.repository' "$values")" == 'ghcr.io/seerr-team/seerr' ]]
tag="$(yq -r '.controllers.seerr.containers.app.image.tag' "$values")"; [[ -n "$tag" && "$tag" != 'null' ]]
[[ "$(yq -r '.controllers.seerr.containers.app.securityContext.capabilities.drop[]' "$values" | tr '\n' ' ')" == 'ALL ' ]]
[[ "$(yq -r '.persistence.config.accessMode' "$values")" == 'ReadWriteOnce' ]]
[[ "$(yq -r '.persistence.config.storageClass' "$values")" == 'longhorn' ]]
[[ "$(yq -r '.persistence.config.annotations."helm.sh/resource-policy"' "$values")" == 'keep' ]]
[[ "$(yq -r '.persistence.config.globalMounts[0].path' "$values")" == '/app/config' ]]
[[ "$(yq -r '.persistence.data // "none"' "$values")" == 'none' ]] || { echo 'seerr is config-only; it must not mount media-data.' >&2; exit 1; }

[[ "$(yq -r '.spec.hostnames[0]' "$route")" == 'seerr.lab.supermorphic.com' ]]
[[ "$(yq -r '.spec.parentRefs[0].name' "$route")" == 'internal' ]]
[[ "$(yq -r '.spec.rules[0].backendRefs[0].name' "$route")" == 'seerr' ]]
[[ "$(yq -r '.spec.rules[0].backendRefs[0].port' "$route")" == '5055' ]]
rg -q '^    - name: seerr$' kubernetes/apps/monitoring/gatus/app/values.yaml || { echo 'seerr has no Gatus endpoint.' >&2; exit 1; }

chart_url="$(yq -r '.spec.url' "$oci")"
chart_tag="$(yq -r '.spec.ref.tag' "$oci")"
kustomize build "$base/app" >/dev/null
helm template seerr "$chart_url" --version "$chart_tag" --namespace media --values "$values" >"$temp_dir/render.yaml"
[[ "$(yq -r 'select(.kind == "Deployment") | .metadata.name' "$temp_dir/render.yaml")" == 'seerr' ]]
[[ "$(yq -r 'select(.kind == "Deployment") | .spec.strategy.type' "$temp_dir/render.yaml")" == 'Recreate' ]]

echo "Seerr $tag source (config-only, app-template, RWO/Recreate config at /app/config), HTTPRoute, Gatus probe, and pinned render passed validation."
