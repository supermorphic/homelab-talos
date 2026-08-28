#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="$repo_root/scripts/validate/n8n.sh"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/n8n-validator-test.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT

tree_root="$test_dir/tree"

reset_tree() {
  rm -rf -- "$tree_root"
  mkdir -p "$tree_root/docs/guides" "$tree_root/docs/runbooks" \
    "$tree_root/scripts/lib" "$tree_root/scripts/test/lib" \
    "$tree_root/scripts/test/scenarios" "$tree_root/scripts/verify" \
    "$tree_root/talos" "$tree_root/tests/chainsaw/smoke/platform" \
    "$tree_root/kubernetes/apps/networking" \
    "$tree_root/kubernetes/apps/monitoring/alerts/app" \
    "$tree_root/kubernetes/apps/monitoring/gatus/app" \
    "$tree_root/kubernetes/apps/monitoring/kube-prometheus-stack/config/dashboards"
  cp "$repo_root/.justfile" "$tree_root/.justfile"
  cp -R "$repo_root/.just" "$tree_root/.just"
  cp "$repo_root/kubernetes/mod.just" "$tree_root/kubernetes/mod.just"
  cp "$repo_root/talos/mod.just" "$tree_root/talos/mod.just"
  cp "$repo_root/tests/mod.just" "$repo_root/tests/catalog.yaml" "$tree_root/tests/"
  cp -R "$repo_root/tests/chainsaw/smoke/platform/n8n" \
    "$tree_root/tests/chainsaw/smoke/platform/n8n"
  cp "$repo_root/docs/guides/n8n-operations.md" "$tree_root/docs/guides/n8n-operations.md"
  cp "$repo_root/docs/runbooks/n8n-recovery.md" "$tree_root/docs/runbooks/n8n-recovery.md"
  cp "$repo_root/scripts/lib/common.sh" "$repo_root/scripts/lib/flux-alerts.sh" \
    "$repo_root/scripts/lib/network.sh" "$tree_root/scripts/lib/"
  cp "$repo_root/scripts/test/lib/lease.sh" "$tree_root/scripts/test/lib/lease.sh"
  cp "$repo_root/scripts/test/scenarios/n8n-persistence.sh" \
    "$repo_root/scripts/test/scenarios/n8n-restore-drill.sh" \
    "$tree_root/scripts/test/scenarios/"
  cp "$repo_root/scripts/verify/n8n.sh" "$tree_root/scripts/verify/n8n.sh"
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
  cp "$repo_root/kubernetes/apps/monitoring/alerts/app/n8n.yaml" \
    "$tree_root/kubernetes/apps/monitoring/alerts/app/n8n.yaml"
  cp "$repo_root/kubernetes/apps/monitoring/alerts/app/kustomization.yaml" \
    "$tree_root/kubernetes/apps/monitoring/alerts/app/kustomization.yaml"
  cp "$repo_root/kubernetes/apps/monitoring/gatus/app/values.yaml" \
    "$tree_root/kubernetes/apps/monitoring/gatus/app/values.yaml"
  cp "$repo_root/kubernetes/apps/monitoring/gatus/app/kustomization.yaml" \
    "$tree_root/kubernetes/apps/monitoring/gatus/app/kustomization.yaml"
  cp "$repo_root/kubernetes/apps/monitoring/kube-prometheus-stack/config/kustomization.yaml" \
    "$tree_root/kubernetes/apps/monitoring/kube-prometheus-stack/config/kustomization.yaml"
  if [[ -f "$repo_root/kubernetes/apps/monitoring/kube-prometheus-stack/config/dashboards/n8n-postgresql.json" ]]; then
    cp "$repo_root/kubernetes/apps/monitoring/kube-prometheus-stack/config/dashboards/n8n-postgresql.json" \
      "$tree_root/kubernetes/apps/monitoring/kube-prometheus-stack/config/dashboards/n8n-postgresql.json"
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

dashboard="$tree_root/kubernetes/apps/monitoring/kube-prometheus-stack/config/dashboards/n8n-postgresql.json"

reset_tree
rm -f -- "$dashboard"
expect_fail 'missing n8n observability dashboard' \
  'Missing n8n observability source:'

alerts="$tree_root/kubernetes/apps/monitoring/alerts/app/n8n.yaml"
gatus_values="$tree_root/kubernetes/apps/monitoring/gatus/app/values.yaml"

reset_tree
jq '.uid = "wrong-dashboard"' "$dashboard" >"$dashboard.tmp"
mv -- "$dashboard.tmp" "$dashboard"
expect_fail 'wrong n8n dashboard UID' \
  'The n8n PostgreSQL dashboard identity, datasource, and panel inventory are incorrect.'

reset_tree
jq '(.templating.list[] | select(.name == "datasource") | .query) = "loki"' \
  "$dashboard" >"$dashboard.tmp"
mv -- "$dashboard.tmp" "$dashboard"
expect_fail 'wrong n8n dashboard default datasource' \
  'The n8n PostgreSQL dashboard identity, datasource, and panel inventory are incorrect.'

reset_tree
jq 'del(.panels[] | select(.title == "Validated logical backup status"))' \
  "$dashboard" >"$dashboard.tmp"
mv -- "$dashboard.tmp" "$dashboard"
expect_fail 'missing first-class backup status panel' \
  'The n8n PostgreSQL dashboard identity, datasource, and panel inventory are incorrect.'

reset_tree
jq '(.panels[] | select(.title == "Validated logical backup age") | .targets[0].expr) = "max(kube_job_status_succeeded{namespace=\"automation\"})"' \
  "$dashboard" >"$dashboard.tmp"
mv -- "$dashboard.tmp" "$dashboard"
expect_fail 'dashboard backup age based on Kubernetes Job success' \
  'Backup observability must use the validated logical-dump status marker.'

reset_tree
yq -i '(.spec.groups[].rules[] | select(.alert == "N8nPostgresqlBackupStale") | .expr) = "kube_job_status_succeeded{namespace=\"automation\"} == 0"' \
  "$alerts"
expect_fail 'backup freshness alert based on Kubernetes Job success' \
  'Backup observability must use the validated logical-dump status marker.'

reset_tree
yq -i '(.spec.groups[].rules[] | select(.alert == "N8nPostgresqlBackupJobFailed") | .expr) = "kube_job_status_failed{namespace=\"automation\",job_name=~\"n8n-postgresql-backup-.*\"} > 0"' \
  "$alerts"
expect_fail 'backup Job alert uses retry-attempt counter instead of terminal result' \
  'The backup Job failure alert must use terminal failure and last-success recovery semantics.'

reset_tree
yq -i '(.spec.groups[].rules[] | select(.alert == "N8nPersistentVolumeUsageWarning") | .expr) |= sub("<= 85"; "<= 95")' \
  "$alerts"
expect_fail 'PVC warning range overlaps the critical range' \
  'The n8n PVC warning range must stop at 85 percent.'

reset_tree
yq -i '(.spec.groups[].rules[] | select(.alert == "N8nCanaryDown") | .expr) = "gatus_results_endpoint_success{group=\"Platform\",name=\"wrong\"} == 0"' \
  "$alerts"
expect_fail 'canary alert identity drift' \
  'The Gatus canary, Prometheus alerts, and dashboard must use one endpoint identity.'

reset_tree
yq -i '(.config.endpoints[] | select(.name == "n8n-platform-canary") | .url) = "https://*.lab.supermorphic.com/webhook/platform-canary"' \
  "$gatus_values"
expect_fail 'Gatus canary wildcard route coupling' \
  'The Gatus canary URL must match the dedicated public certificate and exact route.'

reset_tree
jq '(.panels[] | select(.title == "Persistent volume utilization") | .targets[0].expr) |= gsub("\\|n8n-postgresql-backups"; "")' \
  "$dashboard" >"$dashboard.tmp"
mv -- "$dashboard.tmp" "$dashboard"
expect_fail 'dashboard omits backup PVC' \
  'n8n alert and dashboard PVC inventories must match the three retained claims.'

reset_tree
jq '(.panels[] | select(.title == "Ready replicas") | .targets[0].expr) = "kube_deployment_status_replicas_available{namespace=\"automation\",deployment=\"wrong\"}"' \
  "$dashboard" >"$dashboard.tmp"
mv -- "$dashboard.tmp" "$dashboard"
expect_fail 'dashboard workload identity drift' \
  'n8n availability alerts and dashboard must match the deployed workload identities.'

reset_tree
yq -i '(.spec.groups[].rules[] | select(.alert == "N8nExecutionFailures") | .expr) = "increase(obsolete_n8n_failures_total[15m]) > 0"' \
  "$alerts"
expect_fail 'execution alert uses obsolete n8n metric' \
  'n8n execution alerts and dashboard must use the pinned duration histogram contract.'

workflow="$tree_root/kubernetes/apps/automation/n8n/app/workflows/platform-canary.json"

reset_tree
rm -f -- "$workflow"
expect_fail 'missing Platform Canary workflow template' \
  'Missing n8n Platform Canary workflow template:'

reset_tree
yq -i 'del(.configMapGenerator[] | select(.name == "n8n-workflow-templates"))' \
  "$tree_root/kubernetes/apps/automation/n8n/app/kustomization.yaml"
expect_fail 'unpackaged Platform Canary workflow template' \
  'The n8n app must package the stable values and inactive Platform Canary template ConfigMaps.'

reset_tree
jq '(.nodes[] | select(.name == "Webhook") | .typeVersion) = 2.2' \
  "$workflow" >"$workflow.tmp"
mv -- "$workflow.tmp" "$workflow"
expect_fail 'unsupported Platform Canary Webhook version' \
  'Platform Canary must use the pinned Webhook 2.1 and Edit Fields 3.4 node versions.'

reset_tree
jq '(.nodes[] | select(.name == "Edit Fields") | .typeVersion) = 3.5' \
  "$workflow" >"$workflow.tmp"
mv -- "$workflow.tmp" "$workflow"
expect_fail 'unsupported Platform Canary Edit Fields version' \
  'Platform Canary must use the pinned Webhook 2.1 and Edit Fields 3.4 node versions.'

reset_tree
jq '.active = true' "$workflow" >"$workflow.tmp"
mv -- "$workflow.tmp" "$workflow"
expect_fail 'active Platform Canary import' \
  'Platform Canary must be a secret-free inactive two-node Webhook and Edit Fields template.'

reset_tree
jq '.nodes[0].parameters.path = "route-drift"' "$workflow" >"$workflow.tmp"
mv -- "$workflow.tmp" "$workflow"
expect_fail 'Platform Canary route/workflow path drift' \
  'The public route and Platform Canary Webhook must use the same production path.'

reset_tree
jq '.nodes += [{"name":"Respond to Webhook","type":"n8n-nodes-base.respondToWebhook"}]' \
  "$workflow" >"$workflow.tmp"
mv -- "$workflow.tmp" "$workflow"
expect_fail 'prohibited Respond to Webhook node' \
  'Platform Canary must be a secret-free inactive two-node Webhook and Edit Fields template.'

reset_tree
jq '(.nodes[] | select(.name == "Edit Fields") | .type) = "n8n-nodes-base.postgres"' \
  "$workflow" >"$workflow.tmp"
mv -- "$workflow.tmp" "$workflow"
expect_fail 'prohibited SQL node' \
  'Platform Canary must be a secret-free inactive two-node Webhook and Edit Fields template.'

reset_tree
jq '.nodes[0].credentials = {"httpHeaderAuth": {"id": "credential-id", "name": "Platform Canary Header"}}' \
  "$workflow" >"$workflow.tmp"
mv -- "$workflow.tmp" "$workflow"
expect_fail 'Platform Canary credential binding' \
  'Platform Canary must be a secret-free inactive two-node Webhook and Edit Fields template.'

reset_tree
jq '(.nodes[] | select(.name == "Webhook") | .parameters.responseMode) = "onReceived"' \
  "$workflow" >"$workflow.tmp"
mv -- "$workflow.tmp" "$workflow"
expect_fail 'Platform Canary immediate Webhook response' \
  'Platform Canary must be a secret-free inactive two-node Webhook and Edit Fields template.'

reset_tree
jq '.connections["Edit Fields"] = {"main": [[{"node": "Webhook", "type": "main", "index": 0}]]}' \
  "$workflow" >"$workflow.tmp"
mv -- "$workflow.tmp" "$workflow"
expect_fail 'Platform Canary additive workflow edge' \
  'Platform Canary must be a secret-free inactive two-node Webhook and Edit Fields template.'

reset_tree
jq '(.nodes[] | select(.name == "Edit Fields") | .parameters.assignments.assignments[] |
  select(.name == "status") | .value) = "not-ok"' "$workflow" >"$workflow.tmp"
