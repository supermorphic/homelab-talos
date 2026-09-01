#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
require_bash

base='kubernetes/apps/monitoring/homepage'
ks="$base/ks.yaml"
ns="$base/app/namespace.yaml"
dep="$base/app/deployment.yaml"
route="$base/app/httproute.yaml"
app_kustomization="$base/app/kustomization.yaml"
custom_js="$base/app/config/custom.js"
allure_icon="$base/app/icons/allure.svg"
allure_provenance="$base/app/icons/README.md"
seerr_route='kubernetes/apps/media/seerr/app/httproute.yaml'
n8n_route='kubernetes/apps/automation/n8n/app/httproute.yaml'
gatus_route='kubernetes/apps/monitoring/gatus/app/httproute.yaml'
longhorn_route='kubernetes/apps/storage/longhorn/config/httproute.yaml'
monitoring_routes='kubernetes/apps/monitoring/kube-prometheus-stack/config/httproutes.yaml'
portainer_route='kubernetes/apps/monitoring/portainer/app/httproute.yaml'
ntfy_route='kubernetes/apps/monitoring/ntfy/app/httproute.yaml'
test_reports_route='kubernetes/apps/monitoring/test-reports/app/httproute.yaml'
allure_commit='fe2ea92eaab4e409a3c8cf52ba96e35df96b2298'

for f in "$ks" "$ns" "$dep" "$route" "$base/app/rbac.yaml" "$base/app/service.yaml" \
  "$app_kustomization" "$base/app/config/settings.yaml" \
  "$base/app/config/kubernetes.yaml" "$base/app/config/services.yaml" \
  "$base/app/config/widgets.yaml" "$base/app/config/bookmarks.yaml" "$custom_js" \
  "$allure_icon" \
  "$allure_provenance" "$seerr_route" "$n8n_route" "$gatus_route" "$longhorn_route" \
  "$monitoring_routes" "$portainer_route" "$ntfy_route" "$test_reports_route"; do
  [[ -f "$f" ]] || { echo "Missing Homepage source: $f" >&2; exit 1; }
done
rg -qx '  - ./homepage/ks.yaml' kubernetes/apps/monitoring/kustomization.yaml || {
  echo 'Refusing: ./homepage/ks.yaml is not listed in the monitoring kustomization.' >&2
  exit 1
}

suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
[[ "$(yq -r '.metadata.labels."gateway.supermorphic.com/access"' "$ns")" == 'internal' ]]
[[ "$(yq ea -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'cilium,internal-gateway' ]]
[[ "$(yq -r '.spec.template.spec.containers[0].image' "$dep")" == 'ghcr.io/gethomepage/homepage:v1.13.2' ]]
[[ "$(yq -r '[.spec.template.spec.containers[0].env[] | select(.name == "HOMEPAGE_ALLOWED_HOSTS") | .value] | .[0]' "$dep")" == 'homepage.lab.supermorphic.com' ]]
[[ "$(yq -r '.spec.hostnames[0]' "$route")" == 'homepage.lab.supermorphic.com' ]]
[[ "$(yq -r '.spec.parentRefs[0].name' "$route")" == 'internal' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/icon"' "$seerr_route")" == 'seerr.svg' ]]
[[ "$(yq -r '[.metadata.annotations."gethomepage.dev/enabled",
    .metadata.annotations."gethomepage.dev/name",
    .metadata.annotations."gethomepage.dev/description",
    .metadata.annotations."gethomepage.dev/group",
    .metadata.annotations."gethomepage.dev/icon",
    .metadata.annotations."gethomepage.dev/href",
    .metadata.annotations."gethomepage.dev/pod-selector"] | join(",")' \
  "$n8n_route")" == \
  'true,n8n,Workflow automation,Platform,n8n.svg,https://n8n.lab.supermorphic.com,app.kubernetes.io/name=n8n' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/icon"' "$portainer_route")" == 'portainer-dark.svg' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/name"' "$ntfy_route")" == 'ntfy' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/group"' "$ntfy_route")" == \
  'Monitoring & Testing' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/icon"' "$ntfy_route")" == 'ntfy.svg' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/href"' "$ntfy_route")" == \
  'https://ntfy.lab.supermorphic.com' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.type"' "$ntfy_route")" == \
  'ntfy' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.url"' "$ntfy_route")" == \
  'http://ntfy.ntfy.svc.cluster.local' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.topic"' "$ntfy_route")" == \
  'critical' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.key"' "$ntfy_route")" == \
  '{{HOMEPAGE_VAR_NTFY_TOKEN}}' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.fields"' "$ntfy_route")" == \
  '["title","priority","lastReceived"]' ]]
for mapping in \
  '["portainer.applications", "Applications"]' \
  '["portainer.services", "Services"]' \
  '["portainer.namespaces", "Namespaces"]'; do
  rg -Fq "$mapping" "$custom_js"
done
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/icon"' "$test_reports_route")" == '/icons/allure.svg' ]]
[[ "$(yq ea -r '[select(.kind == "HTTPRoute") |
  .metadata.annotations."gethomepage.dev/group"] | unique | join(",")' \
  "$monitoring_routes")" == 'Monitoring & Testing' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/group"' "$gatus_route")" == \
  'Monitoring & Testing' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/group"' "$test_reports_route")" == \
  'Monitoring & Testing' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/name"' "$test_reports_route")" == \
  'Test Reports' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/description"' \
  "$test_reports_route")" == 'Persistent operator-published test results' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/group"' "$longhorn_route")" == \
  'Platform' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/group"' "$portainer_route")" == \
  'Platform' ]]
