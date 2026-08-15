#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/monitoring/gatus'
ks="$base/ks.yaml"
values="$base/app/values.yaml"
hr="$base/app/helmrelease.yaml"
repo="$base/app/helmrepository.yaml"
route="$base/app/httproute.yaml"
ns="$base/app/namespace.yaml"
echo_route='kubernetes/apps/testing/echo/app/httproute.yaml'
echo_service='kubernetes/apps/testing/echo/app/service.yaml'
internal_gateway='kubernetes/apps/networking/internal-gateway/app/gateway.yaml'
temp_dir="$(mktemp -d /tmp/homelab-talos-gatus-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$values" "$hr" "$repo" "$route" "$ns" "$echo_route" "$echo_service" "$internal_gateway" "$base/app/kustomization.yaml"; do
  [[ -f "$f" ]] || { echo "Missing Phase 10 Gatus source: $f" >&2; exit 1; }
done
rg -qx '  - ./gatus/ks.yaml' kubernetes/apps/monitoring/kustomization.yaml || {
  echo 'Refusing: ./gatus/ks.yaml is not listed in kubernetes/apps/monitoring/kustomization.yaml.' >&2
  exit 1
}

suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
[[ "$(yq -r '.metadata.labels."gateway.supermorphic.com/access"' "$ns")" == 'internal' ]]
[[ "$(yq ea -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'cilium,internal-gateway' ]]
chart_version="$(yq -r '.spec.chart.spec.version' "$hr")"
[[ -n "$chart_version" && "$chart_version" != 'null' ]]
[[ "$(yq -r '.spec.url' "$repo")" == 'https://twin.github.io/helm-charts' ]]
[[ "$(yq -r '.config.storage.type' "$values")" == 'memory' ]]
echo_endpoint="$(yq -o=json -I=0 '.config.endpoints[] | select(.group == "Platform" and .name == "echo")' "$values")"
[[ -n "$echo_endpoint" ]]
[[ "$(yq -r '.url' - <<<"$echo_endpoint")" == 'https://echo.lab.supermorphic.com/' ]]
[[ "$(yq -r '.interval' - <<<"$echo_endpoint")" == '1m' ]]
[[ "$(yq -r '.conditions | join(",")' - <<<"$echo_endpoint")" == '[STATUS] == 200' ]]
[[ "$(yq -r '.client.insecure // false' - <<<"$echo_endpoint")" == 'false' ]]

[[ "$(yq -r '.metadata.annotations."external-dns.k8s.io/audience"' "$echo_route")" == 'internal' ]]
[[ "$(yq -r '.spec.hostnames | join(",")' "$echo_route")" == 'echo.lab.supermorphic.com' ]]
[[ "$(yq -r '.spec.parentRefs[0] | [.group,.kind,.namespace,.name,.sectionName] | join(",")' "$echo_route")" == 'gateway.networking.k8s.io,Gateway,networking,internal,https' ]]
[[ "$(yq -r '.spec.rules[0].backendRefs[0] | [.kind,.name,.port] | join(",")' "$echo_route")" == 'Service,echo,80' ]]
[[ "$(yq -r '.metadata.name' "$echo_service")" == 'echo' ]]
[[ "$(yq -r '.spec.ports[0].port' "$echo_service")" == '80' ]]

gateway_listener="$(yq -o=json -I=0 '.spec.listeners[] | select(.name == "https")' "$internal_gateway")"
[[ "$(yq -r '.hostname' - <<<"$gateway_listener")" == '*.lab.supermorphic.com' ]]
[[ "$(yq -r '[.port,.protocol,.tls.mode] | join(",")' - <<<"$gateway_listener")" == '443,HTTPS,Terminate' ]]
[[ "$(yq -r '.tls.certificateRefs | length' - <<<"$gateway_listener")" == '1' ]]
[[ "$(yq -r '.tls.certificateRefs[0] | [.group,.kind,.name] | join(",")' - <<<"$gateway_listener")" == ',Secret,wildcard-lab-supermorphic-com-tls' ]]
[[ "$(yq -r '.spec.hostnames[0]' "$route")" == 'gatus.lab.supermorphic.com' ]]
[[ "$(yq -r '.spec.parentRefs[0].name' "$route")" == 'internal' ]]

kustomize build "$base/app" >/dev/null
printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
  helm template gatus gatus --repo https://twin.github.io/helm-charts --version "$chart_version" --namespace gatus --values "$values" >/dev/null

echo 'Phase 10 Gatus source, wiring, namespace label, values, HTTPRoute, echo DNS/Gateway/production-TLS source linkage, and pinned chart render passed validation.'
