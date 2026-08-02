#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/network.sh
source scripts/lib/flux-alerts.sh

[[ "$#" -eq 1 ]] || { echo 'Usage: tautulli.sh <kubeconfig>' >&2; exit 2; }
kubeconfig="$1"
ns='media'
host='tautulli.lab.supermorphic.com'
gateway_ip="$HOMELAB_GATEWAY_VIP"
prometheus_base_url='https://prometheus.lab.supermorphic.com'
prometheus_resolve="prometheus.lab.supermorphic.com:443:${gateway_ip}"
expected_rules=(
  MediaEndpointDown
  MediaEndpointsProbeMissing
  PlexProbeMissing
  TautulliProbeMissing
  PlexPersistentVolumeClaimNotBound
  TautulliPersistentVolumeClaimNotBound
)
kc=(kubectl --kubeconfig "$kubeconfig")
if "${kc[@]}" config get-contexts homelab-diagnostic --no-headers >/dev/null 2>&1; then
  kc+=(--context homelab-diagnostic)
fi

[[ "$("${kc[@]}" --namespace flux-system get kustomization tautulli --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'tautulli Kustomization not Ready.' >&2; exit 1; }
[[ "$("${kc[@]}" --namespace "$ns" get helmrelease tautulli --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'tautulli HelmRelease not Ready.' >&2; exit 1; }
"${kc[@]}" --namespace "$ns" rollout status deployment/tautulli --timeout=5m

accepted=false
for _ in {1..24}; do
  [[ "$("${kc[@]}" --namespace "$ns" get httproute tautulli --output jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" == 'True' ]] && { accepted=true; break; }
  sleep 5
done
[[ "$accepted" == 'true' ]] || { echo 'tautulli HTTPRoute was not Accepted.' >&2; exit 1; }
[[ "$(dig +short @"$HOMELAB_DNS_RESOLVER" "$host" A | sort -u)" == "$gateway_ip" ]] || { echo "DNS for $host does not resolve to $gateway_ip." >&2; exit 1; }

# The pinned home-operations Tautulli image includes curl. Execute from the running workload
# so this checks the same Service-DNS path used by in-cluster consumers without depending on
# kube-apiserver's unrelated Service proxy reachability on this kube-proxy-free cluster.
service_status="$("${kc[@]}" --namespace "$ns" exec deployment/tautulli --container app -- \
  curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --max-time 15 --max-redirs 0 \
    http://tautulli.media.svc.cluster.local:8181/status)"
[[ "$service_status" == '200' ]] || { echo "tautulli /status returned $service_status through the in-cluster Service, expected exact 200." >&2; exit 1; }

gateway_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 15 --max-redirs 0 --resolve "$host:443:$gateway_ip" "https://$host/status")"
[[ "$gateway_status" == '200' ]] || { echo "tautulli /status returned $gateway_status through the gateway, expected exact 200." >&2; exit 1; }

metric_response="$(
  flux_alerts_prometheus_query "$prometheus_base_url" "$prometheus_resolve" \
    'gatus_results_endpoint_success{group="Media", name="tautulli"}'
)"
[[ "$(yq -r '.status // ""' <<<"$metric_response")" == 'success' ]]
[[ "$(yq -r '[.data.result[] | select(.metric.group == "Media" and .metric.name == "tautulli")] | length' <<<"$metric_response")" -gt 0 ]] || {
  echo 'Prometheus has no gatus_results_endpoint_success{group="Media", name="tautulli"} series.' >&2
  exit 1
}

rules_response="$(
  flux_alerts_prometheus_get "$prometheus_base_url" "$prometheus_resolve" \
    '/api/v1/rules?type=alert'
)"
[[ "$(yq -r '.status // ""' <<<"$rules_response")" == 'success' ]]
expected_rules_csv="$(IFS=,; echo "${expected_rules[*]}")"
mapfile -t media_rule_rows < <(
  EXPECTED_RULES="$expected_rules_csv" yq -r '
    .data.groups[]?.rules[]? |
    select(.name as $name | (strenv(EXPECTED_RULES) | split(",") | contains([$name]))) |
    [.name, (.health // "unknown"), (.lastError // "")] | @tsv
  ' <<<"$rules_response"
)
[[ "${#media_rule_rows[@]}" -eq "${#expected_rules[@]}" ]] || {
  echo "Prometheus loaded ${#media_rule_rows[@]} of ${#expected_rules[@]} expected media rules." >&2
  exit 1
}
loaded_names="$(printf '%s\n' "${media_rule_rows[@]}" | cut -f1 | sort)"
expected_names="$(printf '%s\n' "${expected_rules[@]}" | sort)"
[[ "$loaded_names" == "$expected_names" ]]
for row in "${media_rule_rows[@]}"; do
  IFS=$'\t' read -r rule_name rule_health rule_error <<<"$row"
  [[ "$rule_health" == 'ok' && -z "$rule_error" ]] || {
    echo "Prometheus rule $rule_name is unhealthy: ${rule_error:-no error text}." >&2
    exit 1
  }
done

echo "Tautulli monitoring passed: resources Ready, route Accepted, DNS correct, /status returned exact $service_status through the Service and $gateway_status through the gateway, the Tautulli Gatus series exists, and all six expected loaded rules are healthy."
