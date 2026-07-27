#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: tailscale-operator.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
ns='tailscale'

# Flux and Helm health.
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization tailscale-operator --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'Tailscale operator Kustomization is not Ready.' >&2; exit 1; }
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get helmrelease tailscale-operator --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'Tailscale operator HelmRelease is not Ready.' >&2; exit 1; }

# Operator Deployment rolled out.
kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status deployment/operator --timeout=5m

# ProxyGroup exists and both HA ingress proxy replicas are Ready.
kubectl --kubeconfig "$kubeconfig" get proxygroup ingress-proxies >/dev/null 2>&1 || { echo 'ProxyGroup ingress-proxies is missing.' >&2; exit 1; }
ready="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get statefulset ingress-proxies --output jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
[[ "${ready:-0}" -ge 2 ]] || { echo "ProxyGroup ingress-proxies StatefulSet has ${ready:-0} ready replicas (want >= 2)." >&2; exit 1; }

just kube foundation-verify
echo 'Tailscale operator acceptance passed: Kustomization + HelmRelease Ready, operator rolled out, and both ingress ProxyGroup replicas Ready.'
echo
echo 'MANUAL (mandatory, Cilium compatibility — review #6/#7): from a device on the tailnet,'
echo 'reach a throwaway Ingress (referencing proxy-group ingress-proxies) that fronts a test'
echo 'Service, proving tailnet client -> ProxyGroup -> Kubernetes Service on the live Cilium'
echo 'cluster, then remove it. See docs/tailscale-operator.md. Do not roll out ntfy (PR2) until'
echo 'this passes.'
