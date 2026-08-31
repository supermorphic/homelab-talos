#!/usr/bin/env bash
# Negative coverage for scripts/validate/gatus.sh. The production source only ever
# supplies one passing configuration, so mutations run in a disposable source tree.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="$repo_root/scripts/validate/gatus.sh"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-gatus-validator-test.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT

run_production_validator() {
  (cd "$repo_root" && "$validator") 2>&1
}

assert_production_activated_render() {
  local values chart_version render
  values="$repo_root/kubernetes/apps/monitoring/gatus/app/values.yaml"
  chart_version="$(yq -r '.spec.chart.spec.version' \
    "$repo_root/kubernetes/apps/monitoring/gatus/app/helmrelease.yaml")"
  render="$test_dir/production-activated.yaml"
  helm template gatus gatus --repo https://twin.github.io/helm-charts \
    --version "$chart_version" --namespace gatus --values "$values" >"$render"
  [[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "gatus") |
    .spec.template.spec.containers[] | select(.name == "gatus") | .env[]? |
    select(.name == "GATUS_N8N_CANARY_TOKEN")] | length' "$render")" == '1' ]] || {
    echo 'Activated Gatus must render exactly one n8n webhook E2E Secret reference.' >&2
    exit 1
  }
  [[ "$(yq ea -r '[select(.kind == "ConfigMap" and .metadata.name == "gatus") |
    .data."config.yaml" | from_yaml | .endpoints[]? |
    select(.name == "n8n-webhook-e2e")] | length' "$render")" == '1' ]] || {
    echo 'Activated Gatus must render exactly one n8n webhook E2E endpoint.' >&2
    exit 1
  }
  [[ "$(yq ea -r '[select(.kind == "ConfigMap" and .metadata.name == "gatus") |
    .data."config.yaml" | from_yaml | .endpoints[]? |
    select(.name == "n8n-readiness")] | length' "$render")" == '1' ]] || {
    echo 'Activated Gatus must render exactly one n8n readiness endpoint.' >&2
    exit 1
  }
}

tree_root="$test_dir/tree"

reset_tree() {
  rm -rf -- "$tree_root"
  mkdir -p "$tree_root/kubernetes/apps/monitoring" \
    "$tree_root/kubernetes/apps/automation/n8n" \
    "$tree_root/kubernetes/apps/automation/n8n-postgresql" \
    "$tree_root/kubernetes/apps/networking/public-webhook-gateway" \
    "$tree_root/kubernetes/apps/testing/echo/app" \
    "$tree_root/kubernetes/apps/networking/internal-gateway/app"
  cp "$repo_root/.sops.yaml" "$tree_root/.sops.yaml"
  cp -R "$repo_root/kubernetes/apps/monitoring/gatus" \
    "$tree_root/kubernetes/apps/monitoring/gatus"
  cp "$repo_root/kubernetes/apps/monitoring/kustomization.yaml" \
    "$tree_root/kubernetes/apps/monitoring/kustomization.yaml"
  cp "$repo_root/kubernetes/apps/testing/echo/app/httproute.yaml" \
    "$tree_root/kubernetes/apps/testing/echo/app/httproute.yaml"
  cp "$repo_root/kubernetes/apps/testing/echo/app/service.yaml" \
    "$tree_root/kubernetes/apps/testing/echo/app/service.yaml"
  cp "$repo_root/kubernetes/apps/networking/internal-gateway/app/gateway.yaml" \
    "$tree_root/kubernetes/apps/networking/internal-gateway/app/gateway.yaml"
  cp "$repo_root/kubernetes/apps/automation/n8n/ks.yaml" \
    "$tree_root/kubernetes/apps/automation/n8n/ks.yaml"
  cp "$repo_root/kubernetes/apps/automation/n8n-postgresql/ks.yaml" \
    "$tree_root/kubernetes/apps/automation/n8n-postgresql/ks.yaml"
  cp "$repo_root/kubernetes/apps/networking/public-webhook-gateway/ks.yaml" \
    "$tree_root/kubernetes/apps/networking/public-webhook-gateway/ks.yaml"
  local synthetic_recipient
  synthetic_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' \
    "$tree_root/.sops.yaml")"
  synthetic_recipient="$synthetic_recipient" yq -n '
    .apiVersion = "v1" |
    .kind = "Secret" |
    .metadata.name = "n8n-canary" |
    .metadata.namespace = "gatus" |
    .type = "Opaque" |
    .stringData.token = "ENC[AES256_GCM,data:c3ludGhldGljLXRlc3Q=,iv:c3ludGhldGljLWl2,tag:c3ludGhldGljLXRhZw==,type:str]" |
    .sops.age = [{"recipient": strenv(synthetic_recipient), "enc": "synthetic-test-envelope"}] |
    .sops.lastmodified = "2026-01-01T00:00:00Z" |
    .sops.mac = "ENC[AES256_GCM,data:c3ludGhldGljLW1hYw==,iv:c3ludGhldGljLWl2,tag:c3ludGhldGljLXRhZw==,type:str]" |
    .sops.encrypted_regex = "^(data|stringData)$" |
    .sops.version = "3.11.0"
  ' >"$tree_root/kubernetes/apps/monitoring/gatus/app/n8n-canary.sops.yaml"
  yq -i '.resources = ([.resources[] |
    select(. != "./n8n-canary.sops.yaml")] + ["./n8n-canary.sops.yaml"])' \
    "$tree_root/kubernetes/apps/monitoring/gatus/app/kustomization.yaml"
}

