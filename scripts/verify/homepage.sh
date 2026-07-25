#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: homepage.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
ns='homepage'
gateway_ip='192.168.90.30'

[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization homepage --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'Homepage Kustomization is not Ready.' >&2; exit 1; }
kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status deployment/homepage --timeout=5m

accepted=false
for _ in {1..18}; do
  route="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get httproute homepage --output json 2>/dev/null)"
  if [[ "$(yq -r '[.status.parents[].conditions[]? | select(.type == "Accepted") | .status] | unique | join(" ")' - <<<"$route")" == 'True' ]]; then accepted=true; break; fi
  sleep 5
done
[[ "$accepted" == 'true' ]] || { echo 'Homepage HTTPRoute is not Accepted.' >&2; exit 1; }

dns_answer=''
for _ in {1..30}; do
  dns_answer="$(dig +short @192.168.90.2 homepage.lab.supermorphic.com A | sort -u)"
  [[ "$dns_answer" == "$gateway_ip" ]] && break
  sleep 10
done
[[ "$dns_answer" == "$gateway_ip" ]] || { echo "Pi-hole returned '$dns_answer' for homepage, not $gateway_ip." >&2; exit 1; }
curl --silent --show-error --fail --max-time 15 --resolve "homepage.lab.supermorphic.com:443:$gateway_ip" https://homepage.lab.supermorphic.com/ >/dev/null

just kube foundation-verify
echo 'Phase 10 Homepage acceptance passed: Kustomization Ready, deployment rolled out, HTTPRoute accepted, and the dashboard reachable with trusted HTTPS at homepage.lab.supermorphic.com.'
