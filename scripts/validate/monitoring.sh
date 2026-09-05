#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -gt 1 ]]; then
	echo 'usage: monitoring.sh [loki|alloy-logs|alloy-events]' >&2
	exit 2
fi
scope="${1-all}"
case "$scope" in
all | loki | alloy-logs | alloy-events) ;;
*)
	echo 'usage: monitoring.sh [loki|alloy-logs|alloy-events]' >&2
	exit 2
	;;
esac

temp_dir="$(mktemp -d /tmp/homelab-talos-monitoring-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT
printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
alloy_logs_river_validator='scripts/validate/alloy-logs-river.py'
alloy_logs_render_validator='scripts/validate/alloy-logs-render.sh'

if [[ "$scope" == all ]]; then
	base='kubernetes/apps/monitoring/kube-prometheus-stack'
	ks="$base/ks.yaml"
	secret="$base/app/grafana-admin.sops.yaml"
	values="$base/app/values.yaml"
	hr="$base/app/helmrelease.yaml"
	repo="$base/app/helmrepository.yaml"
	routes="$base/config/httproutes.yaml"
	expected_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' .sops.yaml)"

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
	# SSA cannot clear the live unowned rollingUpdate defaults, even with null.
	# Keep upgrades on the tested typed strategic-merge path for this release.
	[[ "$(yq -r '.spec.upgrade.serverSideApply' "$hr")" == 'disabled' ]] || {
		echo 'Refusing: kube-prometheus-stack upgrades must use client-side apply to clear Grafana rollout defaults.' >&2
		exit 1
	}
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

	HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
		helm template kube-prometheus-stack kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts --version "$chart_version" --namespace monitoring --values "$values" >"$temp_dir/kps.yaml"
	render_kinds="$(yq ea -r '[select(.kind == "Prometheus" or .kind == "Alertmanager") | .kind] | .[]' "$temp_dir/kps.yaml" | sort -u | tr '\n' ' ')"
	[[ "$render_kinds" == 'Alertmanager Prometheus ' ]]
	# Preserve the explicit clearing instruction for the client-side merge path.
	[[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "kube-prometheus-stack-grafana")] | length' "$temp_dir/kps.yaml")" == '1' ]]
	yq ea -e 'select(.kind == "Deployment" and .metadata.name == "kube-prometheus-stack-grafana") |
    .spec.strategy.type == "Recreate" and (.spec.strategy | has("rollingUpdate")) and
    .spec.strategy.rollingUpdate == null' "$temp_dir/kps.yaml" >/dev/null || {
		echo 'Refusing: rendered Grafana Deployment must use Recreate with explicit rollingUpdate: null.' >&2
		exit 1
	}
fi

# --- Loki: single-binary, filesystem-backed internal log store ---
if [[ "$scope" == all || "$scope" == loki ]]; then
	loki='kubernetes/apps/monitoring/loki'
	loki_ks="$loki/ks.yaml"
	loki_values="$loki/app/values.yaml"
	loki_hr="$loki/app/helmrelease.yaml"
	loki_repo="$loki/app/helmrepository.yaml"
	loki_datasource="$loki/app/datasource.yaml"
	loki_dashboard="$loki/app/dashboards/centralized-logs.json"
	loki_dashboard_validator='scripts/validate/grafana-dashboard.py'

	for f in "$loki_ks" "$loki_values" "$loki_hr" "$loki_repo" "$loki_datasource" \
		"$loki_dashboard" "$loki_dashboard_validator" \
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
	yq -e '
  ((.loki.limits_config.discover_service_name | type) == "!!seq") and
  (.loki.limits_config.discover_service_name | length) == 0
' "$loki_values" >/dev/null || {
		echo 'Refusing: Loki source must disable automatic service-name discovery.' >&2
		exit 1
	}
	yq -e '
  ((.loki.limits_config.shard_streams | type) == "!!map") and
  (.loki.limits_config.shard_streams.enabled == false)
