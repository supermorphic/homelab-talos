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

flux_alerts_source
assert_eq kube-prometheus-stack-kube-state-metrics "$flux_alerts_service" 'production service identity'
assert_eq kube-prometheus-stack-kube-state-metrics "$flux_alerts_deployment" 'production deployment identity'
assert_eq kube-prometheus-stack-kube-state-metrics "$flux_alerts_serviceaccount" 'production ServiceAccount identity'
assert_eq kube-prometheus-stack "$flux_alerts_release" 'production release identity'
assert_eq kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml \
  "$flux_alerts_values" 'production values identity'
assert_eq '."kube-state-metrics"' "$flux_alerts_values_root" 'production values root'
assert_eq 'gotk_resource_info{service="kube-prometheus-stack-kube-state-metrics",namespace="monitoring"}' \
  "$(flux_alerts_metric_selector)" 'production metric selector'
assert_eq 'app.kubernetes.io/name=kube-state-metrics,app.kubernetes.io/instance=kube-prometheus-stack' \
  "$(flux_alerts_workload_selector)" 'bundled workload selector'
assert_eq $'helm.toolkit.fluxcd.io\tv2\tHelmRelease\nkustomize.toolkit.fluxcd.io\tv1\tKustomization\nsource.toolkit.fluxcd.io\tv1\tGitRepository\nsource.toolkit.fluxcd.io\tv1\tHelmRepository\nsource.toolkit.fluxcd.io\tv1\tOCIRepository' \
  "$(flux_alerts_configured_gvks "$flux_alerts_values" "$flux_alerts_values_root" | sort)" \
  'bundled configured GVKs'
assert_eq $'helm.toolkit.fluxcd.io\tv2\tHelmRelease\nkustomize.toolkit.fluxcd.io\tv1\tKustomization\nsource.toolkit.fluxcd.io\tv1\tGitRepository\nsource.toolkit.fluxcd.io\tv1\tHelmRepository\nsource.toolkit.fluxcd.io\tv1\tOCIRepository' \
  "$(flux_alerts_configured_gvks kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml '.["kube-state-metrics"]' | sort)" \
  'bundled configured GVKs'

targets_json='{
  "status": "success",
  "data": {
    "activeTargets": [
      {
        "scrapePool": "serviceMonitor/monitoring/kube-prometheus-stack-kube-state-metrics/0",
        "health": "down",
        "lastError": "bundled target failed",
        "discoveredLabels": {
          "__meta_kubernetes_namespace": "monitoring",
          "__meta_kubernetes_service_name": "kube-prometheus-stack-kube-state-metrics"
        }
      },
      {
        "scrapePool": "serviceMonitor/monitoring/other/0",
        "health": "down",
        "lastError": "unrelated",
        "discoveredLabels": {
          "__meta_kubernetes_service_name": "other"
        }
      },
      {
        "scrapePool": "serviceMonitor/monitoring/flux-kube-state-metrics/0",
        "health": "up",
        "lastError": "",
        "discoveredLabels": {
          "__meta_kubernetes_namespace": "monitoring",
          "__meta_kubernetes_service_name": "flux-kube-state-metrics"
        }
      },
      {
        "scrapePool": "serviceMonitor/other/flux-kube-state-metrics/0",
        "health": "down",
        "lastError": "wrong namespace",
        "discoveredLabels": {
          "__meta_kubernetes_namespace": "other",
          "__meta_kubernetes_service_name": "flux-kube-state-metrics"
        }
      }
    ]
  }
}'
assert_eq 1 "$(flux_alerts_target_count "$flux_alerts_service" monitoring <<<"$targets_json")" \
  'target count'
assert_eq down "$(flux_alerts_target_healths "$flux_alerts_service" monitoring <<<"$targets_json")" \
  'bundled target health ignores healthy fallback'
assert_eq 'bundled target failed' "$(flux_alerts_target_errors "$flux_alerts_service" monitoring <<<"$targets_json")" \
  'bundled target errors ignore healthy fallback'

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

