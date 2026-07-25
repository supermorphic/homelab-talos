#!/usr/bin/env bash
set -euo pipefail

oci='kubernetes/apps/media/namespace/app/ocirepository.yaml'
chart_url="$(yq -r '.spec.url' "$oci")"
chart_tag="$(yq -r '.spec.ref.tag' "$oci")"
temp_dir="$(mktemp -d /tmp/homelab-talos-arr-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for app in prowlarr sonarr radarr; do
  base="kubernetes/apps/media/$app"
  ks="$base/ks.yaml"; hr="$base/app/helmrelease.yaml"; values="$base/app/values.yaml"; route="$base/app/httproute.yaml"
  for f in "$ks" "$hr" "$values" "$route" "$base/app/kustomization.yaml"; do
    [[ -f "$f" ]] || { echo "Missing Phase 13 source: $f" >&2; exit 1; }
  done
  rg -qx "  - ./$app/ks.yaml" kubernetes/apps/media/kustomization.yaml || {
    echo "Refusing: ./$app/ks.yaml is not wired into kubernetes/apps/media/kustomization.yaml." >&2
    exit 1
  }

  suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
  [[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
  # No SOPS decryption — these apps carry no secrets (API keys are first-run).
  [[ "$(yq -r '.spec.decryption // "none"' "$ks")" == 'none' ]] || { echo "$app ks.yaml must not declare decryption (no secrets)." >&2; exit 1; }
  deps="$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")"
  if [[ "$app" == 'prowlarr' ]]; then
    [[ "$deps" == 'internal-gateway,media' ]] || { echo "prowlarr dependsOn must be [media, internal-gateway]; got: $deps." >&2; exit 1; }
  else
    [[ "$deps" == 'internal-gateway,media-storage' ]] || { echo "$app dependsOn must be [media-storage, internal-gateway]; got: $deps." >&2; exit 1; }
  fi

  [[ "$(yq -r '.spec.chartRef.name' "$hr")" == 'app-template' ]]

  [[ "$(yq -r ".controllers.$app.strategy" "$values")" == 'Recreate' ]]
  [[ "$(yq -r ".controllers.$app.containers.app.image.repository" "$values")" == "ghcr.io/home-operations/$app" ]]
  tag="$(yq -r ".controllers.$app.containers.app.image.tag" "$values")"; [[ -n "$tag" && "$tag" != 'null' ]]
  [[ "$(yq -r ".controllers.$app.containers.app.securityContext.capabilities.drop[]" "$values" | tr '\n' ' ')" == 'ALL ' ]]
  [[ "$(yq -r '.persistence.config.accessMode' "$values")" == 'ReadWriteOnce' ]]
  [[ "$(yq -r '.persistence.config.storageClass' "$values")" == 'longhorn' ]]
  [[ "$(yq -r '.persistence.config.annotations."helm.sh/resource-policy"' "$values")" == 'keep' ]]
  if [[ "$app" == 'prowlarr' ]]; then
    [[ "$(yq -r '.persistence.data // "none"' "$values")" == 'none' ]] || { echo 'prowlarr must not mount media-data (config-only).' >&2; exit 1; }
  else
    [[ "$(yq -r '.persistence.data.existingClaim' "$values")" == 'media-data' ]] || { echo "$app must mount media-data at /data." >&2; exit 1; }
  fi

  [[ "$(yq -r '.spec.hostnames[0]' "$route")" == "$app.lab.supermorphic.com" ]]
  [[ "$(yq -r '.spec.parentRefs[0].name' "$route")" == 'internal' ]]
  [[ "$(yq -r '.spec.rules[0].backendRefs[0].name' "$route")" == "$app" ]]

  # Gatus must probe active apps, but not staged/suspended apps that do not exist yet.
  if [[ "$suspend_state" == 'false' ]]; then
    rg -q "^    - name: $app\$" kubernetes/apps/monitoring/gatus/app/values.yaml || { echo "Active $app has no Gatus endpoint." >&2; exit 1; }
  else
    ! rg -q "^    - name: $app\$" kubernetes/apps/monitoring/gatus/app/values.yaml || { echo "Suspended $app must not create a failing Gatus endpoint." >&2; exit 1; }
  fi

  if [[ "$app" == 'prowlarr' ]]; then
    [[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.type"' "$route")" == 'prowlarr' ]]
    [[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.url"' "$route")" == 'http://prowlarr.media.svc.cluster.local:9696' ]]
    [[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.key"' "$route")" == '{{HOMEPAGE_VAR_PROWLARR_API_KEY}}' ]]
  fi
  if [[ "$app" == 'sonarr' ]]; then
    [[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.type"' "$route")" == 'sonarr' ]]
    [[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.url"' "$route")" == 'http://sonarr.media.svc.cluster.local:8989' ]]
    [[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.key"' "$route")" == '{{HOMEPAGE_VAR_SONARR_API_KEY}}' ]]
  fi
  if [[ "$app" == 'radarr' ]]; then
    [[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.type"' "$route")" == 'radarr' ]]
    [[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.url"' "$route")" == 'http://radarr.media.svc.cluster.local:7878' ]]
    [[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.key"' "$route")" == '{{HOMEPAGE_VAR_RADARR_API_KEY}}' ]]
  fi

  kustomize build "$base/app" >/dev/null
  helm template "$app" "$chart_url" --version "$chart_tag" --namespace media --values "$values" >"$temp_dir/$app.yaml"
  [[ "$(yq -r 'select(.kind == "Deployment") | .metadata.name' "$temp_dir/$app.yaml")" == "$app" ]]
  [[ "$(yq -r 'select(.kind == "Deployment") | .spec.strategy.type' "$temp_dir/$app.yaml")" == 'Recreate' ]]
  echo "  $app $tag OK"
done

echo 'Phase 13 *arr source (Prowlarr, Sonarr, Radarr), wiring, dependency graph, config/Recreate + shared /data, HTTPRoutes/Homepage widget, activation-aware Gatus probes, and pinned renders passed validation.'
