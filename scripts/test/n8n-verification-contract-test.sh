#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/n8n-verification.sh
source "$repo_root/scripts/lib/n8n-verification.sh"

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/n8n-verification-contract-test.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

expect_true() {
  local description="$1"
  shift
  "$@" || {
    echo "$description: expected acceptance." >&2
    exit 1
  }
}

expect_false() {
  local description="$1"
  shift
  if "$@"; then
    echo "$description: expected rejection." >&2
    exit 1
  fi
}

chainsaw_assert_file() {
  local resource="$1" assertion="$2"
  chainsaw assert --resource "$resource" "$assertion" >/dev/null 2>&1
}

cat >"$temp_dir/kustomization.json" <<'EOF'
{
  "metadata": {"generation": 7},
  "spec": {"suspend": false},
  "status": {
    "observedGeneration": 7,
    "conditions": [{"type": "Ready", "status": "True", "observedGeneration": 7}]
  }
}
EOF
expect_true 'current Flux resource' n8n_flux_resource_current_ready \
  "$temp_dir/kustomization.json"

yq -p=json -o=json -i '.status.observedGeneration = 6' "$temp_dir/kustomization.json"
expect_false 'stale Flux top-level observation' n8n_flux_resource_current_ready \
  "$temp_dir/kustomization.json"
yq -p=json -o=json -i '.status.observedGeneration = 7 | .status.conditions[0].observedGeneration = 6' \
  "$temp_dir/kustomization.json"
expect_false 'stale Flux Ready condition' n8n_flux_resource_current_ready \
  "$temp_dir/kustomization.json"
yq -p=json -o=json -i '.status.conditions[0].observedGeneration = 7 | .spec.suspend = true' \
  "$temp_dir/kustomization.json"
expect_false 'suspended Flux resource' n8n_flux_resource_current_ready \
  "$temp_dir/kustomization.json"
yq -p=json -o=json -i '.spec.suspend = false | .status.conditions += [{
  "type":"Ready", "status":"False", "observedGeneration":6
}]' "$temp_dir/kustomization.json"
expect_false 'duplicate retained Flux Ready condition' n8n_flux_resource_current_ready \
  "$temp_dir/kustomization.json"

cat >"$temp_dir/chainsaw-current-ready.yaml" <<'EOF'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: n8n
  namespace: flux-system
([metadata.generation] == status.conditions[?type == 'Ready'].observedGeneration): true
EOF
cat >"$temp_dir/chainsaw-kustomization.json" <<'EOF'
{
  "apiVersion": "kustomize.toolkit.fluxcd.io/v1",
  "kind": "Kustomization",
  "metadata": {"name": "n8n", "namespace": "flux-system", "generation": 7},
  "status": {
    "observedGeneration": 7,
    "conditions": [{"type": "Ready", "status": "True", "observedGeneration": 7}]
  }
}
EOF
expect_true 'Chainsaw current Ready expression' chainsaw_assert_file \
  "$temp_dir/chainsaw-kustomization.json" "$temp_dir/chainsaw-current-ready.yaml"
yq -p=json -o=json -i '.status.conditions[0].observedGeneration = 6' \
  "$temp_dir/chainsaw-kustomization.json"
expect_false 'Chainsaw stale retained Ready expression' chainsaw_assert_file \
  "$temp_dir/chainsaw-kustomization.json" "$temp_dir/chainsaw-current-ready.yaml"

cat >"$temp_dir/deployment.json" <<'EOF'
{
  "metadata": {"generation": 8},
  "spec": {"replicas": 1},
  "status": {
    "observedGeneration": 8,
    "replicas": 1,
    "updatedReplicas": 1,
    "readyReplicas": 1,
    "availableReplicas": 1,
    "unavailableReplicas": 0
  }
}
EOF
expect_true 'current Deployment rollout' n8n_deployment_current_ready \
  "$temp_dir/deployment.json"
yq -p=json -o=json -i '.status.observedGeneration = 7' "$temp_dir/deployment.json"
expect_false 'stale Deployment rollout' n8n_deployment_current_ready \
  "$temp_dir/deployment.json"

cat >"$temp_dir/statefulset.json" <<'EOF'
{
  "metadata": {"generation": 9},
  "spec": {"replicas": 1},
  "status": {
    "observedGeneration": 9,
    "replicas": 1,
    "currentReplicas": 1,
    "updatedReplicas": 1,
    "readyReplicas": 1,
    "availableReplicas": 1,
    "currentRevision": "n8n-postgresql-abc",
    "updateRevision": "n8n-postgresql-abc"
  }
}
EOF
expect_true 'current StatefulSet rollout' n8n_statefulset_current_ready \
  "$temp_dir/statefulset.json"
