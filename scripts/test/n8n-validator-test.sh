#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="$repo_root/scripts/validate/n8n.sh"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/n8n-validator-test.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT

tree_root="$test_dir/tree"

reset_tree() {
  rm -rf -- "$tree_root"
  mkdir -p "$tree_root/kubernetes/apps/networking"
  cp "$repo_root/kubernetes/apps/kustomization.yaml" \
    "$tree_root/kubernetes/apps/kustomization.yaml"
  cp -R "$repo_root/kubernetes/apps/automation" \
    "$tree_root/kubernetes/apps/automation"
  cp "$repo_root/kubernetes/apps/networking/kustomization.yaml" \
    "$tree_root/kubernetes/apps/networking/kustomization.yaml"
  cp -R "$repo_root/kubernetes/apps/networking/external-dns" \
    "$tree_root/kubernetes/apps/networking/external-dns"
  if [[ -d "$repo_root/kubernetes/apps/networking/public-webhook-gateway" ]]; then
    cp -R "$repo_root/kubernetes/apps/networking/public-webhook-gateway" \
      "$tree_root/kubernetes/apps/networking/public-webhook-gateway"
  fi
}

run_validator() { (cd "$tree_root" && "$validator") 2>&1; }

expect_pass() {
  local output status
  set +e
  output="$(run_validator)"
  status="$?"
  set -e
  [[ "$status" -eq 0 ]] || {
    echo 'production n8n source: expected validation to pass.' >&2
    echo "$output" >&2
    exit 1
  }
}

expect_fail() {
  local description="$1"
  local expected_message="$2"
  local output status
  set +e
  output="$(run_validator)"
  status="$?"
  set -e
  [[ "$status" -eq 1 ]] || {
    echo "$description: expected exit 1, got $status." >&2
    echo "$output" >&2
    exit 1
  }
  rg -Fq "$expected_message" <<<"$output" || {
    echo "$description: expected validation message." >&2
    echo "$output" >&2
    exit 1
  }
}

reset_tree
expect_pass

reset_tree
yq -i '.metadata.labels."gateway.supermorphic.com/access" = "public"' \
  "$tree_root/kubernetes/apps/automation/namespace/app/namespace.yaml"
expect_fail 'public Gateway access' 'n8n automation namespace Gateway access must be internal.'

reset_tree
rm "$tree_root/kubernetes/apps/networking/public-webhook-gateway/route/httproute.yaml"
expect_fail 'missing public route' 'Missing n8n platform source: kubernetes/apps/networking/public-webhook-gateway/route/httproute.yaml'

reset_tree
yq -i '.spec.rules[0].matches[0].path.type = "PathPrefix"' \
  "$tree_root/kubernetes/apps/networking/public-webhook-gateway/route/httproute.yaml"
expect_fail 'prefix public route' 'The public webhook route must be the exact platform-canary path to automation/n8n:5678.'

reset_tree
yq -i '.spec.dnsNames += ["*.lab.supermorphic.com"]' \
  "$tree_root/kubernetes/apps/networking/public-webhook-gateway/app/certificate.yaml"
expect_fail 'wildcard public certificate' 'The public Certificate must contain only hooks.lab.supermorphic.com.'

reset_tree
yq -i '.spec.listeners[0].allowedRoutes.namespaces = {"from": "Selector", "selector": {"matchLabels": {"gateway.supermorphic.com/access": "public"}}}' \
  "$tree_root/kubernetes/apps/networking/public-webhook-gateway/app/gateway.yaml"
expect_fail 'selector public route admission' 'The public listener must use its exact hostname and Same-namespace route admission.'

echo 'n8n validator public-edge and internal-Gateway cases passed.'
