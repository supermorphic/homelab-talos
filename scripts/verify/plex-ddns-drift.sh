#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source scripts/lib/network.sh
# shellcheck disable=SC1091
source scripts/lib/flux-alerts.sh

[[ "$#" -eq 1 ]] || { echo 'Usage: plex-ddns-drift.sh <kubeconfig>' >&2; exit 2; }
kubeconfig="$1"
[[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }

ns='monitoring'
name='plex-ddns-drift'
prometheus_base_url='https://prometheus.lab.supermorphic.com'
prometheus_resolve="prometheus.lab.supermorphic.com:443:${HOMELAB_GATEWAY_VIP}"
alertmanager_base_url='https://alertmanager.lab.supermorphic.com'
alertmanager_resolve="alertmanager.lab.supermorphic.com:443:${HOMELAB_GATEWAY_VIP}"

state="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$name" --output json)"
[[ "$(yq -r '.spec.suspend // false' - <<<"$state")" == 'false' ]]
[[ "$(yq -r '[.status.conditions[]? | select(.type == "Ready") | .status] | unique | join(" ")' - <<<"$state")" == 'True' ]] || {
  echo 'plex-ddns-drift Kustomization is not active and Ready.' >&2
  exit 1
}
kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status "deployment/$name" --timeout=5m
replicas="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get deployment "$name" --output json | yq -r '[.spec.replicas, (.status.availableReplicas // 0)] | join(" ")')"
[[ "$replicas" == '1 1' ]] || { echo 'plex-ddns-drift Deployment is not 1/1 available.' >&2; exit 1; }
kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get servicemonitor "$name" >/dev/null
kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get prometheusrule "$name" >/dev/null

targets_response="$(flux_alerts_prometheus_get "$prometheus_base_url" "$prometheus_resolve" '/api/v1/targets?state=active')"
[[ "$(flux_alerts_target_count "$name" <<<"$targets_response")" -gt 0 ]]
[[ "$(flux_alerts_target_healths "$name" <<<"$targets_response")" == 'up' ]] || {
  echo 'Prometheus has not discovered an up Plex DDNS drift target.' >&2
  exit 1
}

for metric in plex_ddns_check_success plex_ddns_addresses_match plex_ddns_last_success_unixtime; do
  response="$(flux_alerts_prometheus_query "$prometheus_base_url" "$prometheus_resolve" "$metric")"
  [[ "$(yq -r '.status // ""' - <<<"$response")" == 'success' && "$(yq -r '.data.result | length' - <<<"$response")" -gt 0 ]] || {
    echo "Prometheus has no $metric series." >&2
    exit 1
  }
done

collector_logs="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" logs "deployment/$name" --container collector --since=10m)"
if rg -q '(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)' <<<"$collector_logs"; then
  echo 'Plex DDNS collector logs contain address-shaped text.' >&2
  exit 1
fi

rules_response="$(flux_alerts_prometheus_get "$prometheus_base_url" "$prometheus_resolve" '/api/v1/rules?type=alert')"
loaded_rules="$(yq -r '[.data.groups[]?.rules[]? | select(.name == "PlexDdnsAddressMismatch" or .name == "PlexDdnsCheckFailed" or .name == "PlexDdnsMetricsMissing") | select(.health == "ok" and (.lastError // "") == "") | .name] | unique | sort | join(" ")' - <<<"$rules_response")"
[[ "$loaded_rules" == 'PlexDdnsAddressMismatch PlexDdnsCheckFailed PlexDdnsMetricsMissing' ]] || {
  echo 'Prometheus has not loaded all three healthy Plex DDNS drift alert rules.' >&2
  exit 1
}

alertmanager_status="$(curl --silent --show-error --fail --max-time 15 --resolve "$alertmanager_resolve" "$alertmanager_base_url/api/v2/status")"
alertmanager_config="$(yq -r '.config.original // ""' - <<<"$alertmanager_status")"
yq -r '.route.routes[] | select(.receiver == "ntfy") | .matchers[]' - <<<"$alertmanager_config" |
  rg -q 'severity.*critical.*warning' || {
  echo 'Alertmanager has not loaded the warning route to ntfy.' >&2
  exit 1
}

echo 'Plex DDNS drift verification passed: rollout ready, target up, metrics and alert rules loaded, collector logs address-free, and warnings route to ntfy.'
