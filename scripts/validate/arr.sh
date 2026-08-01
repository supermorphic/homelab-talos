#!/usr/bin/env bash
set -euo pipefail

oci='kubernetes/apps/media/namespace/app/ocirepository.yaml'
chart_url="$(yq -r '.spec.url' "$oci")"
chart_tag="$(yq -r '.spec.ref.tag' "$oci")"
temp_dir="$(mktemp -d /tmp/homelab-talos-arr-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

arr_apps=(
  "prowlarr|9696|no|internal-gateway,media"
  "sonarr|8989|yes|internal-gateway,media-storage"
  "radarr|7878|yes|internal-gateway,media-storage"
  "lidarr|8686|yes|internal-gateway,media-storage"
)

for record in "${arr_apps[@]}"; do
  IFS='|' read -r app port mounts_data expected_deps <<<"$record"
  base="kubernetes/apps/media/$app"
  ks="$base/ks.yaml"; hr="$base/app/helmrelease.yaml"; values="$base/app/values.yaml"; route="$base/app/httproute.yaml"
  for f in "$ks" "$hr" "$values" "$route" "$base/app/kustomization.yaml"; do
    [[ -f "$f" ]] || { echo "Missing *arr source: $f" >&2; exit 1; }
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
  [[ "$deps" == "$expected_deps" ]] || { echo "$app dependsOn must be [$expected_deps]; got: $deps." >&2; exit 1; }

  [[ "$(yq -r '.spec.chartRef.name' "$hr")" == 'app-template' ]]

  [[ "$(yq -r ".controllers.$app.strategy" "$values")" == 'Recreate' ]]
  [[ "$(yq -r ".controllers.$app.containers.app.image.repository" "$values")" == "ghcr.io/home-operations/$app" ]]
  tag="$(yq -r ".controllers.$app.containers.app.image.tag" "$values")"; [[ -n "$tag" && "$tag" != 'null' ]]
  [[ "$(yq -r ".controllers.$app.containers.app.securityContext.capabilities.drop[]" "$values" | tr '\n' ' ')" == 'ALL ' ]]
  [[ "$(yq -r '.persistence.config.accessMode' "$values")" == 'ReadWriteOnce' ]]
  [[ "$(yq -r '.persistence.config.storageClass' "$values")" == 'longhorn' ]]
  [[ "$(yq -r '.persistence.config.annotations."helm.sh/resource-policy"' "$values")" == 'keep' ]]
  if [[ "$mounts_data" == 'no' ]]; then
    [[ "$(yq -r '.persistence.data // "none"' "$values")" == 'none' ]] || { echo 'prowlarr must not mount media-data (config-only).' >&2; exit 1; }
  else
    [[ "$(yq -r '.persistence.data.existingClaim' "$values")" == 'media-data' ]] || { echo "$app must mount media-data at /data." >&2; exit 1; }
  fi

  [[ "$(yq -r '.spec.hostnames[0]' "$route")" == "$app.lab.supermorphic.com" ]]
  [[ "$(yq -r '.spec.parentRefs[0].name' "$route")" == 'internal' ]]
  [[ "$(yq -r '.spec.rules[0].backendRefs[0].name' "$route")" == "$app" ]]
  [[ "$(yq -r '.service.app.ports.http.port' "$values")" == "$port" ]] || {
    echo "$app service port must be $port." >&2
    exit 1
  }
  [[ "$(yq -r '.spec.rules[0].backendRefs[0].port' "$route")" == "$port" ]] || {
    echo "$app HTTPRoute backend port must be $port." >&2
    exit 1
  }

  # Gatus must probe active apps, but not staged/suspended apps that do not exist yet.
  if [[ "$suspend_state" == 'false' ]]; then
    rg -q "^    - name: $app\$" kubernetes/apps/monitoring/gatus/app/values.yaml || { echo "Active $app has no Gatus endpoint." >&2; exit 1; }
  else
    ! rg -q "^    - name: $app\$" kubernetes/apps/monitoring/gatus/app/values.yaml || { echo "Suspended $app must not create a failing Gatus endpoint." >&2; exit 1; }
  fi

  widget_count="$(yq -r \
    '[(.metadata.annotations // {}) | keys[] | select(test("^gethomepage\\.dev/widget\\."))] | length' \
    "$route")"
  if [[ "$suspend_state" == 'false' ]]; then
    [[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.type"' "$route")" == "$app" ]]
    [[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.url"' "$route")" == \
      "http://$app.media.svc.cluster.local:$port" ]]
    widget_key="HOMEPAGE_VAR_${app^^}_API_KEY"
    [[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.key"' "$route")" == \
      "{{${widget_key}}}" ]]
  else
    [[ "$widget_count" == '0' ]] || {
      echo "Suspended $app must not publish widget.* annotations." >&2
      exit 1
    }
  fi

  kustomize build "$base/app" >/dev/null
  helm template "$app" "$chart_url" --version "$chart_tag" --namespace media --values "$values" >"$temp_dir/$app.yaml"
  [[ "$(yq -r 'select(.kind == "Deployment") | .metadata.name' "$temp_dir/$app.yaml")" == "$app" ]]
  [[ "$(yq -r 'select(.kind == "Deployment") | .spec.strategy.type' "$temp_dir/$app.yaml")" == 'Recreate' ]]
  echo "  $app $tag OK"
done

echo '*arr source (Prowlarr, Sonarr, Radarr, Lidarr), wiring, dependency graph, config/Recreate + shared /data, HTTPRoutes, activation-aware Gatus and Homepage widgets, and pinned renders passed validation.'
