#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
require_bash

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-talos-common-test.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

printf '%s\n' 'allowed-value' >"$temp_dir/allowed.txt"
printf '%s\n' 'allowed-value' 'FORBIDDEN_VALUE' >"$temp_dir/forbidden.txt"

assert_command_finds_nothing \
  'allowed fixture unexpectedly contained the forbidden value' \
  rg -q 'FORBIDDEN_VALUE' "$temp_dir/allowed.txt"

forbidden_status=0
assert_command_finds_nothing \
  'negative fixture correctly detected' \
  rg -q 'FORBIDDEN_VALUE' "$temp_dir/forbidden.txt" 2>/dev/null ||
  forbidden_status="$?"
[[ "$forbidden_status" -eq 1 ]] || {
  echo "Forbidden fixture returned $forbidden_status instead of assertion status 1." >&2
  exit 1
}

execution_error_status=0
assert_command_finds_nothing \
  'execution error must not be treated as absence' \
  rg -q 'FORBIDDEN_VALUE' "$temp_dir/missing.txt" 2>/dev/null ||
  execution_error_status="$?"
[[ "$execution_error_status" -gt 1 ]] || {
  echo "Execution error was misclassified as absence (status $execution_error_status)." >&2
  exit 1
}

assert_empty '' 'empty fixture unexpectedly failed'
if assert_empty 'forbidden-resource' 'negative fixture correctly detected' 2>/dev/null; then
  echo 'assert_empty accepted a forbidden resource.' >&2
  exit 1
fi

expect_rejected_match() {
  local name="$1" pattern="$2" content="$3"
  local fixture="$temp_dir/${name}.txt"
  printf '%s\n' "$content" >"$fixture"
  if assert_command_finds_nothing \
    "$name negative fixture correctly detected" \
    rg -q -- "$pattern" "$fixture" 2>/dev/null; then
    echo "$name absence assertion accepted its forbidden fixture." >&2
    exit 1
  fi
}

expect_rejected_value() {
  local name="$1" value="$2"
  if assert_empty "$value" "$name negative fixture correctly detected" 2>/dev/null; then
    echo "$name absence assertion accepted its forbidden fixture." >&2
    exit 1
  fi
}

# One negative fixture for each corrected source/live invariant. Some intentionally
# share a pattern because both the rendered and live forms must remain gated.
expect_rejected_match cilium-sys-module 'SYS_MODULE' 'SYS_MODULE'
expect_rejected_match pihole-private-key 'PRIVATE KEY' '-----BEGIN PRIVATE KEY-----'
expect_rejected_match metallb-rendered-frr '^  name: .*frr' '  name: metallb-frr'
expect_rejected_match pihole-rendered-tls-skip '--pihole-tls-skip-verify' '--pihole-tls-skip-verify'
expect_rejected_match homepage-combined-secret 'homepage-secrets' 'name: homepage-secrets'
expect_rejected_match gluetun-control-route 'gluetun-control' 'backendRef: qbittorrent-gluetun-control'
expect_rejected_value live-kube-proxy 'daemonset.apps/kube-proxy'
expect_rejected_value live-hubble-ui 'deployment.apps/hubble-ui'
expect_rejected_value live-cilium-envoy 'daemonset.apps/cilium-envoy'
expect_rejected_value live-frr 'daemonset.apps/frr-k8s-daemon'
expect_rejected_match pihole-live-tls-skip '--pihole-tls-skip-verify' '--pihole-tls-skip-verify'

echo 'Common assertion negative fixtures passed.'
