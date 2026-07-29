#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/network.sh
source scripts/lib/flux-alerts.sh

[[ "$#" -eq 1 ]] || {
  echo 'Usage: monitoring.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
ns='monitoring'
gateway_ip="$HOMELAB_GATEWAY_VIP"
exporter_name='flux-kube-state-metrics'
exporter_values='kubernetes/apps/monitoring/flux-kube-state-metrics/app/values.yaml'
prometheus_base_url='https://prometheus.lab.supermorphic.com'
prometheus_resolve="prometheus.lab.supermorphic.com:443:${gateway_ip}"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-monitoring-verify.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

for k in kube-prometheus-stack kube-prometheus-stack-config flux-kube-state-metrics; do
  [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$k" --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
    echo "Monitoring Kustomization $k is not Ready." >&2
    exit 1
  }
done
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get helmrelease kube-prometheus-stack --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
  echo 'kube-prometheus-stack HelmRelease is not Ready.' >&2
  exit 1
}
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get helmrelease "$exporter_name" --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
  echo 'flux-kube-state-metrics HelmRelease is not Ready.' >&2
  exit 1
}
kubectl --kubeconfig "$kubeconfig" --namespace "$ns" \
  rollout status "deployment/$exporter_name" --timeout=5m

pvc_json="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pvc --output json)"
[[ "$(yq -r '[.items[] | select(.status.phase == "Bound")] | length' - <<<"$pvc_json")" -ge 3 ]] || { echo 'Expected at least three bound PVCs in monitoring.' >&2; exit 1; }
[[ "$(yq -r '[.items[].status.phase] | unique | join(" ")' - <<<"$pvc_json")" == 'Bound' ]] || { echo 'Not all monitoring PVCs are Bound.' >&2; exit 1; }

for r in grafana prometheus alertmanager; do
  accepted=false
  for _ in {1..18}; do
    route="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get httproute "$r" --output json 2>/dev/null)"
    if [[ "$(yq -r '[.status.parents[].conditions[]? | select(.type == "Accepted") | .status] | unique | join(" ")' - <<<"$route")" == 'True' ]]; then
      accepted=true
      break
    fi
    sleep 5
  done
  [[ "$accepted" == 'true' ]] || {
    echo "HTTPRoute $r is not Accepted; confirm the monitoring namespace carries gateway.supermorphic.com/access=internal and that Envoy Gateway has re-listed it." >&2
    exit 1
  }
done

dns_answer=''
for _ in {1..30}; do
  dns_answer="$(dig +short @"$HOMELAB_DNS_RESOLVER" grafana.lab.supermorphic.com A | sort -u)"
  [[ "$dns_answer" == "$gateway_ip" ]] && break
  sleep 10
done
[[ "$dns_answer" == "$gateway_ip" ]] || { echo "Pi-hole returned '$dns_answer' for grafana, not $gateway_ip." >&2; exit 1; }
for host in prometheus alertmanager; do
  [[ "$(dig +short @"$HOMELAB_DNS_RESOLVER" "$host.lab.supermorphic.com" A | sort -u)" == "$gateway_ip" ]] || { echo "Pi-hole has no $gateway_ip record for $host." >&2; exit 1; }
done

health="$(curl --silent --show-error --fail --max-time 15 --resolve "grafana.lab.supermorphic.com:443:$gateway_ip" https://grafana.lab.supermorphic.com/api/health)"
[[ "$(yq -r '.database' - <<<"$health")" == 'ok' ]] || { echo "Grafana /api/health not ok: $health" >&2; exit 1; }
curl --silent --show-error --fail --max-time 15 --resolve "prometheus.lab.supermorphic.com:443:$gateway_ip" https://prometheus.lab.supermorphic.com/-/healthy >/dev/null
curl --silent --show-error --fail --max-time 15 --resolve "alertmanager.lab.supermorphic.com:443:$gateway_ip" https://alertmanager.lab.supermorphic.com/-/healthy >/dev/null

