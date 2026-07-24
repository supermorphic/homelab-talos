#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/media/plex'
ks="$base/ks.yaml"
hr="$base/app/helmrelease.yaml"
values="$base/app/values.yaml"
route="$base/app/httproute.yaml"
oci='kubernetes/apps/media/namespace/app/ocirepository.yaml'
temp_dir="$(mktemp -d /tmp/homelab-talos-plex-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$hr" "$values" "$route" "$base/app/kustomization.yaml" "$oci"; do
  [[ -f "$f" ]] || { echo "Missing Phase 11 Plex source: $f" >&2; exit 1; }
done

rg -qx '  - ./plex/ks.yaml' kubernetes/apps/media/kustomization.yaml || {
  echo 'Refusing: ./plex/ks.yaml is not wired into kubernetes/apps/media/kustomization.yaml.' >&2
  exit 1
}

suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
[[ "$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'internal-gateway,media-storage' ]]

[[ "$(yq -r '.spec.chartRef.kind' "$hr")" == 'OCIRepository' ]]
[[ "$(yq -r '.spec.chartRef.name' "$hr")" == 'app-template' ]]

[[ "$(yq -r '.controllers.plex.type' "$values")" == 'deployment' ]]
[[ "$(yq -r '.controllers.plex.strategy' "$values")" == 'Recreate' ]]
[[ "$(yq -r '.controllers.plex.containers.app.image.repository' "$values")" == 'ghcr.io/home-operations/plex' ]]
image_tag="$(yq -r '.controllers.plex.containers.app.image.tag' "$values")"
[[ -n "$image_tag" && "$image_tag" != 'null' ]]
[[ "$(yq -r '.persistence.config.accessMode' "$values")" == 'ReadWriteOncePod' ]]
[[ "$(yq -r '.persistence.config.storageClass' "$values")" == 'longhorn' ]]
[[ "$(yq -r '.persistence.media.existingClaim' "$values")" == 'media-data' ]]
[[ "$(yq -r '.persistence.transcode.type' "$values")" == 'emptyDir' ]]

[[ "$(yq -r '.spec.hostnames[0]' "$route")" == 'plex.lab.supermorphic.com' ]]
[[ "$(yq -r '.spec.parentRefs[0].name' "$route")" == 'internal' ]]
[[ "$(yq -r '.spec.rules[0].backendRefs[0].port' "$route")" == '32400' ]]

chart_url="$(yq -r '.spec.url' "$oci")"
chart_tag="$(yq -r '.spec.ref.tag' "$oci")"

kustomize build "$base/app" >/dev/null

helm template plex "$chart_url" --version "$chart_tag" --namespace media --values "$values" >"$temp_dir/render.yaml"
[[ "$(yq -r 'select(.kind == "Deployment") | .metadata.name' "$temp_dir/render.yaml")" == 'plex' ]]
[[ "$(yq -r 'select(.kind == "Deployment") | .spec.strategy.type' "$temp_dir/render.yaml")" == 'Recreate' ]]

echo "Plex $image_tag source, app-template chartRef, values (Recreate/RWOP config, media-data, emptyDir transcode), HTTPRoute, and pinned render passed validation."
