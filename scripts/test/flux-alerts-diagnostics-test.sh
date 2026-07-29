#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

source scripts/lib/flux-alerts.sh
# shellcheck disable=SC1091
source scripts/diagnose/flux-alerts.sh

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || {
    echo "$label: expected '$expected', got '$actual'." >&2
    exit 1
  }
}

targets_json='{
  "status": "success",
  "data": {
    "activeTargets": [
      {
        "scrapePool": "serviceMonitor/monitoring/flux-kube-state-metrics/0",
        "health": "up",
        "lastError": "",
        "discoveredLabels": {
          "__meta_kubernetes_service_name": "flux-kube-state-metrics"
        }
      },
      {
        "scrapePool": "serviceMonitor/monitoring/other/0",
        "health": "down",
        "lastError": "unrelated",
        "discoveredLabels": {
          "__meta_kubernetes_service_name": "other"
        }
      }
    ]
  }
}'
assert_eq 1 "$(flux_alerts_target_count flux-kube-state-metrics <<<"$targets_json")" \
  'target count'
assert_eq up "$(flux_alerts_target_healths flux-kube-state-metrics <<<"$targets_json")" \
  'target health'
assert_eq '' "$(flux_alerts_target_errors flux-kube-state-metrics <<<"$targets_json")" \
  'target errors'

metric_json='{
  "status": "success",
  "data": {
    "result": [
      {"metric": {"customresource_kind": "Kustomization"}, "value": [1, "1"]},
      {"metric": {"customresource_kind": "HelmRelease"}, "value": [1, "1"]},
      {"metric": {"customresource_kind": "Kustomization"}, "value": [1, "1"]}
    ]
  }
}'
assert_eq $'HelmRelease\nKustomization' \
  "$(flux_alerts_metric_kinds <<<"$metric_json")" 'metric kinds'

rules_json='{
  "status": "success",
  "data": {
    "groups": [
      {
        "rules": [
          {
            "name": "FluxReconciliationFailure",
            "state": "inactive",
            "health": "ok",
            "lastError": ""
          },
          {
            "name": "FluxResourceMetricsMissing",
            "state": "firing",
            "health": "ok",
            "lastError": ""
          },
          {
            "name": "Unrelated",
            "state": "inactive",
            "health": "ok",
            "lastError": ""
          }
        ]
      }
    ]
  }
}'
rule_rows="$(
  flux_alerts_rule_rows FluxReconciliationFailure FluxResourceMetricsMissing \
    <<<"$rules_json"
)"
assert_eq 2 "$(wc -l <<<"$rule_rows" | tr -d ' ')" 'rule row count'

alertmanagers_json='{
  "status": "success",
  "data": {
    "activeAlertmanagers": [{"url": "http://alertmanager:9093/api/v2/alerts"}],
    "droppedAlertmanagers": []
  }
}'
assert_eq 1 \
  "$(flux_alerts_active_alertmanager_count <<<"$alertmanagers_json")" \
  'active Alertmanager count'

stage_labels=()
stage_results=()
stage_labels+=('Exporter raw metric' 'Prometheus scrape target' 'Prometheus metric')
stage_results+=('PASS' 'FAIL' 'FAIL')
set +e
table="$(print_stage_table)"
table_status="$?"
set -e
assert_eq 1 "$table_status" 'failed stage table status'
rg -q '^Prometheus scrape target[[:space:]]+FAIL$' <<<"$table"
rg -Uq $'^First broken stage:\nPrometheus scrape target$' <<<"$table"

echo 'Flux alert diagnostic parsing and first-boundary reporting tests passed.'
