#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/network.sh

[[ "$#" -eq 1 ]] || {
  echo 'Usage: alertmanager-ntfy.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
ns='ntfy'
kc=(kubectl --kubeconfig "$kubeconfig")
alertmanager_url='https://alertmanager.lab.supermorphic.com'
alertmanager_resolve="alertmanager.lab.supermorphic.com:443:${HOMELAB_GATEWAY_VIP}"

# Flux + Helm health.
[[ "$("${kc[@]}" --namespace flux-system get kustomization alertmanager-ntfy --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'alertmanager-ntfy Kustomization is not Ready.' >&2; exit 1; }
[[ "$("${kc[@]}" --namespace "$ns" get helmrelease alertmanager-ntfy --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'alertmanager-ntfy HelmRelease is not Ready.' >&2; exit 1; }

# Adapter Deployment rolled out.
"${kc[@]}" --namespace "$ns" rollout status deployment/alertmanager-ntfy --timeout=5m

# Alertmanager's status API exposes the configuration it actually loaded. Checking that
# runtime view preserves the receiver oracle without reading the generated Secret.
status="$(curl --silent --show-error --fail --max-time 15 \
  --resolve "$alertmanager_resolve" "$alertmanager_url/api/v2/status")"
am_cfg="$(yq -r '.config.original // ""' <<<"$status")"
[[ -n "$am_cfg" ]] || { echo 'Alertmanager status API returned no loaded configuration.' >&2; exit 1; }
receiver_count="$(yq -r '[.receivers[]? | select(.name == "ntfy")] | length' <<<"$am_cfg")"
route_count="$(yq -r '[.route.routes[]? | select(.receiver == "ntfy")] | length' <<<"$am_cfg")"
[[ "$receiver_count" -ge 1 && "$route_count" -ge 1 ]] || {
  echo 'Alertmanager loaded config does not contain both the ntfy receiver and route.' >&2
  exit 1
}

just kube foundation-verify
echo 'alertmanager-ntfy acceptance passed: Kustomization + HelmRelease Ready, adapter rolled out, and the Alertmanager ntfy receiver and route are loaded.'
echo
echo 'E2E (operator confirmation required; allow about 25 minutes):'
echo "  FLUX_ALERT_E2E_CONFIRM='test:flux-alert:firing-resolved' \\"
echo '    mise exec -- just kube flux-alert-delivery-test'
echo '  This creates and deletes only a run-owned failing Flux Kustomization, exercises the'
echo '  production 15-minute rule, and verifies synchronous firing + resolved ntfy webhooks.'
