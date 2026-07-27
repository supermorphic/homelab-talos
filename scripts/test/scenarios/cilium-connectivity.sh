#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
require_bash

[[ "$#" -eq 1 ]] || {
  echo 'Usage: cilium-connectivity.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
expected_confirmation='test:cilium-connectivity'
diagnostic_dir="$(mktemp -d /tmp/homelab-talos-cilium-connectivity.XXXXXX)"
cleanup() {
  cilium connectivity test \
    --kubeconfig "$kubeconfig" \
    --test-namespace cilium-test \
    --cleanup >/dev/null 2>&1 || true
}
trap cleanup EXIT

[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run just talos kubeconfig." >&2
  exit 1
}
[[ "${CILIUM_CONNECTIVITY_CONFIRM:-}" == "$expected_confirmation" ]] || {
  echo "Refusing state-changing Cilium connectivity test; set CILIUM_CONNECTIVITY_CONFIRM='$expected_confirmation' after reviewing its cleanup scope." >&2
  exit 1
}

cleanup

# `cilium status --wait` treats stale Failed kube-system pod objects as errors.
# This state-changing test owns the explicit cleanup; read-only verification does not.
kubectl --kubeconfig "$kubeconfig" --namespace kube-system delete pods \
  --field-selector status.phase=Failed --ignore-not-found >/dev/null 2>&1 || true

echo "Connectivity-test diagnostics, if required, will remain in $diagnostic_dir."
if ! cilium connectivity test \
  --kubeconfig "$kubeconfig" \
  --namespace kube-system \
  --test-namespace cilium-test \
  --namespace-labels pod-security.kubernetes.io/enforce=privileged \
  --ip-families ipv4 \
  --hubble=false \
  --flow-validation disabled \
  --test '!no-unexpected-packet-drops' \
  --timeout 45m \
  --sysdump-output-filename "$diagnostic_dir/cilium-sysdump-<ts>"; then
  cilium sysdump \
    --kubeconfig "$kubeconfig" \
    --namespace kube-system \
    --output-filename "$diagnostic_dir/cilium-sysdump-<ts>" || true
  exit 1
fi

cleanup
just kube cilium-postflight

trap - EXIT
rm -rf -- "$diagnostic_dir"
echo 'Cilium connectivity test passed: temporary IPv4 workloads exercised DNS, service, policy, pod, node, and cross-node paths and were removed.'
