#!/usr/bin/env bash
set -euo pipefail

fixture='tests/fixtures/validation/media'
temp_dir="$(mktemp -d /tmp/homelab-talos-media-policy-test.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

scripts/validate/media-policy.sh "$fixture" >/dev/null

expect_policy_failure() {
  local description="$1"
  local expected_message="$2"
  local expression="$3"
  local relative_file="$4"
  local case_root="$temp_dir/${description// /-}"
  local output

  mkdir -p "$case_root"
  cp -R "$fixture/." "$case_root"
  yq -i "$expression" "$case_root/$relative_file"

  if output="$(scripts/validate/media-policy.sh "$case_root" 2>&1)"; then
    printf 'ERROR: expected media policy failure: %s\n' "$description" >&2
    return 1
  fi
  if [[ "$output" != *"$expected_message"* ]]; then
    printf 'ERROR: wrong media policy failure for %s\nexpected output containing: %s\nactual:\n%s\n' \
      "$description" "$expected_message" "$output" >&2
    return 1
  fi
}

expect_policy_failure \
  'mutable image tag' \
  'Mutable version or image tag is forbidden' \
  '.controllers.qbittorrent.containers.app.image.tag = "latest"' \
  'qbittorrent/app/values.yaml'
expect_policy_failure \
  'RollingUpdate with RWO config' \
  'YAML value mismatch' \
  '.controllers.qbittorrent.strategy = "RollingUpdate"' \
  'qbittorrent/app/values.yaml'
expect_policy_failure \
  'unauthorized NET_ADMIN' \
  'NET_ADMIN is forbidden outside the qBittorrent Gluetun sidecar' \
  '.controllers.qbittorrent.containers.app.securityContext.capabilities.add = ["NET_ADMIN"]' \
  'qbittorrent/app/values.yaml'
expect_policy_failure \
  'missing Flux dependency' \
  'Required Flux dependency is missing' \
  'del(.spec.dependsOn[] | select(.name == "internal-gateway"))' \
  'qbittorrent/ks.yaml'
expect_policy_failure \
  'public Gateway exposure' \
  'routes use only the internal Gateway' \
  '.spec.parentRefs[0].name = "public"' \
  'qbittorrent/app/httproute.yaml'

echo 'Media policy negative-fixture tests passed.'