assert_command_finds_nothing \
  'Homepage discovery metadata must use the renamed group taxonomy.' \
  rg -q 'gethomepage\.dev/group: "(Monitoring|Infrastructure)"' kubernetes/apps
[[ "$(yq -r '.configMapGenerator[] | select(.name == "homepage-icons") | .files[0]' "$app_kustomization")" == 'allure.svg=icons/allure.svg' ]]
[[ "$(yq -r '[.spec.template.spec.containers[0].volumeMounts[] | select(.name == "custom-icons") | .mountPath] | .[0]' "$dep")" == '/app/public/icons/allure.svg' ]]
[[ "$(yq -r '[.spec.template.spec.containers[0].volumeMounts[] | select(.name == "custom-icons") | .subPath] | .[0]' "$dep")" == 'allure.svg' ]]
[[ "$(yq -r '[.spec.template.spec.containers[0].volumeMounts[] | select(.name == "custom-icons") | .readOnly] | .[0]' "$dep")" == 'true' ]]
[[ "$(yq -r '[.spec.template.spec.volumes[] | select(.name == "custom-icons") | .configMap.name] | .[0]' "$dep")" == 'homepage-icons' ]]
[[ "$(yq -r '[.spec.template.spec.volumes[] | select(.name == "custom-icons") | .configMap.items[0].key] | .[0]' "$dep")" == 'allure.svg' ]]
[[ "$(yq -r '[.spec.template.spec.volumes[] | select(.name == "custom-icons") | .configMap.items[0].path] | .[0]' "$dep")" == 'allure.svg' ]]
rg -Fq "$allure_commit" "$allure_provenance"
rg -Fq 'packages/web-components/src/assets/svg/report-logo.svg' "$allure_provenance"