mv -- "$workflow.tmp" "$workflow"
expect_fail 'Platform Canary response status drift' \
  'Platform Canary must return only the required status, correlation, and executionId fields.'

reset_tree
jq '.settings.saveDataSuccessExecution = "none"' "$workflow" >"$workflow.tmp"
mv -- "$workflow.tmp" "$workflow"
expect_fail 'Platform Canary success execution retention' \
  'Platform Canary must save successful and failed executions.'

reset_tree
jq '.settings.saveDataErrorExecution = "none"' "$workflow" >"$workflow.tmp"
mv -- "$workflow.tmp" "$workflow"
expect_fail 'Platform Canary error execution retention' \
  'Platform Canary must save successful and failed executions.'

reset_tree
mkdir -p "$tree_root/kubernetes/apps/automation/unapproved-public-route"
apply_patch_file="$tree_root/kubernetes/apps/automation/unapproved-public-route/httproute.yaml"
printf '%s\n' \
  'apiVersion: gateway.networking.k8s.io/v1' \
  'kind: HTTPRoute' \
  'metadata:' \
  '  name: unapproved-public-webhook' \
  '  namespace: networking-public' \
  'spec:' \
  '  parentRefs:' \
  '    - name: public-webhooks' \
  '  rules:' \
  '    - matches:' \
  '        - path:' \
  '            type: Exact' \
  '            value: /webhook/unapproved' >"$apply_patch_file"
