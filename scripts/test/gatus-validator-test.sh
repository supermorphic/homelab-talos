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

tree_root="$test_dir/tree"

reset_tree() {
  rm -rf -- "$tree_root"
  mkdir -p "$tree_root/kubernetes/apps/monitoring" \
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
}

run_validator() {
  (cd "$tree_root" && "$validator") 2>&1
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

# The production source must pass before mutation cases begin. During RED this is the
# intentional failure: the operator-managed Secret and the six endpoints are absent.
expect_pass 'production Gatus source'

values="$tree_root/kubernetes/apps/monitoring/gatus/app/values.yaml"
secret="$tree_root/kubernetes/apps/monitoring/gatus/app/media-integration-api-keys.sops.yaml"

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
