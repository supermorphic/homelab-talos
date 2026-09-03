#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
source scripts/lib/flux-alerts.sh
source scripts/lib/longhorn-verification.sh
source scripts/lib/n8n-verification.sh
source scripts/lib/network.sh
require_bash

[[ "$#" -eq 1 ]] || {
  echo 'Usage: automation-data.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
namespace='automation-data'
longhorn_namespace='longhorn-system'
prometheus_base_url='https://prometheus.lab.supermorphic.com'
prometheus_resolve="prometheus.lab.supermorphic.com:443:${HOMELAB_GATEWAY_VIP}"
kc=(kubectl --kubeconfig "$kubeconfig")

[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
  exit 1
}

require_ready_kustomization() {
  local name="$1" state
  state="$("${kc[@]}" --namespace flux-system get kustomization "$name" --output json)"
  n8n_flux_resource_current_ready <(printf '%s\n' "$state") || {
    echo "Flux Kustomization $name is suspended, stale, or not Ready." >&2
    exit 1
  }
}

for name in automation-data automation-data-postgresql monitoring-alerts \
  kube-prometheus-stack-config longhorn; do
  require_ready_kustomization "$name"
done

statefulset_state="$(
  "${kc[@]}" --namespace "$namespace" get statefulset \
    automation-data-postgresql --output json
)"
n8n_statefulset_current_ready <(printf '%s\n' "$statefulset_state") || {
  echo 'The automation-data PostgreSQL StatefulSet has not completed its current revision.' >&2
  exit 1
}

pvc_json="$(
  "${kc[@]}" --namespace "$namespace" get persistentvolumeclaims \
    automation-data-postgresql-data automation-data-postgresql-backups --output json
)"
[[ "$(yq -r '[.items[].metadata.name] | sort | join(",")' - <<<"$pvc_json")" == \
  'automation-data-postgresql-backups,automation-data-postgresql-data' && \
  "$(yq -r '[.items[].metadata.uid | select(. != "")] | length' - <<<"$pvc_json")" == '2' && \
  "$(yq -r '[.items[].status.phase] | unique | join(",")' - <<<"$pvc_json")" == 'Bound' && \
  "$(yq -r '[.items[].spec.volumeName | select(. != "")] | length' - <<<"$pvc_json")" == '2' ]] || {
  echo 'The two retained automation-data claims are not present, identified, and Bound.' >&2
  exit 1
}

service_json="$(
  "${kc[@]}" --namespace "$namespace" get service automation-data-postgresql --output json
)"
[[ "$(yq -r '[
    .spec.type,
    (.spec.clusterIP != "" and .spec.clusterIP != "None"),
    (.spec.selector."app.kubernetes.io/name"),
    ([.spec.ports[] | [.name, (.port | tostring), (.targetPort | tostring)] | join("/")] | sort | join(","))
  ] | join("|")' - <<<"$service_json")" == \
  'ClusterIP|true|automation-data-postgresql|metrics/9399/metrics,postgresql/5432/postgresql' ]] || {
  echo 'The live automation-data PostgreSQL Service differs from its private two-port contract.' >&2
  exit 1
}

monitor_json="$(
  "${kc[@]}" --namespace "$namespace" get servicemonitor.monitoring.coreos.com \
    automation-data-postgresql --output json
)"
[[ "$(yq -r '[
    .spec.selector.matchLabels."app.kubernetes.io/name",
    .spec.endpoints[0].port,
    .spec.endpoints[0].path,
    .spec.endpoints[0].interval
  ] | join("|")' - <<<"$monitor_json")" == \
  'automation-data-postgresql|metrics|/metrics|1m' ]] || {
  echo 'The live automation-data ServiceMonitor differs from its exact scrape contract.' >&2
  exit 1
}

targets_response=''
target_ready=false
for _attempt in {1..18}; do
  if targets_response="$(
    flux_alerts_prometheus_get "$prometheus_base_url" "$prometheus_resolve" \
      '/api/v1/targets?state=active'
  )" && TARGET_POOL="serviceMonitor/$namespace/automation-data-postgresql/0" \
    yq -e '
      .status == "success" and
      ([.data.activeTargets[]? | select(
        .scrapePool == strenv(TARGET_POOL) and
        .labels.namespace == "automation-data" and
        .labels.service == "automation-data-postgresql" and
        .labels.endpoint == "metrics" and
        .health == "up" and
        (.lastError // "") == ""
      )] | length) == 1
    ' >/dev/null 2>&1 <<<"$targets_response"; then
    target_ready=true
    break
  fi
  (( _attempt == 18 )) || sleep 10
done
[[ "$target_ready" == 'true' ]] || {
  echo 'The automation-data PostgreSQL Prometheus target is absent, duplicated, or unhealthy.' >&2
  exit 1
}

rules_response="$(
  flux_alerts_prometheus_get "$prometheus_base_url" "$prometheus_resolve" \
    '/api/v1/rules?type=alert'
)"
expected_rules=$'AutomationDataPostgresqlBackupJobFailed\nAutomationDataPostgresqlBackupJobOverdue\nAutomationDataPostgresqlBackupStale\nAutomationDataPostgresqlContainerOomKilled\nAutomationDataPostgresqlContainerRestarting\nAutomationDataPostgresqlPersistentVolumeClaimNotBound\nAutomationDataPostgresqlPersistentVolumeUsageCritical\nAutomationDataPostgresqlPersistentVolumeUsageWarning\nAutomationDataPostgresqlProvisioningStuck\nAutomationDataPostgresqlRegistryCatalogInconsistent\nAutomationDataPostgresqlUnavailable\nAutomationDataPostgresqlWorkloadUnavailable'
actual_rules="$(yq -r '
  [.data.groups[]? | select(.name == "automation-data-postgresql") | .rules[]?.name] |
  sort | .[]
