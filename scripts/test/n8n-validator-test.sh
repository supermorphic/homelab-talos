#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="$repo_root/scripts/validate/n8n.sh"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/n8n-validator-test.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT

tree_root="$test_dir/tree"

reset_tree() {
  rm -rf -- "$tree_root"
  mkdir -p "$tree_root/kubernetes/apps"
  cp "$repo_root/kubernetes/apps/kustomization.yaml" \
    "$tree_root/kubernetes/apps/kustomization.yaml"
  cp -R "$repo_root/kubernetes/apps/automation" \
    "$tree_root/kubernetes/apps/automation"
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
  local output status
  set +e
  output="$(run_validator)"
  status="$?"
  set -e
  [[ "$status" -eq 1 ]] || {
    echo "public Gateway access: expected exit 1, got $status." >&2
    echo "$output" >&2
    exit 1
  }
  rg -Fq 'n8n automation namespace Gateway access must be internal.' <<<"$output" || {
    echo 'public Gateway access: expected internal-access validation message.' >&2
    echo "$output" >&2
    exit 1
  }
}

reset_tree
expect_pass

reset_tree
yq -i '.metadata.labels."gateway.supermorphic.com/access" = "public"' \
  "$tree_root/kubernetes/apps/automation/namespace/app/namespace.yaml"
expect_fail

echo 'n8n validator positive and internal-Gateway negative cases passed.'
