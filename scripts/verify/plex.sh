#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source scripts/lib/network.sh

[[ "$#" -eq 1 ]] || {
  echo 'Usage: plex.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
kc=(kubectl --kubeconfig "$kubeconfig")
if "${kc[@]}" config get-contexts homelab-diagnostic --no-headers >/dev/null 2>&1; then
  kc+=(--context homelab-diagnostic)
fi
ns='media'
gateway_ip="$HOMELAB_GATEWAY_VIP"
host='plex.lab.supermorphic.com'

[[ "$("${kc[@]}" --namespace flux-system get kustomization plex --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
  echo 'plex Kustomization is not Ready.' >&2
  exit 1
}
[[ "$("${kc[@]}" --namespace "$ns" get helmrelease plex --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
  echo 'plex HelmRelease is not Ready.' >&2
  exit 1
}
"${kc[@]}" --namespace "$ns" rollout status deployment/plex --timeout=5m

pod="$("${kc[@]}" --namespace media get pods \
  --selector app.kubernetes.io/name=plex \
  --field-selector status.phase=Running \
  --output jsonpath='{.items[0].metadata.name}')"
# This single-quoted program expands only inside the Plex container.
# shellcheck disable=SC2016
"${kc[@]}" --namespace media exec "$pod" -c app -- \
  /bin/bash -ceu '
    [[ "$(id -u)" == "568" ]]
    [[ "$(getent passwd 568 | cut -d: -f1)" == "plex" ]]
    [[ ! -e /var/run/secrets/kubernetes.io/serviceaccount/token ]]
    [[ ",$(findmnt -n -o OPTIONS /Volumes/Prometheus)," == *,ro,* ]] || {
      echo "Plex media mount is not read-only." >&2
      exit 1
    }
    [[ -w /config ]]
  '

accepted=false
for _ in {1..24}; do
  if [[ "$("${kc[@]}" --namespace "$ns" get httproute plex --output jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" == 'True' ]]; then
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
echo 'Phase 11 Plex acceptance passed: Kustomization + HelmRelease Ready, rollout complete, UID 568 plex runtime identity, API token absent, media read-only, config writable, HTTPRoute Accepted, DNS resolves, /identity reachable over TLS. Run the node-failure reschedule test in docs/phase-11-media.md.'
