#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
require_bash

app_dir='kubernetes/apps/kube-system/cilium/app'
values_file='kubernetes/apps/kube-system/cilium/app/values.yaml'
chart='oci://quay.io/cilium/charts/cilium'
version="$(yq -r '.spec.ref.tag' "$app_dir/ocirepository.yaml")"
temp_dir="$(mktemp -d /tmp/homelab-talos-cilium-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for file in \
  "$app_dir/kustomization.yaml" \
  "$app_dir/ocirepository.yaml" \
  "$app_dir/helmrelease.yaml" \
  "$values_file" \
  'kubernetes/apps/kube-system/cilium/ks.yaml'; do
  [[ -f "$file" ]] || {
    echo "Missing required Cilium source: $file" >&2
    exit 1
  }
done

[[ -n "$version" && "$version" != 'null' ]]
[[ "$(yq -r '.spec.url' "$app_dir/ocirepository.yaml")" == "$chart" ]]
[[ "$(yq -r '.spec.releaseName' "$app_dir/helmrelease.yaml")" == 'cilium' ]]
[[ "$(yq -r '.spec.targetNamespace' "$app_dir/helmrelease.yaml")" == 'kube-system' ]]
[[ "$(yq -r '.spec.storageNamespace' "$app_dir/helmrelease.yaml")" == 'kube-system' ]]
[[ "$(yq -r '.spec.valuesFrom[0].name' "$app_dir/helmrelease.yaml")" == 'cilium-values' ]]
[[ "$(yq -r '.spec.valuesFrom[0].valuesKey' "$app_dir/helmrelease.yaml")" == 'values.yaml' ]]

[[ "$(yq -r '.cluster.name' "$values_file")" == 'nuc-cluster' ]]
[[ "$(yq -r '.cluster.id' "$values_file")" == '1' ]]
[[ "$(yq -r '.ipam.mode' "$values_file")" == 'kubernetes' ]]
[[ "$(yq -r '.kubeProxyReplacement' "$values_file")" == 'true' ]]
[[ "$(yq -r '.k8sServiceHost' "$values_file")" == 'localhost' ]]
[[ "$(yq -r '.k8sServicePort' "$values_file")" == '7445' ]]
[[ "$(yq -r '.cgroup.autoMount.enabled' "$values_file")" == 'false' ]]
[[ "$(yq -r '.cgroup.hostRoot' "$values_file")" == '/sys/fs/cgroup' ]]
[[ "$(yq -r '.routingMode' "$values_file")" == 'tunnel' ]]
[[ "$(yq -r '.tunnelProtocol' "$values_file")" == 'vxlan' ]]
[[ "$(yq -r '.bpf.masquerade' "$values_file")" == 'false' ]]
[[ "$(yq -r '.operator.replicas' "$values_file")" == '2' ]]
[[ "$(yq -r '.hubble.relay.enabled' "$values_file")" == 'true' ]]
[[ "$(yq -r '.hubble.ui.enabled' "$values_file")" == 'false' ]]
# Hubble is enabled but exports nothing until these are set, which is why no signal
# exists at 32400 today (docs/decisions/2026-08-12-plex-remote-access-detection.md §3).
[[ "$(yq -r '.hubble.metrics.enabled | length' "$values_file")" == '3' ]]
[[ "$(yq -r '[.hubble.metrics.enabled[] | split(":")[0]] | sort | join(",")' "$values_file")" == 'drop,flow,tcp' ]]
if yq -e '.hubble.metrics.enabled[] | select(test("sourceContext=ip"))' "$values_file" >/dev/null 2>&1; then
  echo 'Refusing: Hubble sourceContext=ip would make every source address a Prometheus label.' >&2
  exit 1
fi
# Identity context collapses every off-cluster address to reserved:world, so the series
# count does not grow with the number of hosts probing the port. `ip` would mint a
# Prometheus series per source address on an Internet-facing port.
[[ "$(yq -r '[.hubble.metrics.enabled[] | select(test("sourceContext=identity"))] | length' "$values_file")" == '3' ]]
[[ "$(yq -r '[.hubble.metrics.enabled[] | select(test("destinationContext=pod"))] | length' "$values_file")" == '3' ]]
# `just bootstrap cilium` installs from this same file onto a bare cluster where the
# Prometheus operator CRDs do not exist yet. A chart-rendered ServiceMonitor would fail
# that install, and the failure would only surface during a rebuild.
[[ "$(yq -r '.hubble.metrics | has("serviceMonitor")' "$values_file")" == 'false' ]]
[[ "$(yq -r '.envoy.enabled' "$values_file")" == 'false' ]]
[[ "$(yq -r '.gatewayAPI.enabled' "$values_file")" == 'false' ]]
[[ "$(yq -r '.l2announcements.enabled' "$values_file")" == 'false' ]]
[[ "$(yq -r '.bgpControlPlane.enabled' "$values_file")" == 'false' ]]
cilium_capabilities="$(yq -r '.securityContext.capabilities.ciliumAgent[]' "$values_file")"
assert_command_finds_nothing \
  'Cilium agent capabilities must not include SYS_MODULE.' \
  rg -qx 'SYS_MODULE' <<<"$cilium_capabilities"

kustomize build "$app_dir" >"$temp_dir/kustomization.yaml"
[[ "$(yq ea -r 'select(.kind == "ConfigMap" and .metadata.name == "cilium-values") | .metadata.labels."reconcile.fluxcd.io/watch"' "$temp_dir/kustomization.yaml")" == 'Enabled' ]]
[[ -n "$(yq ea -r 'select(.kind == "ConfigMap" and .metadata.name == "cilium-values") | .data."values.yaml"' "$temp_dir/kustomization.yaml")" ]]

helm template cilium "$chart" \
  --version "$version" \
  --namespace kube-system \
  --values "$values_file" >"$temp_dir/rendered.yaml"

[[ -n "$(yq ea -r 'select(.kind == "DaemonSet" and .metadata.name == "cilium") | .metadata.name' "$temp_dir/rendered.yaml")" ]]
[[ -n "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "cilium-operator") | .metadata.name' "$temp_dir/rendered.yaml")" ]]
[[ -n "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "hubble-relay") | .metadata.name' "$temp_dir/rendered.yaml")" ]]
[[ -z "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "hubble-ui") | .metadata.name' "$temp_dir/rendered.yaml")" ]]
[[ -z "$(yq ea -r 'select(.kind == "DaemonSet" and .metadata.name == "cilium-envoy") | .metadata.name' "$temp_dir/rendered.yaml")" ]]

# The chart's own interpretation of the values, not a re-read of them: enabling the
# metric sets is what makes this Service exist, and Task 2's ServiceMonitor selects it
# by these exact label and port names.
[[ "$(yq ea -r 'select(.kind == "Service" and .metadata.name == "hubble-metrics") | .metadata.labels."k8s-app"' "$temp_dir/rendered.yaml")" == 'hubble' ]]
[[ "$(yq ea -r 'select(.kind == "Service" and .metadata.name == "hubble-metrics") | .spec.ports[0].name' "$temp_dir/rendered.yaml")" == 'hubble-metrics' ]]
[[ "$(yq ea -r 'select(.kind == "Service" and .metadata.name == "hubble-metrics") | .spec.ports[0].port' "$temp_dir/rendered.yaml")" == '9965' ]]
# Bootstrap safety, proven against the render rather than the source: the chart must not
# emit a ServiceMonitor from these values.
[[ -z "$(yq ea -r 'select(.kind == "ServiceMonitor") | .metadata.name' "$temp_dir/rendered.yaml")" ]]

echo "Cilium $version app sources and Helm render passed validation."