bundled_rules_json='{
  "data": {"groups": [{"rules": [
    {"name": "FluxReconciliationFailure", "query": "gotk_resource_info{service=\"kube-prometheus-stack-kube-state-metrics\",namespace=\"monitoring\"}"},
    {"name": "FluxResourceMetricsMissing", "query": "absent(gotk_resource_info{service=\"kube-prometheus-stack-kube-state-metrics\",namespace=\"monitoring\"})"}
  ]}]}
}'
assert_eq true "$(flux_alerts_rules_select_production_source <<<"$bundled_rules_json")" \
  'decoded bundled rules satisfy production source validation'

fallback_rules_json='{
  "data": {"groups": [{"rules": [
    {"name": "FluxReconciliationFailure", "query": "gotk_resource_info{service=\"flux-kube-state-metrics\",namespace=\"monitoring\"}"},
    {"name": "FluxResourceMetricsMissing", "query": "absent(gotk_resource_info{service=\"flux-kube-state-metrics\",namespace=\"monitoring\"})"}
  ]}]}
}'
assert_eq false "$(flux_alerts_rules_select_production_source <<<"$fallback_rules_json")" \
  'fallback rules cannot satisfy bundled production source validation'
mixed_rules_json='{
  "data": {"groups": [{"rules": [
    {"name": "FluxReconciliationFailure", "query": "gotk_resource_info{service=\"kube-prometheus-stack-kube-state-metrics\",namespace=\"monitoring\"} or gotk_resource_info{service=\"flux-kube-state-metrics\",namespace=\"monitoring\"}"},
    {"name": "FluxResourceMetricsMissing", "query": "absent(gotk_resource_info{service=\"kube-prometheus-stack-kube-state-metrics\",namespace=\"monitoring\"}) or absent(gotk_resource_info{service=\"flux-kube-state-metrics\",namespace=\"monitoring\"})"}
  ]}]}
}'
assert_eq false "$(flux_alerts_rules_select_production_source <<<"$mixed_rules_json")" \
  'mixed bundled and fallback rules cannot satisfy production source validation'
other_source_rules_json='{
  "data": {"groups": [{"rules": [
    {"name": "FluxReconciliationFailure", "query": "gotk_resource_info{service=\"kube-prometheus-stack-kube-state-metrics\",namespace=\"monitoring\"} or gotk_resource_info{service=\"other\",namespace=\"monitoring\"}"},
    {"name": "FluxResourceMetricsMissing", "query": "absent(gotk_resource_info{service=\"kube-prometheus-stack-kube-state-metrics\",namespace=\"monitoring\"}) or absent(gotk_resource_info{service=\"other\",namespace=\"monitoring\"})"}
  ]}]}
}'
assert_eq false "$(flux_alerts_rules_select_production_source <<<"$other_source_rules_json")" \
  'other service cannot satisfy production source validation'
unscoped_rules_json='{
  "data": {"groups": [{"rules": [
    {"name": "FluxReconciliationFailure", "query": "gotk_resource_info{service=\"kube-prometheus-stack-kube-state-metrics\",namespace=\"monitoring\"} or gotk_resource_info{customresource_kind=\"Kustomization\"}"},
    {"name": "FluxResourceMetricsMissing", "query": "absent(gotk_resource_info{service=\"kube-prometheus-stack-kube-state-metrics\",namespace=\"monitoring\"}) or absent(gotk_resource_info{customresource_kind=\"Kustomization\"})"}
  ]}]}
}'
assert_eq false "$(flux_alerts_rules_select_production_source <<<"$unscoped_rules_json")" \
  'unscoped selector cannot satisfy production source validation'
rg -Fq 'get helmrelease "$exporter_release"' scripts/diagnose/flux-alerts.sh

