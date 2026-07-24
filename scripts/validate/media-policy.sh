#!/usr/bin/env bash
set -euo pipefail

source scripts/validate/lib.sh

media_root="${1:-kubernetes/apps/media}"
values_count=0

for values in "$media_root"/*/app/values.yaml; do
  [[ -f "$values" ]] || continue
  ((values_count += 1))

  app_dir="$(dirname "$(dirname "$values")")"
  app="$(basename "$app_dir")"
  ks="$app_dir/ks.yaml"
  route="$app_dir/app/httproute.yaml"

  assert_file "$ks" "$app Flux Kustomization"
  assert_file "$route" "$app HTTPRoute"
  assert_yaml "$values" ".controllers[\"$app\"] != null" "$app controller exists"

  while IFS=$'\t' read -r controller container tag; do
    [[ -n "$controller" ]] || continue
    assert_pinned_value "$tag" "$app/$controller/$container image tag"
  done < <(
    yq -r '
      .controllers | to_entries[] as $controller |
      [($controller.value.containers // {}), ($controller.value.initContainers // {})][] |
      to_entries[] |
      [$controller.key, .key, (.value.image.tag // "null")] | @tsv
    ' "$values"
  )

  while IFS=$'\t' read -r controller container; do
    [[ -n "$controller" ]] || continue
    if [[ "$app/$controller/$container" != 'qbittorrent/qbittorrent/gluetun' ]]; then
      validation_error 'NET_ADMIN is forbidden outside the qBittorrent Gluetun sidecar' \
        'file' "$values" \
        'container' "$app/$controller/$container"
      exit 1
    fi
  done < <(
    yq -r '
      .controllers | to_entries[] as $controller |
      [($controller.value.containers // {}), ($controller.value.initContainers // {})][] |
      to_entries[] |
      select((.value.securityContext.capabilities.add // []) | contains(["NET_ADMIN"])) |
      [$controller.key, .key] | @tsv
    ' "$values"
  )

  assert_yaml "$values" \
    ".controllers[\"$app\"].containers.app.securityContext.capabilities.drop | contains([\"ALL\"])" \
    "$app application container drops all Linux capabilities"

  access_mode="$(yq -r '.persistence.config.accessMode' "$values")"
  if [[ "$access_mode" != 'ReadWriteOnce' && "$access_mode" != 'ReadWriteOncePod' ]]; then
    validation_error 'Media config PVC must use a single-writer access mode' \
      'file' "$values" \
      'actual' "$access_mode"
    exit 1
  fi
  assert_yaml_eq "$values" ".controllers[\"$app\"].strategy" 'Recreate' \
    "$app deployment strategy for a single-writer config PVC"

  assert_depends_on "$ks" internal-gateway
  case "$app" in
    plex|qbittorrent|radarr|sonarr)
      assert_depends_on "$ks" media-storage
      ;;
    prowlarr|seerr)
      assert_depends_on "$ks" media
      ;;
    *)
      validation_error 'Media dependency policy is undefined for app' \
        'app' "$app" \
        'file' "$ks"
      exit 1
      ;;
  esac

  assert_yaml "$route" \
    '([.spec.parentRefs[]?.name] | length) > 0 and ([.spec.parentRefs[]?.name | select(. != "internal")] | length) == 0' \
    "$app routes use only the internal Gateway"
  assert_yaml_eq "$route" '.metadata.annotations."external-dns.k8s.io/audience"' \
    'internal' "$app external-dns audience"

  case "$app" in
    plex)
      assert_yaml_eq "$values" '.persistence.media.existingClaim' 'media-data' \
        'Plex shared media claim'
      ;;
    qbittorrent|radarr|sonarr)
      assert_yaml_eq "$values" '.persistence.data.existingClaim' 'media-data' \
        "$app shared media claim"
      ;;
    prowlarr|seerr)
      assert_yaml "$values" \
        '(.persistence.data // null) == null and (.persistence.media // null) == null' \
        "$app remains config-only"
      ;;
  esac
done

if (( values_count == 0 )); then
  validation_error 'No media application values files found' \
    'root' "$media_root"
  exit 1
fi

echo "Media-wide source policy passed for $values_count applications."
