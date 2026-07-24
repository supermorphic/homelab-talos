#!/usr/bin/env bash
set -euo pipefail

cert_manager_chart='oci://quay.io/jetstack/charts/cert-manager'
metallb_repository='https://metallb.github.io/metallb'
envoy_gateway_chart='oci://docker.io/envoyproxy/gateway-helm'
external_dns_repository='https://kubernetes-sigs.github.io/external-dns'
expected_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' .sops.yaml)"
cloudflare_secret='kubernetes/apps/security/cert-manager/config/cloudflare-api-token.sops.yaml'
pihole_secret='kubernetes/apps/networking/external-dns/app/pihole-password.sops.yaml'
pihole_ca='kubernetes/apps/networking/external-dns/app/pihole-ca.crt'
temp_dir="$(mktemp -d /tmp/homelab-talos-foundation-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for file in \
  'kubernetes/apps/security/cert-manager/ks.yaml' \
  'kubernetes/apps/security/cert-manager/app/ocirepository.yaml' \
  'kubernetes/apps/security/cert-manager/app/helmrelease.yaml' \
  'kubernetes/apps/security/cert-manager/app/values.yaml' \
  'kubernetes/apps/security/cert-manager/config/clusterissuers.yaml' \
  'kubernetes/apps/security/cert-manager/config/staging-certificate.yaml' \
  'kubernetes/apps/security/cert-manager/certificate/certificate.yaml' \
  'kubernetes/apps/networking/metallb/ks.yaml' \
  'kubernetes/apps/networking/metallb/app/helmrelease.yaml' \
  'kubernetes/apps/networking/metallb/app/values.yaml' \
  'kubernetes/apps/networking/metallb/config/address-pool.yaml' \
  'kubernetes/apps/networking/envoy-gateway/ks.yaml' \
  'kubernetes/apps/networking/envoy-gateway/app/ocirepository.yaml' \
  'kubernetes/apps/networking/envoy-gateway/app/helmrelease.yaml' \
  'kubernetes/apps/networking/envoy-gateway/app/values.yaml' \
  'kubernetes/apps/networking/internal-gateway/ks.yaml' \
  'kubernetes/apps/networking/internal-gateway/app/envoyproxy.yaml' \
  'kubernetes/apps/networking/internal-gateway/app/gateway.yaml' \
  'kubernetes/apps/networking/external-dns/ks.yaml' \
  'kubernetes/apps/networking/external-dns/app/helmrelease.yaml' \
  'kubernetes/apps/networking/external-dns/app/kustomization.yaml' \
  "$pihole_ca" \
  'kubernetes/apps/networking/external-dns/app/values.yaml' \
  'kubernetes/apps/testing/echo/ks.yaml' \
  'kubernetes/apps/testing/echo/app/deployment.yaml' \
  'kubernetes/apps/testing/echo/app/httproute.yaml' \
  "$cloudflare_secret" \
  "$pihole_secret"; do
  [[ -f "$file" ]] || {
    echo "Missing required Phase 7 source: $file" >&2
    echo 'Run just repo phase7-secrets if a provider Secret is missing.' >&2
    exit 1
  }
done

for secret in "$cloudflare_secret" "$pihole_secret"; do
  [[ "$(sops filestatus "$secret" | yq -r '.encrypted')" == 'true' ]]
  [[ "$(yq -r '.sops.age[].recipient' "$secret" | sort -u)" == "$expected_recipient" ]]
  [[ "$(yq -r '.kind' "$secret")" == 'Secret' ]]
done
[[ "$(yq -r '.metadata.name' "$cloudflare_secret")" == 'cloudflare-api-token' ]]
[[ "$(yq -r '.metadata.namespace' "$cloudflare_secret")" == 'cert-manager' ]]
[[ "$(yq -r '.metadata.name' "$pihole_secret")" == 'pihole-password' ]]
[[ "$(yq -r '.metadata.namespace' "$pihole_secret")" == 'external-dns' ]]
! rg -q 'PRIVATE KEY' "$pihole_ca"
openssl verify -CAfile "$pihole_ca" "$pihole_ca" >/dev/null
# CA remaining-lifetime is a time-based check: it lives in
# `just kube foundation-ca-expiry`, kept OUT of `just ci` so it cannot turn an
# unrelated PR red purely because the calendar advanced.