# Per-service split Secrets (rotate independently).
grafana_secret="$base/app/homepage-grafana.sops.yaml"
ntfy_secret="$base/app/homepage-ntfy.sops.yaml"
plex_secret="$base/app/homepage-plex.sops.yaml"
portainer_secret="$base/app/homepage-portainer.sops.yaml"
prowlarr_secret="$base/app/homepage-prowlarr.sops.yaml"
qbittorrent_secret="$base/app/homepage-qbittorrent.sops.yaml"
sonarr_secret="$base/app/homepage-sonarr.sops.yaml"
radarr_secret="$base/app/homepage-radarr.sops.yaml"
lidarr_secret="$base/app/homepage-lidarr.sops.yaml"
seerr_secret="$base/app/homepage-seerr.sops.yaml"
[[ -f "$grafana_secret" ]] || { echo "Missing Homepage Grafana Secret: $grafana_secret (run just repo homepage-grafana-secrets)." >&2; exit 1; }
[[ -f "$ntfy_secret" ]] || { echo "Missing Homepage ntfy Secret: $ntfy_secret (run just repo ntfy-identity ensure homepage)." >&2; exit 1; }
[[ -f "$plex_secret" ]] || { echo "Missing Homepage Plex Secret: $plex_secret (run just repo homepage-plex-secrets)." >&2; exit 1; }
[[ -f "$portainer_secret" ]] || { echo "Missing Homepage Portainer Secret: $portainer_secret (run just repo homepage-portainer-secrets)." >&2; exit 1; }
[[ -f "$prowlarr_secret" ]] || { echo "Missing Homepage Prowlarr Secret: $prowlarr_secret (run just repo homepage-prowlarr-secrets)." >&2; exit 1; }
[[ -f "$qbittorrent_secret" ]] || { echo "Missing Homepage qBittorrent Secret: $qbittorrent_secret (run just repo homepage-qbittorrent-secrets)." >&2; exit 1; }
[[ -f "$sonarr_secret" ]] || { echo "Missing Homepage Sonarr Secret: $sonarr_secret (run just repo homepage-sonarr-secrets)." >&2; exit 1; }
[[ -f "$radarr_secret" ]] || { echo "Missing Homepage Radarr Secret: $radarr_secret (run just repo homepage-radarr-secrets)." >&2; exit 1; }
[[ -f "$lidarr_secret" ]] || { echo "Missing Homepage Lidarr Secret: $lidarr_secret (run just repo homepage-lidarr-secrets)." >&2; exit 1; }
[[ -f "$seerr_secret" ]] || { echo "Missing Homepage Seerr Secret: $seerr_secret (run just repo homepage-seerr-secrets)." >&2; exit 1; }
[[ "$(sops filestatus "$grafana_secret" | yq -r '.encrypted')" == 'true' ]]
[[ "$(yq -r '.metadata.name' "$grafana_secret")" == 'homepage-grafana' ]]
[[ "$(yq -r '.metadata.namespace' "$grafana_secret")" == 'homepage' ]]
[[ "$(sops filestatus "$ntfy_secret" | yq -r '.encrypted')" == 'true' ]]
[[ "$(yq -r '.metadata.name' "$ntfy_secret")" == 'homepage-ntfy' ]]
[[ "$(yq -r '.metadata.namespace' "$ntfy_secret")" == 'homepage' ]]
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
[[ "$(sops filestatus "$lidarr_secret" | yq -r '.encrypted')" == 'true' ]]
[[ "$(yq -r '.metadata.name' "$lidarr_secret")" == 'homepage-lidarr' ]]
[[ "$(yq -r '.metadata.namespace' "$lidarr_secret")" == 'homepage' ]]
[[ "$(sops filestatus "$seerr_secret" | yq -r '.encrypted')" == 'true' ]]
[[ "$(yq -r '.metadata.name' "$seerr_secret")" == 'homepage-seerr' ]]
[[ "$(yq -r '.metadata.namespace' "$seerr_secret")" == 'homepage' ]]
# The deployment must reference the split Secrets, not the old combined one.
assert_command_finds_nothing \
  'Homepage must not reference the retired combined homepage-secrets Secret.' \
  rg -q 'homepage-secrets' "$dep"
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_GRAFANA_USER") | .valueFrom.secretKeyRef.name] | .[0]' "$dep")" == 'homepage-grafana' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_NTFY_TOKEN") | .valueFrom.secretKeyRef.name] | .[0]' "$dep")" == 'homepage-ntfy' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_NTFY_TOKEN") | .valueFrom.secretKeyRef.key] | .[0]' "$dep")" == 'token' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_NTFY_TOKEN") | .valueFrom.secretKeyRef.optional] | .[0]' "$dep")" == 'true' ]]
# The ntfy widget token rotates via `just repo ntfy-identity rotate homepage`; the
# pod-template sops-hash annotation restarts Homepage so the new token is picked up.
[[ "$(yq -r '.spec.template.metadata.annotations["sops-hash"]' "$dep")" == "$(git hash-object "$ntfy_secret")" ]] || {
  echo 'Refusing: the Homepage deployment sops-hash annotation must equal git hash-object of homepage-ntfy.sops.yaml.' >&2
  exit 1
}
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_PLEX_TOKEN") | .valueFrom.secretKeyRef.name] | .[0]' "$dep")" == 'homepage-plex' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_PORTAINER_API_KEY") | .valueFrom.secretKeyRef.name] | .[0]' "$dep")" == 'homepage-portainer' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_PORTAINER_API_KEY") | .valueFrom.secretKeyRef.key] | .[0]' "$dep")" == 'apiKey' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_PORTAINER_API_KEY") | .valueFrom.secretKeyRef.optional] | .[0]' "$dep")" == 'true' ]]
[[ "$(yq -r '.spec.template.metadata.annotations["homepage-portainer-sops-hash"]' "$dep")" == \
  "$(git hash-object "$portainer_secret")" ]] || {
  echo 'Refusing: the Homepage Portainer rollout stamp must equal git hash-object of homepage-portainer.sops.yaml.' >&2
  exit 1
}
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
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_LIDARR_API_KEY") | .valueFrom.secretKeyRef.name] | .[0]' "$dep")" == 'homepage-lidarr' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_LIDARR_API_KEY") | .valueFrom.secretKeyRef.key] | .[0]' "$dep")" == 'apiKey' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_LIDARR_API_KEY") | .valueFrom.secretKeyRef.optional] | .[0]' "$dep")" == 'true' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_SEERR_API_KEY") | .valueFrom.secretKeyRef.name] | .[0]' "$dep")" == 'homepage-seerr' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_SEERR_API_KEY") | .valueFrom.secretKeyRef.key] | .[0]' "$dep")" == 'apiKey' ]]

kustomize build "$base/app" >/dev/null

echo 'Homepage source, wiring, namespace label, dependency graph, image, allowed-hosts, HTTPRoute, and split encrypted widget Secrets passed validation.'
