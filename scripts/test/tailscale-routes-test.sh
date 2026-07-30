#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/tailscale-routes.sh

assert_routes() {
  local label="$1"
  local expected="$2"
  local fixture="$3"
  local actual

  actual="$(tailscale_connector_status_routes <<<"$fixture")" || {
    echo "$label: route normalization unexpectedly failed." >&2
    exit 1
  }
  [[ "$actual" == "$expected" ]] || {
    echo "$label: expected '$expected', got '$actual'." >&2
    exit 1
  }
}

assert_rejected() {
  local label="$1"
  local fixture="$2"

  if tailscale_connector_status_routes <<<"$fixture" >/dev/null 2>&1; then
    echo "$label: malformed status was accepted." >&2
    exit 1
  fi
}

assert_not_expected() {
  local label="$1"
  local fixture="$2"
  local actual

  actual="$(tailscale_connector_status_routes <<<"$fixture")" || return 0
  [[ "$actual" != "$expected" ]] || {
    echo "$label: malformed status normalized to the expected routes." >&2
    exit 1
  }
}

expected='192.168.90.2/32,192.168.90.30/32'

assert_routes exact "$expected" \
  '{"status":{"subnetRoutes":"192.168.90.2/32,192.168.90.30/32"}}'
assert_routes reordered "$expected" \
  '{"status":{"subnetRoutes":"192.168.90.30/32,192.168.90.2/32"}}'
assert_routes empty '' '{"status":{"subnetRoutes":""}}'
assert_routes missing '' '{"status":{}}'
assert_routes extra \
  '192.168.90.0/24,192.168.90.2/32,192.168.90.30/32' \
  '{"status":{"subnetRoutes":"192.168.90.30/32,192.168.90.0/24,192.168.90.2/32"}}'
assert_not_expected malformed-delimiter \
  '{"status":{"subnetRoutes":"192.168.90.2/32,,192.168.90.30/32"}}'
assert_rejected wrong-type \
  '{"status":{"subnetRoutes":["192.168.90.2/32","192.168.90.30/32"]}}'
assert_rejected invalid-json 'not-json'

echo 'Tailscale Connector status route parsing tests passed.'