phase7_sources=(
  kubernetes/apps/security/cert-manager/ks.yaml
  kubernetes/apps/networking/metallb/ks.yaml
  kubernetes/apps/networking/envoy-gateway/ks.yaml
  kubernetes/apps/networking/internal-gateway/ks.yaml
  kubernetes/apps/networking/external-dns/ks.yaml
  kubernetes/apps/testing/echo/ks.yaml
)
suspend_states="$(yq ea -r '[select(.kind == "Kustomization") | (.spec.suspend // false)] | .[]' "${phase7_sources[@]}" | sort -u)"
[[ "$suspend_states" == 'true' || "$suspend_states" == 'false' ]] || {
  echo 'Every Phase 7 Kustomization must be staged together: all suspended or all active.' >&2
  exit 1
}

# Versions are read from the manifests (single source of truth) so a Renovate
# bump to a HelmRelease/OCIRepository doesn't need a duplicate literal edited here.
cert_manager_version="$(yq -r '.spec.ref.tag' kubernetes/apps/security/cert-manager/app/ocirepository.yaml)"
metallb_version="$(yq -r '.spec.chart.spec.version' kubernetes/apps/networking/metallb/app/helmrelease.yaml)"
envoy_gateway_version="$(yq -r '.spec.ref.tag' kubernetes/apps/networking/envoy-gateway/app/ocirepository.yaml)"
external_dns_chart_version="$(yq -r '.spec.chart.spec.version' kubernetes/apps/networking/external-dns/app/helmrelease.yaml)"
for v in "$cert_manager_version" "$metallb_version" "$envoy_gateway_version" "$external_dns_chart_version"; do
  [[ -n "$v" && "$v" != 'null' ]]
done
[[ "$(yq -r '.spec.url' kubernetes/apps/security/cert-manager/app/ocirepository.yaml)" == "$cert_manager_chart" ]]
[[ "$(yq -r '.spec.url' kubernetes/apps/networking/envoy-gateway/app/ocirepository.yaml)" == "$envoy_gateway_chart" ]]

cert_ks='kubernetes/apps/security/cert-manager/ks.yaml'
[[ "$(yq ea -r 'select(.metadata.name == "cert-manager") | .spec.dependsOn[].name' "$cert_ks")" == 'cilium' ]]
[[ "$(yq ea -r 'select(.metadata.name == "cert-manager-config") | .spec.dependsOn[].name' "$cert_ks")" == 'cert-manager' ]]
[[ "$(yq ea -r 'select(.metadata.name == "wildcard-certificate") | .spec.dependsOn[].name' "$cert_ks")" == 'cert-manager-config' ]]
[[ "$(yq -r '.spec.dependsOn[].name' kubernetes/apps/networking/metallb/ks.yaml | head -n 1)" == 'cilium' ]]
[[ "$(yq ea -r 'select(.metadata.name == "metallb-config") | .spec.dependsOn[].name' kubernetes/apps/networking/metallb/ks.yaml)" == 'metallb' ]]
[[ "$(yq -r '.spec.dependsOn[].name' kubernetes/apps/networking/envoy-gateway/ks.yaml)" == 'cilium' ]]
[[ "$(yq -r '.spec.dependsOn[].name' kubernetes/apps/networking/internal-gateway/ks.yaml | sort)" == $'envoy-gateway\nmetallb-config\nwildcard-certificate' ]]
[[ "$(yq -r '.spec.dependsOn[].name' kubernetes/apps/networking/external-dns/ks.yaml)" == 'internal-gateway' ]]
[[ "$(yq -r '.spec.dependsOn[].name' kubernetes/apps/testing/echo/ks.yaml)" == 'external-dns-internal' ]]

