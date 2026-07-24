#!/usr/bin/env bash
set -euo pipefail

source scripts/validate/lib.sh

fixture='tests/fixtures/validation/assertions.yaml'
temp_dir="$(mktemp -d /tmp/homelab-talos-validator-test.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

expect_failure() {
  local description="$1"
  local expected_message="$2"
  shift 2
  local output

  if output="$("$@" 2>&1)"; then
    printf 'ERROR: expected failure: %s\n' "$description" >&2
    return 1
  fi
  if [[ "$output" != *"$expected_message"* ]]; then
    printf 'ERROR: wrong failure for %s\nexpected output containing: %s\nactual:\n%s\n' \
      "$description" "$expected_message" "$output" >&2
    return 1
  fi
}

require_value 'v1.2.3' 'test value'
assert_file "$fixture" 'assertion fixture'
assert_wired 'spec:' "$fixture"
assert_yaml_eq "$fixture" '.spec.url' 'oci://example.invalid/chart'
assert_yaml_values "$fixture" \
  '.spec.enabled' 'false' \
  '.spec.replicas' '0' \
  '.spec.strategy' 'Recreate'
assert_yaml "$fixture" '.spec.strategy == "Recreate"' 'Recreate strategy'
assert_yaml_set "$fixture" '.spec.replicas' 'zero is a valid set value'
assert_pinned_tag "$fixture" '.image.tag' 'fixture image'
assert_depends_on "$fixture" cilium media-storage

expect_failure 'empty required value' 'Required value is missing' \
  require_value '' 'empty fixture'
expect_failure 'missing file' 'Required file is missing' \
  assert_file "$temp_dir/missing.yaml"
expect_failure 'missing wiring' 'Kustomization entry is missing' \
  assert_wired 'missing:' "$fixture"
expect_failure 'wrong YAML value' 'YAML value mismatch' \
  assert_yaml_eq "$fixture" '.spec.strategy' 'RollingUpdate'
expect_failure 'missing YAML value' 'Required value is missing' \
  assert_yaml_set "$fixture" '.spec.missing' 'missing field'
expect_failure 'null YAML value' 'Required value is missing' \
  assert_yaml_set "$fixture" '.spec.nullValue' 'null field'
expect_failure 'false YAML policy' 'YAML assertion failed' \
  assert_yaml "$fixture" '.spec.strategy == "RollingUpdate"' 'wrong strategy'
expect_failure 'mutable image tag' 'Mutable version or image tag is forbidden' \
  assert_pinned_tag "$fixture" '.mutableImage.tag' 'mutable fixture image'
expect_failure 'missing dependency' 'Required Flux dependency is missing' \
  assert_depends_on "$fixture" internal-gateway
expect_failure 'odd query/value argument count' \
  'assert_yaml_values requires query/expected pairs' \
  assert_yaml_values "$fixture" '.spec.url'

printf 'spec: [unterminated\n' >"$temp_dir/malformed.yaml"
expect_failure 'malformed YAML' 'Could not evaluate YAML query' \
  assert_yaml_eq "$temp_dir/malformed.yaml" '.spec.url' 'anything'

echo 'Validation assertion library tests passed.'
