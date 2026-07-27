#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
require_bash

base='kubernetes/apps/monitoring/test-reports'
app="$base/app"
ks="$base/ks.yaml"
deployment="$app/deployment.yaml"
kustomization="$app/kustomization.yaml"
pvc="$app/persistentvolumeclaim.yaml"
route="$app/httproute.yaml"
policy="$app/ciliumnetworkpolicy.yaml"
monitor="$app/servicemonitor.yaml"
rule="$app/prometheusrule.yaml"
dashboard="$app/dashboards/test-reports.json"
diagnostics='scripts/diagnose/test-reports.sh'
gatus_values='kubernetes/apps/monitoring/gatus/app/values.yaml'
image='docker.io/library/caddy:2.11.4-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648'

for file in \
  "$ks" "$app/kustomization.yaml" "$app/namespace.yaml" "$deployment" \
  "$pvc" "$app/service.yaml" "$route" "$policy" "$monitor" "$rule" \
  "$app/Caddyfile" "$app/bootstrap-storage.sh" "$app/install-report.sh" "$dashboard" \
  "$diagnostics" "$gatus_values"; do
  [[ -f "$file" ]] || {
    echo "Missing test-report server source: $file" >&2
    exit 1
  }
done
rg -qx '  - ./test-reports/ks.yaml' kubernetes/apps/monitoring/kustomization.yaml || {
  echo 'test-reports is not wired into the monitoring kustomization.' >&2
  exit 1
}
suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
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
[[ "$(yq -r '[.spec.template.spec.containers[].securityContext.allowPrivilegeEscalation,
  .spec.template.spec.initContainers[].securityContext.allowPrivilegeEscalation] |
  all_c(. == false)' "$deployment")" == 'true' ]]
[[ "$(yq -r '[.spec.template.spec.containers[].securityContext.capabilities.drop[],
  .spec.template.spec.initContainers[].securityContext.capabilities.drop[]] |
  unique | join(",")' "$deployment")" == 'ALL' ]]
[[ "$(yq -r '.spec.template.spec.containers[] |
  select(.name == "caddy") | .securityContext.capabilities.add | join(",")' \
  "$deployment")" == 'NET_BIND_SERVICE' ]]
[[ "$(yq -r \
  '[.spec.template.spec.initContainers[].securityContext.capabilities.add[]?] | length' \
  "$deployment")" == '0' ]]

[[ "$(yq -r '.spec.accessModes[0]' "$pvc")" == 'ReadWriteOnce' ]]
[[ "$(yq -r '.spec.storageClassName' "$pvc")" == 'longhorn' ]]
[[ "$(yq -r '.spec.resources.requests.storage' "$pvc")" == '20Gi' ]]
[[ "$(yq -r '.metadata.annotations."kustomize.toolkit.fluxcd.io/prune"' "$pvc")" == \
  'disabled' ]]
[[ "$(yq -r '.spec.hostnames[0]' "$route")" == 'tests.lab.supermorphic.com' ]]
[[ "$(yq -r '.spec.parentRefs[0].name' "$route")" == 'internal' ]]
[[ "$(yq -r '.metadata.annotations."external-dns.k8s.io/audience"' "$route")" == 'internal' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/name"' "$route")" == 'Test Reports' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/description"' "$route")" == \
  'Persistent operator-published test results' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/group"' "$route")" == \
  'Monitoring & Testing' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.type"' "$route")" == \
  'customapi' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.display"' "$route")" == \
  'dynamic-list' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.mappings.format"' "$route")" == \
  'relativeDate' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.mappings.limit"' "$route")" == \
  '6' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.mappings.target"' "$route")" == \
  'https://tests.lab.supermorphic.com{path}' ]]
rg -q 'test-reports\.test-reports\.svc\.cluster\.local:8080/api/homepage\.json' "$route"

[[ "$(yq -r '.spec.egress | length' "$policy")" == '0' ]]
[[ "$(yq -r '[.spec.ingress[].toPorts[].ports[].port] | unique | sort | join(",")' \
  "$policy")" == '8080,9090' ]]
[[ "$(yq -r '[.spec.ingress[].fromEndpoints[]?.matchLabels[
  "k8s:io.kubernetes.pod.namespace"]] | sort | join(",")' "$policy")" == \
  'envoy-gateway-system,homepage,monitoring' ]]
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
rg -Uq 'handle /api/catalog\.json \{\n[[:space:]]+rewrite \* /catalog\.json' \
  "$app/Caddyfile"

# Runtime configuration must be content-addressed so a Caddyfile or installer
# change updates the Deployment pod template and forces a Recreate rollout. The
# dashboard remains fixed-name because Grafana discovers it independently by label.
[[ "$(yq -r '.generatorOptions.disableNameSuffixHash // false' "$kustomization")" == \
  'false' ]]
[[ "$(yq -r '.configMapGenerator[] | select(.name == "test-reports-dashboard") |
  .options.disableNameSuffixHash' "$kustomization")" == 'true' ]]
rendered="$(mktemp "${TMPDIR:-/tmp}/test-reports-render.XXXXXX")"
trap 'rm -f "$rendered"' EXIT
kustomize build "$app" >"$rendered"
runtime_config="$(yq ea -r '
  select(.kind == "ConfigMap" and
    (.metadata.name | test("^test-reports-config-[a-z0-9]+$"))) |
  .metadata.name
' "$rendered")"
deployment_config="$(yq ea -r '
  select(.kind == "Deployment" and .metadata.name == "test-reports") |
  .spec.template.spec.volumes[] |
  select(.name == "config") |
  .configMap.name
' "$rendered")"
[[ -n "$runtime_config" && "$runtime_config" == "$deployment_config" ]] || {
  echo 'Rendered Deployment must reference the hashed runtime ConfigMap.' >&2
  exit 1
}

jq -e '
  .uid == "cluster-verification" and
  .title == "Cluster Verification" and
  .schemaVersion >= 39 and
  ([.panels[].title] | index("Latest Run Age") != null) and
  ([.panels[].title] | index("Passed Cases (Latest per Scenario)") != null) and
  ([.panels[].title] | index("30-Day Run Pass Rate") != null) and
  ([.panels[].title] | index("Run Duration") != null) and
  ([.panels[].title] | index("Failures by Scenario (30 Days)") != null) and
  ([.. | strings] | any(contains("homelab_test_last_run_status"))) and
  ([.. | strings] | any(contains("homelab_test_last_success_timestamp_seconds"))) and
  ([.. | strings] | any(contains("https://tests.lab.supermorphic.com/latest/")))
' "$dashboard" >/dev/null
yq ea -e '
    select(.kind == "ConfigMap" and .metadata.name == "test-reports-dashboard") |
    .metadata.labels.grafana_dashboard == "1" and
    (.data."test-reports.json" | test("\"uid\": \"cluster-verification\""))
  ' "$rendered" >/dev/null

# Uptime monitoring follows activation state: never probe staged-absent source,
# and require the complete user-facing path after operator acceptance.
if [[ "$suspend_state" == 'false' ]]; then
  [[ "$(yq -r '[.config.endpoints[] | select(
    .name == "test-reports" and
    .group == "Observability" and
    .url == "https://tests.lab.supermorphic.com/" and
    .interval == "1m" and
    .conditions[0] == "[STATUS] == 200" and
    (.conditions | length) == 1
  )] | length' "$gatus_values")" == '1' ]] || {
    echo 'Active test-reports has no exact Gatus endpoint.' >&2
    exit 1
  }
else
  ! rg -q '^    - name: test-reports$' "$gatus_values" || {
    echo 'Suspended test-reports must not register a Gatus endpoint.' >&2
    exit 1
  }
fi
if find "$app" -maxdepth 1 -type f \
  \( -name '*role*.yaml' -o -name '*serviceaccount*.yaml' \) -print -quit | rg -q .; then
  echo 'The static test-report server must not have Kubernetes RBAC.' >&2
  exit 1
fi

sh -n "$app/bootstrap-storage.sh" "$app/install-report.sh"
shellcheck "$app/bootstrap-storage.sh" "$app/install-report.sh" "$diagnostics"

echo 'Caddy test-report server, activation-aware Gatus probe, content-addressed runtime configuration, retained RWO storage, Recreate strategy, restricted runtime, internal route, Homepage rollups, Grafana dashboard, network isolation, metrics, and atomic installer passed validation.'
