#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/network.sh

[[ "$#" -eq 1 ]] || {
  echo 'Usage: qbittorrent.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
ns='media'
gateway_ip="$HOMELAB_GATEWAY_VIP"
host='qbittorrent.lab.supermorphic.com'

[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization qbittorrent --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'qbittorrent Kustomization not Ready.' >&2; exit 1; }
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get helmrelease qbittorrent --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'qbittorrent HelmRelease not Ready.' >&2; exit 1; }
kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status deployment/qbittorrent --timeout=5m
accepted=false
for _ in {1..24}; do
  [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get httproute qbittorrent --output jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" == 'True' ]] && { accepted=true; break; }
  sleep 5
done
[[ "$accepted" == 'true' ]] || { echo 'qbittorrent HTTPRoute was not Accepted.' >&2; exit 1; }
[[ "$(dig +short @"$HOMELAB_DNS_RESOLVER" "$host" A | sort -u)" == "$gateway_ip" ]] || { echo "DNS for $host does not resolve to $gateway_ip." >&2; exit 1; }
curl --silent --fail --resolve "$host:443:$gateway_ip" "https://$host/" >/dev/null || { echo 'qBittorrent WebUI not reachable via the gateway.' >&2; exit 1; }
echo 'qBittorrent live acceptance passed: Flux and Helm are Ready, the Deployment rolled out, the HTTPRoute is Accepted, DNS is correct, and the WebUI is reachable.'
