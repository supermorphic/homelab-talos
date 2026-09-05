#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
source scripts/lib/flux-alerts.sh
source scripts/lib/network.sh
require_bash

[[ "$#" -eq 1 ]] || { echo 'Usage: nocodb.sh <kubeconfig>' >&2; exit 2; }
kubeconfig="$1"
namespace='automation-data'
source_ks='kubernetes/apps/automation-data/nocodb/ks.yaml'
gatus_values='kubernetes/apps/monitoring/gatus/app/values.yaml'
gatus_activation_values='kubernetes/apps/monitoring/gatus/app/nocodb-activation.values.yaml'
alerts_kustomization='kubernetes/apps/monitoring/alerts/app/kustomization.yaml'
alerts_definition='kubernetes/apps/monitoring/alerts/app/nocodb.yaml'
catalog='tests/catalog.yaml'
prometheus_base_url='https://prometheus.lab.supermorphic.com'
prometheus_resolve="prometheus.lab.supermorphic.com:443:${HOMELAB_GATEWAY_VIP}"
kc=(kubectl --kubeconfig "$kubeconfig")

fail() { echo "NocoDB verification failed: $*" >&2; exit 1; }
[[ -f "$kubeconfig" ]] || fail "Missing $kubeconfig; generate the task-scoped Talos kubeconfig first."
for source in "$source_ks" "$gatus_values" "$gatus_activation_values" \
  "$alerts_kustomization" "$alerts_definition" "$catalog"; do
  [[ -f "$source" ]] || fail "Missing verification source: $source."
done

yq -e '(.spec.suspend | type) == "!!bool"' "$source_ks" >/dev/null ||
  fail 'Git NocoDB suspension intent is absent or invalid.'
source_suspend="$(yq -r '.spec.suspend' "$source_ks")"
active_gatus_name_count="$(yq -r '[.config.endpoints[]? | select(.name == "nocodb")] | length' "$gatus_values")"
active_gatus_contract_count="$(yq -r '[.config.endpoints[]? | select(
  .name == "nocodb" and .group == "Platform" and
  .url == "https://nocodb.lab.supermorphic.com/api/v1/health" and
  .interval == "1m" and (.conditions | join(",")) == "[STATUS] == 200"
)] | length' "$gatus_values")"
activation_endpoint_count="$(yq -r '[.config.endpoints[]? | select(
  .name == "nocodb" and .group == "Platform" and
  .url == "https://nocodb.lab.supermorphic.com/api/v1/health" and
  .interval == "1m" and (.conditions | join(",")) == "[STATUS] == 200"
)] | length' "$gatus_activation_values")"
selected_rule_count="$(yq -r '[.resources[]? | select(. == "./nocodb.yaml")] | length' "$alerts_kustomization")"
verification_campaign_count="$(yq -r '[.campaigns.verification.members[]? |
  select(. == "verification.nocodb")] | length' "$catalog")"
scoped_campaign_count="$(yq -r '[.campaigns."scoped-verification".members[]? |
  select(. == "verification.nocodb")] | length' "$catalog")"
[[ "$activation_endpoint_count" == 1 ]] || fail 'The retained NocoDB Gatus activation definition is invalid.'

declared_phase="${NOCODB_VERIFY_PHASE:-}"
[[ -z "$declared_phase" || "$declared_phase" == attended ]] ||
  fail 'NOCODB_VERIFY_PHASE must be unset or exactly attended.'

if [[ "$source_suspend" == true ]]; then
  [[ "$active_gatus_name_count" == 0 && "$selected_rule_count" == 0 && \
    "$verification_campaign_count" == 0 && "$scoped_campaign_count" == 0 ]] ||
    fail 'Staged Git intent has active NocoDB monitoring or recurring verification enrollment.'
else
  [[ "$declared_phase" != attended ]] ||
    fail 'Attended phase cannot override durable active Git intent.'
  [[ "$active_gatus_name_count" == 1 && "$active_gatus_contract_count" == 1 && \
    "$selected_rule_count" == 1 && \
    "$verification_campaign_count" == 1 && "$scoped_campaign_count" == 1 ]] ||
    fail 'Durable active Git intent lacks exact NocoDB monitoring and recurring verification enrollment.'
fi

