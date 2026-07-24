#!/usr/bin/env bash
set -euo pipefail

source scripts/validate/lib.sh

app_dir='kubernetes/apps/kube-system/cilium/app'
values_file='kubernetes/apps/kube-system/cilium/app/values.yaml'
chart='oci://quay.io/cilium/charts/cilium'
oci="$app_dir/ocirepository.yaml"
helmrelease="$app_dir/helmrelease.yaml"
version="$(yq -r '.spec.ref.tag' "$oci")"
temp_dir="$(mktemp -d /tmp/homelab-talos-cilium-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for file in \
  "$app_dir/kustomization.yaml" \
  "$oci" \
  "$helmrelease" \
  "$values_file" \
  'kubernetes/apps/kube-system/cilium/ks.yaml'; do
  assert_file "$file" 'required Cilium source'
done

assert_pinned_value "$version" 'Cilium chart version'
assert_yaml_values "$oci" \
  '.spec.url' "$chart"
assert_yaml_values "$helmrelease" \
  '.spec.releaseName' 'cilium' \
  '.spec.targetNamespace' 'kube-system' \
  '.spec.storageNamespace' 'kube-system' \
  '.spec.valuesFrom[0].name' 'cilium-values' \
  '.spec.valuesFrom[0].valuesKey' 'values.yaml'
assert_yaml_values "$values_file" \
  '.cluster.name' 'nuc-cluster' \
  '.cluster.id' '1' \
  '.ipam.mode' 'kubernetes' \
  '.kubeProxyReplacement' 'true' \
  '.k8sServiceHost' 'localhost' \
  '.k8sServicePort' '7445' \
  '.cgroup.autoMount.enabled' 'false' \
  '.cgroup.hostRoot' '/sys/fs/cgroup' \
  '.routingMode' 'tunnel' \
  '.tunnelProtocol' 'vxlan' \
  '.bpf.masquerade' 'false' \
  '.operator.replicas' '2' \
  '.hubble.relay.enabled' 'true' \
  '.hubble.ui.enabled' 'false' \
  '.envoy.enabled' 'false' \
  '.gatewayAPI.enabled' 'false' \
  '.l2announcements.enabled' 'false' \
  '.bgpControlPlane.enabled' 'false'
! yq -r '.securityContext.capabilities.ciliumAgent[]' "$values_file" | rg -qx 'SYS_MODULE'

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

echo "Cilium $version app sources and Helm render passed validation."
