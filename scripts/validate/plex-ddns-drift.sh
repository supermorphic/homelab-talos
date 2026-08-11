#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source scripts/lib/common.sh
require_bash

root='kubernetes/apps/monitoring/plex-ddns-drift'
app="$root/app"
image='docker.io/library/caddy:2.11.4-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648'
validation_tmp="$(mktemp -d "${TMPDIR:-/tmp}/plex-ddns-drift-validate.XXXXXX")"
trap 'rm -rf -- "$validation_tmp"' EXIT

assert_equal() {
  local actual="$1" expected="$2" description="$3"
  [[ "$actual" == "$expected" ]] || {
    echo "$description; expected '$expected', got '$actual'." >&2
    exit 1
  }
}

for file in ks.yaml deployment.yaml service.yaml servicemonitor.yaml prometheusrule.yaml ciliumnetworkpolicy.yaml kustomization.yaml Caddyfile check.sh; do
  path="$root/$file"
  [[ "$file" == ks.yaml ]] || path="$app/$file"
  [[ -f "$path" ]] || { echo "Missing Plex DDNS drift source: $path" >&2; exit 1; }
done
rg -Fxq '  - ./plex-ddns-drift/ks.yaml' kubernetes/apps/monitoring/kustomization.yaml

kustomization="$app/kustomization.yaml"
assert_equal "$(yq -r '.resources | sort | join(" ")' "$kustomization")" \
  './ciliumnetworkpolicy.yaml ./deployment.yaml ./prometheusrule.yaml ./service.yaml ./servicemonitor.yaml' \
  'Plex DDNS drift resources must be exact'
assert_equal "$(yq -r '.configMapGenerator | length' "$kustomization")" '1' \
  'Plex DDNS drift must have exactly one generated ConfigMap'
assert_equal "$(yq -r '.configMapGenerator[0] | [.name, .namespace, (.files | sort | join(","))] | join(" ")' "$kustomization")" \
  'plex-ddns-drift-config monitoring Caddyfile=Caddyfile,check.sh=check.sh' \
  'Plex DDNS drift ConfigMap inputs must be exact'
assert_equal "$(yq -r '.generatorOptions.disableNameSuffixHash // false' "$kustomization")" 'false' \
  'Plex DDNS drift ConfigMap name hashing must remain enabled'

ks="$root/ks.yaml"
[[ "$(yq -r '.metadata.name + " " + .metadata.namespace' "$ks")" == 'plex-ddns-drift flux-system' ]]
[[ "$(yq -r '.spec.suspend' "$ks")" == 'true' ]]
[[ "$(yq -r '.spec.path' "$ks")" == './kubernetes/apps/monitoring/plex-ddns-drift/app' ]]
[[ "$(yq -r '.spec.dependsOn | map(.name) | sort | join(" ")' "$ks")" == 'kube-prometheus-stack' ]]

deployment="$app/deployment.yaml"
[[ "$(yq -r '.metadata.name + " " + .metadata.namespace' "$deployment")" == 'plex-ddns-drift monitoring' ]]
[[ "$(yq -r '.spec.replicas' "$deployment")" == '1' ]]
[[ "$(yq -r '.spec.template.spec.automountServiceAccountToken' "$deployment")" == 'false' ]]
assert_equal "$(yq -r '.spec.template.spec | keys | sort | join(",")' "$deployment")" \
  'automountServiceAccountToken,containers,securityContext,volumes' 'Pod spec fields must be exact'
assert_equal "$(yq -r '.spec.template.spec.securityContext | keys | sort | join(",")' "$deployment")" \
  'fsGroup,fsGroupChangePolicy,runAsGroup,runAsNonRoot,runAsUser,seccompProfile' 'Pod security context fields must be exact'
assert_equal "$(yq -r '.spec.template.spec.securityContext | [.fsGroup, .fsGroupChangePolicy, .runAsGroup, .runAsNonRoot, .runAsUser, .seccompProfile.type] | join(" ")' "$deployment")" \
  '1000 OnRootMismatch 1000 true 1000 RuntimeDefault' 'Pod security context must be exact'
