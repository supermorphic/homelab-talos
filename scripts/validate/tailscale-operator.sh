#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/networking/tailscale-operator'
ks="$base/ks.yaml"
values="$base/app/values.yaml"
hr="$base/app/helmrelease.yaml"
repo="$base/app/helmrepository.yaml"
ns="$base/app/namespace.yaml"
proxygroup="$base/app/proxygroup.yaml"
oauth="$base/app/oauth.sops.yaml"
temp_dir="$(mktemp -d /tmp/homelab-talos-tailscale-operator-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$values" "$hr" "$repo" "$ns" "$proxygroup" "$oauth" "$base/app/kustomization.yaml"; do
  [[ -f "$f" ]] || { echo "Missing Tailscale operator source: $f" >&2; exit 1; }
done
rg -qx '  - ./tailscale-operator/ks.yaml' kubernetes/apps/networking/kustomization.yaml || {
  echo 'Refusing: ./tailscale-operator/ks.yaml is not listed in the networking kustomization.' >&2
  exit 1
}

# Flux Kustomization: suspend gate, single cilium dependency, SOPS decryption wired.
suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
[[ "$(yq ea -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'cilium' ]]
[[ "$(yq -r '.spec.decryption.provider' "$ks")" == 'sops' ]]

# Pinned chart from the Tailscale Helm repository.
chart_version="$(yq -r '.spec.chart.spec.version' "$hr")"
[[ "$chart_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Refusing: Tailscale operator chart version '$chart_version' is not an explicit pinned semver." >&2
  exit 1
}
[[ "$(yq -r '.spec.url' "$repo")" == 'https://pkgs.tailscale.com/helmcharts' ]]

# The tailscale namespace is a documented privileged infrastructure exception
# (proxy Pods need /dev/net/tun). Enforce that the exception is explicit.
[[ "$(yq -r '.metadata.name' "$ns")" == 'tailscale' ]]
[[ "$(yq -r '.metadata.labels."pod-security.kubernetes.io/enforce"' "$ns")" == 'privileged' ]]

# Scope guard: the Kubernetes API server proxy must stay disabled.
[[ "$(yq -r '.apiServerProxyConfig.mode' "$values")" == 'false' ]]
# OAuth credentials come from the pre-created operator-oauth Secret, not values.
[[ "$(yq -r '.oauth.clientId' "$values")" == '' ]]
[[ "$(yq -r '.oauth.clientSecret' "$values")" == '' ]]

# Reusable HA ingress ProxyGroup.
[[ "$(yq -r '.kind' "$proxygroup")" == 'ProxyGroup' ]]
[[ "$(yq -r '.spec.type' "$proxygroup")" == 'ingress' ]]
[[ "$(yq -r '.spec.replicas' "$proxygroup")" -ge 2 ]]

# OAuth Secret shape (metadata is not encrypted; values are handled by verify-files).
[[ "$(yq -r '.kind' "$oauth")" == 'Secret' ]]
[[ "$(yq -r '.metadata.name' "$oauth")" == 'operator-oauth' ]]
[[ "$(yq -r '.metadata.namespace' "$oauth")" == 'tailscale' ]]

kustomize build "$base/app" >/dev/null
printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
  helm template tailscale-operator tailscale-operator --repo https://pkgs.tailscale.com/helmcharts --version "$chart_version" --namespace tailscale --values "$values" >/dev/null

echo 'Tailscale operator source, wiring, dependency, SOPS decryption, pinned chart, privileged-namespace exception, API-proxy scope guard, ingress ProxyGroup, and render passed validation.'
