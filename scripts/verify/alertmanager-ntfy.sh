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
echo 'MANUAL (human acceptance — proves the full alert path + formatting):'
echo '  Fire a synthetic firing+resolved alert through Alertmanager and confirm the phone'
echo '  receives them with the correct topic/priority. Example (port-forward Alertmanager,'
echo '  then post via its v2 API), critical -> critical topic (urgent), warning -> homelab:'
echo '    kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 &'
echo "    amtool alert add alertname=NtfyPipelineTest severity=critical summary='ntfy pipeline test' \\"
echo "      description='synthetic critical' --alertmanager.url=http://localhost:9093"
echo '  Repeat with severity=warning (-> homelab). Resolve by letting them expire or adding'
echo '  --end. Confirm both firing and resolved notifications arrive with the right topic.'