kubectl() {
  printf '%s\n' "$*" >>"$diagnostic_requests"
  case "$*" in
  *'get --raw /apis/kustomize.toolkit.fluxcd.io/v1'*)
    printf '%s\n' '{"resources":[{"kind":"Kustomization","name":"kustomizations"}]}'
    ;;
  *'get --raw /apis/helm.toolkit.fluxcd.io/v2'*)
    printf '%s\n' '{"resources":[{"kind":"HelmRelease","name":"helmreleases"}]}'
    ;;
  *'get --raw /apis/source.toolkit.fluxcd.io/v1'*)
    printf '%s\n' '{"resources":[{"kind":"GitRepository","name":"gitrepositories"},{"kind":"HelmRepository","name":"helmrepositories"},{"kind":"OCIRepository","name":"ocirepositories"}]}'
    ;;
  *'create --raw /apis/authorization.k8s.io/v1/subjectaccessreviews -f -'*)
    local request
    request="$(cat)"
    jq -e '
      .apiVersion == "authorization.k8s.io/v1" and .kind == "SubjectAccessReview" and
      .spec.user == "system:serviceaccount:monitoring:kube-prometheus-stack-kube-state-metrics" and
      (.spec.groups | sort) == (["system:serviceaccounts", "system:serviceaccounts:monitoring", "system:authenticated"] | sort) and
      (.spec.resourceAttributes.verb == "list" or .spec.resourceAttributes.verb == "watch") and
      (.spec.resourceAttributes.namespace // "") == "" and
      ((.spec.resourceAttributes.group == "kustomize.toolkit.fluxcd.io" and
        .spec.resourceAttributes.resource == "kustomizations") or
       (.spec.resourceAttributes.group == "helm.toolkit.fluxcd.io" and
        .spec.resourceAttributes.resource == "helmreleases") or
       (.spec.resourceAttributes.group == "source.toolkit.fluxcd.io" and
        (.spec.resourceAttributes.resource | IN("gitrepositories", "helmrepositories", "ocirepositories"))) or
       (.spec.resourceAttributes.group == "apiextensions.k8s.io" and
        .spec.resourceAttributes.resource == "customresourcedefinitions"))
    ' <<<"$request" >/dev/null || return 64
    jq -c . <<<"$request" >>"$review_requests"
    case "${review_fixture_mode:-allowed}" in
      allowed) printf '%s\n' '{"status":{"allowed":true,"denied":false}}' ;;
      denied) printf '%s\n' '{"status":{"allowed":false,"denied":true}}' ;;
      evaluation-error) printf '%s\n' '{"status":{"allowed":true,"evaluationError":"synthetic authorizer failure"}}' ;;
      malformed) printf '%s\n' '{"status":{"allowed":"true"}}' ;;
      contradictory) printf '%s\n' '{"status":{"allowed":true,"denied":true}}' ;;
      missing-status) printf '%s\n' '{}' ;;
      api-error) return 1 ;;
      *) return 64 ;;
    esac
    ;;
  *'get kustomization kube-prometheus-stack'*) printf 'True' ;;
  *'get helmrelease kube-prometheus-stack'*) printf 'True' ;;
  *'get deployment kube-prometheus-stack-kube-state-metrics'*)
    printf '%s\n' '{"spec":{"replicas":1},"status":{"readyReplicas":1}}'
    ;;
  *'get pods --selector '*)
    if [[ "$*" == *'app.kubernetes.io/name=kube-state-metrics,app.kubernetes.io/instance=kube-prometheus-stack'* ]]; then
      printf '%s\n' 'kube-state-metrics-a Running true 0'
    else
      printf '%s\n' 'grafana-a Running true 0'
      printf '%s\n' 'kube-state-metrics-a Running true 0'
    fi
    ;;
  *'logs deployment/kube-prometheus-stack-kube-state-metrics'*) printf '%s\n' 'metrics configured' ;;
  *'/services/kube-prometheus-stack-kube-state-metrics:http/proxy/metrics'*)
    case "${metrics_fixture_mode:-present}" in
      present) printf '%s\n' 'gotk_resource_info{customresource_kind="Kustomization"} 1' ;;
      absent) printf '%s\n' 'process_start_time_seconds 1' ;;
      api-error) return 1 ;;
      *) return 64 ;;
    esac
    ;;
  *)
    echo "Unexpected kubectl request: $*" >&2
    return 64
    ;;
  esac
}
kubeconfig='/tmp/fixture-kubeconfig'
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-flux-alerts-diagnostics-test.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT
diagnostic_requests="$temp_dir/requests"
review_requests="$temp_dir/reviews"
stage_exporter_workload >"$temp_dir/workload.log"
rg -Fq 'pod kube-state-metrics-a Running true 0' "$temp_dir/workload.log"
if rg -q 'grafana-a' "$temp_dir/workload.log"; then
  echo 'Workload check selected an unrelated Pod.' >&2
  exit 1
