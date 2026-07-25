#!/usr/bin/env bash
set -euo pipefail

# FlareSolverr: stateless, in-cluster-only (no config PVC, no HTTPRoute, no VPN).
# Validates the static source; the live in-cluster probe lives in flaresolverr-verify.
base='kubernetes/apps/media/flaresolverr'
ks="$base/ks.yaml"; hr="$base/app/helmrelease.yaml"; values="$base/app/values.yaml"
oci='kubernetes/apps/media/namespace/app/ocirepository.yaml'
temp_dir="$(mktemp -d /tmp/homelab-talos-flaresolverr-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$hr" "$values" "$base/app/kustomization.yaml" "$oci"; do
  [[ -f "$f" ]] || { echo "Missing FlareSolverr source: $f" >&2; exit 1; }
done
# Stateless: it must NOT carry an HTTPRoute (no operator UI, in-cluster only).
[[ ! -f "$base/app/httproute.yaml" ]] || { echo 'FlareSolverr must not define an HTTPRoute (in-cluster only).' >&2; exit 1; }
rg -qx '  - ./flaresolverr/ks.yaml' kubernetes/apps/media/kustomization.yaml || {
  echo 'Refusing: ./flaresolverr/ks.yaml is not wired into kubernetes/apps/media/kustomization.yaml.' >&2
  exit 1
}

suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
[[ "$(yq -r '.spec.decryption // "none"' "$ks")" == 'none' ]] || { echo 'flaresolverr ks.yaml must not declare decryption (no secrets).' >&2; exit 1; }
[[ "$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'media' ]] || { echo 'flaresolverr must depend on media only (no media-storage, no internal-gateway).' >&2; exit 1; }
[[ "$(yq -r '.spec.chartRef.name' "$hr")" == 'app-template' ]]

[[ "$(yq -r '.controllers.flaresolverr.strategy' "$values")" == 'RollingUpdate' ]]
[[ "$(yq -r '.controllers.flaresolverr.containers.app.image.repository' "$values")" == 'ghcr.io/flaresolverr/flaresolverr' ]]
tag="$(yq -r '.controllers.flaresolverr.containers.app.image.tag' "$values")"; [[ -n "$tag" && "$tag" != 'null' ]]
[[ "$(yq -r '.controllers.flaresolverr.containers.app.securityContext.capabilities.drop[]' "$values" | tr '\n' ' ')" == 'ALL ' ]]
[[ "$(yq -r '.controllers.flaresolverr.containers.app.securityContext.allowPrivilegeEscalation' "$values")" == 'false' ]]
# Non-root without forcing UID 568 (the image ships its own flaresolverr user; forcing 568 breaks Chrome dirs).
[[ "$(yq -r '.controllers.flaresolverr.pod.securityContext.runAsNonRoot' "$values")" == 'true' ]]
[[ "$(yq -r '.controllers.flaresolverr.pod.securityContext.runAsUser // "unset"' "$values")" == 'unset' ]] || { echo 'flaresolverr must not force runAsUser (let the image user stand).' >&2; exit 1; }
# Stateless: no config PVC of any kind.
[[ "$(yq -r '.persistence.config // "none"' "$values")" == 'none' ]] || { echo 'flaresolverr is stateless; it must not define a config PVC.' >&2; exit 1; }
[[ "$(yq -r '.persistence.data // "none"' "$values")" == 'none' ]] || { echo 'flaresolverr must not mount media-data.' >&2; exit 1; }
# Memory-backed /dev/shm for Chromium.
[[ "$(yq -r '.persistence.dshm.type' "$values")" == 'emptyDir' ]]
[[ "$(yq -r '.persistence.dshm.medium' "$values")" == 'Memory' ]]
[[ "$(yq -r '.persistence.dshm.globalMounts[0].path' "$values")" == '/dev/shm' ]]
[[ "$(yq -r '.service.app.ports.http.port' "$values")" == '8191' ]]

if [[ "$suspend_state" == 'false' ]]; then
  rg -q '^    - name: flaresolverr$' kubernetes/apps/monitoring/gatus/app/values.yaml || { echo 'Active flaresolverr has no Gatus endpoint.' >&2; exit 1; }
else
  ! rg -q '^    - name: flaresolverr$' kubernetes/apps/monitoring/gatus/app/values.yaml || { echo 'Suspended flaresolverr must not create a failing Gatus endpoint.' >&2; exit 1; }
fi

chart_url="$(yq -r '.spec.url' "$oci")"
chart_tag="$(yq -r '.spec.ref.tag' "$oci")"
kustomize build "$base/app" >/dev/null
helm template flaresolverr "$chart_url" --version "$chart_tag" --namespace media --values "$values" >"$temp_dir/render.yaml"
[[ "$(yq -r 'select(.kind == "Deployment") | .metadata.name' "$temp_dir/render.yaml")" == 'flaresolverr' ]]
[[ "$(yq -r 'select(.kind == "Deployment") | .spec.strategy.type' "$temp_dir/render.yaml")" == 'RollingUpdate' ]]
[[ "$(yq -r 'select(.kind == "Service") | .spec.ports[0].port' "$temp_dir/render.yaml")" == '8191' ]]
# Rendered Deployment must carry no HTTPRoute anywhere in the app render.
! yq -r 'select(.kind == "HTTPRoute") | .metadata.name' "$temp_dir/render.yaml" | rg -q . || { echo 'flaresolverr render unexpectedly contains an HTTPRoute.' >&2; exit 1; }

echo "FlareSolverr $tag source (stateless, app-template, ClusterIP :8191, /dev/shm memory, no PVC/HTTPRoute, activation-aware Gatus probe, and pinned render) passed validation."
