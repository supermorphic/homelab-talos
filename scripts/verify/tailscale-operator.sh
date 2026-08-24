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

# The dependent ProxyGroup Kustomization (applied only after the operator installed the
# CRD) is Ready.
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization tailscale-operator-proxygroup --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'Tailscale ProxyGroup Kustomization is not Ready.' >&2; exit 1; }

# ProxyGroup exists and both HA ingress proxy replicas are Ready.
kubectl --kubeconfig "$kubeconfig" get proxygroup ingress-proxies >/dev/null 2>&1 || { echo 'ProxyGroup ingress-proxies is missing.' >&2; exit 1; }
ready="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get statefulset ingress-proxies --output jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
[[ "${ready:-0}" -ge 2 ]] || { echo "ProxyGroup ingress-proxies StatefulSet has ${ready:-0} ready replicas (want >= 2)." >&2; exit 1; }

just kube foundation-verify
echo 'Tailscale operator acceptance passed: Kustomization + HelmRelease Ready, operator rolled out, and both ingress ProxyGroup replicas Ready.'
echo
echo 'MANUAL (mandatory for the first application): complete the owning application guide'
echo 'from a real tailnet client. This proves tailnet client -> Tailscale Service -> shared'
echo 'ProxyGroup -> Kubernetes Service. Start with docs/guides/ntfy-operations.md; do not create'
echo 'an ad-hoc production test Ingress.'
