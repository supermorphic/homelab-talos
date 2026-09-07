#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
values="$repo_root/kubernetes/apps/monitoring/gatus/app/values.yaml"
activation_values="$repo_root/kubernetes/apps/monitoring/gatus/app/nocodb-activation.values.yaml"
rule="$repo_root/kubernetes/apps/monitoring/alerts/app/nocodb.yaml"
kustomization="$repo_root/kubernetes/apps/monitoring/alerts/app/kustomization.yaml"

fail() {
  echo "NocoDB alerts test failed: $*" >&2
  exit 1
}

[[ -f "$values" ]] || fail 'Active Gatus values are missing.'
[[ -f "$activation_values" ]] || fail 'Staged NocoDB Gatus activation definition is missing.'
[[ -f "$rule" ]] || fail 'NocoDB PrometheusRule is missing.'

[[ "$(yq -r '[.config.endpoints[] | select(.name == "nocodb")] | length' "$values")" == '0' ]] ||
  fail 'Staged NocoDB must not be enrolled in active Gatus values.'
endpoint="$(yq -o=json -I=0 '.config.endpoints[] | select(.name == "nocodb")' "$activation_values")"
[[ "$(yq -r '.group' <<<"$endpoint")" == 'Platform' ]] || fail 'NocoDB Gatus group must be Platform.'
[[ "$(yq -r '.url' <<<"$endpoint")" == 'https://nocodb.lab.supermorphic.com/api/v1/health' ]] || fail 'NocoDB Gatus URL is incorrect.'
[[ "$(yq -r '.interval' <<<"$endpoint")" == '1m' ]] || fail 'NocoDB Gatus interval must be 1m.'
[[ "$(yq -r '.conditions | join(",")' <<<"$endpoint")" == '[STATUS] == 200' ]] || fail 'NocoDB Gatus must require HTTP 200.'

[[ "$(yq -r '.kind' "$rule")" == 'PrometheusRule' && \
  "$(yq -r '.metadata.namespace' "$rule")" == 'monitoring' && \
  "$(yq -r '.spec.groups[0].name' "$rule")" == 'nocodb' ]] || fail 'NocoDB alert rule identity is incorrect.'

expected_alerts=$'NocoDBAcceptanceJobFailed\nNocoDBAcceptanceJobOverdue\nNocoDBContainerOomKilled\nNocoDBContainerRestarting\nNocoDBDown\nNocoDBMetadataBootstrapJobFailed\nNocoDBMetadataBootstrapJobOverdue\nNocoDBProbeMissing\nNocoDBWorkloadUnavailable'
actual_alerts="$(yq -r '.spec.groups[0].rules[].alert' "$rule" | LC_ALL=C sort)"
[[ "$actual_alerts" == "$expected_alerts" ]] || fail "NocoDB alert coverage is incorrect: $actual_alerts"

for required_expression in \
  'gatus_results_endpoint_success{name="nocodb", group="Platform"}' \
  'absent(gatus_results_endpoint_success{name="nocodb", group="Platform"})' \
  'kube_deployment_status_replicas_available' \
  'kube_pod_container_status_restarts_total' \
  'reason="OOMKilled"' \
  'job_name="nocodb-metadata-bootstrap"' \
  'job_name=~"nocodb-acceptance-.*"'; do
  rg -Fq -- "$required_expression" "$rule" || fail "Missing required PromQL contract: $required_expression"
done

! rg -q 'persistentvolumeclaim|kubelet_volume_stats' "$rule" ||
  fail 'NocoDB alerts must not observe application-local storage'

! rg -Fxq '  - ./nocodb.yaml' "$kustomization" || fail 'Staged NocoDB PrometheusRule must not be selected.'
! rg -q 'ServiceMonitor|alloy|loki' "$repo_root/kubernetes/apps/automation-data/nocodb" ||
  fail 'NocoDB must not add a ServiceMonitor or a second log agent.'

echo 'NocoDB Gatus and Prometheus alert contracts passed.'