metallb_values='kubernetes/apps/networking/metallb/app/values.yaml'
[[ "$(yq -r '.frrk8s.enabled' "$metallb_values")" == 'false' ]]
[[ "$(yq -r '.speaker.frr.enabled' "$metallb_values")" == 'false' ]]
pool='kubernetes/apps/networking/metallb/config/address-pool.yaml'
[[ "$(yq ea -r 'select(.kind == "IPAddressPool") | .spec.addresses[0]' "$pool")" == '192.168.90.30-192.168.90.39' ]]
[[ "$(yq ea -r 'select(.kind == "IPAddressPool") | .spec.autoAssign' "$pool")" == 'false' ]]

gateway='kubernetes/apps/networking/internal-gateway/app/gateway.yaml'
[[ "$(yq ea -r 'select(.kind == "Gateway") | .spec.listeners[0].hostname' "$gateway")" == '*.lab.supermorphic.com' ]]
[[ "$(yq ea -r 'select(.kind == "Gateway") | .spec.listeners[0].port' "$gateway")" == '443' ]]
[[ "$(yq ea -r 'select(.kind == "Gateway") | .spec.listeners[0].tls.certificateRefs[0].name' "$gateway")" == 'wildcard-lab-supermorphic-com-tls' ]]
proxy='kubernetes/apps/networking/internal-gateway/app/envoyproxy.yaml'
[[ "$(yq -r '.spec.provider.kubernetes.envoyDeployment.replicas' "$proxy")" == '2' ]]
[[ "$(yq -r '.spec.provider.kubernetes.envoyService.annotations."metallb.io/loadBalancerIPs"' "$proxy")" == '192.168.90.30' ]]
[[ "$(yq -r '.spec.provider.kubernetes.envoyService.externalTrafficPolicy' "$proxy")" == 'Local' ]]

dns_values='kubernetes/apps/networking/external-dns/app/values.yaml'
[[ "$(yq -r '.provider.name' "$dns_values")" == 'pihole' ]]
[[ "$(yq -r '.registry' "$dns_values")" == 'noop' ]]
[[ "$(yq -r '.policy' "$dns_values")" == 'upsert-only' ]]
[[ "$(yq -r '.sources | join(" ")' "$dns_values")" == 'gateway-httproute' ]]
[[ "$(yq -r '.domainFilters | join(" ")' "$dns_values")" == 'lab.supermorphic.com' ]]
[[ "$(yq -r '.annotationFilter' "$dns_values")" == 'external-dns.k8s.io/audience=internal' ]]
[[ "$(yq -r '.gatewayNamespace' "$dns_values")" == 'networking' ]]
[[ "$(yq -r '.extraArgs."gateway-name"' "$dns_values")" == 'internal' ]]
[[ "$(yq -r '.extraArgs."pihole-api-version"' "$dns_values")" == '6' ]]
[[ "$(yq -r '.extraArgs."pihole-server"' "$dns_values")" == 'https://pi.hole' ]]
[[ "$(yq -r '.extraArgs."pihole-tls-skip-verify" // ""' "$dns_values")" == '' ]]
[[ "$(yq -r '.env[] | select(.name == "SSL_CERT_FILE") | .value' "$dns_values")" == '/etc/ssl/pihole/tls_ca.crt' ]]
[[ "$(yq -r '.extraVolumes[] | select(.name == "pihole-ca") | .configMap.name' "$dns_values")" == 'pihole-ca' ]]
[[ "$(yq -r '.extraVolumeMounts[] | select(.name == "pihole-ca") | [.mountPath, .readOnly] | join(" ")' "$dns_values")" == '/etc/ssl/pihole true' ]]
[[ "$(yq -r '.configMapGenerator[] | select(.name == "pihole-ca") | [.namespace, .files[]] | join(" ")' kubernetes/apps/networking/external-dns/app/kustomization.yaml)" == 'external-dns tls_ca.crt=pihole-ca.crt' ]]