expect_fail 'additional public production webhook path' \
  'The public Gateway must have exactly one complete Platform Canary HTTPRoute contract.'

reset_tree
yq -i '.spec.parentRefs[0].group = "wrong.example.io"' \
  "$tree_root/kubernetes/apps/networking/public-webhook-gateway/route/httproute.yaml"
expect_fail 'alternate public Gateway parent identity' \
  'The public Gateway must have exactly one complete Platform Canary HTTPRoute contract.'

reset_tree
mkdir -p "$tree_root/kubernetes/apps/automation/unapproved-public-catch-all"
catch_all_route="$tree_root/kubernetes/apps/automation/unapproved-public-catch-all/httproute.yaml"
printf '%s\n' \
  'apiVersion: gateway.networking.k8s.io/v1' \
  'kind: HTTPRoute' \
  'metadata:' \
  '  name: unapproved-public-catch-all' \
  '  namespace: networking-public' \
  'spec:' \
  '  parentRefs:' \
  '    - group: gateway.networking.k8s.io' \
  '      kind: Gateway' \
  '      name: public-webhooks' \
  '      namespace: networking-public' \
  '      sectionName: https' \
  '  rules:' \
  '    - backendRefs:' \
  '        - group: ""' \
  '          kind: Service' \
  '          name: n8n' \
  '          namespace: automation' \
  '          port: 5678' >"$catch_all_route"
expect_fail 'matcher-less public catch-all' \
  'The public Gateway must have exactly one complete Platform Canary HTTPRoute contract.'

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