[[ "$(yq -r '.spec.template.spec.containers | length' "$deployment")" == '2' ]]
assert_equal "$(yq -r '.spec.selector.matchLabels | to_entries | map(.key + "=" + .value) | sort | join(",")' "$deployment")" \
  'app.kubernetes.io/name=plex-ddns-drift' 'Deployment selector must be exact'
assert_equal "$(yq -r '.spec.template.metadata.labels | to_entries | map(.key + "=" + .value) | sort | join(",")' "$deployment")" \
  'app.kubernetes.io/name=plex-ddns-drift' 'Pod labels must be exact'
assert_equal "$(yq -r '.spec.template.spec.containers | map(.name) | sort | join(" ")' "$deployment")" \
  'collector server' 'Deployment containers must be exact'
for container in collector server; do
  [[ "$(CONTAINER="$container" yq -r '.spec.template.spec.containers[] | select(.name == strenv(CONTAINER)) | .image' "$deployment")" == "$image" ]]
  [[ "$(CONTAINER="$container" yq -r '.spec.template.spec.containers[] | select(.name == strenv(CONTAINER)) | [.resources.requests.cpu, .resources.requests.memory, .resources.limits.memory] | join(" ")' "$deployment")" == '5m 16Mi 64Mi' ]]
  [[ "$(CONTAINER="$container" yq -r '.spec.template.spec.containers[] | select(.name == strenv(CONTAINER)) | [.securityContext.allowPrivilegeEscalation, .securityContext.readOnlyRootFilesystem, (.securityContext.capabilities.drop | join(","))] | join(" ")' "$deployment")" == 'false true ALL' ]]
  assert_equal "$(CONTAINER="$container" yq -r '.spec.template.spec.containers[] | select(.name == strenv(CONTAINER)) | .resources | keys | sort | join(",")' "$deployment")" \
    'limits,requests' "$container resource fields must be exact"
  assert_equal "$(CONTAINER="$container" yq -r '.spec.template.spec.containers[] | select(.name == strenv(CONTAINER)) | .resources.requests | keys | sort | join(",")' "$deployment")" \
    'cpu,memory' "$container resource requests must be exact"
  assert_equal "$(CONTAINER="$container" yq -r '.spec.template.spec.containers[] | select(.name == strenv(CONTAINER)) | .resources.limits | keys | sort | join(",")' "$deployment")" \
    'memory' "$container resource limits must be exact"
  assert_equal "$(CONTAINER="$container" yq -r '.spec.template.spec.containers[] | select(.name == strenv(CONTAINER)) | .securityContext | keys | sort | join(",")' "$deployment")" \
    'allowPrivilegeEscalation,capabilities,readOnlyRootFilesystem' "$container security fields must be exact"
done
assert_equal "$(yq -r '.spec.template.spec.containers[] | select(.name == "collector") | keys | sort | join(",")' "$deployment")" \
  'command,image,name,resources,securityContext,volumeMounts' 'Collector container fields must be exact'
assert_equal "$(yq -r '.spec.template.spec.containers[] | select(.name == "collector") | .command | join(" ")' "$deployment")" \
  '/bin/sh /opt/plex-ddns-drift/check.sh' 'Collector command must be exact'
assert_equal "$(yq -r '.spec.template.spec.containers[] | select(.name == "collector") | .volumeMounts | map(.name + "=" + .mountPath + ":" + ((.readOnly // false) | tostring)) | sort | join(",")' "$deployment")" \
  'config=/opt/plex-ddns-drift:true,metrics=/metrics:false' 'Collector volume mounts must be exact'
assert_equal "$(yq -r '.spec.template.spec.containers[] | select(.name == "server") | keys | sort | join(",")' "$deployment")" \
  'args,env,image,livenessProbe,name,ports,readinessProbe,resources,securityContext,volumeMounts' 'Metrics server container fields must be exact'
assert_equal "$(yq -r '.spec.template.spec.containers[] | select(.name == "server") | .args | join(" ")' "$deployment")" \
  'caddy run --config /opt/plex-ddns-drift/Caddyfile --adapter caddyfile' 'Metrics server arguments must be exact'
assert_equal "$(yq -r '.spec.template.spec.containers[] | select(.name == "server") | .env | map(.name + "=" + .value) | sort | join(",")' "$deployment")" \
  'HOME=/tmp,XDG_CONFIG_HOME=/tmp/config,XDG_DATA_HOME=/tmp/data' 'Metrics server environment must be exact'
