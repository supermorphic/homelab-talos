#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/monitoring/kube-prometheus-stack'
ks="$base/ks.yaml"
secret="$base/app/grafana-admin.sops.yaml"
values="$base/app/values.yaml"
hr="$base/app/helmrelease.yaml"
repo="$base/app/helmrepository.yaml"
routes="$base/config/httproutes.yaml"
expected_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' .sops.yaml)"
temp_dir="$(mktemp -d /tmp/homelab-talos-monitoring-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$secret" "$values" "$hr" "$repo" "$routes" \
  "$base/app/namespace.yaml" "$base/app/kustomization.yaml" \
  "$base/config/kustomization.yaml" kubernetes/apps/monitoring/kustomization.yaml; do
  [[ -f "$f" ]] || {
    echo "Missing Phase 10 monitoring source: $f" >&2
    echo 'Run just repo monitoring-secrets if the Grafana Secret is missing.' >&2
    exit 1
  }
done

rg -qx '  - ./monitoring' kubernetes/apps/kustomization.yaml || {
  echo 'Refusing: ./monitoring is not wired into kubernetes/apps/kustomization.yaml.' >&2
  exit 1
}

[[ "$(sops filestatus "$secret" | yq -r '.encrypted')" == 'true' ]]
[[ "$(yq -r '.sops.age[].recipient' "$secret" | sort -u)" == "$expected_recipient" ]]
[[ "$(yq -r '.kind' "$secret")" == 'Secret' ]]
[[ "$(yq -r '.metadata.name' "$secret")" == 'grafana-admin-secret' ]]
[[ "$(yq -r '.metadata.namespace' "$secret")" == 'monitoring' ]]

suspend_states="$(yq ea -r '[select(.kind == "Kustomization") | (.spec.suspend // false)] | .[]' "$ks" | sort -u)"
[[ "$suspend_states" == 'true' || "$suspend_states" == 'false' ]] || {
  echo 'Both monitoring Kustomizations must be staged together: all suspended or all active.' >&2
  exit 1
}

