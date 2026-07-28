#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/network.sh

[[ "$#" -eq 2 ]] || {
  echo 'Usage: arr.sh <prowlarr|sonarr|radarr> <kubeconfig>' >&2
  exit 2
}
app="$1"
kubeconfig="$2"
case "$app" in
  prowlarr|sonarr|radarr) ;;
  *)
    echo 'Usage: arr.sh <prowlarr|sonarr|radarr> <kubeconfig>' >&2
    exit 2
    ;;
esac
namespace='media'
gateway_ip='192.168.90.30'
host="$app.lab.supermorphic.com"

[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
  get kustomization "$app" \
  --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
  2>/dev/null)" == 'True' ]] || {
  echo "$app Kustomization not Ready." >&2
  exit 1
}
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
  get helmrelease "$app" \
  --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
  2>/dev/null)" == 'True' ]] || {
  echo "$app HelmRelease not Ready." >&2
  exit 1
}
kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
  rollout status "deployment/$app" --timeout=5m
accepted=false
for _ in {1..24}; do
  if [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
    get httproute "$app" \
    --output jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' \
    2>/dev/null)" == 'True' ]]; then
    accepted=true
    break
  fi
  sleep 5
done
[[ "$accepted" == 'true' ]] || {
  echo "$app HTTPRoute was not Accepted." >&2
  exit 1
}
[[ "$(dig +short @"$HOMELAB_DNS_RESOLVER" "$host" A | sort -u)" == "$gateway_ip" ]] || {
  echo "DNS for $host does not resolve to $gateway_ip." >&2
  exit 1
}
curl --silent --fail --resolve "$host:443:$gateway_ip" \
  "https://$host/ping" >/dev/null || {
  echo "$app /ping not reachable via the gateway." >&2
  exit 1
}
echo "$app live acceptance passed (Ready, rollout, HTTPRoute Accepted, DNS, /ping)."