run_validator() {
  (cd "$tree_root" && "$validator") 2>&1
}

deactivate_webhook_e2e_values() {
  local values
  values="$tree_root/kubernetes/apps/monitoring/gatus/app/values.yaml"
  yq -i 'del(.env.GATUS_N8N_CANARY_TOKEN) |
    del(.config.endpoints[] | select(.name == "n8n-webhook-e2e"))' "$values"
}

activate_webhook_e2e_values() {
  local values activation candidate
  values="$tree_root/kubernetes/apps/monitoring/gatus/app/values.yaml"
  activation="$tree_root/kubernetes/apps/monitoring/gatus/app/n8n-canary-activation.values.yaml"
  candidate="$test_dir/activated-values.yaml"
  deactivate_webhook_e2e_values
  # shellcheck disable=SC2016 # yq expands $item inside its expression.
  yq ea '. as $item ireduce ({}; . *+ $item)' "$values" "$activation" >"$candidate"
  mv -- "$candidate" "$values"
  yq -i '.spec.suspend = false' \
    "$tree_root/kubernetes/apps/automation/n8n/ks.yaml"
  yq -i '.spec.suspend = false' \
    "$tree_root/kubernetes/apps/automation/n8n-postgresql/ks.yaml"
  yq -i '(select(.metadata.name == "public-webhook-route") | .spec.suspend) = false' \
    "$tree_root/kubernetes/apps/networking/public-webhook-gateway/ks.yaml"
}

expect_pass() {
  local description="$1"
  local output exit_code
  set +e
  output="$(run_production_validator)"
  exit_code="$?"
  set -e
  [[ "$exit_code" -eq 0 ]] || {
    echo "$description: expected Gatus validation to pass." >&2
    echo "$output" >&2
    exit 1
  }
}

expect_fixture_pass() {
  local description="$1"
  local output exit_code
  set +e
  output="$(run_validator)"
  exit_code="$?"
  set -e
  [[ "$exit_code" -eq 0 ]] || {
    echo "$description: expected selected synthetic Gatus Secret fixture to pass." >&2
    echo "$output" >&2
    exit 1
  }
}

expect_fail() {
  local description="$1"
  local expected_message="$2"
  local output exit_code
  set +e
  output="$(run_validator)"
  exit_code="$?"
  set -e
  [[ "$exit_code" -eq 1 ]] || {
    echo "$description: expected exit 1, got $exit_code." >&2
    echo "$output" >&2
    exit 1
  }
  rg -Fq "$expected_message" <<<"$output" || {
    echo "$description: missing expected failure message: $expected_message" >&2
    echo "$output" >&2
    exit 1
  }
}

