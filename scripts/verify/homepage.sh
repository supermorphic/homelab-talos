#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/network.sh

[[ "$#" -eq 1 ]] || {
  echo 'Usage: homepage.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
ns='homepage'
gateway_ip="$HOMELAB_GATEWAY_VIP"

[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization homepage --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'Homepage Kustomization is not Ready.' >&2; exit 1; }
kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status deployment/homepage --timeout=5m

accepted=false
for _ in {1..18}; do
  route="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get httproute homepage --output json 2>/dev/null)"
  if [[ "$(yq -r '[.status.parents[].conditions[]? | select(.type == "Accepted") | .status] | unique | join(" ")' - <<<"$route")" == 'True' ]]; then accepted=true; break; fi
  sleep 5
done
[[ "$accepted" == 'true' ]] || { echo 'Homepage HTTPRoute is not Accepted.' >&2; exit 1; }

homepage_pod="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pods \
  --selector app.kubernetes.io/name=homepage \
  --field-selector status.phase=Running \
  --output jsonpath='{.items[0].metadata.name}')"
[[ -n "$homepage_pod" ]] || { echo 'Homepage has no running pod.' >&2; exit 1; }
kubectl --kubeconfig "$kubeconfig" --namespace "$ns" exec "$homepage_pod" -- \
  test -f /app/public/icons/allure.svg

dns_answer=''
for _ in {1..30}; do
  dns_answer="$(dig +short @"$HOMELAB_DNS_RESOLVER" homepage.lab.supermorphic.com A | sort -u)"
  [[ "$dns_answer" == "$gateway_ip" ]] && break
  sleep 10
done
[[ "$dns_answer" == "$gateway_ip" ]] || { echo "Pi-hole returned '$dns_answer' for homepage, not $gateway_ip." >&2; exit 1; }
curl --silent --show-error --fail --max-time 15 --resolve "homepage.lab.supermorphic.com:443:$gateway_ip" https://homepage.lab.supermorphic.com/ >/dev/null
allure_icon="$(curl --silent --show-error --fail --max-time 15 \
  --resolve "homepage.lab.supermorphic.com:443:$gateway_ip" \
  https://homepage.lab.supermorphic.com/icons/allure.svg)"
rg -q '<svg([[:space:]>])' <<<"$allure_icon" || {
  echo 'Homepage /icons/allure.svg did not return SVG content.' >&2
  exit 1
}

just kube foundation-verify
echo 'Phase 10 Homepage acceptance passed: Kustomization Ready, deployment rolled out, HTTPRoute accepted, Allure icon mounted and served, and the dashboard reachable with trusted HTTPS at homepage.lab.supermorphic.com.'