fi
stage_exporter_raw_metric
assert_eq true "$raw_metric_present" 'present native Flux metric'
for metrics_fixture_mode in absent api-error; do
  raw_metric_present=true
  if stage_exporter_raw_metric >"$temp_dir/metrics-$metrics_fixture_mode.log" 2>&1; then
    echo 'Raw exporter check accepted an absent metric or failed Service proxy.' >&2
    exit 1
  fi
  assert_eq false "$raw_metric_present" 'failure clears the previous metric result'
done
rg -Fq 'No config telemetry is exposed on the named Service' "$temp_dir/metrics-absent.log"
metrics_fixture_mode=present

mapfile -t configured_gvks < <(flux_alerts_configured_gvks "$flux_alerts_values" "$flux_alerts_values_root")
for review_fixture_mode in allowed denied evaluation-error malformed contradictory missing-status api-error; do
  : >"$review_requests"
  if stage_exporter_rbac >"$temp_dir/review-$review_fixture_mode.log" 2>&1; then
    [[ "$review_fixture_mode" == allowed ]] || {
      echo 'Exporter permission check accepted a denied or ambiguous review.' >&2
      exit 1
    }
  else
    [[ "$review_fixture_mode" != allowed ]] || {
      echo 'Exporter permission check could not use authorization reviews.' >&2
      exit 1
    }
  fi
  assert_eq 12 "$(wc -l <"$review_requests" | tr -d ' ')" 'one review per list/watch permission'
  jq -se 'length == 12 and
    (unique_by([.spec.resourceAttributes.group, .spec.resourceAttributes.resource,
      .spec.resourceAttributes.verb]) | length) == 12' "$review_requests" >/dev/null
done
if rg -q -- '--as=|/pods/[^ ]*/proxy/|auth can-i' "$diagnostic_requests"; then
  echo 'Observation attempted impersonation or an unrestricted Pod proxy.' >&2
  exit 1
fi

curl() {
  printf '%s\n' "$*" >>"$temp_dir/http-requests"
  case "${*: -1}" in
    */-/healthy) return 0 ;;
    */api/v1/alertmanagers) printf '%s\n' "$alertmanagers_json" ;;
    */api/v2/status)
      local config='receivers: [{name: ntfy, webhook_configs: [{url: "http://example.invalid/webhook"}]}]
route: {routes: [{receiver: ntfy, matchers: ["severity=~\"critical|warning\""]}]}'
      case "$alertmanager_fixture_mode" in
        loaded) ;;
        missing-config) printf '%s\n' '{}'; return ;;
        malformed-status) printf '%s\n' '{'; return ;;
        api-error) return 22 ;;
        missing-receiver) config="$(yq '.receivers = []' <<<"$config")" ;;
        missing-webhook) config="$(yq '.receivers[0].webhook_configs = []' <<<"$config")" ;;
        missing-route) config="$(yq '.route.routes = []' <<<"$config")" ;;
        wrong-severity) config="$(yq '.route.routes[0].matchers = ["severity=\"info\""]' <<<"$config")" ;;
        *) return 64 ;;
      esac
      jq -n --arg config "$config" '{config: {original: $config}}'
      ;;
    *) echo "Unexpected HTTP request: ${*: -1}" >&2; return 64 ;;
  esac
}
for alertmanager_fixture_mode in loaded missing-config malformed-status api-error \
  missing-receiver missing-webhook missing-route wrong-severity; do
  if stage_alertmanager >"$temp_dir/alertmanager-$alertmanager_fixture_mode.log" 2>&1; then
    [[ "$alertmanager_fixture_mode" == loaded ]] || {
      echo "Alertmanager stage accepted $alertmanager_fixture_mode." >&2
      exit 1
    }
  else
    [[ "$alertmanager_fixture_mode" != loaded ]] || {
      echo 'Alertmanager stage could not inspect its loaded configuration without Secret access.' >&2
      exit 1
    }
  fi
done
rg -Fq 'Alertmanager receiver ntfy=loaded' "$temp_dir/alertmanager-loaded.log"
rg -Fq 'severity warning/critical route to ntfy=loaded' "$temp_dir/alertmanager-loaded.log"
if rg -q 'get secret|get secrets' "$diagnostic_requests"; then
  echo 'Alertmanager stage attempted to read a Kubernetes Secret.' >&2
  exit 1
fi

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
