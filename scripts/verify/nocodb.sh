#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
source scripts/lib/flux-alerts.sh
source scripts/lib/network.sh
require_bash

[[ "$#" -eq 1 ]] || { echo 'Usage: nocodb.sh <kubeconfig>' >&2; exit 2; }
kubeconfig="$1"
namespace='automation-data'
prometheus_base_url='https://prometheus.lab.supermorphic.com'
prometheus_resolve="prometheus.lab.supermorphic.com:443:${HOMELAB_GATEWAY_VIP}"
kc=(kubectl --kubeconfig "$kubeconfig")

fail() { echo "NocoDB verification failed: $*" >&2; exit 1; }
[[ -f "$kubeconfig" ]] || fail "Missing $kubeconfig; generate the task-scoped Talos kubeconfig first."

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

for name in automation-data nocodb monitoring-alerts gatus; do
  ready_resource kustomization "$name" flux-system
done
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
ports = lambda rule: sorted(
    (item["port"], item["protocol"])
    for to_port in rule.get("toPorts", [])
    for item in to_port.get("ports", [])
)
ingress = lambda rule: {
    "endpoints": sorted((item.get("matchLabels", {}) for item in rule.get("fromEndpoints", [])), key=lambda value: json.dumps(value, sort_keys=True)),
    "entities": sorted(rule.get("fromEntities", [])),
    "ports": ports(rule),
}
egress = lambda rule: {
    "endpoints": sorted((item.get("matchLabels", {}) for item in rule.get("toEndpoints", [])), key=lambda value: json.dumps(value, sort_keys=True)),
    "ports": ports(rule),
}
expected_ingress = sorted([
    {"endpoints": [{"k8s:io.kubernetes.pod.namespace": "envoy-gateway-system", "gateway.envoyproxy.io/owning-gateway-name": "internal", "gateway.envoyproxy.io/owning-gateway-namespace": "networking"}], "entities": [], "ports": [("8080", "TCP")]},
    {"endpoints": [{"k8s:io.kubernetes.pod.namespace": "automation", "app.kubernetes.io/name": "n8n"}], "entities": [], "ports": [("8080", "TCP")]},
    {"endpoints": [], "entities": ["host", "remote-node"], "ports": [("8080", "TCP")]},
], key=lambda value: json.dumps(value, sort_keys=True))
expected_egress = sorted([
    {"endpoints": [{"k8s:io.kubernetes.pod.namespace": "kube-system", "k8s:k8s-app": "kube-dns"}], "ports": [("53", "TCP"), ("53", "UDP")]},
    {"endpoints": [{"k8s:io.kubernetes.pod.namespace": "automation-data", "app.kubernetes.io/name": "automation-data-postgresql"}], "ports": [("5432", "TCP")]},
], key=lambda value: json.dumps(value, sort_keys=True))
actual_ingress = sorted((ingress(rule) for rule in policy.get("ingress", [])), key=lambda value: json.dumps(value, sort_keys=True))
actual_egress = sorted((egress(rule) for rule in policy.get("egress", [])), key=lambda value: json.dumps(value, sort_keys=True))
valid = (
    policy.get("endpointSelector", {}).get("matchLabels") == {"app.kubernetes.io/name": "nocodb"}
    and actual_ingress == expected_ingress
    and actual_egress == expected_egress
)
raise SystemExit(0 if valid else 1)
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
    ([
      ([
        ($matches[0].status.state == "attached"),
        ($matches[0].status.robustness == "healthy"),
        (($matches[0].status.replicaModeMap | length) == 2),
        (([$matches[0].status.replicaModeMap[]? | select(. == "RW")] | length) == 2)
      ] | all),
      ([
        ($matches[0].status.state == "detached"),
        ($matches[0].status.robustness == "unknown"),
        (($matches[0].status.replicaModeMap | length) == 2),
        ([$matches[0].status.replicaModeMap[]? | select(. == "ERR")] | length == 0)
      ] | all)
    ] | any)
  ] | all
' - >/dev/null <<<"$volumes" || fail 'NocoDB Longhorn volume identity, replica health, detached state, or default recurring group is invalid.'

rule="$("${kc[@]}" --namespace monitoring get prometheusrule nocodb --output json)"
expected_rules=$'NocoDBAcceptanceJobFailed\nNocoDBAcceptanceJobOverdue\nNocoDBContainerOomKilled\nNocoDBContainerRestarting\nNocoDBDown\nNocoDBMetadataBootstrapJobFailed\nNocoDBMetadataBootstrapJobOverdue\nNocoDBPersistentVolumeClaimNotBound\nNocoDBPersistentVolumeUsageCritical\nNocoDBPersistentVolumeUsageWarning\nNocoDBProbeMissing\nNocoDBWorkloadUnavailable'
actual_rules="$(yq -p=json -r '.spec.groups[]? | select(.name == "nocodb") | .rules[]?.alert' - <<<"$rule" | LC_ALL=C sort)"
[[ "$actual_rules" == "$expected_rules" ]] || fail 'NocoDB PrometheusRule does not expose the exact 12-alert contract.'

query_value() {
  local query="$1" response
  response="$(flux_alerts_prometheus_query "$prometheus_base_url" "$prometheus_resolve" "$query")" || return 1
  yq -p=json -r 'select(.status == "success" and (.data.result | length) == 1) | .data.result[0].value[1]' - <<<"$response"
}

[[ "$(query_value 'gatus_results_endpoint_success{name="nocodb", group="Platform"}')" == '1' ]] ||
  fail 'NocoDB Gatus success metric is absent or unhealthy.'

rules_response="$(flux_alerts_prometheus_get "$prometheus_base_url" "$prometheus_resolve" '/api/v1/rules?type=alert')"
actual_loaded_rules="$(yq -p=json -r '[.data.groups[]? | select(.name == "nocodb") | .rules[]?.name] | sort | .[]' - <<<"$rules_response")"
loaded_rule_health="$(yq -p=json -r '[.data.groups[]? | select(.name == "nocodb") | .rules[]? | [(.health // ""), (.lastError // "")] | join("|")] | unique | join(",")' - <<<"$rules_response")"
[[ "$(yq -p=json -r '.status' - <<<"$rules_response")" == 'success' && "$actual_loaded_rules" == "$expected_rules" && "$loaded_rule_health" == 'ok|' ]] ||
  fail 'Prometheus has not loaded the exact NocoDB alert rule group.'

backup_timestamp="$(query_value 'automation_data_postgresql_backup_last_success_timestamp_seconds{namespace="automation-data",service="automation-data-postgresql"}')"
# shellcheck disable=SC2016 # yq evaluates the literal expression.
VALUE="$backup_timestamp" yq -n -e 'env(VALUE) | tonumber as $value | [($value >= (now | to_unix) - 129600), ($value <= (now | to_unix))] | all' >/dev/null ||
  fail 'Automation-data logical backup freshness is absent or older than 36 hours.'

echo 'NocoDB read-only acceptance passed: current Flux and Helm state, one Ready Pod, private Service and route, policy, retained attachment volume, Gatus, alerts, and automation-data logical backup freshness match their contracts.'
