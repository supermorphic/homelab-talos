#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="$repo_root/scripts/validate/plex-ddns-drift.sh"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/plex-ddns-drift-validator-test.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT

tree_root="$test_dir/tree"
app="$tree_root/kubernetes/apps/monitoring/plex-ddns-drift/app"

reset_tree() {
  rm -rf -- "$tree_root"
  mkdir -p "$tree_root/kubernetes/apps/monitoring" "$tree_root/scripts/lib" \
    "$tree_root/kubernetes/apps/media/plex/app"
  cp -R "$repo_root/kubernetes/apps/monitoring/plex-ddns-drift" \
    "$tree_root/kubernetes/apps/monitoring/plex-ddns-drift"
  cp "$repo_root/kubernetes/apps/media/plex/app/ciliumnetworkpolicy.yaml" \
    "$tree_root/kubernetes/apps/media/plex/app/ciliumnetworkpolicy.yaml"
  cp "$repo_root/kubernetes/apps/monitoring/kustomization.yaml" \
    "$tree_root/kubernetes/apps/monitoring/kustomization.yaml"
  cp "$repo_root/scripts/lib/common.sh" "$tree_root/scripts/lib/common.sh"
}

run_validator() {
  (cd "$tree_root" && "$validator") 2>&1
}

expect_pass() {
  local description="$1"
  run_validator >/dev/null || {
    echo "$description: expected Plex DDNS drift validation to pass." >&2
    exit 1
  }
}

expect_fail() {
  local description="$1" expected_message="$2"
  local output status

  set +e
  output="$(run_validator)"
  status="$?"
  set -e

  [[ "$status" -eq 1 ]] || {
    echo "$description: expected exit 1, got $status." >&2
    exit 1
  }
  rg -Fq "$expected_message" <<<"$output" || {
    echo "$description: missing expected failure message: $expected_message" >&2
    echo "$output" >&2
    exit 1
  }
}

reset_tree
expect_pass 'production Plex DDNS drift source'

reset_tree
yq -i '.generatorOptions.disableNameSuffixHash = true' "$app/kustomization.yaml"
expect_fail 'ConfigMap hashing disabled' 'ConfigMap name hashing must remain enabled'

reset_tree
yq -i '.spec.template.spec.containers[] |= select(.name == "server").args += ["--watch"]' "$app/deployment.yaml"
expect_fail 'metrics server arguments widened' 'Metrics server arguments must be exact'

reset_tree
yq -i '.spec.template.spec.securityContext.fsGroup = 0' "$app/deployment.yaml"
expect_fail 'pod group ownership weakened' 'Pod security context must be exact'

reset_tree
yq -i '.spec.template.spec.hostNetwork = true' "$app/deployment.yaml"
expect_fail 'pod joins the host network' 'Pod spec fields must be exact'

reset_tree
yq -i '(.spec.template.spec.volumes[] | select(.name == "tmp")) = {"name": "tmp", "hostPath": {"path": "/tmp"}}' "$app/deployment.yaml"
expect_fail 'tmp volume replaced by hostPath' 'Temporary volume must be emptyDir only'

reset_tree
yq -i '.spec.ports += [{"name": "admin", "port": 2019, "protocol": "TCP", "targetPort": 2019}]' "$app/service.yaml"
expect_fail 'Service exposes an extra port' 'Service port must be exact'

reset_tree
yq -i '.spec.ingress[0].fromEndpoints += [{"matchLabels": {"k8s:io.kubernetes.pod.namespace": "default"}}]' "$app/ciliumnetworkpolicy.yaml"
expect_fail 'Cilium ingress gains another source' 'Cilium ingress must have exactly one source selector'

reset_tree
yq -i '.spec.egress += [{"toEntities": ["cluster"]}]' "$app/ciliumnetworkpolicy.yaml"
expect_fail 'Cilium policy gains another egress rule' 'Cilium policy must have exactly three egress rules'

reset_tree
yq -i '(.spec.egress[] | select(has("toCIDR"))).toPorts += [{"ports": [{"port": "22", "protocol": "TCP"}]}]' "$app/ciliumnetworkpolicy.yaml"
expect_fail 'resolver rule gains another port block' 'Cilium resolver port rule must be exact'

reset_tree
yq -i '(.spec.egress[] | select(has("toCIDRSet"))).toPorts[0].ports += [{"port": "80", "protocol": "TCP"}]' "$app/ciliumnetworkpolicy.yaml"
expect_fail 'HTTPS rule gains another port' 'Cilium HTTPS port list must be exact'

reset_tree
yq -i '(.spec.egress[] | select(has("toCIDRSet"))) = {"toEntities": ["world"], "toPorts": [{"ports": [{"port": "443", "protocol": "TCP"}]}]}' \
  "$app/ciliumnetworkpolicy.yaml"
expect_fail 'HTTPS rule widened back to the world entity' 'Cilium egress must not use a broad entity selector'

reset_tree
yq -i '(.spec.egress[] | select(has("toCIDRSet"))).toCIDRSet[0].except -= ["192.168.0.0/16"]' "$app/ciliumnetworkpolicy.yaml"
expect_fail 'HTTPS rule reaches the LAN' 'Cilium HTTPS exclusions must match the deployed Plex egress bound'

reset_tree
printf "    printf '# TYPE plex_ddns_probe_seconds gauge\\\\n'\n" >>"$app/check.sh"
expect_fail 'collector exports a metric no alert watches' \
  'Plex DDNS metrics are exported but never alerted on: plex_ddns_probe_seconds'

reset_tree
yq -i '.spec.template.spec.containers[] |= (select(.name == "server").securityContext.capabilities.add = ["NET_BIND_SERVICE"])' \
  "$app/deployment.yaml"
expect_fail 'metrics server regains a capability' 'Metrics server capabilities must be exact'

reset_tree
printf '\n:2019 {\n\trespond "ok" 200\n}\n' >>"$app/Caddyfile"
expect_fail 'Caddy gains an extra route' 'Caddy metrics route must be exact'

echo 'Plex DDNS drift validator mutation tests passed.'
