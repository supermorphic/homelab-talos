#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source scripts/lib/network.sh

public_base='kubernetes/apps/networking/public-gateway'
public_ks="$public_base/ks.yaml"
public_app="$public_base/app"
namespace="$public_app/namespace.yaml"
certificate="$public_app/certificate.yaml"
envoyproxy="$public_app/envoyproxy.yaml"
gateway="$public_app/gateway.yaml"
public_kustomization="$public_app/kustomization.yaml"
pool='kubernetes/apps/networking/metallb/config/address-pool.yaml'
networking_kustomization='kubernetes/apps/networking/kustomization.yaml'
media_namespace='kubernetes/apps/media/namespace/app/namespace.yaml'
route='kubernetes/apps/media/plex/app/httproute-public.yaml'
plex_kustomization='kubernetes/apps/media/plex/app/kustomization.yaml'
internal_envoy='kubernetes/apps/networking/internal-gateway/app/envoyproxy.yaml'

required_files=(
  "$public_ks"
  "$namespace"
  "$certificate"
  "$envoyproxy"
  "$gateway"
  "$public_kustomization"
  "$pool"
  "$networking_kustomization"
  "$media_namespace"
  "$route"
  "$plex_kustomization"
  "$internal_envoy"
)
missing=0
for required_file in "${required_files[@]}"; do
  if [[ ! -f "$required_file" ]]; then
    echo "Missing Plex public source: $required_file" >&2
    missing=1
  fi
done
(( missing == 0 )) || exit 1

rg -qx '  - ./public-gateway/ks.yaml' "$networking_kustomization"
rg -qx '  - ./httproute-public.yaml' "$plex_kustomization"