yq -p=json -o=json -i '.status.updateRevision = "n8n-postgresql-new"' \
  "$temp_dir/statefulset.json"
expect_false 'stale StatefulSet revision' n8n_statefulset_current_ready \
  "$temp_dir/statefulset.json"

cat >"$temp_dir/targets.json" <<'EOF'
{
  "status": "success",
  "data": {
    "activeTargets": [
      {
        "scrapePool": "serviceMonitor/automation/n8n/0",
        "labels": {"namespace": "automation", "service": "n8n", "endpoint": "http", "job": "n8n"},
        "health": "up"
      },
      {
        "scrapePool": "serviceMonitor/automation/n8n-postgresql/0",
        "labels": {"namespace": "automation", "service": "n8n-postgresql", "endpoint": "metrics", "job": "n8n-postgresql"},
        "health": "up"
      }
    ]
  }
}
EOF
expect_true 'two exact Prometheus targets' n8n_prometheus_targets_match_contract \
  "$temp_dir/targets.json"
yq -p=json -o=json '.data.activeTargets += [.data.activeTargets[0]]' \
  "$temp_dir/targets.json" >"$temp_dir/targets-duplicate.json"
expect_false 'duplicate exact Prometheus target' n8n_prometheus_targets_match_contract \
  "$temp_dir/targets-duplicate.json"
yq -p=json -o=json '.data.activeTargets += [
  (.data.activeTargets[0] |
    .scrapePool = "serviceMonitor/automation/n8n-shadow/0" |
    .health = "down")
]' "$temp_dir/targets.json" >"$temp_dir/targets-alternate-pool-duplicate.json"
expect_false 'unhealthy exact-identity duplicate in alternate Prometheus scrape pool' \
  n8n_prometheus_targets_match_contract "$temp_dir/targets-alternate-pool-duplicate.json"
yq -p=json -o=json '.data.activeTargets += [
  (.data.activeTargets[0] | .labels.service = "n8n-shadow" | .labels.job = "n8n-shadow")
]' "$temp_dir/targets.json" >"$temp_dir/targets-pool-collision.json"
expect_false 'unrelated target in exact Prometheus scrape pool' \
  n8n_prometheus_targets_match_contract "$temp_dir/targets-pool-collision.json"
yq -p=json -o=json '(.data.activeTargets[] | select(.labels.service == "n8n") | .health) = "down"' \
  "$temp_dir/targets.json" >"$temp_dir/targets-down.json"
expect_false 'down exact Prometheus target' n8n_prometheus_targets_match_contract \
  "$temp_dir/targets-down.json"
yq -p=json -o=json '(.data.activeTargets[] | select(.labels.service == "n8n") |
  .scrapePool) = "serviceMonitor/automation/n8n-shadow/0" |
  (.data.activeTargets[] | select(.labels.service == "n8n") |
  .labels.service) = "n8n-shadow"' "$temp_dir/targets.json" \
  >"$temp_dir/targets-substring.json"
expect_false 'substring-only Prometheus target' n8n_prometheus_targets_match_contract \
  "$temp_dir/targets-substring.json"

cat >"$temp_dir/rules-absent.json" <<'EOF'
{
  "status": "success",
  "data": {"groups": [{"name": "unrelated-platform", "rules": []}]}
}
EOF
cat >"$temp_dir/rules-exact.json" <<'EOF'
{
  "status": "success",
  "data": {
    "groups": [{
      "name": "n8n-platform",
      "rules": [
        {"name": "N8nCanaryDown", "health": "ok", "lastError": ""},
        {"name": "N8nCanaryProbeMissing", "health": "ok", "lastError": ""},
        {"name": "N8nContainerOomKilled", "health": "ok", "lastError": ""},
        {"name": "N8nContainerRestarting", "health": "ok", "lastError": ""},
        {"name": "N8nExecutionFailures", "health": "ok", "lastError": ""},
        {"name": "N8nPersistentVolumeClaimNotBound", "health": "ok", "lastError": ""},
        {"name": "N8nPersistentVolumeUsageCritical", "health": "ok", "lastError": ""},
        {"name": "N8nPersistentVolumeUsageWarning", "health": "ok", "lastError": ""},
        {"name": "N8nPostgresqlBackupJobFailed", "health": "ok", "lastError": ""},
        {"name": "N8nPostgresqlBackupJobOverdue", "health": "ok", "lastError": ""},
        {"name": "N8nPostgresqlBackupStale", "health": "ok", "lastError": ""},
        {"name": "N8nPostgresqlUnavailable", "health": "ok", "lastError": ""},
        {"name": "N8nPostgresqlWorkloadUnavailable", "health": "ok", "lastError": ""},
        {"name": "N8nUnavailable", "health": "ok", "lastError": ""},
        {"name": "N8nWorkloadUnavailable", "health": "ok", "lastError": ""}
      ]
    }]
  }
}
EOF
expect_true 'private verifier accepts an absent staged n8n rule group' \
  n8n_prometheus_rule_group_matches_contract private "$temp_dir/rules-absent.json"
