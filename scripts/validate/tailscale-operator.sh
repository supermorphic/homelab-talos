#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/networking/tailscale-operator'
ks="$base/ks.yaml"
values="$base/app/values.yaml"
hr="$base/app/helmrelease.yaml"
repo="$base/app/helmrepository.yaml"
ns="$base/app/namespace.yaml"
proxygroup="$base/proxygroup/proxygroup.yaml"
oauth="$base/app/oauth.sops.yaml"
temp_dir="$(mktemp -d /tmp/homelab-talos-tailscale-operator-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

# The rule lives in the networking alerts application; its placement, wiring, and promtool
# coverage belong to `just kube alerts-validate networking`. What stays here is the
# contract that the alerts still cover this operator and both of its proxies.
prometheusrule='kubernetes/apps/networking/alerts/app/tailscale.yaml'
for f in "$ks" "$values" "$hr" "$repo" "$ns" "$proxygroup" "$oauth" "$prometheusrule" \
  "$base/app/kustomization.yaml" "$base/proxygroup/kustomization.yaml"; do
  [[ -f "$f" ]] || { echo "Missing Tailscale operator source: $f" >&2; exit 1; }
done
rg -qx '  - ./tailscale-operator/ks.yaml' kubernetes/apps/networking/kustomization.yaml || {
  echo 'Refusing: ./tailscale-operator/ks.yaml is not listed in the networking kustomization.' >&2
  exit 1
}

# Two Flux Kustomizations in ks.yaml: the operator (installs the tailscale.com CRDs)
# and the ProxyGroup CR, split so the CRD exists before the CR is dry-run.
# Operator Kustomization: suspend gate, single cilium dependency, SOPS decryption.
op_suspend="$(yq ea 'select(.metadata.name == "tailscale-operator") | .spec.suspend // false' "$ks")"
[[ "$op_suspend" == 'true' || "$op_suspend" == 'false' ]]
[[ "$(yq ea 'select(.metadata.name == "tailscale-operator") | [.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'cilium' ]]
[[ "$(yq ea 'select(.metadata.name == "tailscale-operator") | .spec.decryption.provider' "$ks")" == 'sops' ]]
[[ "$(yq ea 'select(.metadata.name == "tailscale-operator") | .spec.path' "$ks")" == './kubernetes/apps/networking/tailscale-operator/app' ]]

# ProxyGroup Kustomization must depend on the operator (CRD-ordering deadlock fix) and
# point at the proxygroup overlay.
[[ "$(yq ea 'select(.metadata.name == "tailscale-operator-proxygroup") | [.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'tailscale-operator' ]]
[[ "$(yq ea 'select(.metadata.name == "tailscale-operator-proxygroup") | .spec.path' "$ks")" == './kubernetes/apps/networking/tailscale-operator/proxygroup' ]]

# The operator overlay must NOT carry the ProxyGroup CR (that is the whole point).
if rg -q 'proxygroup' "$base/app/kustomization.yaml"; then
  echo 'Refusing: the operator overlay (app/kustomization.yaml) must not reference the ProxyGroup CR.' >&2
  exit 1
fi

[[ "$(yq -r '.kind' "$prometheusrule")" == 'PrometheusRule' ]]
# Alerts must cover the operator and both proxy StatefulSets (subnet router + ntfy ingress).
prometheus_alerts="$(yq -r '.spec.groups[].rules[].alert' "$prometheusrule")"
for a in TailscaleOperatorDown TailscaleSubnetRouterDown TailscaleNtfyIngressDown; do
  rg -qx "$a" <<<"$prometheus_alerts" || {
    echo "Refusing: PrometheusRule is missing the $a alert." >&2
    exit 1
  }
done

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
kustomize build "$base/proxygroup" >/dev/null
printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
  helm template tailscale-operator tailscale-operator --repo https://pkgs.tailscale.com/helmcharts --version "$chart_version" --namespace tailscale --values "$values" >/dev/null

echo 'Tailscale operator source, split operator/proxygroup Kustomizations, dependency wiring, SOPS decryption, pinned chart, privileged-namespace exception, API-proxy scope guard, ingress ProxyGroup, PrometheusRule alert coverage (operator + both proxy StatefulSets), and renders passed validation.'
