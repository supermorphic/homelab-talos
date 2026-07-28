#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/network.sh

[[ "$#" -eq 1 ]] || {
  echo 'Usage: plex.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
ns='media'
gateway_ip='192.168.90.30'
host='plex.lab.supermorphic.com'

[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization plex --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
  echo 'plex Kustomization is not Ready.' >&2
  exit 1
}
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get helmrelease plex --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
  echo 'plex HelmRelease is not Ready.' >&2
  exit 1
}
kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status deployment/plex --timeout=5m

accepted=false
for _ in {1..24}; do
  if [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get httproute plex --output jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" == 'True' ]]; then
    accepted=true
    break
  fi
  sleep 5
done
[[ "$accepted" == 'true' ]] || { echo 'plex HTTPRoute was not Accepted.' >&2; exit 1; }

[[ "$(dig +short @"$HOMELAB_DNS_RESOLVER" "$host" A | sort -u)" == "$gateway_ip" ]] || {
  echo "DNS for $host does not resolve to $gateway_ip via Pi-hole." >&2
  exit 1
}
curl --silent --fail --resolve "$host:443:$gateway_ip" "https://$host/identity" >/dev/null || {
  echo "Plex /identity is not reachable via the internal gateway." >&2
  exit 1
}
echo 'Phase 11 Plex acceptance passed: Kustomization + HelmRelease Ready, rollout complete, HTTPRoute Accepted, DNS resolves, /identity reachable over TLS. Run the node-failure reschedule test in docs/phase-11-media.md.'