' - <<<"$rules_response")"
rule_health="$(yq -r '
  [.data.groups[]? | select(.name == "automation-data-postgresql") | .rules[]? |
    [(.health // ""), (.lastError // "")] | join("|")] | unique | join(",")
' - <<<"$rules_response")"
[[ "$(yq -r '.status // ""' - <<<"$rules_response")" == 'success' && \
  "$actual_rules" == "$expected_rules" && "$rule_health" == 'ok|' ]] || {
  echo 'The loaded automation-data alert group differs from the exact healthy 12-rule contract.' >&2
  exit 1
}

dashboard_configmaps="$(
  "${kc[@]}" --namespace monitoring get configmaps \
    --selector grafana_dashboard=1 --output json
)"
[[ "$(yq -r '[.items[] | select(
  .data."automation-data-postgresql.json" != null
)] | length' - <<<"$dashboard_configmaps")" == '1' ]] || {
  echo 'Grafana has not loaded exactly one automation-data PostgreSQL dashboard ConfigMap.' >&2
  exit 1
}

query_single_value() {
  local query="$1" response
  response="$(
    flux_alerts_prometheus_query "$prometheus_base_url" "$prometheus_resolve" "$query"
  )" || return 1
  yq -r '
    select(.status == "success" and (.data.result | length) == 1) |
    .data.result[0].value[1]
  ' - <<<"$response"
}

backup_timestamp="$(query_single_value \
  'automation_data_postgresql_backup_last_success_timestamp_seconds{namespace="automation-data",service="automation-data-postgresql"}')"
# shellcheck disable=SC2016 # yq evaluates $value and now.
[[ "$(VALUE="$backup_timestamp" yq -n -r '
  env(VALUE) | tonumber as $value |
  ($value >= (now | to_unix) - 129600 and $value <= (now | to_unix))
')" == 'true' ]] || {
  echo 'The validated automation-data backup freshness series is absent or older than 36 hours.' >&2
  exit 1
}

registry_consistent="$(query_single_value \
  'automation_data_postgresql_registry_catalog_consistent{namespace="automation-data",service="automation-data-postgresql"}')"
[[ "$registry_consistent" == '1' ]] || {
  echo 'The automation-data registry and PostgreSQL catalog consistency series is not healthy.' >&2
  exit 1
}

incomplete_age="$(query_single_value \
  'automation_data_postgresql_oldest_incomplete_provisioning_age_seconds{namespace="automation-data",service="automation-data-postgresql"}')"
# shellcheck disable=SC2016 # yq evaluates $value.
[[ "$(VALUE="$incomplete_age" yq -n -r '
  env(VALUE) | tonumber as $value | ($value >= 0 and $value <= 1800)
')" == 'true' ]] || {
  echo 'An automation-data provisioning or rotation operation has been incomplete for more than 30 minutes.' >&2
  exit 1
}

longhorn_volumes="$(
  "${kc[@]}" --namespace "$longhorn_namespace" get volumes.longhorn.io --output json
)"
while IFS=$'\t' read -r claim volume; do
  mode='active'
  [[ "$claim" == 'automation-data-postgresql-backups' ]] && mode='retained-backup'
  [[ -n "$claim" && -n "$volume" ]] || {
    echo 'A retained automation-data claim has no bound Longhorn volume identity.' >&2
    exit 1
  }
  longhorn_volume_matches_claim_health \
    "$namespace" "$claim" "$volume" "$mode" \
    <(printf '%s\n' "$longhorn_volumes") || {
    echo "The Longhorn volume for $namespace/$claim is absent or unhealthy." >&2
    exit 1
  }
done < <(yq -r '.items[] | [.metadata.name, .spec.volumeName] | @tsv' - <<<"$pvc_json")

echo 'automation-data read-only acceptance passed: Flux and the current StatefulSet are Ready; both retained claims and Longhorn volumes are healthy; the private Service, scrape target, 12 alert rules, dashboard, backup freshness, registry consistency, and incomplete-operation age match their contracts.'