expect_false 'private verifier rejects a stale or early n8n rule group' \
  n8n_prometheus_rule_group_matches_contract private "$temp_dir/rules-exact.json"
expect_false 'full verifier rejects a missing n8n rule group' \
  n8n_prometheus_rule_group_matches_contract full "$temp_dir/rules-absent.json"
expect_true 'full verifier accepts the exact 15-rule n8n group' \
  n8n_prometheus_rule_group_matches_contract full "$temp_dir/rules-exact.json"
yq -p=json -o=json '(.data.groups[0].rules[] | select(.name == "N8nUnavailable") |
  .health) = "err"' "$temp_dir/rules-exact.json" >"$temp_dir/rules-unhealthy.json"
expect_false 'full verifier rejects an unhealthy rule in the exact n8n group' \
  n8n_prometheus_rule_group_matches_contract full "$temp_dir/rules-unhealthy.json"

cat >"$temp_dir/routes.json" <<'EOF'
{
  "items": [
    {
      "apiVersion": "gateway.networking.k8s.io/v1",
      "kind": "HTTPRoute",
      "metadata": {"name": "n8n", "namespace": "automation", "generation": 3},
      "spec": {
        "hostnames": ["n8n.lab.supermorphic.com"],
        "parentRefs": [{"name": "internal", "namespace": "networking", "sectionName": "https"}],
        "rules": [{
          "matches": [{"path": {"type": "PathPrefix", "value": "/"}}],
          "backendRefs": [{"name": "n8n", "port": 5678}]
        }]
      },
      "status": {"parents": [{
        "parentRef": {"name": "internal", "namespace": "networking", "sectionName": "https"},
        "conditions": [
          {"type": "Accepted", "status": "True", "observedGeneration": 3},
          {"type": "ResolvedRefs", "status": "True", "observedGeneration": 3}
        ]
      }]}
    },
    {
      "apiVersion": "gateway.networking.k8s.io/v1",
      "kind": "HTTPRoute",
      "metadata": {"name": "n8n-platform-canary", "namespace": "networking-public", "generation": 4},
      "spec": {
        "hostnames": ["hooks.lab.supermorphic.com"],
        "parentRefs": [{"name": "public-webhooks", "sectionName": "https"}],
        "rules": [{
          "matches": [{"path": {"type": "Exact", "value": "/webhook/platform-canary"}}],
          "backendRefs": [{"group": "", "kind": "Service", "name": "n8n", "namespace": "automation", "port": 5678}]
        }]
      },
      "status": {"parents": [{
        "parentRef": {"name": "public-webhooks", "sectionName": "https"},
        "conditions": [
          {"type": "Accepted", "status": "True", "observedGeneration": 4},
          {"type": "ResolvedRefs", "status": "True", "observedGeneration": 4}
        ]
      }]}
    }
  ]
}
EOF
expect_true 'canonical routes with Gateway API defaults' n8n_routes_match_contract \
  full "$temp_dir/routes.json"
expect_true 'private route only' n8n_routes_match_contract \
  private <(yq -p=json -o=json '.items = [.items[0]]' "$temp_dir/routes.json")
yq -p=json -o=json '.items[1].spec.rules[0].matches +=
  [{"path":{"type":"PathPrefix","value":"/webhook"}}]' \
  "$temp_dir/routes.json" >"$temp_dir/routes-broad.json"
expect_false 'second broader public match' n8n_routes_match_contract \
  full "$temp_dir/routes-broad.json"
yq -p=json -o=json '.items += [{
  "apiVersion":"gateway.networking.k8s.io/v1",
  "kind":"HTTPRoute",
  "metadata":{"name":"omitted-kind","namespace":"gatus","generation":1},
  "spec":{"hostnames":["other.example.test"],"parentRefs":[{"name":"other"}],
    "rules":[{"backendRefs":[{"name":"n8n","namespace":"automation","port":5678}]}]},
  "status":{"parents":[]}
}]' "$temp_dir/routes.json" >"$temp_dir/routes-omitted-kind.json"
expect_false 'additional n8n route with omitted Service kind' n8n_routes_match_contract \
  full "$temp_dir/routes-omitted-kind.json"
expect_true 'omitted Service kind is found for no-route safety' \
  n8n_routes_target_service automation n8n "$temp_dir/routes-omitted-kind.json"
expect_false 'unrelated Service is not found for no-route safety' \
  n8n_routes_target_service automation not-n8n "$temp_dir/routes-omitted-kind.json"

echo 'n8n verification readiness, target, and route fixtures passed.'
