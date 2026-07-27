#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: test-reports.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
namespace='test-reports'
host='tests.lab.supermorphic.com'
gateway_ip='192.168.90.30'

[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
  get kustomization test-reports \
  --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == \
  'True' ]] || {
  echo 'test-reports Kustomization is not Ready.' >&2
  exit 1
}
kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
  rollout status deployment/test-reports --timeout=5m
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
  get deployment test-reports --output jsonpath='{.spec.strategy.type}')" == 'Recreate' ]]
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
  get deployment test-reports \
  --output jsonpath='{.spec.template.spec.automountServiceAccountToken}')" == 'false' ]]
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
  get persistentvolumeclaim test-reports --output jsonpath='{.status.phase}')" == 'Bound' ]]
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
  get persistentvolumeclaim test-reports \
  --output jsonpath='{.spec.storageClassName}')" == 'longhorn' ]]

for kind in role rolebinding serviceaccount; do
  [[ -z "$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
    get "$kind" --selector app.kubernetes.io/name=test-reports \
    --output name 2>/dev/null)" ]] || {
    echo "test-reports unexpectedly owns Kubernetes $kind objects." >&2
    exit 1
  }
done
for resource in \
  ciliumnetworkpolicy/test-reports \
  servicemonitor/test-reports \
  prometheusrule/test-reports; do
  kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get "$resource" >/dev/null
done

accepted=false
resolved=false
for _ in {1..24}; do
  route="$(
    kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
      get httproute test-reports --output json 2>/dev/null || true
  )"
  [[ "$(yq -r '[.status.parents[].conditions[]? |
    select(.type == "Accepted") | .status] | unique | join(" ")' - <<<"$route")" == \
    'True' ]] && accepted=true
  [[ "$(yq -r '[.status.parents[].conditions[]? |
    select(.type == "ResolvedRefs") | .status] | unique | join(" ")' - <<<"$route")" == \
    'True' ]] && resolved=true
  [[ "$accepted" == 'true' && "$resolved" == 'true' ]] && break
  sleep 5
done
[[ "$accepted" == 'true' && "$resolved" == 'true' ]] || {
  echo 'test-reports HTTPRoute is not Accepted with ResolvedRefs.' >&2
  exit 1
}

dns_answer=''
for _ in {1..30}; do
  dns_answer="$(dig +short @192.168.90.2 "$host" A | sort -u)"
  [[ "$dns_answer" == "$gateway_ip" ]] && break
  sleep 10
done
[[ "$dns_answer" == "$gateway_ip" ]] || {
  echo "Pi-hole returned '$dns_answer' for $host, not $gateway_ip." >&2
  exit 1
}
curl --silent --show-error --fail --max-time 15 \
  --resolve "$host:443:$gateway_ip" "https://$host/healthz" |
  rg -qx 'ok'
catalog="$(
  curl --silent --show-error --fail --max-time 15 \
    --resolve "$host:443:$gateway_ip" "https://$host/api/catalog.json"
)"
yq -e '.schema_version == 1 and (.runs | type == "!!seq")' - <<<"$catalog" >/dev/null

echo 'Test-report server acceptance passed: Ready, retained Longhorn PVC, restricted no-RBAC runtime, accepted internal HTTPS route, health endpoint, and catalog API.'
