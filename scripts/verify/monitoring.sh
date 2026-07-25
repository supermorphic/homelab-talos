#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: monitoring.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
ns='monitoring'
gateway_ip='192.168.90.30'

for k in kube-prometheus-stack kube-prometheus-stack-config; do
  [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$k" --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
    echo "Monitoring Kustomization $k is not Ready." >&2
    exit 1
  }
done
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get helmrelease kube-prometheus-stack --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
  echo 'kube-prometheus-stack HelmRelease is not Ready.' >&2
  exit 1
}

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
  dns_answer="$(dig +short @192.168.90.2 grafana.lab.supermorphic.com A | sort -u)"
  [[ "$dns_answer" == "$gateway_ip" ]] && break
  sleep 10
done
[[ "$dns_answer" == "$gateway_ip" ]] || { echo "Pi-hole returned '$dns_answer' for grafana, not $gateway_ip." >&2; exit 1; }
for host in prometheus alertmanager; do
  [[ "$(dig +short @192.168.90.2 "$host.lab.supermorphic.com" A | sort -u)" == "$gateway_ip" ]] || { echo "Pi-hole has no $gateway_ip record for $host." >&2; exit 1; }
done

health="$(curl --silent --show-error --fail --max-time 15 --resolve "grafana.lab.supermorphic.com:443:$gateway_ip" https://grafana.lab.supermorphic.com/api/health)"
[[ "$(yq -r '.database' - <<<"$health")" == 'ok' ]] || { echo "Grafana /api/health not ok: $health" >&2; exit 1; }
curl --silent --show-error --fail --max-time 15 --resolve "prometheus.lab.supermorphic.com:443:$gateway_ip" https://prometheus.lab.supermorphic.com/-/healthy >/dev/null
curl --silent --show-error --fail --max-time 15 --resolve "alertmanager.lab.supermorphic.com:443:$gateway_ip" https://alertmanager.lab.supermorphic.com/-/healthy >/dev/null

just kube foundation-verify
echo 'Phase 10 monitoring acceptance passed: kube-prometheus-stack Ready (Prometheus, Alertmanager, Grafana, exporters), PVCs bound on Longhorn, HTTPRoutes accepted, and all three UIs reachable with trusted HTTPS through the internal gateway.'
