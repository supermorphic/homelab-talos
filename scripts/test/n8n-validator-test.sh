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
yq -i '(.spec.postRenderers[0].kustomize.patches[] |
  select(.target.kind == "Deployment") | .target.group) = "wrong.example.io"' \
  "$tree_root/kubernetes/apps/automation/n8n/app/helmrelease.yaml"
expect_fail 'wrong n8n post-render target group' \
  'The Helm post-renderer must expose the one main Deployment and Service as n8n.'

reset_tree
yq -i '(.spec.postRenderers[0].kustomize.patches[] |
  select(.target.kind == "Service") | .target.labelSelector) = "app.kubernetes.io/name=does-not-match"' \
  "$tree_root/kubernetes/apps/automation/n8n/app/helmrelease.yaml"
expect_fail 'non-matching n8n post-render selector' \
  'The Helm post-renderer must expose the one main Deployment and Service as n8n.'

reset_tree
yq -i '.spec.postRenderers[0].kustomize.images = [{
  "name": "does-not-exist",
  "newTag": "ignored"
}]' "$tree_root/kubernetes/apps/automation/n8n/app/helmrelease.yaml"
expect_fail 'additional n8n post-render image transform' \
  'The Helm post-renderer must expose the one main Deployment and Service as n8n.'

reset_tree
yq -i '.spec.postRenderers += [{"kustomize": {"patches": []}}]' \
  "$tree_root/kubernetes/apps/automation/n8n/app/helmrelease.yaml"
expect_fail 'additional n8n post-renderer' \
  'The Helm post-renderer must expose the one main Deployment and Service as n8n.'

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

reset_tree
yq -i 'with(select(.metadata.name == "n8n-postgresql");
  (.spec.ingress[] | select(.toPorts[].ports[].port == "9399") |
    .fromEndpoints[0].matchLabels) = {
      "k8s:io.kubernetes.pod.namespace": "monitoring"
    })' \
  "$tree_root/kubernetes/apps/automation/n8n-postgresql/app/ciliumnetworkpolicy.yaml"
expect_fail 'namespace-only Prometheus ingress' \
  'PostgreSQL metrics ingress must select only the pinned Prometheus workload identity.'

reset_tree
yq -i '.pdb.enabled = true' \
  "$tree_root/kubernetes/apps/automation/n8n/app/values.yaml"
expect_fail 'chart-generated disruption budget' \
  'The n8n chart must not render queue, Redis, worker, webhook-processor, autoscaling, disruption-budget, or Ingress behavior.'

reset_tree
yq -i 'del(.resources.main.limits.cpu)' \
  "$tree_root/kubernetes/apps/automation/n8n/app/values.yaml"
expect_fail 'inherited chart CPU limit' \
  'The n8n pod must use the exact resource envelope without Kubernetes API credentials.'

reset_tree
yq -i 'del(.taskRunners.authToken.existingSecret)' \
  "$tree_root/kubernetes/apps/automation/n8n/app/values.yaml"
expect_fail 'unused chart task-runner Secret' \
  'The n8n chart must not render queue, Redis, worker, webhook-processor, autoscaling, disruption-budget, or Ingress behavior.'

reset_tree
yq -i '.config.extraEnv += [{"name": "WEBHOOK_URL", "value": "https://hooks.lab.supermorphic.com/"}]' \
  "$tree_root/kubernetes/apps/automation/n8n/app/values.yaml"
expect_fail 'deprecated webhook URL variable' \
  'The n8n container must have each canonical URL once and no deprecated WEBHOOK_URL.'

reset_tree
yq -i 'del(.config.extraEnv[] | select(.name == "N8N_DIAGNOSTICS_ENABLED"))' \
  "$tree_root/kubernetes/apps/automation/n8n/app/values.yaml"
expect_fail 'missing telemetry disable' \
  'The n8n proxy, metrics, telemetry, and filesystem settings are incorrect.'

reset_tree
yq -i '.secretRefs.existingSecret = "other-runtime"' \
  "$tree_root/kubernetes/apps/automation/n8n/app/values.yaml"
expect_fail 'wrong n8n runtime Secret' \
  'The n8n container must consume only the exact runtime and database Secret keys.'

reset_tree
yq -i '.spec.to += [{"group": "", "kind": "Secret"}]' \
  "$tree_root/kubernetes/apps/automation/n8n/app/referencegrant.yaml"
expect_fail 'Secret ReferenceGrant access' \
  'The ReferenceGrant must admit only networking-public HTTPRoutes to Service n8n.'

reset_tree
yq -i 'del(.spec.egress[] | select(.toCIDRSet != null) | .toCIDRSet[0].except[] | select(. == "192.168.0.0/16"))' \
  "$tree_root/kubernetes/apps/automation/n8n/app/ciliumnetworkpolicy.yaml"
expect_fail 'private-network HTTPS egress' \
  'n8n egress must reach only DNS, PostgreSQL, and public IPv4 HTTPS.'

reset_tree
yq -i 'del(.spec.egress[] | select(.toCIDRSet != null) |
  .toCIDRSet[0].except[] | select(. == "192.88.99.0/24"))' \
  "$tree_root/kubernetes/apps/automation/n8n/app/ciliumnetworkpolicy.yaml"
expect_fail '6to4 relay anycast HTTPS egress' \
  'n8n egress must reach only DNS, PostgreSQL, and public IPv4 HTTPS.'

reset_tree
yq -i '(.spec.ingress[] |
  select(.fromEndpoints[]?.matchLabels."gateway.envoyproxy.io/owning-gateway-name" == "internal") |
  .fromEndpoints) += [{"matchLabels": {
    "k8s:io.kubernetes.pod.namespace": "automation",
    "app.kubernetes.io/name": "unauthorized-ingress"
  }}]' "$tree_root/kubernetes/apps/automation/n8n/app/ciliumnetworkpolicy.yaml"
expect_fail 'additional n8n ingress endpoint' \
  'n8n ingress must admit only both Envoy data planes, Prometheus, and kubelet probes.'

reset_tree
yq -i '(.spec.egress[] | select(.toPorts[].ports[].port == "5432") |
  .toEndpoints) += [{"matchLabels": {
    "k8s:io.kubernetes.pod.namespace": "automation",
    "app.kubernetes.io/name": "unauthorized-database"
  }}]' "$tree_root/kubernetes/apps/automation/n8n/app/ciliumnetworkpolicy.yaml"
expect_fail 'additional PostgreSQL-rule egress endpoint' \
  'n8n egress must reach only DNS, PostgreSQL, and public IPv4 HTTPS.'

reset_tree
yq -i '(.spec.ingress[].fromEndpoints[] | select(.matchLabels."app.kubernetes.io/name" == "prometheus") | .matchLabels) = {
  "k8s:io.kubernetes.pod.namespace": "monitoring"
}' "$tree_root/kubernetes/apps/automation/n8n/app/ciliumnetworkpolicy.yaml"
expect_fail 'namespace-only n8n metrics ingress' \
  'n8n ingress must admit only both Envoy data planes, Prometheus, and kubelet probes.'

echo 'n8n validator public-edge, rendered-runtime, routing, and containment cases passed.'