targets_response="$(
  flux_alerts_prometheus_get "$prometheus_base_url" "$prometheus_resolve" \
    '/api/v1/targets?state=active'
)"
[[ "$(yq -r '.status // ""' <<<"$targets_response")" == 'success' ]] || {
  echo 'Prometheus targets API did not return status=success.' >&2
  exit 1
}
target_count="$(flux_alerts_target_count "$exporter_name" <<<"$targets_response")"
target_healths="$(flux_alerts_target_healths "$exporter_name" <<<"$targets_response")"
[[ "$target_count" -gt 0 ]] || {
  echo 'Prometheus has not discovered the flux-kube-state-metrics scrape target.' >&2
  exit 1
}
[[ "$target_healths" == 'up' ]] || {
  echo "flux-kube-state-metrics Prometheus target health is '${target_healths:-unknown}', not up." >&2
  exit 1
}

metric_response="$(
  flux_alerts_prometheus_query "$prometheus_base_url" "$prometheus_resolve" \
    'gotk_resource_info'
)"
[[ "$(yq -r '.status // ""' <<<"$metric_response")" == 'success' ]] || {
  echo 'Prometheus gotk_resource_info query did not return status=success.' >&2
  exit 1
}
[[ "$(yq -r '.data.result | length' <<<"$metric_response")" -gt 0 ]] || {
  echo 'Prometheus returned no gotk_resource_info series.' >&2
  exit 1
}
metric_kinds="$(flux_alerts_metric_kinds <<<"$metric_response")"
while IFS=$'\t' read -r _group _version expected_kind; do
  [[ -n "$expected_kind" ]] || continue
  rg -Fxq "$expected_kind" <<<"$metric_kinds" || {
    echo "Prometheus gotk_resource_info is missing configured Flux kind $expected_kind." >&2
    exit 1
  }
done < <(flux_alerts_configured_gvks "$exporter_values")

rules_response="$(
  flux_alerts_prometheus_get "$prometheus_base_url" "$prometheus_resolve" \
    '/api/v1/rules?type=alert'
)"
[[ "$(yq -r '.status // ""' <<<"$rules_response")" == 'success' ]] || {
  echo 'Prometheus rules API did not return status=success.' >&2
  exit 1
}
mapfile -t flux_rule_rows < <(
  flux_alerts_rule_rows FluxReconciliationFailure FluxResourceMetricsMissing \
    <<<"$rules_response"
)
[[ "${#flux_rule_rows[@]}" -eq 2 ]] || {
  echo "Prometheus loaded ${#flux_rule_rows[@]} of the two expected Flux alert rules." >&2
  exit 1
}
for row in "${flux_rule_rows[@]}"; do
  IFS=$'\t' read -r rule_name _rule_state rule_health rule_error <<<"$row"
  [[ "$rule_health" == 'ok' && -z "$rule_error" ]] || {
    echo "Prometheus rule $rule_name is unhealthy." >&2
    exit 1
  }
done

alertmanagers_response="$(
  flux_alerts_prometheus_get "$prometheus_base_url" "$prometheus_resolve" \
    '/api/v1/alertmanagers'
)"
[[ "$(yq -r '.status // ""' <<<"$alertmanagers_response")" == 'success' ]] || {
  echo 'Prometheus Alertmanager API did not return status=success.' >&2
  exit 1
}
[[ "$(flux_alerts_active_alertmanager_count <<<"$alertmanagers_response")" -gt 0 ]] || {
  echo 'Prometheus has no active Alertmanager connection.' >&2
  exit 1
}

alertmanager_config="$temp_dir/alertmanager.yaml"
kubectl --kubeconfig "$kubeconfig" --namespace "$ns" \
  get secret alertmanager-kube-prometheus-stack-alertmanager-generated \
  --output jsonpath='{.data.alertmanager\.yaml\.gz}' |
  base64 -d |
  gunzip >"$alertmanager_config"
yq -e '
  .receivers[] |
  select(.name == "ntfy") |
  (.webhook_configs | length) > 0
' "$alertmanager_config" >/dev/null || {
  echo 'Alertmanager has not loaded the expected ntfy receiver.' >&2
  exit 1
}
yq -r '
  .route.routes[] |
  select(.receiver == "ntfy") |
  .matchers[]
' "$alertmanager_config" |
  rg -q 'severity.*critical.*warning' || {
    echo 'Alertmanager has not loaded the expected warning/critical route to ntfy.' >&2
    exit 1
  }

just kube foundation-verify
echo 'Phase 10 monitoring acceptance passed: the stack and Flux exporter are Ready; Prometheus discovered an up exporter target, ingested every configured Flux resource kind, loaded both healthy Flux alert rules, and has an active Alertmanager connection with the expected ntfy route. This does not send or prove external ntfy delivery.'
