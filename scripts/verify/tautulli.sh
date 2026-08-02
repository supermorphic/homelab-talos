#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/network.sh

[[ "$#" -eq 1 ]] || { echo 'Usage: tautulli.sh <kubeconfig>' >&2; exit 2; }
kubeconfig="$1"
ns='media'
host='tautulli.lab.supermorphic.com'
gateway_ip="$HOMELAB_GATEWAY_VIP"
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

echo "Tautulli liveness passed: resources Ready, route Accepted, DNS correct, and /status returned exact $service_status through the Service and $gateway_status through the gateway."
