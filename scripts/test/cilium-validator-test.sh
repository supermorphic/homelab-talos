#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="$repo_root/scripts/validate/cilium.sh"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/cilium-validator-test.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT

tree_root="$test_dir/tree"
cilium="$tree_root/kubernetes/apps/kube-system/cilium"

reset_tree() {
  rm -rf -- "$tree_root"
  mkdir -p "$tree_root/kubernetes/apps/kube-system" "$tree_root/scripts/lib"
  cp -R "$repo_root/kubernetes/apps/kube-system/cilium" "$cilium"
  cp "$repo_root/scripts/lib/common.sh" "$tree_root/scripts/lib/common.sh"
}

run_validator() { (cd "$tree_root" && "$validator") 2>&1; }

expect_pass() {
  local description="$1"
  run_validator >/dev/null || {
    echo "$description: expected the production Cilium source to pass." >&2
    exit 1
  }
}

expect_fail() {
  local description="$1"
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
}

reset_tree
expect_pass 'production Cilium source'

echo '1. Removing the Hubble metrics block is rejected.'
reset_tree
yq -i 'del(.hubble.metrics)' "$cilium/app/values.yaml"
expect_fail 'hubble metrics removed'

echo '2. Dropping a metric set is rejected.'
reset_tree
yq -i '.hubble.metrics.enabled = ["flow:sourceContext=identity;destinationContext=pod","tcp:sourceContext=identity;destinationContext=pod"]' \
  "$cilium/app/values.yaml"
expect_fail 'metric set dropped'

echo '3. sourceContext=ip is rejected.'
reset_tree
yq -i '.hubble.metrics.enabled[0] = "flow:sourceContext=ip;destinationContext=pod"' "$cilium/app/values.yaml"
expect_fail 'unbounded source cardinality'

echo '4. A different destinationContext is rejected.'
reset_tree
yq -i '.hubble.metrics.enabled[1] = "tcp:sourceContext=identity;destinationContext=identity"' "$cilium/app/values.yaml"
expect_fail 'destination context drifted'

echo '5. Declaring a ServiceMonitor in the values is rejected.'
reset_tree
yq -i '.hubble.metrics.serviceMonitor.enabled = true' "$cilium/app/values.yaml"
expect_fail 'chart-rendered ServiceMonitor would break bootstrap'

echo '6. Removing the monitoring ServiceMonitor is rejected.'
reset_tree
rm -f "$cilium/monitoring/servicemonitor.yaml"
expect_fail 'servicemonitor source removed'

echo '7. Dropping the kube-prometheus-stack dependency is rejected.'
reset_tree
yq -i 'select(.metadata.name == "cilium-monitoring") |= del(.spec.dependsOn)' "$cilium/ks.yaml"
expect_fail 'monitoring no longer waits for the Prometheus CRDs'

echo '8. A ServiceMonitor port that the Service does not expose is rejected.'
reset_tree
yq -i '.spec.endpoints[0].port = "metrics"' "$cilium/monitoring/servicemonitor.yaml"
expect_fail 'servicemonitor port does not match the rendered Service'

echo '9. A non-ip, non-identity sourceContext is rejected.'
reset_tree
yq -i '.hubble.metrics.enabled[2] = "drop:sourceContext=namespace;destinationContext=pod"' "$cilium/app/values.yaml"
expect_fail 'source context drifted off identity without tripping the ip refusal'

echo '10. Renaming a metric set (drop,flow,tcp no longer intact) is rejected.'
reset_tree
yq -i '.hubble.metrics.enabled[2] = "http:sourceContext=identity;destinationContext=pod"' "$cilium/app/values.yaml"
expect_fail 'metric set name drifted while list length and context stayed valid'

echo 'Cilium validator mutation tests passed.'
