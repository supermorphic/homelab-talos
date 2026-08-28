#!/usr/bin/env bash
# Exercise the monitoring alerts validator against staged and activated n8n source trees.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="$repo_root/scripts/validate/alerts.sh"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-monitoring-alerts-validator-test.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT
tree_root="$test_dir/tree"

reset_tree() {
  rm -rf -- "$tree_root"
  mkdir -p "$tree_root/kubernetes/apps/monitoring" \
    "$tree_root/kubernetes/apps/automation/n8n" \
    "$tree_root/kubernetes/apps/automation/n8n-postgresql" \
    "$tree_root/kubernetes/apps/networking/public-webhook-gateway" \
    "$tree_root/kubernetes/apps/monitoring/gatus/app" \
    "$tree_root/tests/prometheus"
  cp -R "$repo_root/kubernetes/apps/monitoring/alerts" \
    "$tree_root/kubernetes/apps/monitoring/alerts"
  cp "$repo_root/kubernetes/apps/monitoring/kustomization.yaml" \
    "$tree_root/kubernetes/apps/monitoring/kustomization.yaml"
  cp "$repo_root/kubernetes/apps/automation/n8n/ks.yaml" \
    "$tree_root/kubernetes/apps/automation/n8n/ks.yaml"
  cp "$repo_root/kubernetes/apps/automation/n8n-postgresql/ks.yaml" \
    "$tree_root/kubernetes/apps/automation/n8n-postgresql/ks.yaml"
  cp "$repo_root/kubernetes/apps/networking/public-webhook-gateway/ks.yaml" \
    "$tree_root/kubernetes/apps/networking/public-webhook-gateway/ks.yaml"
  cp "$repo_root/kubernetes/apps/monitoring/gatus/app/kustomization.yaml" \
    "$tree_root/kubernetes/apps/monitoring/gatus/app/kustomization.yaml"
  cp "$repo_root/kubernetes/apps/monitoring/gatus/app/values.yaml" \
    "$tree_root/kubernetes/apps/monitoring/gatus/app/values.yaml"
  cp "$repo_root/kubernetes/apps/monitoring/gatus/app/n8n-canary-activation.values.yaml" \
    "$tree_root/kubernetes/apps/monitoring/gatus/app/n8n-canary-activation.values.yaml"
  cp "$repo_root/tests/prometheus/monitoring-alerts_test.yaml" \
    "$tree_root/tests/prometheus/monitoring-alerts_test.yaml"
  # Selection cases isolate the source validator. The two focused Flux-independence
  # cases run through the normal Prometheus validation command in their own TDD cycle.
  yq -i 'del(.tests[] | select(
    .name == "selected availability rules fire for zero sources despite failed Flux reconciliation" or
    .name == "selected availability rules fire when Flux and source series are fully absent"
  ))' "$tree_root/tests/prometheus/monitoring-alerts_test.yaml"
}

run_validator() {
  (cd "$tree_root" && "$validator" monitoring) 2>&1
}

expect_pass() {
  local description="$1" output
  output="$(run_validator)" || {
    echo "$description: expected monitoring alerts validation to pass." >&2
    echo "$output" >&2
    exit 1
  }
}

expect_fail() {
  local description="$1" expected_message="$2" output exit_code
  set +e
  output="$(run_validator)"
  exit_code="$?"
  set -e
  [[ "$exit_code" -eq 1 ]] || {
    echo "$description: expected exit 1, got $exit_code." >&2
    echo "$output" >&2
    exit 1
  }
  rg -Fq -- "$expected_message" <<<"$output" || {
    echo "$description: missing expected failure message: $expected_message" >&2
    echo "$output" >&2
    exit 1
  }
}

set_alert_selection() {
  local selected="$1"
  local kustomization="$tree_root/kubernetes/apps/monitoring/alerts/app/kustomization.yaml"
  yq -i 'del(.resources[] | select(. == "./n8n.yaml" or . == "n8n.yaml"))' "$kustomization"
  [[ "$selected" != true ]] || yq -i '.resources += ["./n8n.yaml"]' "$kustomization"
}

activate_platform() {
  local values activation candidate
  values="$tree_root/kubernetes/apps/monitoring/gatus/app/values.yaml"
  activation="$tree_root/kubernetes/apps/monitoring/gatus/app/n8n-canary-activation.values.yaml"
  candidate="$test_dir/activated-values.yaml"
  # shellcheck disable=SC2016 # yq expands $item inside its expression.
  yq ea '. as $item ireduce ({}; . *+ $item)' "$values" "$activation" >"$candidate"
  mv -- "$candidate" "$values"
  yq -i '.resources += ["./n8n-canary.sops.yaml"]' \
    "$tree_root/kubernetes/apps/monitoring/gatus/app/kustomization.yaml"
  yq -i '.spec.suspend = false' "$tree_root/kubernetes/apps/automation/n8n/ks.yaml"
  yq -i '.spec.suspend = false' \
    "$tree_root/kubernetes/apps/automation/n8n-postgresql/ks.yaml"
  yq -i '(select(.metadata.name == "public-webhook-route") | .spec.suspend) = false' \
    "$tree_root/kubernetes/apps/networking/public-webhook-gateway/ks.yaml"
}