ready_resource() {
  local resource="$1" name="$2" resource_namespace="$3" state
  state="$("${kc[@]}" --namespace "$resource_namespace" get "$resource" "$name" --output json)"
  # shellcheck disable=SC2016 # yq evaluates the literal expression.
  yq -p=json -e '
    .metadata.generation as $generation |
    [
      ((.spec.suspend // false) == false),
      (.status.observedGeneration == $generation),
      (([.status.conditions[]? | select(.type == "Ready" and .status == "True" and .observedGeneration == $generation)] | length) == 1)
    ] | all
  ' - >/dev/null <<<"$state" || fail "$resource/$name is not current and Ready."
}

for name in automation-data monitoring-alerts gatus; do
  ready_resource kustomization "$name" flux-system
done

nocodb_kustomization="$("${kc[@]}" --namespace flux-system get kustomization nocodb --output json)"
yq -p=json -e '(.spec.suspend | type) == "!!bool"' - >/dev/null <<<"$nocodb_kustomization" ||
  fail 'Live NocoDB suspension state is absent or invalid.'
live_suspend="$(yq -p=json -r '.spec.suspend' - <<<"$nocodb_kustomization")"
phase=''
monitoring_required=false
if [[ "$source_suspend" == true && -z "$declared_phase" ]]; then
  [[ "$live_suspend" == true ]] ||
    fail 'Staged NocoDB is active without an explicit attended verification phase.'
  staged_deployment="$("${kc[@]}" --namespace "$namespace" get deployment nocodb \
    --ignore-not-found --output name)"
  [[ -z "$staged_deployment" ]] ||
    fail 'Staged NocoDB has an active Deployment; declare attended only for the reviewed temporary activation.'
  echo 'NocoDB read-only verification passed: phase=staged-absent; Git and live suspension agree, no application Deployment is active, and monitoring remains unenrolled.'
  exit 0
elif [[ "$source_suspend" == true ]]; then
  [[ "$live_suspend" == false ]] || fail 'Attended NocoDB verification requires a live active Kustomization.'
  phase='temporary-attended'
else
  [[ "$live_suspend" == false ]] || fail 'Durable active NocoDB is suspended in the live cluster.'
  phase='durable-active'
  monitoring_required=true
fi

# shellcheck disable=SC2016 # yq evaluates its own variables.
yq -p=json -e '
  .metadata.generation as $generation |
  [
    (.spec.suspend == false),
    (.status.observedGeneration == $generation),
    (([.status.conditions[]? | select(
      .type == "Ready" and .status == "True" and .observedGeneration == $generation
    )] | length) == 1)
  ] | all
' - >/dev/null <<<"$nocodb_kustomization" || fail 'Active NocoDB Kustomization is not current and Ready.'
ready_resource helmrelease nocodb "$namespace"

assert_no_worker_or_redis() {
  local resource="$1" input="$2"
  # shellcheck disable=SC2016 # yq evaluates the literal expression.
  yq -p=json -e '
    [
      .items[]? |
      [
        (.metadata.name // ""),
        (.metadata.labels."app.kubernetes.io/name" // ""),
        (.metadata.labels."app.kubernetes.io/component" // "")
      ] | join("|") |
      select(test("(?i)(^|[|_-])(nocodb[-_])?(worker|redis)([|_-]|$)"))
    ] | length == 0
  ' - >/dev/null <<<"$input" || fail "NocoDB $resource inventory contains a worker or Redis resource."
}

# Enumerate namespace workloads and Service identities. The expected design has no NocoDB
# worker or Redis companion, so the scoped observer must reject either before accepting
# the main application resource.
deployments="$("${kc[@]}" --namespace "$namespace" get deployments --output json)"
pods_inventory="$("${kc[@]}" --namespace "$namespace" get pods --output json)"
services="$("${kc[@]}" --namespace "$namespace" get services --output json)"
assert_no_worker_or_redis Deployment "$deployments"
assert_no_worker_or_redis Pod "$pods_inventory"
assert_no_worker_or_redis Service "$services"

deployment="$("${kc[@]}" --namespace "$namespace" get deployment nocodb --output json)"
# shellcheck disable=SC2016 # yq evaluates the literal expression.
yq -p=json -e '
  .metadata.generation as $generation |
  [
    (.spec.replicas == 1), (.status.observedGeneration == $generation),
    (.status.replicas == 1), (.status.updatedReplicas == 1),
    (.status.readyReplicas == 1), (.status.availableReplicas == 1),
    ((.status.unavailableReplicas // 0) == 0)
  ] | all
' - >/dev/null <<<"$deployment" || fail 'NocoDB Deployment is not the current single ready replica.'

pods="$("${kc[@]}" --namespace "$namespace" get pods --selector app.kubernetes.io/name=nocodb --output json)"
yq -p=json -e '
  (.items | length) == 1 and .items[0].status.phase == "Running" and
  ([.items[0].status.conditions[]? | select(.type == "Ready" and .status == "True")] | length) == 1
' - >/dev/null <<<"$pods" || fail 'NocoDB does not have exactly one Ready application Pod.'

service="$("${kc[@]}" --namespace "$namespace" get service nocodb --output json)"
yq -p=json -e '
  .spec.type == "ClusterIP" and .spec.clusterIP != "" and .spec.clusterIP != "None" and
  .spec.selector."app.kubernetes.io/name" == "nocodb" and
  ([.spec.ports[]? | select(.port == 8080 and (.targetPort | tostring) == "8080")] | length) == 1
' - >/dev/null <<<"$service" || fail 'NocoDB Service does not match the private port-8080 contract.'

endpoints="$("${kc[@]}" --namespace "$namespace" get endpointslice --selector kubernetes.io/service-name=nocodb --output json)"
yq -p=json -e '
  ([.items[]?.endpoints[]? | select(.conditions.ready == true and .targetRef.kind == "Pod" and .targetRef.name != "")] | length) == 1 and
  ([.items[]?.ports[]? | select(.port == 8080)] | length) == 1
' - >/dev/null <<<"$endpoints" || fail 'NocoDB Service has no exact ready port-8080 endpoint.'

route="$("${kc[@]}" --namespace "$namespace" get httproute nocodb --output json)"
# shellcheck disable=SC2016 # yq evaluates the literal expression.
yq -p=json -e '
  .metadata.generation as $generation |
  [
    ((.spec.hostnames | length) == 1), (.spec.hostnames[0] == "nocodb.lab.supermorphic.com"),
    ((.spec.parentRefs | length) == 1),
    (.spec.parentRefs[0].group == "gateway.networking.k8s.io"),
    (.spec.parentRefs[0].kind == "Gateway"), (.spec.parentRefs[0].name == "internal"),
    (.spec.parentRefs[0].namespace == "networking"), (.spec.parentRefs[0].sectionName == "https"),
    (([.status.parents[]?.conditions[]? | select(.type == "Accepted" and .status == "True" and .observedGeneration == $generation)] | length) == 1),
    (([.status.parents[]?.conditions[]? | select(.type == "ResolvedRefs" and .status == "True" and .observedGeneration == $generation)] | length) == 1)
  ] | all
' - >/dev/null <<<"$route" || fail 'NocoDB HTTPRoute is not current, Accepted, and ResolvedRefs.'

policy="$("${kc[@]}" --namespace "$namespace" get ciliumnetworkpolicy nocodb --output json)"
# shellcheck disable=SC2016 # Python evaluates the literal program.
python -c '
import json
import sys

policy = json.load(sys.stdin)["spec"]
expected = {
    "endpointSelector": {"matchLabels": {"app.kubernetes.io/name": "nocodb"}},
    "ingress": [
        {
            "fromEndpoints": [{"matchLabels": {
                "k8s:io.kubernetes.pod.namespace": "envoy-gateway-system",
                "gateway.envoyproxy.io/owning-gateway-name": "internal",
                "gateway.envoyproxy.io/owning-gateway-namespace": "networking",
            }}],
            "toPorts": [{"ports": [{"port": "8080", "protocol": "TCP"}]}],
        },
        {
            "fromEndpoints": [{"matchLabels": {
                "k8s:io.kubernetes.pod.namespace": "automation",
                "app.kubernetes.io/name": "n8n",
            }}],
            "toPorts": [{"ports": [{"port": "8080", "protocol": "TCP"}]}],
        },
        {
            "fromEntities": ["host", "remote-node"],
            "toPorts": [{"ports": [{"port": "8080", "protocol": "TCP"}]}],
        },
    ],
    "egress": [
        {
            "toEndpoints": [{"matchLabels": {
                "k8s:io.kubernetes.pod.namespace": "kube-system",
                "k8s:k8s-app": "kube-dns",
            }}],
            "toPorts": [{"ports": [
                {"port": "53", "protocol": "UDP"},
                {"port": "53", "protocol": "TCP"},
            ]}],
        },
        {
            "toEndpoints": [{"matchLabels": {
                "k8s:io.kubernetes.pod.namespace": "automation-data",
                "app.kubernetes.io/name": "automation-data-postgresql",
            }}],
            "toPorts": [{"ports": [{"port": "5432", "protocol": "TCP"}]}],
        },
    ],
}

unordered_list_keys = frozenset({
    "ingress", "egress", "fromEndpoints", "toEndpoints", "fromEntities", "toPorts", "ports",
})

def normalize(value, path=()):
    if isinstance(value, dict):
        return {key: normalize(item, path + (key,)) for key, item in value.items()}
    if isinstance(value, list):
        items = [normalize(item, path) for item in value]
        if path[-1] in unordered_list_keys:
            return sorted(items, key=lambda item: json.dumps(item, sort_keys=True))
        return items
    return value

raise SystemExit(0 if normalize(policy) == normalize(expected) else 1)
' <<<"$policy" || fail 'NocoDB CiliumNetworkPolicy identity or ports differ from the contract.'

pvc="$("${kc[@]}" --namespace "$namespace" get persistentvolumeclaim nocodb-data --output json)"
yq -p=json -e '
  .status.phase == "Bound" and .spec.storageClassName == "longhorn" and
  .spec.resources.requests.storage == "10Gi" and .spec.volumeName != ""
' - >/dev/null <<<"$pvc" || fail 'NocoDB attachment PVC is not the expected Bound 10Gi Longhorn claim.'
volume_name="$(yq -p=json -r '.spec.volumeName' - <<<"$pvc")"

volumes="$("${kc[@]}" --namespace longhorn-system get volumes.longhorn.io --output json)"
# shellcheck disable=SC2016 # yq evaluates the literal expression.
VOLUME_NAME="$volume_name" yq -p=json -e '
  [.items[]? | select(
    .status.kubernetesStatus.namespace == "automation-data" and
    .status.kubernetesStatus.pvcName == "nocodb-data" and
    .status.kubernetesStatus.pvName == strenv(VOLUME_NAME)
  )] as $matches |
  [
    (($matches | length) == 1),
    ($matches[0].metadata.labels."recurring-job-group.longhorn.io/default" == "enabled"),
    ($matches[0].spec.numberOfReplicas == 2),
    ($matches[0].status.state == "attached"),
    ($matches[0].status.robustness == "healthy"),
    (($matches[0].status.replicaModeMap | length) == 2),
    (([$matches[0].status.replicaModeMap[]? | select(. == "RW")] | length) == 2)
  ] | all
' - >/dev/null <<<"$volumes" || fail 'NocoDB Longhorn volume identity, attached health, two RW replicas, or default recurring group is invalid.'

query_value() {
  local query="$1" response
  response="$(flux_alerts_prometheus_query "$prometheus_base_url" "$prometheus_resolve" "$query")" || return 1
  yq -p=json -r 'select(.status == "success" and (.data.result | length) == 1) | .data.result[0].value[1]' - <<<"$response"
}

if [[ "$monitoring_required" == true ]]; then
  rule="$("${kc[@]}" --namespace monitoring get prometheusrule nocodb --output json)"
  expected_rules=$'NocoDBAcceptanceJobFailed\nNocoDBAcceptanceJobOverdue\nNocoDBContainerOomKilled\nNocoDBContainerRestarting\nNocoDBDown\nNocoDBMetadataBootstrapJobFailed\nNocoDBMetadataBootstrapJobOverdue\nNocoDBPersistentVolumeClaimNotBound\nNocoDBPersistentVolumeUsageCritical\nNocoDBPersistentVolumeUsageWarning\nNocoDBProbeMissing\nNocoDBWorkloadUnavailable'
  actual_rules="$(yq -p=json -r '.spec.groups[]? | select(.name == "nocodb") | .rules[]?.alert' - <<<"$rule" | LC_ALL=C sort)"
  [[ "$actual_rules" == "$expected_rules" ]] || fail 'NocoDB PrometheusRule does not expose the exact 12-alert contract.'

  [[ "$(query_value 'gatus_results_endpoint_success{name="nocodb", group="Platform"}')" == '1' ]] ||
    fail 'NocoDB Gatus success metric is absent or unhealthy.'

  rules_response="$(flux_alerts_prometheus_get "$prometheus_base_url" "$prometheus_resolve" '/api/v1/rules?type=alert')"
  actual_loaded_rules="$(yq -p=json -r '[.data.groups[]? | select(.name == "nocodb") | .rules[]?.name] | sort | .[]' - <<<"$rules_response")"
  loaded_rule_health="$(yq -p=json -r '[.data.groups[]? | select(.name == "nocodb") | .rules[]? | [(.health // ""), (.lastError // "")] | join("|")] | unique | join(",")' - <<<"$rules_response")"
  [[ "$(yq -p=json -r '.status' - <<<"$rules_response")" == 'success' && "$actual_loaded_rules" == "$expected_rules" && "$loaded_rule_health" == 'ok|' ]] ||
    fail 'Prometheus has not loaded the exact NocoDB alert rule group.'
fi

backup_timestamp="$(query_value 'automation_data_postgresql_backup_last_success_timestamp_seconds{namespace="automation-data",service="automation-data-postgresql"}')"
# shellcheck disable=SC2016 # yq evaluates the literal expression.
VALUE="$backup_timestamp" yq -n -e 'env(VALUE) | tonumber as $value | [($value >= (now | to_unix) - 129600), ($value <= (now | to_unix))] | all' >/dev/null ||
  fail 'Automation-data logical backup freshness is absent or older than 36 hours.'

if [[ "$monitoring_required" == true ]]; then
  echo "NocoDB read-only verification passed: phase=$phase; current Flux and Helm state, one Ready Pod, private Service and route, policy, retained attachment volume, Gatus, alerts, and automation-data logical backup freshness match their contracts."
else
  echo "NocoDB read-only verification passed: phase=$phase; the temporary workload, private Service and route, policy, retained attachment volume, and automation-data logical backup freshness match their direct contracts; monitoring remains intentionally unenrolled."
fi