assert_equal "$(yq -r '.spec.template.spec.containers[] | select(.name == "server") | .ports | map(.name + "=" + (.containerPort | tostring) + "/" + .protocol) | join(",")' "$deployment")" \
  'metrics=9090/TCP' 'Metrics server port must be exact'
for probe in livenessProbe readinessProbe; do
  assert_equal "$(PROBE="$probe" yq -r '.spec.template.spec.containers[] | select(.name == "server") | .[strenv(PROBE)] | keys | join(",")' "$deployment")" \
    'httpGet' "Metrics server $probe fields must be exact"
  assert_equal "$(PROBE="$probe" yq -r '.spec.template.spec.containers[] | select(.name == "server") | .[strenv(PROBE)].httpGet | [.path, .port] | join(" ")' "$deployment")" \
    '/metrics metrics' "Metrics server $probe must target the metrics route"
done
assert_equal "$(yq -r '.spec.template.spec.containers[] | select(.name == "server") | .volumeMounts | map(.name + "=" + .mountPath + ":" + ((.readOnly // false) | tostring)) | sort | join(",")' "$deployment")" \
  'config=/opt/plex-ddns-drift:true,metrics=/metrics:true,tmp=/tmp:false' 'Metrics server volume mounts must be exact'
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "collector") | (.securityContext.capabilities.add // []) | length' "$deployment")" == '0' ]]
assert_equal "$(yq -r '.spec.template.spec.containers[] | select(.name == "collector") | .securityContext.capabilities | keys | join(",")' "$deployment")" \
  'drop' 'Collector capabilities must be exact'
assert_equal "$(yq -r '.spec.template.spec.containers[] | select(.name == "server") | .securityContext.capabilities | keys | sort | join(",")' "$deployment")" \
  'add,drop' 'Metrics server capabilities must be exact'
# NET_BIND_SERVICE is mandatory here and must not be "cleaned up": the Caddy binary
# carries file capabilities, so under NO_NEW_PRIVS the exec itself fails without it.
# Assert the exact singleton so neither removing it nor widening it passes.
assert_equal "$(yq -r '.spec.template.spec.containers[] | select(.name == "server") | .securityContext.capabilities.add | join(",")' "$deployment")" \
  'NET_BIND_SERVICE' 'Metrics server must add exactly NET_BIND_SERVICE to exec Caddy'
assert_equal "$(yq -r '.spec.template.spec.volumes | map(.name) | sort | join(" ")' "$deployment")" \
  'config metrics tmp' 'Deployment volumes must be exact'
assert_equal "$(yq -r '.spec.template.spec.volumes[] | select(.name == "config") | keys | sort | join(",")' "$deployment")" \
  'configMap,name' 'Config volume type must be exact'
assert_equal "$(yq -r '.spec.template.spec.volumes[] | select(.name == "config") | .configMap | keys | sort | join(",")' "$deployment")" \
  'defaultMode,name' 'ConfigMap volume fields must be exact'
assert_equal "$(yq -r '.spec.template.spec.volumes[] | select(.name == "config") | [.configMap.name, (.configMap.defaultMode | tostring)] | join(" ")' "$deployment")" \
  'plex-ddns-drift-config 0555' 'Generated ConfigMap volume must be exact'
for volume in metrics tmp; do
  volume_label="${volume^}"
  [[ "$volume" != 'tmp' ]] || volume_label='Temporary'
  assert_equal "$(VOLUME="$volume" yq -r '.spec.template.spec.volumes[] | select(.name == strenv(VOLUME)) | keys | sort | join(",")' "$deployment")" \
    'emptyDir,name' "$volume_label volume must be emptyDir only"
  assert_equal "$(VOLUME="$volume" yq -r '.spec.template.spec.volumes[] | select(.name == strenv(VOLUME)) | .emptyDir | keys | length' "$deployment")" \
    '0' "$volume_label emptyDir must have no widening options"
done

service="$app/service.yaml"
assert_equal "$(yq -r '.spec | keys | sort | join(",")' "$service")" 'ports,selector' 'Service fields must be exact'
assert_equal "$(yq -r '.spec.selector | to_entries | map(.key + "=" + .value) | join(",")' "$service")" \
  'app.kubernetes.io/name=plex-ddns-drift' 'Service selector must be exact'
assert_equal "$(yq -r '.spec.ports | map([.name, (.port | tostring), .protocol, .targetPort] | join("/")) | join(" ")' "$service")" \
  'metrics/9090/TCP/metrics' 'Service port must be exact'
[[ "$(yq -r '.spec.endpoints | length' "$app/servicemonitor.yaml")" == '1' ]]
[[ "$(yq -r '.spec.endpoints[0] | [.port, .path, .interval] | join(" ")' "$app/servicemonitor.yaml")" == 'metrics /metrics 60s' ]]
assert_equal "$(yq -r '.spec.selector.matchLabels | to_entries | map(.key + "=" + .value) | join(",")' "$app/servicemonitor.yaml")" \
  'app.kubernetes.io/name=plex-ddns-drift' 'ServiceMonitor selector must be exact'
assert_equal "$(yq -r '.spec.endpoints[0] | keys | sort | join(",")' "$app/servicemonitor.yaml")" \
  'interval,path,port' 'ServiceMonitor endpoint fields must be exact'

rules="$app/prometheusrule.yaml"
[[ "$(yq -r '.spec.groups[0].rules | map(.alert) | sort | join(" ")' "$rules")" == 'PlexDdnsAddressMismatch PlexDdnsCheckFailed PlexDdnsCheckStale PlexDdnsMetricsMissing' ]]
[[ "$(yq -r '.spec.groups[0].rules[] | select(.alert == "PlexDdnsAddressMismatch") | [.expr, .for, .labels.severity] | join("|")' "$rules")" == 'plex_ddns_check_success == 1 and plex_ddns_addresses_match == 0|10m|warning' ]]
[[ "$(yq -r '.spec.groups[0].rules[] | select(.alert == "PlexDdnsCheckFailed") | [.expr, .for, .labels.severity] | join("|")' "$rules")" == 'plex_ddns_check_success == 0|15m|warning' ]]
[[ "$(yq -r '.spec.groups[0].rules[] | select(.alert == "PlexDdnsCheckStale") | [.expr, .for, .labels.severity] | join("|")' "$rules")" == 'plex_ddns_last_success_unixtime > 0 and time() - plex_ddns_last_success_unixtime > 1800|5m|warning' ]]
[[ "$(yq -r '.spec.groups[0].rules[] | select(.alert == "PlexDdnsMetricsMissing") | [.expr, .for, .labels.severity] | join("|")' "$rules")" == 'absent(plex_ddns_check_success)|15m|warning' ]]

# Every metric the collector publishes must be watched by at least one alert. A
# metric exported and never evaluated is a blind spot that looks like coverage:
# a wedged collector keeps serving its last file, so only the success timestamp
# distinguishes hung from healthy.
exported_metrics="$(rg -o --replace '$1' '# TYPE (plex_ddns_[a-z_]+) gauge' "$app/check.sh" | sort -u)"
[[ -n "$exported_metrics" ]]
alerted_metrics="$(yq -r '.spec.groups[].rules[].expr' "$rules" | rg -o 'plex_ddns_[a-z_]+' | sort -u)"
unwatched="$(comm -23 <(printf '%s\n' "$exported_metrics") <(printf '%s\n' "$alerted_metrics"))"
[[ -z "$unwatched" ]] || {
  echo "Plex DDNS metrics are exported but never alerted on: $(tr '\n' ' ' <<<"$unwatched")" >&2
  exit 1
}
if yq -r '.spec.groups[].rules[].annotations[]' "$rules" | rg -q '([0-9]{1,3}\.){3}[0-9]{1,3}'; then
  echo 'Plex DDNS alert annotations must never contain addresses.' >&2
  exit 1
fi

policy="$app/ciliumnetworkpolicy.yaml"
[[ "$(yq -r '.metadata.name + " " + .metadata.namespace' "$policy")" == 'plex-ddns-drift monitoring' ]]
assert_equal "$(yq -r '.spec.endpointSelector.matchLabels | to_entries | map(.key + "=" + .value) | join(",")' "$policy")" \
  'app.kubernetes.io/name=plex-ddns-drift' 'Cilium endpoint selector must be exact'
assert_equal "$(yq -r '.spec.ingress | length' "$policy")" '1' 'Cilium policy must have exactly one ingress rule'
assert_equal "$(yq -r '.spec.ingress[0] | keys | sort | join(",")' "$policy")" \
  'fromEndpoints,toPorts' 'Cilium ingress rule fields must be exact'
assert_equal "$(yq -r '.spec.ingress[0].fromEndpoints | length' "$policy")" '1' \
  'Cilium ingress must have exactly one source selector'
assert_equal "$(yq -r '.spec.ingress[0].fromEndpoints[0].matchLabels | to_entries | map(.key + "=" + .value) | join(",")' "$policy")" \
  'k8s:io.kubernetes.pod.namespace=monitoring' 'Cilium ingress source must be the monitoring namespace'
assert_equal "$(yq -r '.spec.ingress[0].toPorts | length' "$policy")" '1' \
  'Cilium ingress must have exactly one port rule'
assert_equal "$(yq -r '.spec.ingress[0].toPorts[0] | keys | join(",")' "$policy")" \
  'ports' 'Cilium ingress port rule fields must be exact'
assert_equal "$(yq -r '.spec.ingress[0].toPorts[0].ports | length' "$policy")" '1' \
  'Cilium ingress port list must be exact'
assert_equal "$(yq -r '.spec.ingress[0].toPorts[0].ports | map(.port + "/" + .protocol) | join(" ")' "$policy")" \
  '9090/TCP' 'Cilium ingress port must be exact'
assert_equal "$(yq -r '.spec.egress | length' "$policy")" '3' 'Cilium policy must have exactly three egress rules'
assert_equal "$(yq -r '.spec.egress[] | select(has("toEndpoints")) | keys | sort | join(",")' "$policy")" \
  'toEndpoints,toPorts' 'Cilium kube-dns egress fields must be exact'
assert_equal "$(yq -r '.spec.egress[] | select(has("toEndpoints")) | .toEndpoints | length' "$policy")" '1' \
  'Cilium kube-dns egress must have exactly one endpoint selector'
assert_equal "$(yq -r '.spec.egress[] | select(has("toEndpoints")) | .toEndpoints[0].matchLabels | to_entries | map(.key + "=" + .value) | sort | join(",")' "$policy")" \
  'k8s:io.kubernetes.pod.namespace=kube-system,k8s:k8s-app=kube-dns' 'Cilium kube-dns selector must be exact'
assert_equal "$(yq -r '.spec.egress[] | select(has("toEndpoints")) | .toPorts | length' "$policy")" '1' \
  'Cilium kube-dns port rule must be exact'
assert_equal "$(yq -r '.spec.egress[] | select(has("toEndpoints")) | .toPorts[0] | keys | join(",")' "$policy")" \
  'ports' 'Cilium kube-dns port rule fields must be exact'
assert_equal "$(yq -r '.spec.egress[] | select(has("toEndpoints")) | .toPorts[0].ports | length' "$policy")" '2' \
  'Cilium kube-dns port list must be exact'
assert_equal "$(yq -r '.spec.egress[] | select(has("toEndpoints")) | .toPorts[0].ports | map(.port + "/" + .protocol) | sort | join(",")' "$policy")" \
  '53/TCP,53/UDP' 'Cilium kube-dns ports must be exact'
assert_equal "$(yq -r '.spec.egress[] | select(has("toCIDR")) | keys | sort | join(",")' "$policy")" \
  'toCIDR,toPorts' 'Cilium resolver egress fields must be exact'
assert_equal "$(yq -r '.spec.egress[] | select(has("toCIDR")) | .toCIDR | join(" ")' "$policy")" \
  '1.1.1.1/32' 'Cilium resolver CIDR must be exact'
assert_equal "$(yq -r '.spec.egress[] | select(has("toCIDR")) | .toPorts | length' "$policy")" '1' \
  'Cilium resolver port rule must be exact'
assert_equal "$(yq -r '.spec.egress[] | select(has("toCIDR")) | .toPorts[0] | keys | join(",")' "$policy")" \
  'ports' 'Cilium resolver port rule fields must be exact'
assert_equal "$(yq -r '.spec.egress[] | select(has("toCIDR")) | .toPorts[0].ports | length' "$policy")" '2' \
  'Cilium resolver port list must be exact'
assert_equal "$(yq -r '.spec.egress[] | select(has("toCIDR")) | .toPorts[0].ports | map(.port + "/" + .protocol) | sort | join(",")' "$policy")" \
  '53/TCP,53/UDP' 'Cilium resolver ports must be exact'
assert_equal "$(yq -r '[.spec.egress[] | select(has("toEntities"))] | length' "$policy")" '0' \
  'Cilium egress must not use a broad entity selector'
assert_equal "$(yq -r '.spec.egress[] | select(has("toCIDRSet")) | keys | sort | join(",")' "$policy")" \
  'toCIDRSet,toPorts' 'Cilium HTTPS egress fields must be exact'
assert_equal "$(yq -r '.spec.egress[] | select(has("toCIDRSet")) | .toCIDRSet | length' "$policy")" '1' \
  'Cilium HTTPS CIDR set must be exact'
assert_equal "$(yq -r '.spec.egress[] | select(has("toCIDRSet")) | .toCIDRSet[0].cidr' "$policy")" \
  '0.0.0.0/0' 'Cilium HTTPS CIDR must be exact'
assert_equal "$(yq -r '.spec.egress[] | select(has("toCIDRSet")) | .toPorts | length' "$policy")" '1' \
  'Cilium HTTPS port rule must be exact'
assert_equal "$(yq -r '.spec.egress[] | select(has("toCIDRSet")) | .toPorts[0] | keys | join(",")' "$policy")" \
  'ports' 'Cilium HTTPS port rule fields must be exact'
assert_equal "$(yq -r '.spec.egress[] | select(has("toCIDRSet")) | .toPorts[0].ports | length' "$policy")" '1' \
  'Cilium HTTPS port list must be exact'
assert_equal "$(yq -r '.spec.egress[] | select(has("toCIDRSet")) | [.toPorts[0].ports[0].port, .toPorts[0].ports[0].protocol] | join(" ")' "$policy")" \
  '443 TCP' 'Cilium HTTPS egress must be exact'

# The exporter reaches one public IP-echo endpoint, so its off-cluster HTTPS bound
# must exclude every private, shared, and documentation range the Plex policy
# excludes. Derived from that deployed policy rather than restated here, so the two
# cannot drift apart.
plex_policy='kubernetes/apps/media/plex/app/ciliumnetworkpolicy.yaml'
[[ -f "$plex_policy" ]] || { echo "Missing $plex_policy" >&2; exit 1; }
assert_equal "$(yq -r '.spec.egress[] | select(has("toCIDRSet")) | .toCIDRSet[0].except | sort | join(",")' "$policy")" \
  "$(yq -r '.spec.egress[] | select(has("toCIDRSet")) | .toCIDRSet[0].except | sort | join(",")' "$plex_policy")" \
  'Cilium HTTPS exclusions must match the deployed Plex egress bound'

rg -Fq 'wget -qO- -T 10 https://api.ipify.org 2>/dev/null' "$app/check.sh"
rg -Fq 'nslookup plex.lab.supermorphic.com 1.1.1.1 2>/dev/null' "$app/check.sh"
rg -Fxq '  sleep 300' "$app/check.sh"
rg -Fq 'mv -f -- "$temporary_file" "$metrics_file"' "$app/check.sh"
expected_caddy="$validation_tmp/Caddyfile"
cat >"$expected_caddy" <<'EOF'
{
	admin off
	auto_https off
	persist_config off
}

:9090 {
	handle /metrics {
		rewrite * /metrics.prom
		root * /metrics
		header Content-Type "text/plain; version=0.0.4; charset=utf-8"
		file_server
	}

	handle {
		respond "not found" 404
	}
}
EOF
cmp -s "$expected_caddy" "$app/Caddyfile" || {
  echo 'Caddy metrics route must be exact.' >&2
  exit 1
}

rendered="$validation_tmp/rendered.yaml"
kustomize build "$app" >"$rendered"
[[ "$(rg -c '^kind:' "$rendered")" == '6' ]]

echo 'Plex DDNS drift source contract passed: suspended credential-free exporter, hardened runtime, exact endpoints, bounded policy, metrics, and alerts.'
