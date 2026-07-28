#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/network.sh

[[ "$#" -eq 1 ]] || {
  echo 'Usage: gatus.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
ns='gatus'
gateway_ip="$HOMELAB_GATEWAY_VIP"

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

just kube foundation-verify
echo 'Phase 10 Gatus acceptance passed: Kustomization and HelmRelease Ready, deployment rolled out (in-memory storage), HTTPRoute accepted, and the dashboard reachable with trusted HTTPS at gatus.lab.supermorphic.com.'
