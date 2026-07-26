#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/monitoring/homepage'
ks="$base/ks.yaml"
ns="$base/app/namespace.yaml"
dep="$base/app/deployment.yaml"
route="$base/app/httproute.yaml"

for f in "$ks" "$ns" "$dep" "$route" "$base/app/rbac.yaml" "$base/app/service.yaml" \
  "$base/app/kustomization.yaml" "$base/app/config/settings.yaml" \
  "$base/app/config/kubernetes.yaml" "$base/app/config/services.yaml" \
  "$base/app/config/widgets.yaml" "$base/app/config/bookmarks.yaml"; do
  [[ -f "$f" ]] || { echo "Missing Phase 10 Homepage source: $f" >&2; exit 1; }
done
rg -qx '  - ./homepage/ks.yaml' kubernetes/apps/monitoring/kustomization.yaml || {
  echo 'Refusing: ./homepage/ks.yaml is not listed in the monitoring kustomization.' >&2
  exit 1
}

suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
[[ "$(yq -r '.metadata.labels."gateway.supermorphic.com/access"' "$ns")" == 'internal' ]]
[[ "$(yq ea -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'cilium,internal-gateway' ]]
[[ "$(yq -r '.spec.template.spec.containers[0].image' "$dep")" == ghcr.io/gethomepage/homepage:* ]]
[[ "$(yq -r '[.spec.template.spec.containers[0].env[] | select(.name == "HOMEPAGE_ALLOWED_HOSTS") | .value] | .[0]' "$dep")" == 'homepage.lab.supermorphic.com' ]]
[[ "$(yq -r '.spec.hostnames[0]' "$route")" == 'homepage.lab.supermorphic.com' ]]
[[ "$(yq -r '.spec.parentRefs[0].name' "$route")" == 'internal' ]]

# Per-service split Secrets (rotate independently).
grafana_secret="$base/app/homepage-grafana.sops.yaml"
plex_secret="$base/app/homepage-plex.sops.yaml"
portainer_secret="$base/app/homepage-portainer.sops.yaml"
prowlarr_secret="$base/app/homepage-prowlarr.sops.yaml"
qbittorrent_secret="$base/app/homepage-qbittorrent.sops.yaml"
sonarr_secret="$base/app/homepage-sonarr.sops.yaml"
radarr_secret="$base/app/homepage-radarr.sops.yaml"
seerr_secret="$base/app/homepage-seerr.sops.yaml"
[[ -f "$grafana_secret" ]] || { echo "Missing Homepage Grafana Secret: $grafana_secret (run just repo homepage-grafana-secrets)." >&2; exit 1; }
[[ -f "$plex_secret" ]] || { echo "Missing Homepage Plex Secret: $plex_secret (run just repo homepage-plex-secrets)." >&2; exit 1; }
[[ -f "$portainer_secret" ]] || { echo "Missing Homepage Portainer Secret: $portainer_secret (run just repo homepage-portainer-secrets)." >&2; exit 1; }
[[ -f "$prowlarr_secret" ]] || { echo "Missing Homepage Prowlarr Secret: $prowlarr_secret (run just repo homepage-prowlarr-secrets)." >&2; exit 1; }
[[ -f "$qbittorrent_secret" ]] || { echo "Missing Homepage qBittorrent Secret: $qbittorrent_secret (run just repo homepage-qbittorrent-secrets)." >&2; exit 1; }
[[ -f "$sonarr_secret" ]] || { echo "Missing Homepage Sonarr Secret: $sonarr_secret (run just repo homepage-sonarr-secrets)." >&2; exit 1; }
[[ -f "$radarr_secret" ]] || { echo "Missing Homepage Radarr Secret: $radarr_secret (run just repo homepage-radarr-secrets)." >&2; exit 1; }
[[ -f "$seerr_secret" ]] || { echo "Missing Homepage Seerr Secret: $seerr_secret (run just repo homepage-seerr-secrets)." >&2; exit 1; }
[[ "$(sops filestatus "$grafana_secret" | yq -r '.encrypted')" == 'true' ]]
[[ "$(yq -r '.metadata.name' "$grafana_secret")" == 'homepage-grafana' ]]
[[ "$(yq -r '.metadata.namespace' "$grafana_secret")" == 'homepage' ]]
[[ "$(sops filestatus "$plex_secret" | yq -r '.encrypted')" == 'true' ]]
[[ "$(yq -r '.metadata.name' "$plex_secret")" == 'homepage-plex' ]]
[[ "$(yq -r '.metadata.namespace' "$plex_secret")" == 'homepage' ]]
[[ "$(sops filestatus "$portainer_secret" | yq -r '.encrypted')" == 'true' ]]
[[ "$(yq -r '.metadata.name' "$portainer_secret")" == 'homepage-portainer' ]]
[[ "$(yq -r '.metadata.namespace' "$portainer_secret")" == 'homepage' ]]
[[ "$(sops filestatus "$prowlarr_secret" | yq -r '.encrypted')" == 'true' ]]
[[ "$(yq -r '.metadata.name' "$prowlarr_secret")" == 'homepage-prowlarr' ]]
[[ "$(yq -r '.metadata.namespace' "$prowlarr_secret")" == 'homepage' ]]
[[ "$(sops filestatus "$qbittorrent_secret" | yq -r '.encrypted')" == 'true' ]]
[[ "$(yq -r '.metadata.name' "$qbittorrent_secret")" == 'homepage-qbittorrent' ]]
[[ "$(yq -r '.metadata.namespace' "$qbittorrent_secret")" == 'homepage' ]]
[[ "$(sops filestatus "$sonarr_secret" | yq -r '.encrypted')" == 'true' ]]
[[ "$(yq -r '.metadata.name' "$sonarr_secret")" == 'homepage-sonarr' ]]
[[ "$(yq -r '.metadata.namespace' "$sonarr_secret")" == 'homepage' ]]
[[ "$(sops filestatus "$radarr_secret" | yq -r '.encrypted')" == 'true' ]]
[[ "$(yq -r '.metadata.name' "$radarr_secret")" == 'homepage-radarr' ]]
[[ "$(yq -r '.metadata.namespace' "$radarr_secret")" == 'homepage' ]]
[[ "$(sops filestatus "$seerr_secret" | yq -r '.encrypted')" == 'true' ]]
[[ "$(yq -r '.metadata.name' "$seerr_secret")" == 'homepage-seerr' ]]
[[ "$(yq -r '.metadata.namespace' "$seerr_secret")" == 'homepage' ]]
# The deployment must reference the split Secrets, not the old combined one.
! rg -q 'homepage-secrets' "$dep"
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_GRAFANA_USER") | .valueFrom.secretKeyRef.name] | .[0]' "$dep")" == 'homepage-grafana' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_PLEX_TOKEN") | .valueFrom.secretKeyRef.name] | .[0]' "$dep")" == 'homepage-plex' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_PORTAINER_API_KEY") | .valueFrom.secretKeyRef.name] | .[0]' "$dep")" == 'homepage-portainer' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_PORTAINER_API_KEY") | .valueFrom.secretKeyRef.key] | .[0]' "$dep")" == 'apiKey' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_PORTAINER_API_KEY") | .valueFrom.secretKeyRef.optional] | .[0]' "$dep")" == 'true' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_PROWLARR_API_KEY") | .valueFrom.secretKeyRef.name] | .[0]' "$dep")" == 'homepage-prowlarr' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_PROWLARR_API_KEY") | .valueFrom.secretKeyRef.key] | .[0]' "$dep")" == 'apiKey' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_QBITTORRENT_USERNAME") | .valueFrom.secretKeyRef.name] | .[0]' "$dep")" == 'homepage-qbittorrent' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_QBITTORRENT_USERNAME") | .valueFrom.secretKeyRef.key] | .[0]' "$dep")" == 'username' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_QBITTORRENT_PASSWORD") | .valueFrom.secretKeyRef.name] | .[0]' "$dep")" == 'homepage-qbittorrent' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_QBITTORRENT_PASSWORD") | .valueFrom.secretKeyRef.key] | .[0]' "$dep")" == 'password' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_SONARR_API_KEY") | .valueFrom.secretKeyRef.name] | .[0]' "$dep")" == 'homepage-sonarr' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_SONARR_API_KEY") | .valueFrom.secretKeyRef.key] | .[0]' "$dep")" == 'apiKey' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_RADARR_API_KEY") | .valueFrom.secretKeyRef.name] | .[0]' "$dep")" == 'homepage-radarr' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_RADARR_API_KEY") | .valueFrom.secretKeyRef.key] | .[0]' "$dep")" == 'apiKey' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_SEERR_API_KEY") | .valueFrom.secretKeyRef.name] | .[0]' "$dep")" == 'homepage-seerr' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_SEERR_API_KEY") | .valueFrom.secretKeyRef.key] | .[0]' "$dep")" == 'apiKey' ]]

kustomize build "$base/app" >/dev/null

echo 'Phase 10 Homepage source, wiring, namespace label, dependency graph, image, allowed-hosts, HTTPRoute, and split encrypted widget Secrets passed validation.'
