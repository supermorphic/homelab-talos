#!/usr/bin/env bash
# Negative coverage for Loki limits and persistent-volume labels in monitoring validation.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="$repo_root/scripts/validate/monitoring.sh"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/monitoring-loki-validator-test.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT

tree_root="$test_dir/tree"
values="$tree_root/kubernetes/apps/monitoring/loki/app/values.yaml"
shim_dir="$test_dir/bin"
real_helm="$(command -v helm)"

reset_tree() {
  rm -rf -- "$tree_root"
  mkdir -p "$tree_root"
  cp "$repo_root/.sops.yaml" "$tree_root/.sops.yaml"
  cp -R "$repo_root/kubernetes" "$tree_root/kubernetes"
  cp -R "$repo_root/scripts" "$tree_root/scripts"
  cp -R "$repo_root/tests" "$tree_root/tests"
}

run_validator() {
  (
    cd "$tree_root"
    PATH="$shim_dir:$PATH" REAL_HELM="$real_helm" "$validator"
  ) 2>&1
}

expect_pass() {
  local description="$1" output status
  set +e
  output="$(run_validator)"
  status="$?"
  set -e
  [[ "$status" -eq 0 ]] || {
    echo "$description: expected exit 0, got $status." >&2
    echo "$output" >&2
    exit 1
  }
}

expect_fail() {
  local description="$1" expected_message="$2" output status
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
    echo "$description: missing expected failure message: $expected_message" >&2
    echo "$output" >&2
    exit 1
  }
}

mkdir -p "$shim_dir"
cat >"$shim_dir/helm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

render_file="$(mktemp "${TMPDIR:-/tmp}/monitoring-loki-helm-shim.XXXXXX")"
trap 'rm -f -- "$render_file"' EXIT
"$REAL_HELM" "$@" >"$render_file"

case "${HELM_RENDER_MUTATION:-}" in
  discover-service-name)
    yq ea '
      (select(.kind == "ConfigMap" and .metadata.name == "loki") |
        .data."config.yaml") |= (
          from_yaml |
          .limits_config.discover_service_name = ["service"] |
          to_yaml
      )
    ' "$render_file"
    ;;
  default-recurring-group)
    yq ea '
      (select(.kind == "StatefulSet" and .metadata.name == "loki") |
        .spec.volumeClaimTemplates[] |
          select(.metadata.name == "storage") |
          .metadata.labels."recurring-job-group.longhorn.io/default") = "enabled"
    ' "$render_file"
    ;;
  *)
    command cat "$render_file"
    ;;
esac
EOF
chmod +x "$shim_dir/helm"

reset_tree
expect_pass 'production monitoring source'

echo '1. Enabling automatic service-name discovery in source values is rejected.'
reset_tree
yq -i '.loki.limits_config.discover_service_name = ["service"]' "$values"
expect_fail 'source service-name discovery enabled' \
  'Refusing: Loki source must disable automatic service-name discovery.'

echo '2. Enabling automatic service-name discovery only in the pinned render is rejected.'
reset_tree
HELM_RENDER_MUTATION=discover-service-name \
  expect_fail 'rendered service-name discovery enabled' \
    'Refusing: rendered Loki must disable automatic service-name discovery.'

echo '3. Assigning the default recurring-job group in source values is rejected.'
reset_tree
yq -i '.singleBinary.persistence.labels."recurring-job-group.longhorn.io/default" = "enabled"' "$values"
expect_fail 'source default recurring-job group enabled' \
  'Refusing: Loki source PVC labels must contain only source and filesystem-trim assignments.'

echo '4. Assigning the default recurring-job group only in the pinned render is rejected.'
reset_tree
HELM_RENDER_MUTATION=default-recurring-group \
  expect_fail 'rendered default recurring-job group enabled' \
    'Refusing: rendered Loki PVC labels must contain only source and filesystem-trim assignments.'

echo 'Loki monitoring validator mutation tests passed.'