for directory in \
  kubernetes/apps \
  kubernetes/apps/security/cert-manager/app \
  kubernetes/apps/security/cert-manager/config \
  kubernetes/apps/security/cert-manager/certificate \
  kubernetes/apps/networking/metallb/app \
  kubernetes/apps/networking/metallb/config \
  kubernetes/apps/networking/envoy-gateway/app \
  kubernetes/apps/networking/internal-gateway/app \
  kubernetes/apps/networking/external-dns/app \
  kubernetes/apps/testing/echo/app; do
  kustomize build "$directory" >"$temp_dir/$(tr '/' '-' <<<"$directory").yaml"
done

printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repositories.yaml"
export HELM_REPOSITORY_CONFIG="$temp_dir/repositories.yaml"
export HELM_REPOSITORY_CACHE="$temp_dir/repository-cache"
helm template cert-manager "$cert_manager_chart" \
  --version "$cert_manager_version" \
  --namespace cert-manager \
  --values kubernetes/apps/security/cert-manager/app/values.yaml >"$temp_dir/cert-manager.yaml"
helm template metallb metallb \
  --repo "$metallb_repository" \
  --version "$metallb_version" \
  --namespace metallb-system \
  --values "$metallb_values" >"$temp_dir/metallb.yaml"
helm template envoy-gateway "$envoy_gateway_chart" \
  --version "$envoy_gateway_version" \
  --namespace envoy-gateway-system \
  --include-crds \
  --values kubernetes/apps/networking/envoy-gateway/app/values.yaml >"$temp_dir/envoy-gateway.yaml"
helm template external-dns-internal external-dns \
  --repo "$external_dns_repository" \
  --version "$external_dns_chart_version" \
  --namespace external-dns \
  --values "$dns_values" >"$temp_dir/external-dns.yaml"

rg -q '^kind: Deployment$' "$temp_dir/cert-manager.yaml"
rg -q '^  name: cert-manager$' "$temp_dir/cert-manager.yaml"
rg -q '^kind: DaemonSet$' "$temp_dir/metallb.yaml"
rg -q '^  name: metallb-speaker$' "$temp_dir/metallb.yaml"
! rg -q '^  name: .*frr' "$temp_dir/metallb.yaml"
rg -q '^  name: envoy-gateway$' "$temp_dir/envoy-gateway.yaml"
rg -q '^  name: gatewayclasses.gateway.networking.k8s.io$' "$temp_dir/envoy-gateway.yaml"
rg -q '^  name: gateways.gateway.networking.k8s.io$' "$temp_dir/envoy-gateway.yaml"
rg -q '^  name: httproutes.gateway.networking.k8s.io$' "$temp_dir/envoy-gateway.yaml"
rg -q '^  name: envoyproxies.gateway.envoyproxy.io$' "$temp_dir/envoy-gateway.yaml"
rg -q -- '--source=gateway-httproute' "$temp_dir/external-dns.yaml"
rg -q -- '--provider=pihole' "$temp_dir/external-dns.yaml"
rg -q -- '--annotation-filter=external-dns.k8s.io/audience=internal' "$temp_dir/external-dns.yaml"
rg -q -- '--gateway-name=internal' "$temp_dir/external-dns.yaml"
rg -q -- '--pihole-server=https://pi.hole' "$temp_dir/external-dns.yaml"
! rg -q -- '--pihole-tls-skip-verify' "$temp_dir/external-dns.yaml"
[[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "external-dns-internal") | .spec.template.spec.containers[] | select(.name == "external-dns") | .env[] | select(.name == "SSL_CERT_FILE") | .value' "$temp_dir/external-dns.yaml")" == '/etc/ssl/pihole/tls_ca.crt' ]]
[[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "external-dns-internal") | .spec.template.spec.volumes[] | select(.name == "pihole-ca") | .configMap.name' "$temp_dir/external-dns.yaml")" == 'pihole-ca' ]]
[[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "external-dns-internal") | .spec.template.spec.containers[] | select(.name == "external-dns") | .volumeMounts[] | select(.name == "pihole-ca") | [.mountPath, .readOnly] | join(" ")' "$temp_dir/external-dns.yaml")" == '/etc/ssl/pihole true' ]]

echo 'Phase 7 source, SOPS provider Secrets, dependency graph, policy, and pinned Helm renders passed validation.'