' "$loki_values" >/dev/null || {
		echo 'Refusing: Loki source must explicitly disable automatic stream sharding.' >&2
		exit 1
	}
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
	[[ "$(yq -r '[.singleBinary.persistence.labels | to_entries[] | select(.key | test("^recurring-job(-group)?\\.longhorn\\.io/")) | "\(.key)=\(.value)"] | sort | join(",")' "$loki_values")" == "$expected_loki_recurring_labels" ]] || {
		echo 'Refusing: Loki source PVC labels must contain only source and filesystem-trim assignments.' >&2
		exit 1
	}
	for label in daily-snapshot daily-backup; do
		[[ "$(yq -r ".singleBinary.persistence.labels.\"recurring-job.longhorn.io/${label}\" // \"absent\"" "$loki_values")" == 'absent' ]]
	done
	[[ "$(yq -r '.singleBinary.persistence.labels."recurring-job-group.longhorn.io/default" // "absent"' "$loki_values")" == 'absent' ]] || {
		echo 'Refusing: Loki source PVC labels must contain only source and filesystem-trim assignments.' >&2
		exit 1
	}
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

	# The dashboard is executable configuration, so validate its query behavior rather than
	# checking for marker strings. Every panel uses one of the two declared datasource
	# variables, and the required investigation views must remain independently queryable.
	jq -e '.' "$loki_dashboard" >/dev/null
	python "$loki_dashboard_validator" "$loki_dashboard"
	[[ "$(jq -r '.title' "$loki_dashboard")" == 'Centralized Logs' ]]
	[[ "$(jq -r '.uid' "$loki_dashboard")" == 'centralized-logs' ]]
	[[ "$(jq -r '.schemaVersion >= 41' "$loki_dashboard")" == 'true' ]]
	jq -e '
  [.templating.list[] | select(.type == "datasource") | [.name, .query]] | sort ==
    [["loki", "loki"], ["prometheus", "prometheus"]]
' "$loki_dashboard" >/dev/null
	jq -e '
  [.panels[].datasource] | length > 0 and
  all(.[];
    (.type == "loki" and .uid == "${loki}") or
    (.type == "prometheus" and .uid == "${prometheus}")
  )
' "$loki_dashboard" >/dev/null
	jq -e '
  [.panels[].targets[]?.expr] as $queries |
  ([ $queries[] | select(test("count_over_time")) ] | length) >= 4 and
  any($queries[]; test("sum by \\(source\\).*count_over_time")) and
  any($queries[]; test("sum by \\(namespace\\).*count_over_time")) and
  any($queries[]; test("sum by \\(app\\).*count_over_time")) and
  any($queries[]; test("sum by \\(node\\).*count_over_time")) and
  any($queries[]; contains("source=\"kubernetes_event\"") and contains("event_type=\"Warning\"")) and
  any($queries[]; contains("source=\"talos\"") and contains("service!=\"kernel\"") and test("error\\|fail\\|fatal\\|panic")) and
  any($queries[]; contains("source=\"talos\"") and contains("service=\"kernel\"") and test("error\\|fail\\|fatal\\|panic"))
' "$loki_dashboard" >/dev/null
	if rg -qi 'https?://|nuc-cluster|supermorphic|([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-f]{2}:){5}[0-9a-f]{2}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$loki_dashboard"; then
		echo 'Refusing: Centralized Logs dashboard embeds a raw infrastructure identifier.' >&2
		exit 1
	fi

	kustomize build "$loki/app" >"$temp_dir/loki-package.yaml"
	[[ "$(yq ea -r '[select(.kind == "ConfigMap" and .metadata.name == "centralized-logs-dashboard") | .metadata.namespace] | join(",")' "$temp_dir/loki-package.yaml")" == 'monitoring' ]]
	[[ "$(yq ea -r '[select(.kind == "ConfigMap" and .metadata.name == "centralized-logs-dashboard") | .metadata.labels.grafana_dashboard] | join(",")' "$temp_dir/loki-package.yaml")" == '1' ]]
	[[ "$(yq ea -r '[select(.kind == "ConfigMap" and .metadata.name == "centralized-logs-dashboard") | (.data | has("centralized-logs.json"))] | join(",")' "$temp_dir/loki-package.yaml")" == 'true' ]]
	HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
		helm template loki loki --repo https://grafana.github.io/helm-charts --version 7.3.0 \
		--namespace monitoring --api-versions monitoring.coreos.com/v1/ServiceMonitor \
		--values "$loki_values" >"$temp_dir/loki.yaml"
	[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | .spec.replicas] | join(",")' "$temp_dir/loki.yaml")" == '1' ]]
	[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | .spec.template.spec.containers[] | select(.name == "loki") | .image] | join(",")' "$temp_dir/loki.yaml")" == 'docker.io/grafana/loki:3.6.11' ]]
	# The chart omits a StatefulSet retention policy when automatic PVC deletion is disabled.
	# Kubernetes defaults both lifecycle actions to Retain in that case.
	[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | (.spec.persistentVolumeClaimRetentionPolicy.whenDeleted // "Retain")] | join(",")' "$temp_dir/loki.yaml")" == 'Retain' ]]
	[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | (.spec.persistentVolumeClaimRetentionPolicy.whenScaled // "Retain")] | join(",")' "$temp_dir/loki.yaml")" == 'Retain' ]]
	[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | .spec.volumeClaimTemplates[] | select(.metadata.name == "storage") | .spec.accessModes | join(",") ] | join(",")' "$temp_dir/loki.yaml")" == 'ReadWriteOnce' ]]
	[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | .spec.volumeClaimTemplates[] | select(.metadata.name == "storage") | .spec.resources.requests.storage] | join(",")' "$temp_dir/loki.yaml")" == '50Gi' ]]
	[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | .spec.volumeClaimTemplates[] | select(.metadata.name == "storage") | .spec.storageClassName] | join(",")' "$temp_dir/loki.yaml")" == 'longhorn' ]]
	[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | .spec.volumeClaimTemplates[] | select(.metadata.name == "storage") | .metadata.labels."recurring-job.longhorn.io/source"] | join(",")' "$temp_dir/loki.yaml")" == 'enabled' ]]
	[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | .spec.volumeClaimTemplates[] | select(.metadata.name == "storage") | .metadata.labels."recurring-job.longhorn.io/loki-filesystem-trim"] | join(",")' "$temp_dir/loki.yaml")" == 'enabled' ]]
	[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | .spec.volumeClaimTemplates[] | select(.metadata.name == "storage") | .metadata.labels | to_entries | map(select(.key | test("^recurring-job(-group)?\\.longhorn\\.io/"))) | map("\(.key)=\(.value)") | sort | join(",")] | join(",")' "$temp_dir/loki.yaml")" == "$expected_loki_recurring_labels" ]] || {
		echo 'Refusing: rendered Loki PVC labels must contain only source and filesystem-trim assignments.' >&2
		exit 1
	}
	[[ "$(yq ea -r '[select(.kind == "StatefulSet" and .metadata.name == "loki") | .spec.volumeClaimTemplates[] | select(.metadata.name == "storage") | .metadata.labels."recurring-job-group.longhorn.io/default" // "absent"] | join(",")' "$temp_dir/loki.yaml")" == 'absent' ]] || {
		echo 'Refusing: rendered Loki PVC labels must contain only source and filesystem-trim assignments.' >&2
		exit 1
	}
	[[ "$(yq ea -r '[select(.kind == "ConfigMap" and .metadata.name == "loki") | (.data."config.yaml" | from_yaml).limits_config.allow_structured_metadata] | join(",")' "$temp_dir/loki.yaml")" == 'false' ]]
	rendered_discover_service_name="$(yq ea --output-format json --indent 0 '
  select(.kind == "ConfigMap" and .metadata.name == "loki") |
  (.data."config.yaml" | from_yaml).limits_config.discover_service_name
' "$temp_dir/loki.yaml")"
	[[ "$rendered_discover_service_name" == '[]' ]] || {
		echo 'Refusing: rendered Loki must disable automatic service-name discovery.' >&2
		exit 1
	}
	rendered_shard_streams="$(yq ea --output-format json --indent 0 '
  select(.kind == "ConfigMap" and .metadata.name == "loki") |
  (.data."config.yaml" | from_yaml).limits_config.shard_streams
' "$temp_dir/loki.yaml")"
	yq -e '
  (. | type) == "!!map" and
  .enabled == false
' >/dev/null 2>&1 <<<"$rendered_shard_streams" || {
		echo 'Refusing: rendered Loki must explicitly disable automatic stream sharding.' >&2
		exit 1
	}
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
fi

# --- Alloy logs: node-local Kubernetes CRI and Talos file collection ---
if [[ "$scope" == all || "$scope" == alloy-logs ]]; then
	alloy_logs='kubernetes/apps/monitoring/alloy-logs'
	alloy_logs_ks="$alloy_logs/ks.yaml"
	alloy_logs_values="$alloy_logs/app/values.yaml"
	alloy_logs_hr="$alloy_logs/app/helmrelease.yaml"
	alloy_logs_config="$alloy_logs/app/config.alloy"
	alloy_logs_kustomization="$alloy_logs/app/kustomization.yaml"

	for f in "$alloy_logs_ks" "$alloy_logs_values" "$alloy_logs_hr" \
		"$alloy_logs_config" "$alloy_logs_kustomization" "$alloy_logs_river_validator" \
		"$alloy_logs_render_validator"; do
		[[ -f "$f" ]] || {
			echo "Missing Alloy logs source: $f" >&2
			exit 1
		}
	done

	rg -qx '  - ./alloy-logs/ks.yaml' kubernetes/apps/monitoring/kustomization.yaml || {
		echo 'Refusing: alloy-logs is not wired into monitoring/kustomization.yaml.' >&2
		exit 1
	}

	[[ "$(yq -r '.metadata.name' "$alloy_logs_ks")" == 'alloy-logs' ]]
	[[ "$(yq -r '.metadata.namespace' "$alloy_logs_ks")" == 'flux-system' ]]
	[[ "$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$alloy_logs_ks")" == 'loki' ]]
	[[ "$(yq -r '.spec.path' "$alloy_logs_ks")" == './kubernetes/apps/monitoring/alloy-logs/app' ]]
	[[ "$(yq -r '.spec.prune' "$alloy_logs_ks")" == 'true' ]]
	[[ "$(yq -r '.spec.wait' "$alloy_logs_ks")" == 'true' ]]

	[[ "$(yq -r '.metadata.name' "$alloy_logs_hr")" == 'alloy-logs' ]]
	[[ "$(yq -r '.metadata.namespace' "$alloy_logs_hr")" == 'monitoring' ]]
	[[ "$(yq -r '.spec.chart.spec.chart' "$alloy_logs_hr")" == 'alloy' ]]
	[[ "$(yq -r '.spec.chart.spec.version' "$alloy_logs_hr")" == '1.12.0' ]]
	[[ "$(yq -r '.spec.chart.spec.sourceRef.kind' "$alloy_logs_hr")" == 'HelmRepository' ]]
	[[ "$(yq -r '.spec.chart.spec.sourceRef.name' "$alloy_logs_hr")" == 'grafana' ]]
	[[ "$(yq -r '.spec.targetNamespace' "$alloy_logs_hr")" == 'monitoring' ]]
	[[ "$(yq -r '.spec.valuesFrom[0].kind' "$alloy_logs_hr")" == 'ConfigMap' ]]
	[[ "$(yq -r '.spec.valuesFrom[0].name' "$alloy_logs_hr")" == 'alloy-logs-values' ]]
	[[ "$(yq -r '.spec.valuesFrom[0].valuesKey' "$alloy_logs_hr")" == 'values.yaml' ]]

	[[ "$(yq -r '.alloy.configMap.create' "$alloy_logs_values")" == 'false' ]]
	[[ "$(yq -r '.alloy.configMap.name' "$alloy_logs_values")" == 'alloy-logs-config' ]]
	[[ "$(yq -r '.alloy.configMap.key' "$alloy_logs_values")" == 'config.alloy' ]]
	[[ "$(yq -r '.alloy.clustering.enabled' "$alloy_logs_values")" == 'false' ]]
	[[ "$(yq -r '.alloy.enableReporting' "$alloy_logs_values")" == 'false' ]]
	[[ "$(yq -r '.alloy.stabilityLevel' "$alloy_logs_values")" == 'generally-available' ]]
	[[ "$(yq -r '.alloy.storagePath' "$alloy_logs_values")" == '/var/lib/alloy' ]]
	[[ "$(yq -r '.alloy.mounts.varlog' "$alloy_logs_values")" == 'true' ]]
	[[ "$(yq -r '.alloy.resources.requests.cpu' "$alloy_logs_values")" == '100m' ]]
	[[ "$(yq -r '.alloy.resources.requests.memory' "$alloy_logs_values")" == '128Mi' ]]
	[[ "$(yq -r '.alloy.resources.limits.cpu' "$alloy_logs_values")" == '1' ]]
	[[ "$(yq -r '.alloy.resources.limits.memory' "$alloy_logs_values")" == '512Mi' ]]
	[[ "$(yq -r '.controller.type' "$alloy_logs_values")" == 'daemonset' ]]
	[[ "$(yq -r '.controller.tolerations[] | select(.key == "node-role.kubernetes.io/control-plane") | .operator + ":" + .effect' "$alloy_logs_values")" == 'Exists:NoSchedule' ]]
	[[ "$(yq -r '.serviceMonitor.enabled' "$alloy_logs_values")" == 'true' ]]
	[[ "$(yq -r '.ingress.enabled' "$alloy_logs_values")" == 'false' ]]
	[[ "$(yq -r '.crds.create' "$alloy_logs_values")" == 'false' ]]

	[[ "$(yq -r '[((.rbac.rules // []) + (.rbac.clusterRules // []))[].apiGroups[]] | unique | sort | join(",")' "$alloy_logs_values")" == '' ]]
	[[ "$(yq -r '[((.rbac.rules // []) + (.rbac.clusterRules // []))[].resources[]] | unique | sort | join(",")' "$alloy_logs_values")" == 'pods' ]]
	[[ "$(yq -r '[((.rbac.rules // []) + (.rbac.clusterRules // []))[].verbs[]] | unique | sort | join(",")' "$alloy_logs_values")" == 'get,list,watch' ]]
	if yq -r '[((.rbac.rules // []) + (.rbac.clusterRules // []))[].resources[]] | .[]' "$alloy_logs_values" | rg -q '^(secrets|pods/log)$'; then
		echo 'Refusing: alloy-logs RBAC must not read Secrets or pods/log.' >&2
		exit 1
	fi

	# River behavior invariants. The exact Alloy v1.19.0 parser is run separately as an
	# independent syntax oracle; these checks keep the collection, filtering, and label
	# contracts reviewable in the repository validation gate.
	rg -Fq 'field = "spec.nodeName=" + env("NODE_NAME")' "$alloy_logs_config"
	rg -Fq '__meta_kubernetes_pod_annotation_observability_supermorphic_com_logs' "$alloy_logs_config"
	rg -Fq 'regex         = `^;(.+?)(?:-[a-z0-9]{8,10})?$`' "$alloy_logs_config"
	rg -Fq '__path__ = "/var/log/*.log"' "$alloy_logs_config"
	rg -Fq '__path__ = "/var/log/audit/kmsg.log"' "$alloy_logs_config"
	rg -Fq 'url = "http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push"' "$alloy_logs_config"
	[[ "$(rg -c '^[[:space:]]*stage\.cri \{[[:space:]]*\}$' "$alloy_logs_config")" == '1' ]]
	[[ "$(rg -Fc 'expression = `(?i)authorization\s*[:=]\s*(?:bearer|basic)\s+([^\s,;]+)`' "$alloy_logs_config")" == '2' ]]
	[[ "$(rg -Fc "expression = \`(?i)(?:password|passwd|token|api[_-]?key|secret)\s*[:=]\s*[\"']?([^\s\"',;]+)\`" "$alloy_logs_config")" == '2' ]]
	[[ "$(rg -Fc 'expression          = `(?i)temporary password.*session`' "$alloy_logs_config")" == '2' ]]
	[[ "$(rg -Fc 'drop_counter_reason = "temporary_password"' "$alloy_logs_config")" == '2' ]]
	python "$alloy_logs_river_validator" "$alloy_logs_config"

	kustomize build "$alloy_logs/app" >"$temp_dir/alloy-logs-package.yaml"
	[[ "$(yq ea -r 'select(.kind == "ConfigMap" and .metadata.name == "alloy-logs-values") | (.data | has("values.yaml"))' "$temp_dir/alloy-logs-package.yaml")" == 'true' ]]
	[[ "$(yq ea -r 'select(.kind == "ConfigMap" and .metadata.name == "alloy-logs-config") | (.data | has("config.alloy"))' "$temp_dir/alloy-logs-package.yaml")" == 'true' ]]

	HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
		helm template alloy-logs alloy --repo https://grafana.github.io/helm-charts --version 1.12.0 \
		--namespace monitoring --api-versions monitoring.coreos.com/v1/ServiceMonitor \
		--values "$alloy_logs_values" >"$temp_dir/alloy-logs.yaml"
	[[ "$(yq ea -r '[select(.kind == "DaemonSet" and .metadata.name == "alloy-logs")] | length' "$temp_dir/alloy-logs.yaml")" == '1' ]]
	[[ "$(yq ea -r '[select(.kind == "Deployment" or .kind == "StatefulSet")] | length' "$temp_dir/alloy-logs.yaml")" == '0' ]]
	[[ "$(yq ea -r '[select(.kind == "ServiceMonitor")] | length' "$temp_dir/alloy-logs.yaml")" == '1' ]]
	[[ "$(yq ea -r '[select(.kind == "Ingress" or .kind == "HTTPRoute")] | length' "$temp_dir/alloy-logs.yaml")" == '0' ]]
	[[ "$(yq ea -r '[select(.kind == "DaemonSet" and .metadata.name == "alloy-logs") | .spec.template.spec.nodeSelector // {} | length] | join(",")' "$temp_dir/alloy-logs.yaml")" == '0' ]]
	[[ "$(yq ea -r '[select(.kind == "DaemonSet" and .metadata.name == "alloy-logs") | .spec.template.spec.tolerations[] | select(.key == "node-role.kubernetes.io/control-plane") | .operator + ":" + .effect] | join(",")' "$temp_dir/alloy-logs.yaml")" == 'Exists:NoSchedule' ]]
	[[ "$(yq ea -r '[select(.kind == "DaemonSet" and .metadata.name == "alloy-logs") | .spec.template.spec.containers[] | select(.name == "alloy") | .env[] | select(.name == "NODE_NAME") | .valueFrom.fieldRef.fieldPath] | join(",")' "$temp_dir/alloy-logs.yaml")" == 'spec.nodeName' ]]
	[[ "$(yq ea -r '[select(.kind == "DaemonSet" and .metadata.name == "alloy-logs") | .spec.template.spec.volumes[] | select(.name == "alloy-storage") | .hostPath.path + ":" + .hostPath.type] | join(",")' "$temp_dir/alloy-logs.yaml")" == '/var/mnt/alloy-logs:DirectoryOrCreate' ]]
	[[ "$(yq ea -r '[select(.kind == "DaemonSet" and .metadata.name == "alloy-logs") | .spec.template.spec.containers[] | select(.name == "alloy") | .volumeMounts[] | select(.name == "alloy-storage") | .mountPath] | join(",")' "$temp_dir/alloy-logs.yaml")" == '/var/lib/alloy' ]]
	[[ "$(yq ea -r '[select(.kind == "DaemonSet" and .metadata.name == "alloy-logs") | .spec.template.spec.containers[] | select(.name == "alloy") | .volumeMounts[] | select(.name == "varlog") | .mountPath + ":" + (.readOnly | tostring)] | join(",")' "$temp_dir/alloy-logs.yaml")" == '/var/log:true' ]]
	[[ "$(yq ea -r '[select(.kind == "DaemonSet" and .metadata.name == "alloy-logs") | .spec.template.spec.volumes[] | select(has("hostPath")) | .hostPath.path] | sort | join(",")' "$temp_dir/alloy-logs.yaml")" == '/var/log,/var/mnt/alloy-logs' ]]
	[[ "$(yq ea -r '[select(.kind == "DaemonSet" and .metadata.name == "alloy-logs") | .spec.template.spec.containers[] | select(.name == "alloy") | .resources.requests.cpu] | join(",")' "$temp_dir/alloy-logs.yaml")" == '100m' ]]
	[[ "$(yq ea -r '[select(.kind == "DaemonSet" and .metadata.name == "alloy-logs") | .spec.template.spec.containers[] | select(.name == "alloy") | .resources.requests.memory] | join(",")' "$temp_dir/alloy-logs.yaml")" == '128Mi' ]]
	[[ "$(yq ea -r '[select(.kind == "DaemonSet" and .metadata.name == "alloy-logs") | .spec.template.spec.containers[] | select(.name == "alloy") | .resources.limits.cpu] | join(",")' "$temp_dir/alloy-logs.yaml")" == '1' ]]
	[[ "$(yq ea -r '[select(.kind == "DaemonSet" and .metadata.name == "alloy-logs") | .spec.template.spec.containers[] | select(.name == "alloy") | .resources.limits.memory] | join(",")' "$temp_dir/alloy-logs.yaml")" == '512Mi' ]]
	[[ "$(yq ea -r '[select(.kind == "DaemonSet" and .metadata.name == "alloy-logs") | .spec.template.spec.containers[] | select(.name == "alloy") | .args[] | select(. == "--disable-reporting")] | length' "$temp_dir/alloy-logs.yaml")" == '1' ]]
	[[ "$(yq ea -r '[select(.kind == "DaemonSet" and .metadata.name == "alloy-logs") | .spec.template.spec.containers[] | select(.name == "alloy") | .args[] | select(test("^--cluster\\."))] | length' "$temp_dir/alloy-logs.yaml")" == '0' ]]
	[[ "$(yq ea -r '[select(.kind == "ClusterRole" and .metadata.name == "alloy-logs") | .rules[].apiGroups[]] | unique | sort | join(",")' "$temp_dir/alloy-logs.yaml")" == '' ]]
	[[ "$(yq ea -r '[select(.kind == "ClusterRole" and .metadata.name == "alloy-logs") | .rules[].resources[]] | unique | sort | join(",")' "$temp_dir/alloy-logs.yaml")" == 'pods' ]]
	[[ "$(yq ea -r '[select(.kind == "ClusterRole" and .metadata.name == "alloy-logs") | .rules[].verbs[]] | unique | sort | join(",")' "$temp_dir/alloy-logs.yaml")" == 'get,list,watch' ]]
	bash "$alloy_logs_render_validator" "$temp_dir/alloy-logs.yaml"
fi

# --- Alloy Events: one cluster-wide, disposable Kubernetes Event reader ---
if [[ "$scope" == all || "$scope" == alloy-events ]]; then
	alloy_events='kubernetes/apps/monitoring/alloy-events'
	alloy_events_ks="$alloy_events/ks.yaml"
	alloy_events_values="$alloy_events/app/values.yaml"
	alloy_events_hr="$alloy_events/app/helmrelease.yaml"
	alloy_events_config="$alloy_events/app/config.alloy"
	alloy_events_kustomization="$alloy_events/app/kustomization.yaml"

	for f in "$alloy_events_ks" "$alloy_events_values" "$alloy_events_hr" \
		"$alloy_events_config" "$alloy_events_kustomization"; do
		[[ -f "$f" ]] || {
			echo "Missing Alloy Events source: $f" >&2
			exit 1
		}
	done

	rg -qx '  - ./alloy-events/ks.yaml' kubernetes/apps/monitoring/kustomization.yaml || {
		echo 'Refusing: alloy-events is not wired into monitoring/kustomization.yaml.' >&2
		exit 1
	}

	[[ "$(yq -r '.metadata.name' "$alloy_events_ks")" == 'alloy-events' ]]
	[[ "$(yq -r '.metadata.namespace' "$alloy_events_ks")" == 'flux-system' ]]
	[[ "$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$alloy_events_ks")" == 'loki' ]]
	[[ "$(yq -r '.spec.path' "$alloy_events_ks")" == './kubernetes/apps/monitoring/alloy-events/app' ]]
	[[ "$(yq -r '.spec.prune' "$alloy_events_ks")" == 'true' ]]
	[[ "$(yq -r '.spec.wait' "$alloy_events_ks")" == 'true' ]]

	[[ "$(yq -r '.metadata.name' "$alloy_events_hr")" == 'alloy-events' ]]
	[[ "$(yq -r '.metadata.namespace' "$alloy_events_hr")" == 'monitoring' ]]
	[[ "$(yq -r '.spec.chart.spec.chart' "$alloy_events_hr")" == 'alloy' ]]
	[[ "$(yq -r '.spec.chart.spec.version' "$alloy_events_hr")" == '1.12.0' ]]
	[[ "$(yq -r '.spec.chart.spec.sourceRef.kind' "$alloy_events_hr")" == 'HelmRepository' ]]
	[[ "$(yq -r '.spec.chart.spec.sourceRef.name' "$alloy_events_hr")" == 'grafana' ]]
	[[ "$(yq -r '.spec.targetNamespace' "$alloy_events_hr")" == 'monitoring' ]]
	[[ "$(yq -r '.spec.valuesFrom[0].kind' "$alloy_events_hr")" == 'ConfigMap' ]]
	[[ "$(yq -r '.spec.valuesFrom[0].name' "$alloy_events_hr")" == 'alloy-events-values' ]]
	[[ "$(yq -r '.spec.valuesFrom[0].valuesKey' "$alloy_events_hr")" == 'values.yaml' ]]

	[[ "$(yq -r '.alloy.configMap.create' "$alloy_events_values")" == 'false' ]]
	[[ "$(yq -r '.alloy.configMap.name' "$alloy_events_values")" == 'alloy-events-config' ]]
	[[ "$(yq -r '.alloy.configMap.key' "$alloy_events_values")" == 'config.alloy' ]]
	[[ "$(yq -r '.alloy.clustering.enabled' "$alloy_events_values")" == 'false' ]]
	[[ "$(yq -r '.alloy.enableReporting' "$alloy_events_values")" == 'false' ]]
	[[ "$(yq -r '.alloy.stabilityLevel' "$alloy_events_values")" == 'generally-available' ]]
	[[ "$(yq -r '.alloy.storagePath' "$alloy_events_values")" == '/tmp/alloy' ]]
	[[ "$(yq -r '.alloy.mounts.varlog' "$alloy_events_values")" == 'false' ]]
	[[ "$(yq -r '.alloy.resources.requests.cpu' "$alloy_events_values")" == '25m' &&
	"$(yq -r '.alloy.resources.requests.memory' "$alloy_events_values")" == '64Mi' &&
	"$(yq -r '.alloy.resources.limits.cpu' "$alloy_events_values")" == '250m' &&
	"$(yq -r '.alloy.resources.limits.memory' "$alloy_events_values")" == '256Mi' ]] || {
		echo 'Refusing: Alloy Events resource envelope drifted.' >&2
		exit 1
	}
	[[ "$(yq -r '.controller.type' "$alloy_events_values")" == 'deployment' ]] || {
		echo 'Refusing: Alloy Events controller must remain a Deployment.' >&2
		exit 1
	}
	[[ "$(yq -r '.controller.replicas' "$alloy_events_values")" == '1' ]] || {
		echo 'Refusing: Alloy Events controller must have exactly one replica.' >&2
		exit 1
	}
	[[ "$(yq -r '.controller.updateStrategy.type' "$alloy_events_values")" == 'Recreate' ]] || {
		echo 'Refusing: Alloy Events controller must use Recreate.' >&2
		exit 1
	}
	[[ "$(yq -r '.serviceMonitor.enabled' "$alloy_events_values")" == 'true' ]]
	[[ "$(yq -r '.ingress.enabled' "$alloy_events_values")" == 'false' ]]
	[[ "$(yq -r '.crds.create' "$alloy_events_values")" == 'false' ]]

	[[ "$(yq -r '[((.rbac.rules // []) + (.rbac.clusterRules // []))[]] | length' "$alloy_events_values")" == '2' ]] || {
		echo 'Refusing: Alloy Events source RBAC must contain exactly the two chart-compatible Event rules.' >&2
		exit 1
	}
	[[ "$(yq -r '[((.rbac.rules // []) + (.rbac.clusterRules // []))[] | (keys | sort | join(","))] | unique | join(";")' "$alloy_events_values")" == 'apiGroups,resources,verbs' ]] || {
		echo 'Refusing: Alloy Events source RBAC rules must not contain non-resource permissions or unexpected fields.' >&2
		exit 1
	}
	[[ "$(yq -r '[((.rbac.rules // []) + (.rbac.clusterRules // []))[] | ((.apiGroups | sort | join(",")) + "|" + (.resources | sort | join(",")) + "|" + (.verbs | sort | join(",")))] | unique | join(";")' "$alloy_events_values")" == '|events|get,list,watch' ]] || {
		echo 'Refusing: every Alloy Events source RBAC rule must grant only core Events get, list, and watch.' >&2
		exit 1
	}

	# The structural validator proves all-namespace collection, the protected route,
	# redaction, exact label allowlist, and absence of alternate source, metadata, and WAL paths.
	python "$alloy_logs_river_validator" --events "$alloy_events_config"

	kustomize build "$alloy_events/app" >"$temp_dir/alloy-events-package.yaml"
	[[ "$(yq ea -r 'select(.kind == "ConfigMap" and .metadata.name == "alloy-events-values") | (.data | has("values.yaml"))' "$temp_dir/alloy-events-package.yaml")" == 'true' ]]
	[[ "$(yq ea -r 'select(.kind == "ConfigMap" and .metadata.name == "alloy-events-config") | (.data | has("config.alloy"))' "$temp_dir/alloy-events-package.yaml")" == 'true' ]]
	[[ "$(yq ea -r '[select(.kind == "PersistentVolumeClaim" or .kind == "PrometheusRule" or .kind == "AlertmanagerConfig")] | length' "$temp_dir/alloy-events-package.yaml")" == '0' ]]

	HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
		helm template alloy-events alloy --repo https://grafana.github.io/helm-charts --version 1.12.0 \
		--namespace monitoring --api-versions monitoring.coreos.com/v1/ServiceMonitor \
		--values "$alloy_events_values" >"$temp_dir/alloy-events.yaml"
	[[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "alloy-events")] | length' "$temp_dir/alloy-events.yaml")" == '1' ]]
	[[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "alloy-events") | .spec.replicas] | join(",")' "$temp_dir/alloy-events.yaml")" == '1' ]]
	[[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "alloy-events") | .spec.strategy.type] | join(",")' "$temp_dir/alloy-events.yaml")" == 'Recreate' ]]
	[[ "$(yq ea -r '[select(.kind == "DaemonSet" or .kind == "StatefulSet" or .kind == "HorizontalPodAutoscaler")] | length' "$temp_dir/alloy-events.yaml")" == '0' ]]
	[[ "$(yq ea -r '[select(.kind == "ServiceMonitor")] | length' "$temp_dir/alloy-events.yaml")" == '1' ]]
	[[ "$(yq ea -r '[select(.kind == "Ingress" or .kind == "HTTPRoute" or .kind == "PersistentVolumeClaim" or .kind == "PrometheusRule" or .kind == "AlertmanagerConfig")] | length' "$temp_dir/alloy-events.yaml")" == '0' ]]
	[[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "alloy-events") | .spec.template.spec.volumes[] | select(has("persistentVolumeClaim"))] | length' "$temp_dir/alloy-events.yaml")" == '0' ]]
	[[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "alloy-events") | .spec.template.spec.volumes[] | select(.name == "alloy-storage") | has("emptyDir")] | join(",")' "$temp_dir/alloy-events.yaml")" == 'true' ]]
	[[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "alloy-events") | .spec.template.spec.containers[] | select(.name == "alloy") | .volumeMounts[] | select(.name == "alloy-storage") | .mountPath] | join(",")' "$temp_dir/alloy-events.yaml")" == '/tmp/alloy' ]]
	[[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "alloy-events") | .spec.template.spec.volumes[] | select(has("hostPath") or has("persistentVolumeClaim"))] | length' "$temp_dir/alloy-events.yaml")" == '0' ]]
	[[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "alloy-events") | .spec.template.spec.containers[] | select(.name == "alloy") | .resources.requests.cpu] | join(",")' "$temp_dir/alloy-events.yaml")" == '25m' ]]
	[[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "alloy-events") | .spec.template.spec.containers[] | select(.name == "alloy") | .resources.requests.memory] | join(",")' "$temp_dir/alloy-events.yaml")" == '64Mi' ]]
	[[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "alloy-events") | .spec.template.spec.containers[] | select(.name == "alloy") | .resources.limits.cpu] | join(",")' "$temp_dir/alloy-events.yaml")" == '250m' ]]
	[[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "alloy-events") | .spec.template.spec.containers[] | select(.name == "alloy") | .resources.limits.memory] | join(",")' "$temp_dir/alloy-events.yaml")" == '256Mi' ]]
	[[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "alloy-events") | .spec.template.spec.containers[] | select(.name == "alloy") | .args[] | select(. == "--disable-reporting")] | length' "$temp_dir/alloy-events.yaml")" == '1' ]]
	[[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "alloy-events") | .spec.template.spec.containers[] | select(.name == "alloy") | .args[] | select(test("^--cluster\\."))] | length' "$temp_dir/alloy-events.yaml")" == '0' ]]
	[[ "$(yq ea -r '[select(.kind == "ClusterRole" and .metadata.name == "alloy-events") | .rules[]] | length' "$temp_dir/alloy-events.yaml")" == '2' ]] || {
		echo 'Refusing: rendered Alloy Events ClusterRole must contain exactly the two chart-compatible Event rules.' >&2
		exit 1
	}
	[[ "$(yq ea -r '[select(.kind == "ClusterRole" and .metadata.name == "alloy-events") | .rules[] | (keys | sort | join(","))] | unique | join(";")' "$temp_dir/alloy-events.yaml")" == 'apiGroups,resources,verbs' ]] || {
		echo 'Refusing: rendered Alloy Events RBAC rules must not contain non-resource permissions or unexpected fields.' >&2
		exit 1
	}
	[[ "$(yq ea -r '[select(.kind == "ClusterRole" and .metadata.name == "alloy-events") | .rules[] | ((.apiGroups | sort | join(",")) + "|" + (.resources | sort | join(",")) + "|" + (.verbs | sort | join(",")))] | unique | join(";")' "$temp_dir/alloy-events.yaml")" == '|events|get,list,watch' ]] || {
		echo 'Refusing: every rendered Alloy Events RBAC rule must grant only core Events get, list, and watch.' >&2
		exit 1
	}
	bash "$alloy_logs_render_validator" "$temp_dir/alloy-events.yaml" Deployment alloy-events 473
fi

# --- Flux reconciliation alerting: dedicated KSM (gotk_resource_info) + PodMonitor + rule ---
if [[ "$scope" == all ]]; then
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

	# Keep the dedicated exporter until a separately validated migration proves
	# metric and alert parity. A successful KPS upgrade alone does not prove parity.
	[[ "$(yq -r '.["kube-state-metrics"].customResourceState // "absent"' "$values")" == 'absent' ]] || {
		echo 'Refusing: bundled customResourceState requires a validated Flux exporter migration.' >&2
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
fi

case "$scope" in
all)
	echo 'Monitoring source, encrypted Grafana Secret, dependency graph, values, HTTPRoutes, pinned kube-prometheus-stack, Loki, Alloy logs, and Alloy Events renders, Grafana Loki datasource, and Flux reconciliation alerting (dedicated KSM + PodMonitor + rule) passed validation.'
	;;
loki) echo 'Loki source and render passed validation.' ;;
alloy-logs) echo 'Alloy Logs source and render passed validation.' ;;
alloy-events) echo 'Alloy Events source and render passed validation.' ;;
esac
