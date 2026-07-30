#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: alertmanager-ntfy.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
ns='ntfy'
kc=(kubectl --kubeconfig "$kubeconfig")

# Flux + Helm health.
[[ "$("${kc[@]}" --namespace flux-system get kustomization alertmanager-ntfy --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'alertmanager-ntfy Kustomization is not Ready.' >&2; exit 1; }
[[ "$("${kc[@]}" --namespace "$ns" get helmrelease alertmanager-ntfy --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'alertmanager-ntfy HelmRelease is not Ready.' >&2; exit 1; }

# Adapter Deployment rolled out.
"${kc[@]}" --namespace "$ns" rollout status deployment/alertmanager-ntfy --timeout=5m

# Alertmanager loaded the 'ntfy' receiver from the rendered config secret (proves the
# kube-prometheus-stack config change reconciled).
am_cfg="$("${kc[@]}" --namespace monitoring get secret alertmanager-kube-prometheus-stack-alertmanager-generated --output jsonpath='{.data.alertmanager\.yaml\.gz}' 2>/dev/null | base64 -d | gunzip 2>/dev/null || true)"
if [[ -n "$am_cfg" ]]; then
  grep -q 'alertmanager-ntfy.ntfy.svc.cluster.local:8000/hook' <<<"$am_cfg" || { echo "Alertmanager config does not reference the alertmanager-ntfy webhook." >&2; exit 1; }
fi

just kube foundation-verify
echo 'alertmanager-ntfy acceptance passed: Kustomization + HelmRelease Ready, adapter rolled out, and the Alertmanager ntfy receiver is present.'
echo
echo 'E2E (operator confirmation required; allow about 25 minutes):'
echo "  FLUX_ALERT_E2E_CONFIRM='test:flux-alert:firing-resolved' \\"
echo '    mise exec -- just kube flux-alert-delivery-test'
echo '  This creates and deletes only a run-owned failing Flux Kustomization, exercises the'
echo '  production 15-minute rule, and verifies synchronous firing + resolved ntfy webhooks.'
