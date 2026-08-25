#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/network.sh
source scripts/lib/flux-alerts.sh

[[ "$#" -eq 1 ]] || {
  echo 'Usage: gatus.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
ns='gatus'
gateway_ip="$HOMELAB_GATEWAY_VIP"
prometheus_base_url='https://prometheus.lab.supermorphic.com'
prometheus_resolve="prometheus.lab.supermorphic.com:443:${gateway_ip}"

[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization gatus --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'Gatus Kustomization is not Ready.' >&2; exit 1; }
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get helmrelease gatus --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'Gatus HelmRelease is not Ready.' >&2; exit 1; }
kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status deployment/gatus --timeout=3m

accepted=false
for _ in {1..18}; do
  route="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get httproute gatus --output json 2>/dev/null)"
  if [[ "$(yq -r '[.status.parents[].conditions[]? | select(.type == "Accepted") | .status] | unique | join(" ")' - <<<"$route")" == 'True' ]]; then accepted=true; break; fi
  sleep 5
done
[[ "$accepted" == 'true' ]] || { echo 'Gatus HTTPRoute is not Accepted.' >&2; exit 1; }

dns_answer=''
for _ in {1..30}; do
  dns_answer="$(dig +short @"$HOMELAB_DNS_RESOLVER" gatus.lab.supermorphic.com A | sort -u)"
  [[ "$dns_answer" == "$gateway_ip" ]] && break
  sleep 10
done
[[ "$dns_answer" == "$gateway_ip" ]] || { echo "Pi-hole returned '$dns_answer' for gatus, not $gateway_ip." >&2; exit 1; }
curl --silent --show-error --fail --max-time 15 --resolve "gatus.lab.supermorphic.com:443:$gateway_ip" https://gatus.lab.supermorphic.com/health >/dev/null

echo_metric_response="$(
  flux_alerts_prometheus_query \
    "$prometheus_base_url" \
    "$prometheus_resolve" \
    'gatus_results_endpoint_success{group="Platform",name="echo"}'
)"
[[ "$(yq -r '.status // ""' <<<"$echo_metric_response")" == 'success' ]]
[[ "$(yq -r '.data.result | length' <<<"$echo_metric_response")" == '1' ]]
[[ "$(yq -r '.data.result[0].metric.group' <<<"$echo_metric_response")" == 'Platform' ]]
[[ "$(yq -r '.data.result[0].metric.name' <<<"$echo_metric_response")" == 'echo' ]]
[[ "$(yq -r '.data.result[0].value[1]' <<<"$echo_metric_response")" == '1' ]]

just kube foundation-verify
echo 'Gatus acceptance passed: Kustomization and HelmRelease Ready, deployment rolled out (in-memory storage), HTTPRoute accepted, and the dashboard reachable with trusted HTTPS at gatus.lab.supermorphic.com. The deployed echo Gatus result proves ordinary DNS, trusted production wildcard TLS, the internal Gateway, route, Service, and backend.'