status_only_probe_succeeds() {
  local status="$1"
  : "$2" # The contract intentionally ignores the response body.
  [[ "$status" == '200' ]]
}

status_only_bodies=(
  '[]'
  '[{"source":"UpdateCheck"}]'
  '[{"source":"UpdateCheck"},{"source":"UpdateCheck"}]'
  '[{"source":"DownloadClientCheck"}]'
  '[{"source":"IndexerStatusCheck"}]'
  '[{"source":"UpdateCheck"},{"source":"DownloadClientCheck"}]'
)
for synthetic_body in "${status_only_bodies[@]}"; do
  status_only_probe_succeeds '200' "$synthetic_body" || {
    echo "Synthetic HTTP 200 response must pass regardless of body: $synthetic_body" >&2
    exit 1
  }
done
if status_only_probe_succeeds '503' '[]'; then
  echo 'Synthetic non-200 response must fail regardless of body.' >&2
  exit 1
fi

source_values="$repo_root/kubernetes/apps/monitoring/gatus/app/values.yaml"
for native_endpoint in \
  prowlarr-native-health \
  sonarr-native-health \
  radarr-native-health \
  lidarr-native-health; do
  [[ "$(yq -r ".config.endpoints[] | select(.name == \"$native_endpoint\") | .conditions | join(\"|\")" "$source_values")" == '[STATUS] == 200' ]] || {
    echo "Production $native_endpoint must use only authenticated HTTP 200 success." >&2
    exit 1
  }
done

# The production source must pass before mutation cases begin. The rendered assertion
# independently proves that both active n8n monitoring signals reach the Helm release.
assert_production_activated_render
expect_pass 'production Gatus source'

values="$tree_root/kubernetes/apps/monitoring/gatus/app/values.yaml"
secret="$tree_root/kubernetes/apps/monitoring/gatus/app/media-integration-api-keys.sops.yaml"
canary_secret="$tree_root/kubernetes/apps/monitoring/gatus/app/n8n-canary.sops.yaml"

reset_tree
expect_fixture_pass 'selected synthetic n8n canary Secret'

reset_tree
yq -i '.spec.valuesFrom[0].valuesKey = "n8n-canary-activation.values.yaml"' \
  "$tree_root/kubernetes/apps/monitoring/gatus/app/helmrelease.yaml"
expect_fail 'active HelmRelease selects staged n8n canary values directly' \
  'Active Gatus Helm values source:'

reset_tree
activate_webhook_e2e_values
expect_fixture_pass 'complete activated n8n canary values'

reset_tree
activate_webhook_e2e_values
yq -i '(select(.metadata.name == "public-webhook-route") | .spec.suspend) = true' \
  "$tree_root/kubernetes/apps/networking/public-webhook-gateway/ks.yaml"
expect_fail 'activated n8n canary with suspended public route' \
  'Activated Gatus public webhook route Kustomization state:'

reset_tree
yq -i 'del(.env.GATUS_N8N_CANARY_TOKEN)' \
  "$tree_root/kubernetes/apps/monitoring/gatus/app/n8n-canary-activation.values.yaml"
expect_fail 'staged n8n canary missing Secret reference' \
  'Staged Gatus n8n webhook E2E environment contract:'

reset_tree
yq -i 'del(.config.endpoints[] | select(.name == "n8n-webhook-e2e"))' \
  "$tree_root/kubernetes/apps/monitoring/gatus/app/n8n-canary-activation.values.yaml"
expect_fail 'staged n8n canary missing endpoint' \
  'Staged Gatus n8n webhook E2E endpoint contract:'

reset_tree
rm -f -- "$canary_secret"
expect_fail 'absent selected n8n canary Secret' 'Missing selected Gatus SOPS Secret:'

reset_tree
yq -i '.stringData.token = "malformed-ciphertext"' "$canary_secret"
expect_fail 'malformed selected n8n canary ciphertext' \
  'Selected Gatus SOPS Secret is not encrypted:'

reset_tree
yq -i '.stringData.token = "ENC[AES256_GCM,data:c3ludGhldGlj,iv:c3ludGhldGlj]"' \
  "$canary_secret"
expect_fail 'incomplete selected n8n canary SOPS value envelope' \
  'Selected Gatus SOPS Secret is not encrypted:'

reset_tree
activate_webhook_e2e_values
yq -i 'del(.config.endpoints[] | select(.name == "n8n-webhook-e2e") | .headers."X-Platform-Canary")' \
  "$values"
expect_fail 'n8n canary missing authentication header' \
  'Activated Gatus n8n webhook E2E endpoint contract:'

reset_tree
activate_webhook_e2e_values
yq -i '(.config.endpoints[] | select(.name == "n8n-webhook-e2e") | .url) = "https://*.lab.supermorphic.com/webhook/platform-canary"' \
  "$values"
expect_fail 'n8n webhook E2E wildcard URL' \
  'Activated Gatus n8n webhook E2E endpoint contract:'

reset_tree
activate_webhook_e2e_values
yq -i '(.config.endpoints[] | select(.name == "n8n-webhook-e2e") | .interval) = "1m"' \
  "$values"
expect_fail 'n8n canary one-minute interval' \
  'Activated Gatus n8n webhook E2E endpoint contract:'

reset_tree
yq -i '(.config.endpoints[] | select(.name == "n8n-readiness") | .url) = "https://n8n.lab.supermorphic.com/healthz"' \
  "$values"
expect_fail 'n8n readiness using liveness endpoint' \
  'Gatus n8n readiness endpoint contract:'

reset_tree
yq -i '(.config.endpoints[] | select(.name == "n8n-readiness") | .conditions) = ["[STATUS] == 200"]' \
  "$values"
expect_fail 'n8n readiness missing body status condition' \
  'Gatus n8n readiness endpoint contract:'

reset_tree
yq -i 'del(.config.endpoints[] | select(.name == "prowlarr-native-health"))' "$values"
expect_fail 'missing native-health endpoint' 'Media Integration endpoint names:'

reset_tree
yq -i '(.config.endpoints[] | select(.name == "prowlarr-native-health") | .conditions) += ["len([BODY]) == 0"]' "$values"
expect_fail 'body-dependent native-health condition' \
  'Media Integration endpoint prowlarr-native-health conditions:'

reset_tree
yq -i '(.config.endpoints[] | select(.name == "prowlarr-native-health") | .method) = "POST"' "$values"
expect_fail 'non-GET media-integration endpoint' \
  'Media Integration endpoint prowlarr-native-health method:'

reset_tree
# shellcheck disable=SC2016 # The placeholder is literal Gatus configuration, not shell input.
yq -i '.config.endpoints += [{"name":"synthetic-extra-media-integration","group":"Media Integration","url":"https://synthetic.invalid/","method":"GET","interval":"1m","headers":{"X-Api-Key":"${GATUS_PROWLARR_API_KEY}"},"conditions":["[STATUS] == 200"],"ui":{"hide-errors":true}}]' "$values"
expect_fail 'extra media-integration endpoint' 'Media Integration endpoint names:'

reset_tree
# shellcheck disable=SC2016 # The placeholder is literal Gatus configuration, not shell input.
yq -i '(.config.endpoints[] | select(.name == "prowlarr-native-health") | .headers."X-Api-Key") = "${GATUS_SONARR_API_KEY}"' "$values"
expect_fail 'wrong media-integration API-key header' \
  'Media Integration endpoint prowlarr-native-health API-key header:'

reset_tree
yq -i '.env.GATUS_PROWLARR_API_KEY.valueFrom.secretKeyRef.key = "sonarr_api_key"' "$values"
expect_fail 'wrong rendered media API-key Secret key reference' \
  'Rendered Gatus GATUS_PROWLARR_API_KEY Secret key:'

reset_tree
yq -i 'del(.stringData.prowlarr_api_key)' "$secret"
expect_fail 'missing media API-key Secret data key' 'Gatus media API-key Secret stringData keys:'

echo 'Gatus source validator tests passed: status-only Servarr contract and mutation guards.'
