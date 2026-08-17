#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/monitoring/gatus'
ks="$base/ks.yaml"
values="$base/app/values.yaml"
hr="$base/app/helmrelease.yaml"
repo="$base/app/helmrepository.yaml"
route="$base/app/httproute.yaml"
ns="$base/app/namespace.yaml"
secret="$base/app/media-integration-api-keys.sops.yaml"
echo_route='kubernetes/apps/testing/echo/app/httproute.yaml'
echo_service='kubernetes/apps/testing/echo/app/service.yaml'
internal_gateway='kubernetes/apps/networking/internal-gateway/app/gateway.yaml'
expected_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' .sops.yaml)"
temp_dir="$(mktemp -d /tmp/homelab-talos-gatus-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

require_equal() {
  local description="$1"
  local actual="$2"
  local expected="$3"
  [[ "$actual" == "$expected" ]] || {
    echo "$description: expected $expected; got $actual." >&2
    exit 1
  }
}

for f in "$ks" "$values" "$hr" "$repo" "$route" "$ns" "$secret" "$echo_route" "$echo_service" "$internal_gateway" "$base/app/kustomization.yaml"; do
  [[ -f "$f" ]] || { echo "Missing Phase 10 Gatus source: $f" >&2; exit 1; }
done
rg -qx '  - ./gatus/ks.yaml' kubernetes/apps/monitoring/kustomization.yaml || {
  echo 'Refusing: ./gatus/ks.yaml is not listed in kubernetes/apps/monitoring/kustomization.yaml.' >&2
  exit 1
}

suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
[[ "$(yq -r '.metadata.labels."gateway.supermorphic.com/access"' "$ns")" == 'internal' ]]
[[ "$(yq ea -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'cilium,internal-gateway' ]]
require_equal 'Gatus Flux SOPS provider' "$(yq -r '.spec.decryption.provider' "$ks")" 'sops'
require_equal 'Gatus Flux SOPS Secret reference' "$(yq -r '.spec.decryption.secretRef.name' "$ks")" 'sops-age'
require_equal 'Gatus media API-key Secret resource count' \
  "$(yq -r '[.resources[] | select(. == "./media-integration-api-keys.sops.yaml")] | length' "$base/app/kustomization.yaml")" '1'
require_equal 'Gatus media API-key Secret encryption state' \
  "$(sops filestatus "$secret" | yq -r '.encrypted')" 'true'
require_equal 'Gatus media API-key Secret SOPS recipient' \
  "$(yq -r '.sops.age[].recipient' "$secret" | sort -u)" "$expected_recipient"
require_equal 'Gatus media API-key Secret kind' "$(yq -r '.kind' "$secret")" 'Secret'
require_equal 'Gatus media API-key Secret name' "$(yq -r '.metadata.name' "$secret")" 'gatus-media-integration-api-keys'
require_equal 'Gatus media API-key Secret namespace' "$(yq -r '.metadata.namespace' "$secret")" 'gatus'
require_equal 'Gatus media API-key Secret type' "$(yq -r '.type' "$secret")" 'Opaque'
require_equal 'Gatus media API-key Secret must not use data' "$(yq -r 'has("data")' "$secret")" 'false'
require_equal 'Gatus media API-key Secret stringData keys' \
  "$(yq -r '.stringData | keys | sort | join(",")' "$secret")" \
  'lidarr_api_key,prowlarr_api_key,radarr_api_key,seerr_api_key,sonarr_api_key'
chart_version="$(yq -r '.spec.chart.spec.version' "$hr")"
[[ -n "$chart_version" && "$chart_version" != 'null' ]]
[[ "$(yq -r '.spec.url' "$repo")" == 'https://twin.github.io/helm-charts' ]]
[[ "$(yq -r '.config.storage.type' "$values")" == 'memory' ]]
echo_endpoint="$(yq -o=json -I=0 '.config.endpoints[] | select(.group == "Platform" and .name == "echo")' "$values")"
[[ -n "$echo_endpoint" ]]
[[ "$(yq -r '.url' - <<<"$echo_endpoint")" == 'https://echo.lab.supermorphic.com/' ]]
[[ "$(yq -r '.interval' - <<<"$echo_endpoint")" == '1m' ]]
[[ "$(yq -r '.conditions | join(",")' - <<<"$echo_endpoint")" == '[STATUS] == 200' ]]
[[ "$(yq -r '.client.insecure // false' - <<<"$echo_endpoint")" == 'false' ]]

[[ "$(yq -r '.metadata.annotations."external-dns.k8s.io/audience"' "$echo_route")" == 'internal' ]]
[[ "$(yq -r '.spec.hostnames | join(",")' "$echo_route")" == 'echo.lab.supermorphic.com' ]]
[[ "$(yq -r '.spec.parentRefs[0] | [.group,.kind,.namespace,.name,.sectionName] | join(",")' "$echo_route")" == 'gateway.networking.k8s.io,Gateway,networking,internal,https' ]]
[[ "$(yq -r '.spec.rules[0].backendRefs[0] | [.kind,.name,.port] | join(",")' "$echo_route")" == 'Service,echo,80' ]]
[[ "$(yq -r '.metadata.name' "$echo_service")" == 'echo' ]]
[[ "$(yq -r '.spec.ports[0].port' "$echo_service")" == '80' ]]

gateway_listener="$(yq -o=json -I=0 '.spec.listeners[] | select(.name == "https")' "$internal_gateway")"
[[ "$(yq -r '.hostname' - <<<"$gateway_listener")" == '*.lab.supermorphic.com' ]]
[[ "$(yq -r '[.port,.protocol,.tls.mode] | join(",")' - <<<"$gateway_listener")" == '443,HTTPS,Terminate' ]]
[[ "$(yq -r '.tls.certificateRefs | length' - <<<"$gateway_listener")" == '1' ]]
[[ "$(yq -r '.tls.certificateRefs[0] | [.group,.kind,.name] | join(",")' - <<<"$gateway_listener")" == ',Secret,wildcard-lab-supermorphic-com-tls' ]]
[[ "$(yq -r '.spec.hostnames[0]' "$route")" == 'gatus.lab.supermorphic.com' ]]
[[ "$(yq -r '.spec.parentRefs[0].name' "$route")" == 'internal' ]]

media_endpoint_names='lidarr-native-health,prowlarr-native-health,radarr-native-health,seerr-radarr-service-read,seerr-sonarr-service-read,sonarr-native-health'
require_equal 'Media Integration endpoint names' \
  "$(yq -r '[.config.endpoints[] | select(.group == "Media Integration") | .name] | sort | join(",")' "$values")" \
  "$media_endpoint_names"

check_media_endpoint() {
  local name="$1"
  local url="$2"
  local api_key_env="$3"
  local conditions="$4"
  local endpoint
  endpoint="$(yq -o=json -I=0 ".config.endpoints[] | select(.name == \"$name\")" "$values")"
  [[ -n "$endpoint" ]] || {
    echo "Media Integration endpoint $name is missing." >&2
    exit 1
  }
  require_equal "Media Integration endpoint $name group" "$(yq -r '.group' - <<<"$endpoint")" 'Media Integration'
  require_equal "Media Integration endpoint $name URL" "$(yq -r '.url' - <<<"$endpoint")" "$url"
  require_equal "Media Integration endpoint $name method" "$(yq -r '.method' - <<<"$endpoint")" 'GET'
  require_equal "Media Integration endpoint $name interval" "$(yq -r '.interval' - <<<"$endpoint")" '1m'
  require_equal "Media Integration endpoint $name API-key header" \
    "$(yq -r '.headers."X-Api-Key"' - <<<"$endpoint")" "$api_key_env"
  require_equal "Media Integration endpoint $name conditions" \
    "$(yq -r '.conditions | join("|")' - <<<"$endpoint")" "$conditions"
  require_equal "Media Integration endpoint $name hides errors" \
    "$(yq -r '.ui."hide-errors"' - <<<"$endpoint")" 'true'
}

check_media_endpoint 'prowlarr-native-health' \
  'https://prowlarr.lab.supermorphic.com/api/v1/health' "\${GATUS_PROWLARR_API_KEY}" \
  '[STATUS] == 200'
check_media_endpoint 'sonarr-native-health' \
  'https://sonarr.lab.supermorphic.com/api/v3/health' "\${GATUS_SONARR_API_KEY}" \
  '[STATUS] == 200'
check_media_endpoint 'radarr-native-health' \
  'https://radarr.lab.supermorphic.com/api/v3/health' "\${GATUS_RADARR_API_KEY}" \
  '[STATUS] == 200'
check_media_endpoint 'lidarr-native-health' \
  'https://lidarr.lab.supermorphic.com/api/v1/health' "\${GATUS_LIDARR_API_KEY}" \
  '[STATUS] == 200'
check_media_endpoint 'seerr-sonarr-service-read' \
  'https://seerr.lab.supermorphic.com/api/v1/service/sonarr/0' "\${GATUS_SEERR_API_KEY}" \
  '[STATUS] == 200|[BODY].server.id == 0|has([BODY].profiles) == true|has([BODY].rootFolders) == true'
check_media_endpoint 'seerr-radarr-service-read' \
  'https://seerr.lab.supermorphic.com/api/v1/service/radarr/0' "\${GATUS_SEERR_API_KEY}" \
  '[STATUS] == 200|[BODY].server.id == 0|has([BODY].profiles) == true|has([BODY].rootFolders) == true'
require_equal 'Media Integration endpoint methods and bodies' \
  "$(yq -r '[.config.endpoints[] | select(.group == "Media Integration") | select(.method != "GET" or has("body"))] | length' "$values")" '0'

legacy_endpoint_names='alertmanager,echo,flaresolverr,grafana,letsencrypt-acme,lidarr,longhorn-ui,ntfy,plex,portainer,prometheus,prowlarr,qbittorrent-vpn,radarr,seerr,sonarr,tautulli,test-reports'
require_equal 'Existing Level 1 endpoint names' \
  "$(yq -r '[.config.endpoints[] | select(.group != "Media Integration") | .name] | sort | join(",")' "$values")" \
  "$legacy_endpoint_names"
while IFS='|' read -r name group url interval conditions; do
  require_equal "Existing Level 1 endpoint $name group" \
    "$(yq -r ".config.endpoints[] | select(.name == \"$name\") | .group" "$values")" "$group"
  require_equal "Existing Level 1 endpoint $name URL" \
    "$(yq -r ".config.endpoints[] | select(.name == \"$name\") | .url" "$values")" "$url"
  require_equal "Existing Level 1 endpoint $name interval" \
    "$(yq -r ".config.endpoints[] | select(.name == \"$name\") | .interval" "$values")" "$interval"
  require_equal "Existing Level 1 endpoint $name conditions" \
    "$(yq -r ".config.endpoints[] | select(.name == \"$name\") | .conditions | join(\"|\")" "$values")" "$conditions"
done <<'EOF'
grafana|Observability|https://grafana.lab.supermorphic.com/api/health|1m|[STATUS] == 200|[BODY].database == ok
prometheus|Observability|https://prometheus.lab.supermorphic.com/-/healthy|1m|[STATUS] == 200
alertmanager|Observability|https://alertmanager.lab.supermorphic.com/-/healthy|1m|[STATUS] == 200
test-reports|Observability|https://tests.lab.supermorphic.com/|1m|[STATUS] == 200
echo|Platform|https://echo.lab.supermorphic.com/|1m|[STATUS] == 200
portainer|Platform|https://portainer.lab.supermorphic.com/|1m|[STATUS] == 200
ntfy|Platform|http://ntfy.ntfy.svc.cluster.local/v1/health|1m|[STATUS] == 200|[BODY].healthy == true
longhorn-ui|Storage|http://longhorn-frontend.longhorn-system.svc.cluster.local/|2m|[STATUS] == 200
plex|Media|https://plex.lab.supermorphic.com/identity|1m|[STATUS] == 200
qbittorrent-vpn|Media|http://qbittorrent-gluetun-control.media.svc.cluster.local:8000/v1/vpn/status|1m|[STATUS] == 200|[BODY].status == running
prowlarr|Media|https://prowlarr.lab.supermorphic.com/ping|1m|[STATUS] == 200
sonarr|Media|https://sonarr.lab.supermorphic.com/ping|1m|[STATUS] == 200
radarr|Media|https://radarr.lab.supermorphic.com/ping|1m|[STATUS] == 200
lidarr|Media|https://lidarr.lab.supermorphic.com/ping|1m|[STATUS] == 200
seerr|Media|https://seerr.lab.supermorphic.com/api/v1/status|1m|[STATUS] == 200
tautulli|Media|https://tautulli.lab.supermorphic.com/status|1m|[STATUS] == 200
flaresolverr|Media|http://flaresolverr.media.svc.cluster.local:8191/|1m|[STATUS] == 200
letsencrypt-acme|External|https://acme-v02.api.letsencrypt.org/directory|10m|[STATUS] == 200
EOF

kustomize build "$base/app" >/dev/null
printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
  helm template gatus gatus --repo https://twin.github.io/helm-charts --version "$chart_version" --namespace gatus --values "$values" >"$temp_dir/render.yaml"
rendered="$temp_dir/render.yaml"
require_equal 'Rendered Gatus Deployment' \
  "$(yq -r 'select(.kind == "Deployment") | .metadata.name' "$rendered")" 'gatus'
require_equal 'Rendered Gatus TZ environment variable' \
  "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "gatus") | .spec.template.spec.containers[] | select(.name == "gatus") | .env[] | select(.name == "TZ") | .value] | .[0]' "$rendered")" \
  'America/Denver'
while IFS='|' read -r env_name secret_key; do
  require_equal "Rendered Gatus $env_name Secret name" \
    "$(yq ea -r "[select(.kind == \"Deployment\" and .metadata.name == \"gatus\") | .spec.template.spec.containers[] | select(.name == \"gatus\") | .env[] | select(.name == \"$env_name\") | .valueFrom.secretKeyRef.name] | .[0]" "$rendered")" \
    'gatus-media-integration-api-keys'
  require_equal "Rendered Gatus $env_name Secret key" \
    "$(yq ea -r "[select(.kind == \"Deployment\" and .metadata.name == \"gatus\") | .spec.template.spec.containers[] | select(.name == \"gatus\") | .env[] | select(.name == \"$env_name\") | .valueFrom.secretKeyRef.key] | .[0]" "$rendered")" \
    "$secret_key"
done <<'EOF'
GATUS_PROWLARR_API_KEY|prowlarr_api_key
GATUS_SONARR_API_KEY|sonarr_api_key
GATUS_RADARR_API_KEY|radarr_api_key
GATUS_LIDARR_API_KEY|lidarr_api_key
GATUS_SEERR_API_KEY|seerr_api_key
EOF
require_equal 'Rendered Gatus container envFrom Secret references' \
  "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "gatus") | .spec.template.spec.containers[] | select(.name == "gatus") | .envFrom[]? | select(has("secretRef"))] | length' "$rendered")" '0'

echo 'Phase 10 Gatus source, encrypted media API-key Secret, exact silent media-integration probes, legacy Level 1 probes, wiring, namespace label, values, HTTPRoute, echo DNS/Gateway/production-TLS source linkage, and pinned chart render passed validation.'
