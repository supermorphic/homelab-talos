#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
require_bash

base='kubernetes/apps/monitoring/test-reports'
app="$base/app"
ks="$base/ks.yaml"
deployment="$app/deployment.yaml"
pvc="$app/persistentvolumeclaim.yaml"
route="$app/httproute.yaml"
policy="$app/ciliumnetworkpolicy.yaml"
monitor="$app/servicemonitor.yaml"
rule="$app/prometheusrule.yaml"
image='docker.io/library/caddy:2.11.4-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648'

for file in \
  "$ks" "$app/kustomization.yaml" "$app/namespace.yaml" "$deployment" \
  "$pvc" "$app/service.yaml" "$route" "$policy" "$monitor" "$rule" \
  "$app/Caddyfile" "$app/bootstrap-storage.sh" "$app/install-report.sh"; do
  [[ -f "$file" ]] || {
    echo "Missing test-report server source: $file" >&2
    exit 1
  }
done
rg -qx '  - ./test-reports/ks.yaml' kubernetes/apps/monitoring/kustomization.yaml || {
  echo 'test-reports is not wired into the monitoring kustomization.' >&2
  exit 1
}
[[ "$(yq -r '.spec.suspend' "$ks")" == 'true' ]] || {
  echo 'The source PR must stage test-reports suspended.' >&2
  exit 1
}
[[ "$(yq ea -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == \
  'cilium,internal-gateway,kube-prometheus-stack,longhorn' ]]
[[ "$(yq -r '.metadata.labels."pod-security.kubernetes.io/enforce"' "$app/namespace.yaml")" == \
  'restricted' ]]
[[ "$(yq -r '.metadata.labels."gateway.supermorphic.com/access"' "$app/namespace.yaml")" == \
  'internal' ]]

[[ "$(yq -r '.spec.strategy.type' "$deployment")" == 'Recreate' ]]
[[ "$(yq -r '.spec.replicas' "$deployment")" == '1' ]]
[[ "$(yq -r '.spec.template.spec.automountServiceAccountToken' "$deployment")" == 'false' ]]
[[ "$(yq -r '.spec.template.spec.securityContext.runAsNonRoot' "$deployment")" == 'true' ]]
[[ "$(yq -r '.spec.template.spec.securityContext.seccompProfile.type' "$deployment")" == \
  'RuntimeDefault' ]]
[[ "$(yq -r '[.spec.template.spec.initContainers[].image,
  .spec.template.spec.containers[].image] | unique | join(",")' "$deployment")" == "$image" ]]
[[ "$(yq -r '[.spec.template.spec.containers[].securityContext.readOnlyRootFilesystem,
  .spec.template.spec.initContainers[].securityContext.readOnlyRootFilesystem] | all' \
  "$deployment")" == 'true' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].securityContext.capabilities.drop[],
  .spec.template.spec.initContainers[].securityContext.capabilities.drop[]] |
  unique | join(",")' "$deployment")" == 'ALL' ]]

[[ "$(yq -r '.spec.accessModes[0]' "$pvc")" == 'ReadWriteOnce' ]]
[[ "$(yq -r '.spec.storageClassName' "$pvc")" == 'longhorn' ]]
[[ "$(yq -r '.spec.resources.requests.storage' "$pvc")" == '20Gi' ]]
[[ "$(yq -r '.metadata.annotations."kustomize.toolkit.fluxcd.io/prune"' "$pvc")" == \
  'disabled' ]]
[[ "$(yq -r '.spec.hostnames[0]' "$route")" == 'tests.lab.supermorphic.com' ]]
[[ "$(yq -r '.spec.parentRefs[0].name' "$route")" == 'internal' ]]
[[ "$(yq -r '.metadata.annotations."external-dns.k8s.io/audience"' "$route")" == 'internal' ]]

[[ "$(yq -r '.spec.egress | length' "$policy")" == '0' ]]
[[ "$(yq -r '[.spec.ingress[].toPorts[].ports[].port] | unique | sort | join(",")' \
  "$policy")" == '8080,9090' ]]
[[ "$(yq -r '[.spec.endpoints[].port] | sort | join(",")' "$monitor")" == 'http,metrics' ]]
[[ "$(yq -r '[.spec.endpoints[].path] | sort | join(",")' "$monitor")" == \
  '/api/metrics.prom,/metrics' ]]
alerts="$(yq -r '[.spec.groups[].rules[].alert] | sort | join(",")' "$rule")"
[[ "$alerts" == 'TestReportsArchiveCapacityLow,TestReportsPersistentVolumeClaimNotBound' ]]
rg -q 'kubelet_volume_stats_available_bytes' "$rule"
rg -q 'current' "$app/Caddyfile"
rg -q 'admin off' "$app/Caddyfile"
rg -q 'auto_https off' "$app/Caddyfile"
rg -q 'metrics' "$app/Caddyfile"

# The staged server must not create a guaranteed-failing uptime probe before the
# operator bootstrap. The activation PR adds this endpoint after acceptance.
! rg -q '^    - name: test-reports$' kubernetes/apps/monitoring/gatus/app/values.yaml || {
  echo 'Suspended test-reports must not register a Gatus endpoint.' >&2
  exit 1
}
if find "$app" -maxdepth 1 -type f \
  \( -name '*role*.yaml' -o -name '*serviceaccount*.yaml' \) -print -quit | rg -q .; then
  echo 'The static test-report server must not have Kubernetes RBAC.' >&2
  exit 1
fi

sh -n "$app/bootstrap-storage.sh" "$app/install-report.sh"
shellcheck "$app/bootstrap-storage.sh" "$app/install-report.sh"
kustomize build "$app" >/dev/null

echo 'Suspended Caddy test-report server, retained RWO storage, Recreate strategy, restricted runtime, internal route, network isolation, metrics, and atomic installer passed validation.'
