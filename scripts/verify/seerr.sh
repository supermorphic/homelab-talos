#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/network.sh

[[ "$#" -eq 1 ]] || {
  echo 'Usage: seerr.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
ns='media'
gateway_ip="$HOMELAB_GATEWAY_VIP"
host='seerr.lab.supermorphic.com'

[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization seerr --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'seerr Kustomization not Ready.' >&2; exit 1; }
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get helmrelease seerr --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'seerr HelmRelease not Ready.' >&2; exit 1; }
kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status deployment/seerr --timeout=5m
accepted=false
for _ in {1..24}; do
  [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get httproute seerr --output jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" == 'True' ]] && { accepted=true; break; }
  sleep 5
done
[[ "$accepted" == 'true' ]] || { echo 'seerr HTTPRoute was not Accepted.' >&2; exit 1; }
[[ "$(dig +short @"$HOMELAB_DNS_RESOLVER" "$host" A | sort -u)" == "$gateway_ip" ]] || { echo "DNS for $host does not resolve to $gateway_ip." >&2; exit 1; }
curl --silent --fail --resolve "$host:443:$gateway_ip" "https://$host/api/v1/status" >/dev/null || { echo 'seerr /api/v1/status not reachable via the gateway.' >&2; exit 1; }
echo 'Phase 14 Seerr acceptance passed. First-run: connect Plex + Sonarr/Radarr (URLs + API keys) in the Seerr UI.'
