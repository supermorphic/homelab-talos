#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: trivy.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
ns='trivy-system'

[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization trivy-operator --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'Trivy Kustomization is not Ready.' >&2; exit 1; }
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get helmrelease trivy-operator --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'Trivy HelmRelease is not Ready.' >&2; exit 1; }
kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status deployment/trivy-operator --timeout=5m
for crd in vulnerabilityreports.aquasecurity.github.io configauditreports.aquasecurity.github.io; do
  kubectl --kubeconfig "$kubeconfig" get crd "$crd" >/dev/null 2>&1 || { echo "Missing Trivy CRD $crd." >&2; exit 1; }
done

just kube foundation-verify
echo 'Phase 10 Trivy Operator acceptance passed: Kustomization and HelmRelease Ready, operator rolled out, and report CRDs installed.'