[[ "$(yq -r '.kind' "$public_ks")" == 'Kustomization' ]]
[[ "$(yq -r '.metadata.name' "$public_ks")" == 'public-gateway' ]]
[[ "$(yq -r '.metadata.namespace' "$public_ks")" == 'flux-system' ]]
[[ "$(yq -r '.spec.path' "$public_ks")" == './kubernetes/apps/networking/public-gateway/app' ]]
[[ "$(yq -r '.spec.suspend' "$public_ks")" == 'true' ]]
[[ "$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$public_ks")" == 'cert-manager-config,envoy-gateway,metallb-config' ]]

[[ "$(yq -r '.kind' "$namespace")" == 'Namespace' ]]
[[ "$(yq -r '.metadata.name' "$namespace")" == 'networking-public' ]]
[[ "$(yq -r '.metadata.labels."gateway.supermorphic.com/access"' "$namespace")" == 'public' ]]
for psa_mode in audit enforce warn; do
  [[ "$(yq -r ".metadata.labels.\"pod-security.kubernetes.io/$psa_mode\"" "$namespace")" == 'restricted' ]]
done

[[ "$(yq ea -r 'select(.kind == "IPAddressPool" and .metadata.name == "internal") | .spec.addresses | join(",")' "$pool")" == '192.168.90.30-192.168.90.38' ]]
[[ "$(yq ea -r 'select(.kind == "IPAddressPool" and .metadata.name == "internal") | .spec.autoAssign' "$pool")" == 'false' ]]
[[ "$(yq ea -r 'select(.kind == "IPAddressPool" and .metadata.name == "public") | .spec.addresses | join(",")' "$pool")" == "$HOMELAB_PUBLIC_GATEWAY_VIP/32" ]]
[[ "$(yq ea -r 'select(.kind == "IPAddressPool" and .metadata.name == "public") | .spec.autoAssign' "$pool")" == 'false' ]]
[[ "$(yq ea -r '[select(.kind == "L2Advertisement") | .metadata.name] | sort | join(",")' "$pool")" == 'internal,public' ]]
[[ "$(yq ea -r 'select(.kind == "L2Advertisement" and .metadata.name == "internal") | .spec.ipAddressPools | join(",")' "$pool")" == 'internal' ]]
[[ "$(yq ea -r 'select(.kind == "L2Advertisement" and .metadata.name == "public") | .spec.ipAddressPools | join(",")' "$pool")" == 'public' ]]

[[ "$(yq -r '.kind' "$envoyproxy")" == 'EnvoyProxy' ]]
[[ "$(yq -r '.metadata.name + "/" + .metadata.namespace' "$envoyproxy")" == 'public/networking-public' ]]
for field in \
  '.spec.provider.type' \
  '.spec.provider.kubernetes.envoyDeployment.replicas' \
  '.spec.provider.kubernetes.envoyDeployment.container.resources.requests.cpu' \
  '.spec.provider.kubernetes.envoyDeployment.container.resources.requests.memory' \
  '.spec.provider.kubernetes.envoyPDB.minAvailable' \
  '.spec.provider.kubernetes.envoyService.externalTrafficPolicy' \
  '.spec.provider.kubernetes.envoyService.type'; do
  [[ "$(yq -r "$field" "$envoyproxy")" == "$(yq -r "$field" "$internal_envoy")" ]]
done
[[ "$(yq -r '.spec.provider.kubernetes.envoyService.annotations."metallb.io/address-pool"' "$envoyproxy")" == 'public' ]]
[[ "$(yq -r '.spec.provider.kubernetes.envoyService.annotations."metallb.io/loadBalancerIPs"' "$envoyproxy")" == "$HOMELAB_PUBLIC_GATEWAY_VIP" ]]

[[ "$(yq -r '.spec.telemetry.accessLog.settings | length' "$envoyproxy")" == '1' ]]
[[ "$(yq -r '.spec.telemetry.accessLog.settings[0].format.type' "$envoyproxy")" == 'JSON' ]]
expected_log_fields='authority,bytes_received,bytes_sent,downstream_remote_address,duration,method,path,protocol,request_id,requested_server_name,response_code,response_flags,route_name,start_time,upstream_host,user_agent,x_forwarded_for'
[[ "$(yq -r '.spec.telemetry.accessLog.settings[0].format.json | keys | sort | join(",")' "$envoyproxy")" == "$expected_log_fields" ]]
[[ "$(yq -r '.spec.telemetry.accessLog.settings[0].format.json.path' "$envoyproxy")" == '%PATH(NQ:ORIG_OR_PATH)%' ]]
[[ "$(yq -r '.spec.telemetry.accessLog.settings[0].format.json.downstream_remote_address' "$envoyproxy")" == '%DOWNSTREAM_REMOTE_ADDRESS%' ]]
[[ "$(yq -r '.spec.telemetry.accessLog.settings[0].format.json.x_forwarded_for' "$envoyproxy")" == '%REQ(X-FORWARDED-FOR)%' ]]
[[ "$(yq -r '.spec.telemetry.accessLog.settings[0].sinks | length' "$envoyproxy")" == '1' ]]
[[ "$(yq -r '.spec.telemetry.accessLog.settings[0].sinks[0].type' "$envoyproxy")" == 'File' ]]
[[ "$(yq -r '.spec.telemetry.accessLog.settings[0].sinks[0].file.path' "$envoyproxy")" == '/dev/stdout' ]]
if rg -i -q 'X-ENVOY-ORIGINAL-PATH|REQ\(:PATH\)|AUTHORIZATION|COOKIE|X-PLEX-TOKEN|QUERY' "$envoyproxy"; then
  echo 'Refusing: public Envoy access logging contains a token-, header-, or query-unsafe formatter.' >&2
  exit 1
fi

[[ "$(yq -r '.kind' "$certificate")" == 'Certificate' ]]
[[ "$(yq -r '.metadata.name + "/" + .metadata.namespace' "$certificate")" == 'plex-lab-supermorphic-com/networking-public' ]]
[[ "$(yq -r '.spec.dnsNames | join(",")' "$certificate")" == 'plex.lab.supermorphic.com' ]]
[[ "$(yq -r '.spec.issuerRef | [.group, .kind, .name] | join(",")' "$certificate")" == 'cert-manager.io,ClusterIssuer,letsencrypt-production' ]]
[[ "$(yq -r '.spec.privateKey | [.algorithm, .rotationPolicy, .size] | join(",")' "$certificate")" == 'ECDSA,Always,256' ]]
[[ "$(yq -r '.spec.secretName' "$certificate")" == 'plex-lab-supermorphic-com-tls' ]]

[[ "$(yq ea -r 'select(.kind == "GatewayClass") | .metadata.name' "$gateway")" == 'public' ]]
[[ "$(yq ea -r 'select(.kind == "GatewayClass") | .spec.controllerName' "$gateway")" == 'gateway.envoyproxy.io/gatewayclass-controller' ]]
[[ "$(yq ea -r 'select(.kind == "Gateway") | .metadata.name + "/" + .metadata.namespace' "$gateway")" == 'public/networking-public' ]]
[[ "$(yq ea -r 'select(.kind == "Gateway") | .spec.gatewayClassName' "$gateway")" == 'public' ]]
[[ "$(yq ea -r 'select(.kind == "Gateway") | .spec.infrastructure.parametersRef | [.group, .kind, .name] | join(",")' "$gateway")" == 'gateway.envoyproxy.io,EnvoyProxy,public' ]]
[[ "$(yq ea -r 'select(.kind == "Gateway") | .spec.listeners | length' "$gateway")" == '1' ]]
listener='select(.kind == "Gateway") | .spec.listeners[0]'
[[ "$(yq ea -r "$listener | [.name, .hostname, .port, .protocol] | join(\",\")" "$gateway")" == 'https,plex.lab.supermorphic.com,443,HTTPS' ]]
[[ "$(yq ea -r "$listener | .tls.mode" "$gateway")" == 'Terminate' ]]
[[ "$(yq ea -r "$listener | .tls.certificateRefs | length" "$gateway")" == '1' ]]
[[ "$(yq ea -r "$listener | .tls.certificateRefs[0] | [.group, .kind, .name] | join(\",\")" "$gateway")" == ',Secret,plex-lab-supermorphic-com-tls' ]]
[[ "$(yq ea -r "$listener | .allowedRoutes.namespaces.from" "$gateway")" == 'Selector' ]]
[[ "$(yq ea -r "$listener | .allowedRoutes.namespaces.selector.matchLabels.\"gateway.supermorphic.com/public-plex\"" "$gateway")" == 'true' ]]
[[ "$(yq ea -r "$listener | .allowedRoutes.kinds | length" "$gateway")" == '1' ]]
[[ "$(yq ea -r "$listener | .allowedRoutes.kinds[0] | [.group, .kind] | join(\",\")" "$gateway")" == 'gateway.networking.k8s.io,HTTPRoute' ]]

[[ "$(yq -r '.metadata.labels."gateway.supermorphic.com/access"' "$media_namespace")" == 'internal' ]]
[[ "$(yq -r '.metadata.labels."gateway.supermorphic.com/public-plex"' "$media_namespace")" == 'true' ]]
[[ "$(yq -r '.kind' "$route")" == 'HTTPRoute' ]]
[[ "$(yq -r '.metadata.name + "/" + .metadata.namespace' "$route")" == 'plex-public/media' ]]
[[ "$(yq -r '.metadata | has("annotations")' "$route")" == 'false' ]]
[[ "$(yq -r '.spec.hostnames | join(",")' "$route")" == 'plex.lab.supermorphic.com' ]]
[[ "$(yq -r '.spec.parentRefs | length' "$route")" == '1' ]]
[[ "$(yq -r '.spec.parentRefs[0] | [.group, .kind, .namespace, .name, .sectionName] | join(",")' "$route")" == 'gateway.networking.k8s.io,Gateway,networking-public,public,https' ]]
[[ "$(yq -r '.spec.rules | length' "$route")" == '1' ]]
[[ "$(yq -r '.spec.rules[0].backendRefs | length' "$route")" == '1' ]]
[[ "$(yq -r '.spec.rules[0].backendRefs[0] | [.group, .kind, .name, .port] | join(",")' "$route")" == ',Service,plex,32400' ]]

mapfile -t kubernetes_yaml < <(rg --files kubernetes -g '*.yaml' | sort)
public_parent_routes="$(yq ea -r 'select(.kind == "HTTPRoute") | . as $route | .spec.parentRefs[]? | select(.name == "public" and .namespace == "networking-public") | $route.metadata.namespace + "/" + $route.metadata.name' "${kubernetes_yaml[@]}")"
[[ "$public_parent_routes" == 'media/plex-public' ]]

if yq ea -e 'select(.kind == "ReferenceGrant")' "$public_app"/*.yaml >/dev/null 2>&1; then
  echo 'Refusing: networking-public must not contain a ReferenceGrant.' >&2
  exit 1
fi
if rg -i -q 'wildcard-lab-supermorphic-com|kind:[[:space:]]*(AAAA|DNSRecord)|cloudflare' "$public_app" "$route"; then
  echo 'Refusing: public source contains a wildcard key, AAAA/DNS resource, or Cloudflare resource.' >&2
  exit 1
fi
if yq ea -e 'select(.kind == "Service" and .metadata.name == "plex")' "$public_app"/*.yaml "$route" >/dev/null 2>&1; then
  echo 'Refusing: Plex must not gain a public Service.' >&2
  exit 1
fi

kustomize build "$public_app" >/dev/null
kustomize build kubernetes/apps/media/plex/app >/dev/null

echo 'Plex public Gateway source contract passed: dedicated suspended plane, exact route, bounded listener, and token-safe stdout logging.'