[[ "$(yq ea -r 'select(.metadata.name == "kube-prometheus-stack") | [.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'cilium,longhorn' ]]
[[ "$(yq ea -r 'select(.metadata.name == "kube-prometheus-stack-config") | [.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'internal-gateway,kube-prometheus-stack' ]]

chart_version="$(yq -r '.spec.chart.spec.version' "$hr")"
[[ -n "$chart_version" && "$chart_version" != 'null' ]]
[[ "$(yq -r '.spec.url' "$repo")" == 'https://prometheus-community.github.io/helm-charts' ]]
[[ "$(yq -r '.prometheus.prometheusSpec.retention' "$values")" == '30d' ]]
[[ "$(yq -r '.prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage' "$values")" == '50Gi' ]]
[[ "$(yq -r '.grafana.persistence.enabled' "$values")" == 'true' ]]
for c in kubeProxy kubeControllerManager kubeScheduler kubeEtcd; do
  [[ "$(yq -r ".${c}.enabled" "$values")" == 'false' ]]
done
[[ "$(yq ea -r '[select(.kind == "HTTPRoute") | .spec.hostnames[0]] | sort | join(" ")' "$routes")" == 'alertmanager.lab.supermorphic.com grafana.lab.supermorphic.com prometheus.lab.supermorphic.com' ]]
[[ "$(yq ea -r '[select(.kind == "HTTPRoute") | .spec.parentRefs[].name] | unique | .[]' "$routes")" == 'internal' ]]
[[ "$(yq -r '.metadata.labels."gateway.supermorphic.com/access"' "$base/app/namespace.yaml")" == 'internal' ]]

kustomize build "$base/app" >/dev/null
kustomize build "$base/config" >/dev/null

printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
  helm template kube-prometheus-stack kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts --version "$chart_version" --namespace monitoring --values "$values" >"$temp_dir/kps.yaml"
render_kinds="$(yq ea -r '[select(.kind == "Prometheus" or .kind == "Alertmanager") | .kind] | .[]' "$temp_dir/kps.yaml" | sort -u | tr '\n' ' ')"
[[ "$render_kinds" == 'Alertmanager Prometheus ' ]]

# --- Flux reconciliation alerting: dedicated KSM (gotk_resource_info) + PodMonitor + rule ---
fksm='kubernetes/apps/monitoring/flux-kube-state-metrics'
cfg="$base/config"
fksm_values="$fksm/app/values.yaml"
flux_alerts_lib='scripts/lib/flux-alerts.sh'
flux_alerts_diagnostics='scripts/diagnose/flux-alerts.sh'
flux_alerts_promql='scripts/validate/flux-alerts-promql.sh'
flux_alerts_promql_test='tests/prometheus/flux-alerts.test.yaml'

for f in "$fksm/ks.yaml" "$fksm/app/kustomization.yaml" "$fksm/app/helmrelease.yaml" \
  "$fksm_values" "$fksm/app/rbac.yaml" "$fksm/README.md" \
  "$cfg/flux-podmonitor.yaml" "$cfg/flux-alerts.yaml" \
  "$flux_alerts_lib" "$flux_alerts_diagnostics" \
  "$flux_alerts_promql" "$flux_alerts_promql_test"; do
  [[ -f "$f" ]] || {
    echo "Missing Flux monitoring source: $f" >&2
    exit 1
  }
done

# Wiring into the respective kustomizations.
rg -qx '  - ./flux-kube-state-metrics/ks.yaml' kubernetes/apps/monitoring/kustomization.yaml || {
  echo 'Refusing: flux-kube-state-metrics is not wired into monitoring/kustomization.yaml.' >&2
  exit 1
}
rg -qx '  - ./flux-podmonitor.yaml' "$cfg/kustomization.yaml"
rg -qx '  - ./flux-alerts.yaml' "$cfg/kustomization.yaml"

# The bundled kube-state-metrics MUST stay untouched — changing KPS HelmRelease values trips
# the documented helm-controller upgrade wedge, which is exactly why the Flux exporter is a
# separate instance.
[[ "$(yq -r '.["kube-state-metrics"].customResourceState // "absent"' "$values")" == 'absent' ]] || {
  echo 'Refusing: kube-prometheus-stack values must not configure customResourceState (KPS upgrade wedge).' >&2
  exit 1
}

# Dedicated exporter is custom-resource-state-only with chart RBAC disabled.
[[ "$(yq -r '.customResourceState.enabled' "$fksm_values")" == 'true' ]]
[[ "$(yq -r '.collectors | length' "$fksm_values")" == '0' ]]
rg -q -- '--custom-resource-state-only=true' "$fksm_values"
[[ "$(yq -r '.rbac.create' "$fksm_values")" == 'false' ]]
[[ "$(yq -r '.prometheus.monitor.enabled' "$fksm_values")" == 'true' ]]
fksm_ver="$(yq -r '.spec.chart.spec.version' "$fksm/app/helmrelease.yaml")"
[[ -n "$fksm_ver" && "$fksm_ver" != 'null' ]]
fksm_resource_count="$(
  yq -r '.customResourceState.config.spec.resources | length' "$fksm_values"
)"
fksm_unique_help_count="$(
  yq -r '
    [
      .customResourceState.config.spec.resources[].metrics[].help
    ] |
    unique |
    length
  ' "$fksm_values"
)"
[[ "$fksm_unique_help_count" -eq "$fksm_resource_count" ]] || {
  echo 'Refusing: every Flux custom-resource collector must use a unique help string.' >&2
  exit 1
}
# `$resource` is a yq variable and must not be expanded by the shell.
# shellcheck disable=SC2016
yq -e '
  [
    .customResourceState.config.spec.resources[] |
    . as $resource |
    .metrics[] |
    .help == (
      "The current state of a Flux " +
      $resource.groupVersionKind.kind +
      " resource."
    )
  ] |
  all
' "$fksm_values" >/dev/null || {
  echo 'Refusing: Flux collector help strings must identify their resource kind.' >&2
  exit 1
}

# Minimal RBAC: CRD discovery plus only the exported Flux API groups, list/watch,
# no wildcards.
[[ "$(yq ea '[select(.kind == "ClusterRole") | .rules[].apiGroups[]] | unique | sort | join(",")' "$fksm/app/rbac.yaml")" == 'apiextensions.k8s.io,helm.toolkit.fluxcd.io,kustomize.toolkit.fluxcd.io,source.toolkit.fluxcd.io' ]]
[[ "$(yq ea '[select(.kind == "ClusterRole") | .rules[].verbs[]] | unique | sort | join(",")' "$fksm/app/rbac.yaml")" == 'list,watch' ]]
[[ "$(yq ea -r 'select(.kind == "ClusterRole") | .rules[] | select(.apiGroups[] == "apiextensions.k8s.io") | .resources | join(",")' "$fksm/app/rbac.yaml")" == 'customresourcedefinitions' ]]
if rg -q '\*' "$fksm/app/rbac.yaml"; then
  echo 'Refusing: flux-kube-state-metrics RBAC must not use wildcards.' >&2
  exit 1
fi

kustomize build "$fksm/app" >/dev/null

# Render the dedicated KSM chart: proves the ServiceMonitor + custom-resource-state-only wiring
# and that the chart emits no broad ClusterRole (rbac.create: false).
HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
  helm template flux-kube-state-metrics kube-state-metrics --repo https://prometheus-community.github.io/helm-charts --version "$fksm_ver" --namespace monitoring --values "$fksm_values" >"$temp_dir/fksm.yaml"
[[ "$(yq ea -r '[select(.kind == "ServiceMonitor")] | length' "$temp_dir/fksm.yaml")" -ge 1 ]]
[[ "$(yq ea -r '[select(.kind == "ClusterRole")] | length' "$temp_dir/fksm.yaml")" == '0' ]]
rg -q -- '--custom-resource-state-only=true' "$temp_dir/fksm.yaml"

# Flux controller PodMonitor: flux-system, part-of=flux, http-prom port.
pm="$cfg/flux-podmonitor.yaml"
[[ "$(yq -r '.kind' "$pm")" == 'PodMonitor' ]]
[[ "$(yq -r '.spec.namespaceSelector.matchNames[0]' "$pm")" == 'flux-system' ]]
[[ "$(yq -r '.spec.selector.matchLabels."app.kubernetes.io/part-of"' "$pm")" == 'flux' ]]
[[ "$(yq -r '.spec.podMetricsEndpoints[0].port' "$pm")" == 'http-prom' ]]

# Flux PrometheusRule: gotk_resource_info based, warning severity, excludes suspended, and
# never references the metric Flux v2 removed. (Exact alert-name set is intentionally not
# asserted until live verification confirms KPS TargetDown covers controller scrape-down.)
fr="$cfg/flux-alerts.yaml"
[[ "$(yq -r '.kind' "$fr")" == 'PrometheusRule' ]]
[[ "$(yq -r '.metadata.name' "$fr")" == 'flux' ]]
for a in FluxReconciliationFailure FluxResourceMetricsMissing; do
  yq -e ".spec.groups[].rules[] | select(.alert == \"$a\")" "$fr" >/dev/null
done
[[ "$(yq -r '.spec.groups[].rules[] | select(.alert == "FluxReconciliationFailure") | .labels.severity' "$fr")" == 'warning' ]]
frf_expr="$(yq -r '.spec.groups[].rules[] | select(.alert == "FluxReconciliationFailure") | .expr' "$fr")"
[[ "$frf_expr" == *gotk_resource_info* ]]
[[ "$frf_expr" == *'ready!="True"'* ]]
[[ "$frf_expr" == *'suspended!="true"'* ]]
frm_expr="$(yq -r '.spec.groups[].rules[] | select(.alert == "FluxResourceMetricsMissing") | .expr' "$fr")"
while IFS= read -r expected_kind; do
  [[ -n "$expected_kind" ]] || continue
  [[ "$frm_expr" == *"customresource_kind=\"$expected_kind\""* ]] || {
    echo "Refusing: FluxResourceMetricsMissing does not watch $expected_kind metrics." >&2
    exit 1
  }
done < <(
  yq -r '
    .customResourceState.config.spec.resources[].groupVersionKind.kind
  ' "$fksm_values"
)
# Inspect the rule expressions only (not explanatory comments): none may use the metric
# Flux v2 removed.
if yq -r '.spec.groups[].rules[].expr' "$fr" | rg -q 'gotk_reconcile_condition'; then
  echo 'Refusing: Flux alert expressions must use gotk_resource_info, not the removed gotk_reconcile_condition.' >&2
  exit 1
fi

rg -q '^flux-alerts-diagnostics: require-bash$' kubernetes/mod.just
yq -e '
  .suites[] |
  select(.metadata.id == "diagnostics.flux-alerts") |
  select(.metadata.tier == "diagnostics") |
  select(.metadata.mutates_cluster == false) |
  select(.runner.implementation == "scripts/diagnose/flux-alerts.sh")
' tests/catalog.yaml >/dev/null
bash -n "$flux_alerts_lib" "$flux_alerts_diagnostics" "$flux_alerts_promql"
shellcheck --external-sources \
  "$flux_alerts_lib" "$flux_alerts_diagnostics" "$flux_alerts_promql"
"$flux_alerts_promql"

echo 'Phase 10 monitoring source, encrypted Grafana Secret, dependency graph, values, HTTPRoutes, pinned kube-prometheus-stack render, and Flux reconciliation alerting (dedicated KSM + PodMonitor + rule) passed validation.'
