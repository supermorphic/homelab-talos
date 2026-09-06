#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/monitoring/gatus'
ks="$base/ks.yaml"
values="$base/app/values.yaml"
canary_activation_values="$base/app/n8n-canary-activation.values.yaml"
hr="$base/app/helmrelease.yaml"
repo="$base/app/helmrepository.yaml"
route="$base/app/httproute.yaml"
ns="$base/app/namespace.yaml"
secret="$base/app/media-integration-api-keys.sops.yaml"
canary_secret="$base/app/n8n-canary.sops.yaml"
echo_route='kubernetes/apps/testing/echo/app/httproute.yaml'
echo_service='kubernetes/apps/testing/echo/app/service.yaml'
internal_gateway='kubernetes/apps/networking/internal-gateway/app/gateway.yaml'
n8n_ks='kubernetes/apps/automation/n8n/ks.yaml'
postgresql_ks='kubernetes/apps/automation/n8n-postgresql/ks.yaml'
public_route_ks='kubernetes/apps/networking/public-webhook-gateway/ks.yaml'
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

normalise_resource_path() {
  local path="$1"
  while [[ "$path" == ./* ]]; do
    path="${path#./}"
  done
  printf '%s\n' "$path"
}

validate_selected_sops_secret() {
  local owner="$1" resource="$2" target="$3" expected_name="$4"
  local expected_namespace="$5" expected_keys="$6" expected_recipient selected_resource
  local normalised_resource normalised_selected_resource selected=false
  local -a expected_recipients candidate_recipients

  normalised_resource="$(normalise_resource_path "$resource")"
  while IFS= read -r selected_resource; do
    normalised_selected_resource="$(normalise_resource_path "$selected_resource")"
    [[ "$normalised_selected_resource" != "$normalised_resource" ]] || selected=true
  done < <(yq -r '.resources[]?' "$owner")
  [[ "$selected" == true ]] || return 0
  [[ -f "$target" ]] || {
    echo "Missing selected Gatus SOPS Secret: $target." >&2
    exit 1
  }
  # shellcheck disable=SC2016 # yq reads target through its env() function.
  mapfile -t expected_recipients < <(
    target="$target" yq -r \
      '.creation_rules[] | select(.path_regex as $rule | env(target) | test($rule)) | .age' \
      .sops.yaml
  )
  [[ "${#expected_recipients[@]}" -eq 1 && -n "${expected_recipients[0]}" && \
    "${expected_recipients[0]}" != 'null' ]] || {
    echo "Unable to select exactly one SOPS age recipient for $target." >&2
    exit 1
  }
  expected_recipient="${expected_recipients[0]}"
  # This verifies the complete serialized SOPS value envelope shape. Only Task 9
  # operator/Flux decryption with the private key can prove cryptographic authenticity.
  [[ "$(sops filestatus "$target" | yq -r '.encrypted')" == 'true' && \
    "$(yq -r '[.stringData[] | test("^ENC\\[AES256_GCM,data:[A-Za-z0-9+/=]+,iv:[A-Za-z0-9+/=]+,tag:[A-Za-z0-9+/=]+,type:str\\]$")] | all' "$target")" == 'true' ]] || {
    echo "Selected Gatus SOPS Secret is not encrypted: $target." >&2
    exit 1
  }
  mapfile -t candidate_recipients < <(yq -r '.sops.age[].recipient' "$target" | sort -u)
  [[ "${#candidate_recipients[@]}" -eq 1 && \
    "${candidate_recipients[0]}" == "$expected_recipient" ]] || {
    echo "Selected Gatus SOPS Secret has an unexpected age recipient: $target." >&2
    exit 1
  }
  [[ "$(yq -r 'has("data") | not' "$target")" == 'true' && \
    "$(yq -r 'keys | sort | join(",")' "$target")" == \
      'apiVersion,kind,metadata,sops,stringData,type' && \
    "$(yq -r '.metadata | keys | sort | join(",")' "$target")" == 'name,namespace' && \
    "$(yq -r '.apiVersion' "$target")" == 'v1' && \
    "$(yq -r '.kind' "$target")" == 'Secret' && \
    "$(yq -r '.metadata.name' "$target")" == "$expected_name" && \
    "$(yq -r '.metadata.namespace' "$target")" == "$expected_namespace" && \
    "$(yq -r '.type' "$target")" == 'Opaque' ]] || {
    echo "Selected Gatus SOPS Secret has an unexpected Secret contract: $target." >&2
    exit 1
  }
  [[ "$(yq -r '.stringData | keys | sort | join(",")' "$target")" == "$expected_keys" ]] || {
    echo "Selected Gatus SOPS Secret has an unexpected key set: $target." >&2
    exit 1
  }
}

for f in "$ks" "$values" "$canary_activation_values" "$hr" "$repo" "$route" "$ns" \
  "$secret" "$echo_route" "$echo_service" "$internal_gateway" \
  "$n8n_ks" "$postgresql_ks" "$public_route_ks" "$base/app/kustomization.yaml"; do
  [[ -f "$f" ]] || { echo "Missing Gatus source: $f" >&2; exit 1; }
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
declare -A resource_counts=()
while IFS= read -r resource; do
  resource="$(normalise_resource_path "$resource")"
  case "$resource" in
    helmrelease.yaml | helmrepository.yaml | httproute.yaml | \
      media-integration-api-keys.sops.yaml | namespace.yaml | n8n-canary.sops.yaml)
      resource_counts["$resource"]=$(( ${resource_counts["$resource"]:-0} + 1 ))
      ;;
    *)
      echo "The Gatus app Kustomization selects an unexpected resource: $resource" >&2
      exit 1
      ;;
  esac
done < <(yq -r '.resources[]' "$base/app/kustomization.yaml")
for resource in helmrelease.yaml helmrepository.yaml httproute.yaml \
  media-integration-api-keys.sops.yaml namespace.yaml; do
  require_equal "Gatus resource $resource count" "${resource_counts["$resource"]:-0}" '1'
done
[[ "${resource_counts[n8n-canary.sops.yaml]:-0}" -le 1 ]] || {
  echo 'The Gatus app must not select n8n-canary.sops.yaml more than once.' >&2
  exit 1
}
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
validate_selected_sops_secret "$base/app/kustomization.yaml" './n8n-canary.sops.yaml' \
  "$canary_secret" n8n-canary gatus token
active_canary_env_count="$(yq -r \
  '[.env.GATUS_N8N_CANARY_TOKEN | select(. != null)] | length' "$values")"
active_canary_endpoint_count="$(yq -r \
  '[.config.endpoints[] | select(.name == "n8n-webhook-e2e")] | length' "$values")"
[[ "$active_canary_env_count" == "$active_canary_endpoint_count" && \
  ("$active_canary_env_count" == '0' || "$active_canary_env_count" == '1') ]] || {
  echo 'Active Gatus n8n webhook E2E values must be entirely absent or entirely activated.' >&2
  exit 1
}
canary_active=false
[[ "$active_canary_env_count" == '0' ]] || canary_active=true
if [[ "$canary_active" == true ]]; then
  require_equal 'Activated Gatus n8n webhook E2E Secret selection' \
    "${resource_counts[n8n-canary.sops.yaml]:-0}" '1'
  require_equal 'Activated Gatus n8n Kustomization state' \
    "$(yq -r '.spec.suspend // false' "$n8n_ks")" 'false'
  require_equal 'Activated Gatus n8n PostgreSQL Kustomization state' \
    "$(yq -r '.spec.suspend // false' "$postgresql_ks")" 'false'
  require_equal 'Activated Gatus public webhook route Kustomization state' \
    "$(yq ea -r 'select(.metadata.name == "public-webhook-route") |
      .spec.suspend // false' "$public_route_ks")" 'false'
fi
chart_version="$(yq -r '.spec.chart.spec.version' "$hr")"
[[ -n "$chart_version" && "$chart_version" != 'null' ]]
require_equal 'Active Gatus Helm values source' \
  "$(yq -r '.spec.valuesFrom | map([.kind, .name, .valuesKey] | join(",")) | join("|")' \
    "$hr")" 'ConfigMap,gatus-values,values.yaml'
require_equal 'Active Gatus generated values files' \
  "$(yq -r '[.configMapGenerator[] | select(.name == "gatus-values") | .files[]] |
    sort | join(",")' "$base/app/kustomization.yaml")" 'values.yaml=values.yaml'
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
  "$(yq -r '[.config.endpoints[] | select(.group != "Media Integration" and
    .name != "n8n-readiness" and .name != "n8n-webhook-e2e" and
    .name != "automation-data-e2e") | .name] | sort | join(",")' "$values")" \
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

readiness_endpoint="$(yq -o=json -I=0 \
  '.config.endpoints[] | select(.group == "Automation" and .name == "n8n-readiness")' \
  "$values")"
require_equal 'Gatus n8n readiness endpoint contract' "$readiness_endpoint" \
  '{"name":"n8n-readiness","group":"Automation","url":"https://n8n.lab.supermorphic.com/healthz/readiness","method":"GET","interval":"1m","conditions":["[STATUS] == 200","[BODY].status == ok"]}'

require_equal 'Gatus automation-data E2E endpoint count' \
  "$(yq -r '[.config.endpoints[] | select(.name == "automation-data-e2e")] | length' "$values")" '1'
automation_data_endpoint="$(yq -o=json -I=0 \
  '.config.endpoints[] | select(.name == "automation-data-e2e")' "$values")"
require_equal 'Gatus automation-data E2E private request contract' \
  "$(yq -r '[.group,.url,.method,.interval,.body] | join("|")' - <<<"$automation_data_endpoint")" \
  'Automation|https://n8n.lab.supermorphic.com/webhook/automation-data-canary|POST|5m|{}'
# shellcheck disable=SC2016 # The expected value is a literal Gatus environment placeholder.
require_equal 'Gatus automation-data E2E authentication headers' \
  "$(yq -o=json -I=0 '.headers | sort_keys(.)' - <<<"$automation_data_endpoint")" \
  '{"Content-Type":"application/json","X-Platform-Canary":"${GATUS_N8N_CANARY_TOKEN}"}'
require_equal 'Gatus automation-data E2E response conditions' \
  "$(yq -r '.conditions | join("|")' - <<<"$automation_data_endpoint")" \
  '[STATUS] == 200|[BODY].status == ok|[BODY].database == automation_data_canary|[BODY].role == automation_data_canary_runtime|len([BODY].executionId) > 0'
require_equal 'Gatus automation-data E2E hides errors' \
  "$(yq -r '.ui."hide-errors"' - <<<"$automation_data_endpoint")" 'true'
require_equal 'Gatus automation-data E2E verifies TLS' \
  "$(yq -r '.client.insecure // false' - <<<"$automation_data_endpoint")" 'false'
require_equal 'Gatus has no direct automation-data PostgreSQL probe' \
  "$(yq -r '[.config.endpoints[] | select(.url | test("automation-data-postgresql|^postgres(ql)?://|:5432(/|$)"))] | length' "$values")" '0'
require_equal 'Gatus automation-data E2E reuses the active canary environment' \
  "$active_canary_env_count" '1'

canary_endpoint="$(yq -o=json -I=0 \
  '.config.endpoints[] | select(.group == "Automation" and .name == "n8n-webhook-e2e")' \
  "$canary_activation_values")"
require_equal 'Staged Gatus n8n webhook E2E environment contract' \
  "$(yq -o=json -I=0 '.env.GATUS_N8N_CANARY_TOKEN' "$canary_activation_values")" \
  '{"valueFrom":{"secretKeyRef":{"name":"n8n-canary","key":"token"}}}'
require_equal 'Staged Gatus n8n webhook E2E endpoint contract' \
  "$(yq -r '[.config.endpoints[] | select(.name == "n8n-webhook-e2e")] | length' \
    "$canary_activation_values")" '1'
require_equal 'Automation n8n webhook E2E endpoint method' \
  "$(yq -r '.method' - <<<"$canary_endpoint")" 'POST'
# shellcheck disable=SC2016 # The expected value is a literal Gatus environment placeholder.
require_equal 'Automation n8n webhook E2E endpoint authentication header' \
  "$(yq -r '.headers."X-Platform-Canary"' - <<<"$canary_endpoint")" \
  '${GATUS_N8N_CANARY_TOKEN}'
require_equal 'Automation n8n webhook E2E endpoint header inventory' \
  "$(yq -r '.headers | keys | sort | join(",")' - <<<"$canary_endpoint")" \
  'Content-Type,X-Platform-Canary'
require_equal 'Automation n8n webhook E2E endpoint content type' \
  "$(yq -r '.headers."Content-Type"' - <<<"$canary_endpoint")" 'application/json'
require_equal 'Automation n8n webhook E2E endpoint body' \
  "$(yq -r '.body' - <<<"$canary_endpoint")" '{"correlation":"gatus-platform-canary"}'
require_equal 'Automation n8n webhook E2E endpoint hides errors' \
  "$(yq -r '.ui."hide-errors"' - <<<"$canary_endpoint")" 'true'

if [[ "$canary_active" == true ]]; then
  require_equal 'Activated Gatus n8n webhook E2E environment contract' \
    "$(yq -o=json -I=0 '.env.GATUS_N8N_CANARY_TOKEN' "$values")" \
    "$(yq -o=json -I=0 '.env.GATUS_N8N_CANARY_TOKEN' "$canary_activation_values")"
  require_equal 'Activated Gatus n8n webhook E2E endpoint contract' \
    "$(yq -o=json -I=0 '.config.endpoints[] | select(.name == "n8n-webhook-e2e")' \
      "$values")" "$canary_endpoint"
fi

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
rendered_canary_env_count="$(yq ea -r \
  '[select(.kind == "Deployment" and .metadata.name == "gatus") |
    .spec.template.spec.containers[] | select(.name == "gatus") | .env[]? |
    select(.name == "GATUS_N8N_CANARY_TOKEN")] | length' "$rendered")"
require_equal 'Rendered active Gatus n8n webhook E2E environment count' \
  "$rendered_canary_env_count" "$active_canary_env_count"
rendered_canary_endpoint_count="$(yq ea -r \
  '[select(.kind == "ConfigMap" and .metadata.name == "gatus") |
    .data."config.yaml" | from_yaml | .endpoints[]? |
    select(.name == "n8n-webhook-e2e")] | length' "$rendered")"
require_equal 'Rendered active Gatus n8n webhook E2E endpoint count' \
  "$rendered_canary_endpoint_count" "$active_canary_endpoint_count"
if [[ "$canary_active" == true ]]; then
  require_equal 'Rendered Gatus GATUS_N8N_CANARY_TOKEN Secret name' \
    "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "gatus") | .spec.template.spec.containers[] | select(.name == "gatus") | .env[] | select(.name == "GATUS_N8N_CANARY_TOKEN") | .valueFrom.secretKeyRef.name] | .[0]' "$rendered")" \
    'n8n-canary'
  require_equal 'Rendered Gatus GATUS_N8N_CANARY_TOKEN Secret key' \
    "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "gatus") | .spec.template.spec.containers[] | select(.name == "gatus") | .env[] | select(.name == "GATUS_N8N_CANARY_TOKEN") | .valueFrom.secretKeyRef.key] | .[0]' "$rendered")" \
    'token'
fi
require_equal 'Rendered Gatus container envFrom Secret references' \
  "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "gatus") | .spec.template.spec.containers[] | select(.name == "gatus") | .envFrom[]? | select(has("secretRef"))] | length' "$rendered")" '0'

echo 'Gatus source, n8n readiness and staged webhook E2E contracts, permanent automation-data E2E probe, encrypted media API-key Secret, exact silent media-integration probes, active Level 1 probes, wiring, namespace label, values, HTTPRoute, echo DNS/Gateway/production-TLS source linkage, and pinned chart render passed validation.'