assert_rendered_rule_count() {
  local expected="$1" actual
  actual="$(
    kustomize build "$tree_root/kubernetes/apps/monitoring/alerts/app" |
      yq ea -r '[select(.kind == "PrometheusRule" and .metadata.namespace == "monitoring" and .metadata.name == "n8n")] | length' -
  )"
  [[ "$actual" == "$expected" ]] || {
    echo "Expected the active monitoring alerts render to contain $expected n8n rule, got $actual." >&2
    exit 1
  }
}

case_production() {
  reset_tree
  assert_rendered_rule_count 0
  expect_pass 'production pre-activation source'
}

case_unsafe_selection() {
  reset_tree
  set_alert_selection true
  expect_fail 'pre-activation n8n alert selection' \
    'Pre-activation n8n alerts must select no resource path resolving to n8n.yaml; found 1.'
}

case_unsafe_path() {
  local kustomization
  reset_tree
  set_alert_selection false
  kustomization="$tree_root/kubernetes/apps/monitoring/alerts/app/kustomization.yaml"
  yq -i '.resources += ["n8n.yaml"]' "$kustomization"
  expect_fail 'non-canonical n8n alert resource selection' \
    'Pre-activation n8n alerts must select no resource path resolving to n8n.yaml; found 1.'
}

case_parent_alias() {
  local kustomization
  reset_tree
  set_alert_selection false
  kustomization="$tree_root/kubernetes/apps/monitoring/alerts/app/kustomization.yaml"
  yq -i '.resources += ["../app/n8n.yaml"]' "$kustomization"
  expect_fail 'parent-directory alias selects staged n8n alert rule' \
    'Pre-activation n8n alerts must select no resource path resolving to n8n.yaml; found 1.'
}

case_complete_activation() {
  reset_tree
  activate_platform
  set_alert_selection true
  assert_rendered_rule_count 1
  expect_pass 'complete n8n platform activation'
}

case_missing_activation_selection() {
  reset_tree
  activate_platform
  set_alert_selection false
  expect_fail 'activated platform without n8n alert selection' \
    'Complete n8n platform activation must select exactly one resource path resolving to n8n.yaml; found 0.'
}

case_complete_alias_selection() {
  local kustomization
  reset_tree
  activate_platform
  set_alert_selection false
  kustomization="$tree_root/kubernetes/apps/monitoring/alerts/app/kustomization.yaml"
  yq -i '.resources += ["n8n.yaml"]' "$kustomization"
  expect_fail 'complete activation with non-canonical n8n alert path' \
    'Complete n8n platform activation must use the literal resource path ./n8n.yaml; got n8n.yaml.'
}

case_duplicate_canonical_selection() {
  local kustomization
  reset_tree
  activate_platform
  set_alert_selection true
  kustomization="$tree_root/kubernetes/apps/monitoring/alerts/app/kustomization.yaml"
  yq -i '.resources += ["./n8n.yaml"]' "$kustomization"
  expect_fail 'complete activation with duplicate canonical n8n alert entries' \
    'Complete n8n platform activation must select exactly one resource path resolving to n8n.yaml; found 2.'
}

case_canonical_alias_duplicate_selection() {
  local kustomization
  reset_tree
  activate_platform
  set_alert_selection true
  kustomization="$tree_root/kubernetes/apps/monitoring/alerts/app/kustomization.yaml"
  yq -i '.resources += ["../app/n8n.yaml"]' "$kustomization"
  expect_fail 'complete activation with canonical and aliased n8n alert entries' \
    'Complete n8n platform activation must select exactly one resource path resolving to n8n.yaml; found 2.'
}

case "${1:-all}" in
  production) case_production ;;
  unsafe-selection) case_unsafe_selection ;;
  unsafe-path) case_unsafe_path ;;
  parent-alias) case_parent_alias ;;
  complete-activation) case_complete_activation ;;
  missing-activation-selection) case_missing_activation_selection ;;
  complete-alias-selection) case_complete_alias_selection ;;
  duplicate-canonical-selection) case_duplicate_canonical_selection ;;
  canonical-alias-duplicate-selection) case_canonical_alias_duplicate_selection ;;
  all)
    case_production
    case_unsafe_selection
    case_unsafe_path
    case_parent_alias
    case_complete_activation
    case_missing_activation_selection
    case_complete_alias_selection
    case_duplicate_canonical_selection
    case_canonical_alias_duplicate_selection
    ;;
  *) echo "Unknown monitoring-alerts-validator test case: $1" >&2; exit 2 ;;
esac

echo 'Monitoring alerts staged n8n activation validator tests passed.'
