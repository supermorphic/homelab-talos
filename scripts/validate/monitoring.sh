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
    echo "Missing monitoring source: $f" >&2
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

# --- Loki: single-binary, filesystem-backed internal log store ---
loki='kubernetes/apps/monitoring/loki'
loki_ks="$loki/ks.yaml"
loki_values="$loki/app/values.yaml"
loki_hr="$loki/app/helmrelease.yaml"
loki_repo="$loki/app/helmrepository.yaml"
loki_datasource="$loki/app/datasource.yaml"

for f in "$loki_ks" "$loki_values" "$loki_hr" "$loki_repo" "$loki_datasource" \
  "$loki/app/kustomization.yaml"; do
  [[ -f "$f" ]] || {
    echo "Missing Loki source: $f" >&2
    exit 1
  }
done

rg -qx '  - ./loki/ks.yaml' kubernetes/apps/monitoring/kustomization.yaml || {
  echo 'Refusing: loki is not wired into monitoring/kustomization.yaml.' >&2
  exit 1
}

[[ "$(yq -r '.metadata.name' "$loki_ks")" == 'loki' ]]
[[ "$(yq -r '.metadata.namespace' "$loki_ks")" == 'flux-system' ]]
[[ "$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$loki_ks")" == 'kube-prometheus-stack,longhorn' ]]
[[ "$(yq -r '.spec.path' "$loki_ks")" == './kubernetes/apps/monitoring/loki/app' ]]
[[ "$(yq -r '.spec.prune' "$loki_ks")" == 'true' ]]
[[ "$(yq -r '.spec.wait' "$loki_ks")" == 'true' ]]

[[ "$(yq -r '.metadata.name' "$loki_repo")" == 'grafana' ]]
[[ "$(yq -r '.metadata.namespace' "$loki_repo")" == 'monitoring' ]]
[[ "$(yq -r '.spec.url' "$loki_repo")" == 'https://grafana.github.io/helm-charts' ]]
[[ "$(yq -r '.metadata.name' "$loki_hr")" == 'loki' ]]
[[ "$(yq -r '.metadata.namespace' "$loki_hr")" == 'monitoring' ]]
[[ "$(yq -r '.spec.chart.spec.chart' "$loki_hr")" == 'loki' ]]
[[ "$(yq -r '.spec.chart.spec.version' "$loki_hr")" == '7.3.0' ]]
[[ "$(yq -r '.spec.chart.spec.sourceRef.kind' "$loki_hr")" == 'HelmRepository' ]]
[[ "$(yq -r '.spec.chart.spec.sourceRef.name' "$loki_hr")" == 'grafana' ]]
[[ "$(yq -r '.spec.targetNamespace' "$loki_hr")" == 'monitoring' ]]
[[ "$(yq -r '.spec.valuesFrom[0].kind' "$loki_hr")" == 'ConfigMap' ]]
[[ "$(yq -r '.spec.valuesFrom[0].name' "$loki_hr")" == 'loki-values' ]]
[[ "$(yq -r '.spec.valuesFrom[0].valuesKey' "$loki_hr")" == 'values.yaml' ]]
[[ "$(yq -r '.spec.install.remediation.retries' "$loki_hr")" == '3' ]]
[[ "$(yq -r '.spec.upgrade.cleanupOnFail' "$loki_hr")" == 'true' ]]
[[ "$(yq -r '.spec.upgrade.remediation.retries' "$loki_hr")" == '3' ]]
[[ "$(yq -r '.spec.upgrade.remediation.strategy' "$loki_hr")" == 'rollback' ]]

[[ "$(yq -r '.deploymentMode' "$loki_values")" == 'SingleBinary' ]]
[[ "$(yq -r '.loki.auth_enabled' "$loki_values")" == 'false' ]]
[[ "$(yq -r '.loki.commonConfig.replication_factor' "$loki_values")" == '1' ]]
[[ "$(yq -r '.loki.schemaConfig.configs[0].store' "$loki_values")" == 'tsdb' ]]
[[ "$(yq -r '.loki.schemaConfig.configs[0].object_store' "$loki_values")" == 'filesystem' ]]
[[ "$(yq -r '.loki.schemaConfig.configs[0].schema' "$loki_values")" == 'v13' ]]
[[ "$(yq -r '.loki.schemaConfig.configs[0].index.prefix' "$loki_values")" == 'index_' ]]
[[ "$(yq -r '.loki.schemaConfig.configs[0].index.period' "$loki_values")" == '24h' ]]
[[ "$(yq -r '.loki.storage.type' "$loki_values")" == 'filesystem' ]]
[[ "$(yq -r '.loki.limits_config.allow_structured_metadata' "$loki_values")" == 'false' ]]
[[ "$(yq -r '.loki.limits_config.ingestion_rate_mb' "$loki_values")" == '2' ]]
[[ "$(yq -r '.loki.limits_config.ingestion_burst_size_mb' "$loki_values")" == '4' ]]
[[ "$(yq -r '.loki.limits_config.per_stream_rate_limit' "$loki_values")" == '1MB' ]]
[[ "$(yq -r '.loki.limits_config.per_stream_rate_limit_burst' "$loki_values")" == '2MB' ]]
[[ "$(yq -r '.loki.limits_config.max_line_size' "$loki_values")" == '256KB' ]]
[[ "$(yq -r '.loki.limits_config.max_global_streams_per_user' "$loki_values")" == '5000' ]]
[[ "$(yq -r '.loki.limits_config.retention_period' "$loki_values")" == '336h' ]]
[[ "$(yq -r '.loki.limits_config.max_query_lookback' "$loki_values")" == '336h' ]]
[[ "$(yq -r '.loki.compactor.retention_enabled' "$loki_values")" == 'true' ]]
[[ "$(yq -r '.loki.compactor.delete_request_store' "$loki_values")" == 'filesystem' ]]
[[ "$(yq -r '.singleBinary.replicas' "$loki_values")" == '1' ]]
[[ "$(yq -r '.singleBinary.resources.requests.cpu' "$loki_values")" == '250m' ]]
[[ "$(yq -r '.singleBinary.resources.requests.memory' "$loki_values")" == '1Gi' ]]
[[ "$(yq -r '.singleBinary.resources.limits.cpu' "$loki_values")" == '2' ]]
[[ "$(yq -r '.singleBinary.resources.limits.memory' "$loki_values")" == '3Gi' ]]
for component in read write backend; do
  [[ "$(yq -r ".${component}.replicas" "$loki_values")" == '0' ]]
done
[[ "$(yq -r '.singleBinary.persistence.enabled' "$loki_values")" == 'true' ]]
[[ "$(yq -r '.singleBinary.persistence.accessModes | join(",")' "$loki_values")" == 'ReadWriteOnce' ]]
[[ "$(yq -r '.singleBinary.persistence.size' "$loki_values")" == '50Gi' ]]
[[ "$(yq -r '.singleBinary.persistence.storageClass' "$loki_values")" == 'longhorn' ]]
[[ "$(yq -r '.singleBinary.persistence.whenScaled' "$loki_values")" == 'Retain' ]]
[[ "$(yq -r '.singleBinary.persistence.whenDeleted' "$loki_values")" == 'Retain' ]]
[[ "$(yq -r '.singleBinary.persistence.enableStatefulSetAutoDeletePVC' "$loki_values")" == 'false' ]]
[[ "$(yq -r '.singleBinary.persistence.labels."recurring-job.longhorn.io/source"' "$loki_values")" == 'enabled' ]]
[[ "$(yq -r '.singleBinary.persistence.labels."recurring-job.longhorn.io/loki-filesystem-trim"' "$loki_values")" == 'enabled' ]]
expected_loki_recurring_labels='recurring-job.longhorn.io/loki-filesystem-trim=enabled,recurring-job.longhorn.io/source=enabled'
[[ "$(yq -r '[.singleBinary.persistence.labels | to_entries[] | select(.key | test("^recurring-job\\.longhorn\\.io/")) | "\(.key)=\(.value)"] | sort | join(",")' "$loki_values")" == "$expected_loki_recurring_labels" ]]
for label in daily-snapshot daily-backup default; do
  [[ "$(yq -r ".singleBinary.persistence.labels.\"recurring-job.longhorn.io/${label}\" // \"absent\"" "$loki_values")" == 'absent' ]]
done
for component in gateway lokiCanary resultsCache chunksCache; do
  [[ "$(yq -r ".${component}.enabled" "$loki_values")" == 'false' ]]
done
[[ "$(yq -r '.test.enabled' "$loki_values")" == 'false' ]]
[[ "$(yq -r '.monitoring.serviceMonitor.enabled' "$loki_values")" == 'true' ]]

[[ "$(yq -r '.kind' "$loki_datasource")" == 'ConfigMap' ]]
[[ "$(yq -r '.metadata.namespace' "$loki_datasource")" == 'monitoring' ]]
[[ "$(yq -r '.metadata.labels.grafana_datasource' "$loki_datasource")" == '1' ]]
[[ "$(yq -r '(.data."loki.yaml" | from_yaml).datasources | length' "$loki_datasource")" == '1' ]]
[[ "$(yq -r '(.data."loki.yaml" | from_yaml).datasources[0].name' "$loki_datasource")" == 'Loki' ]]
[[ "$(yq -r '(.data."loki.yaml" | from_yaml).datasources[0].type' "$loki_datasource")" == 'loki' ]]
[[ "$(yq -r '(.data."loki.yaml" | from_yaml).datasources[0].access' "$loki_datasource")" == 'proxy' ]]
[[ "$(yq -r '(.data."loki.yaml" | from_yaml).datasources[0].url' "$loki_datasource")" == 'http://loki.monitoring.svc.cluster.local:3100' ]]
[[ "$(yq -r '(.data."loki.yaml" | from_yaml).datasources[0].isDefault' "$loki_datasource")" == 'false' ]]
[[ "$(yq -r '(.data."loki.yaml" | from_yaml).datasources[0].editable' "$loki_datasource")" == 'false' ]]
[[ "$(yq -r '(.data."loki.yaml" | from_yaml).datasources[0].jsonData.maxLines' "$loki_datasource")" == '1000' ]]

kustomize build "$loki/app" >/dev/null
HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
  helm template loki loki --repo https://grafana.github.io/helm-charts --version 7.3.0 \
  --namespace monitoring --api-versions monitoring.coreos.com/v1/ServiceMonitor \
  --values "$loki_values" >"$temp_dir/loki.yaml"
[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | .spec.replicas] | join(",")' "$temp_dir/loki.yaml")" == '1' ]]
# The chart omits a StatefulSet retention policy when automatic PVC deletion is disabled.
# Kubernetes defaults both lifecycle actions to Retain in that case.
[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | (.spec.persistentVolumeClaimRetentionPolicy.whenDeleted // "Retain")] | join(",")' "$temp_dir/loki.yaml")" == 'Retain' ]]
[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | (.spec.persistentVolumeClaimRetentionPolicy.whenScaled // "Retain")] | join(",")' "$temp_dir/loki.yaml")" == 'Retain' ]]
[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | .spec.volumeClaimTemplates[] | select(.metadata.name == "storage") | .spec.accessModes | join(",") ] | join(",")' "$temp_dir/loki.yaml")" == 'ReadWriteOnce' ]]
[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | .spec.volumeClaimTemplates[] | select(.metadata.name == "storage") | .spec.resources.requests.storage] | join(",")' "$temp_dir/loki.yaml")" == '50Gi' ]]
[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | .spec.volumeClaimTemplates[] | select(.metadata.name == "storage") | .spec.storageClassName] | join(",")' "$temp_dir/loki.yaml")" == 'longhorn' ]]
[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | .spec.volumeClaimTemplates[] | select(.metadata.name == "storage") | .metadata.labels."recurring-job.longhorn.io/source"] | join(",")' "$temp_dir/loki.yaml")" == 'enabled' ]]
[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | .spec.volumeClaimTemplates[] | select(.metadata.name == "storage") | .metadata.labels."recurring-job.longhorn.io/loki-filesystem-trim"] | join(",")' "$temp_dir/loki.yaml")" == 'enabled' ]]
[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | .spec.volumeClaimTemplates[] | select(.metadata.name == "storage") | .metadata.labels | to_entries | map(select(.key | test("^recurring-job\\.longhorn\\.io/"))) | map("\(.key)=\(.value)") | sort | join(",")] | join(",")' "$temp_dir/loki.yaml")" == "$expected_loki_recurring_labels" ]]
[[ "$(yq ea -r '[select(.kind == "ConfigMap" and .metadata.name == "loki") | (.data."config.yaml" | from_yaml).limits_config.allow_structured_metadata] | join(",")' "$temp_dir/loki.yaml")" == 'false' ]]
[[ "$(yq ea -r '[select(.kind == "ConfigMap" and .metadata.name == "loki") | (.data."config.yaml" | from_yaml).limits_config.ingestion_rate_mb] | join(",")' "$temp_dir/loki.yaml")" == '2' ]]
[[ "$(yq ea -r '[select(.kind == "ConfigMap" and .metadata.name == "loki") | (.data."config.yaml" | from_yaml).limits_config.ingestion_burst_size_mb] | join(",")' "$temp_dir/loki.yaml")" == '4' ]]
[[ "$(yq ea -r '[select(.kind == "ConfigMap" and .metadata.name == "loki") | (.data."config.yaml" | from_yaml).limits_config.per_stream_rate_limit] | join(",")' "$temp_dir/loki.yaml")" == '1MB' ]]
[[ "$(yq ea -r '[select(.kind == "ConfigMap" and .metadata.name == "loki") | (.data."config.yaml" | from_yaml).limits_config.per_stream_rate_limit_burst] | join(",")' "$temp_dir/loki.yaml")" == '2MB' ]]
[[ "$(yq ea -r '[select(.kind == "ConfigMap" and .metadata.name == "loki") | (.data."config.yaml" | from_yaml).limits_config.max_line_size] | join(",")' "$temp_dir/loki.yaml")" == '256KB' ]]
[[ "$(yq ea -r '[select(.kind == "ConfigMap" and .metadata.name == "loki") | (.data."config.yaml" | from_yaml).limits_config.max_global_streams_per_user] | join(",")' "$temp_dir/loki.yaml")" == '5000' ]]
[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | .spec.template.spec.containers[] | select(.name == "loki") | .resources.requests.cpu] | join(",")' "$temp_dir/loki.yaml")" == '250m' ]]
[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | .spec.template.spec.containers[] | select(.name == "loki") | .resources.requests.memory] | join(",")' "$temp_dir/loki.yaml")" == '1Gi' ]]
[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | .spec.template.spec.containers[] | select(.name == "loki") | .resources.limits.cpu] | join(",")' "$temp_dir/loki.yaml")" == '2' ]]
[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | .spec.template.spec.containers[] | select(.name == "loki") | .resources.limits.memory] | join(",")' "$temp_dir/loki.yaml")" == '3Gi' ]]
[[ "$(yq ea -r '[select(.kind == "Service" and .metadata.name == "loki") | .spec.type] | join(",")' "$temp_dir/loki.yaml")" == 'ClusterIP' ]]
[[ "$(yq ea -r '[select(.kind == "ServiceMonitor")] | length' "$temp_dir/loki.yaml")" -ge 1 ]]
[[ "$(yq ea -r '[select(.kind == "Ingress" or .kind == "HTTPRoute")] | length' "$temp_dir/loki.yaml")" == '0' ]]
[[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name | test("canary"))] | length' "$temp_dir/loki.yaml")" == '0' ]]
[[ "$(yq ea -r '[select(.kind == "Deployment" or .kind == "StatefulSet") | .metadata.name | select(test("gateway|results-cache|chunks-cache"))] | length' "$temp_dir/loki.yaml")" == '0' ]]

# --- Flux reconciliation alerting: dedicated KSM (gotk_resource_info) + PodMonitor + rule ---
fksm='kubernetes/apps/monitoring/flux-kube-state-metrics'
cfg="$base/config"
fksm_values="$fksm/app/values.yaml"
flux_alerts_lib='scripts/lib/flux-alerts.sh'
flux_alerts_diagnostics='scripts/diagnose/flux-alerts.sh'
# The rule itself now lives in the monitoring alerts application. Its placement, wiring,
# and promtool coverage belong to `just kube alerts-validate monitoring`; what stays here
# is the content contract that ties the rule to this exporter's configuration.
flux_rule='kubernetes/apps/monitoring/alerts/app/flux.yaml'

for f in "$fksm/ks.yaml" "$fksm/app/kustomization.yaml" "$fksm/app/helmrelease.yaml" \
  "$fksm_values" "$fksm/app/rbac.yaml" "$fksm/README.md" \
  "$cfg/flux-podmonitor.yaml" "$flux_rule" \
  "$flux_alerts_lib" "$flux_alerts_diagnostics"; do
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
fr="$flux_rule"
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
bash -n "$flux_alerts_lib" "$flux_alerts_diagnostics"
shellcheck --external-sources "$flux_alerts_lib" "$flux_alerts_diagnostics"

echo 'Monitoring source, encrypted Grafana Secret, dependency graph, values, HTTPRoutes, pinned kube-prometheus-stack and Loki renders, Grafana Loki datasource, and Flux reconciliation alerting (dedicated KSM + PodMonitor + rule) passed validation.'
