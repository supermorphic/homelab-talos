#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/automation'
ns="$base/namespace/app/namespace.yaml"
public_base='kubernetes/apps/networking/public-webhook-gateway'
public_namespace="$public_base/app/namespace.yaml"
public_pool="$public_base/app/address-pool.yaml"
public_certificate="$public_base/app/certificate.yaml"
public_gateway="$public_base/app/gateway.yaml"
public_route="$public_base/route/httproute.yaml"
public_ks="$public_base/ks.yaml"
external_dns='kubernetes/apps/networking/external-dns/app/values.yaml'

for file in "$base/kustomization.yaml" "$base/namespace/ks.yaml" \
  "$base/namespace/app/kustomization.yaml" "$ns"; do
  [[ -f "$file" ]] || { echo "Missing n8n platform source: $file" >&2; exit 1; }
done
for file in "$public_namespace" "$public_pool" "$public_certificate" "$public_gateway" \
  "$public_route" "$public_ks" "$public_base/app/kustomization.yaml" \
  "$public_base/route/kustomization.yaml" "$external_dns"; do
  [[ -f "$file" ]] || { echo "Missing n8n platform source: $file" >&2; exit 1; }
done
yq -e '.resources[] | select(. == "./automation")' kubernetes/apps/kustomization.yaml >/dev/null
yq -e '.resources[] | select(. == "./public-webhook-gateway/ks.yaml")' \
  kubernetes/apps/networking/kustomization.yaml >/dev/null
[[ "$(yq -r '.metadata.name' "$ns")" == 'automation' ]]
[[ "$(yq -r '.metadata.labels."gateway.supermorphic.com/access"' "$ns")" == 'internal' ]] || {
  echo 'n8n automation namespace Gateway access must be internal.' >&2
  exit 1
}
[[ "$(yq -r '.metadata.labels."pod-security.kubernetes.io/enforce"' "$ns")" == 'restricted' ]]
[[ "$(yq -r '.spec.dependsOn[0].name' "$base/namespace/ks.yaml")" == 'cilium' ]]
kustomize build "$base/namespace/app" >/dev/null

yq -e '(.metadata.name == "networking-public") and
  (.metadata.labels | length == 1) and
  (.metadata.labels."gateway.supermorphic.com/access" == "public")' "$public_namespace" >/dev/null || {
  echo 'networking-public must have only the public Gateway access label.' >&2
  exit 1
}
[[ "$(yq ea -r '[select(.kind == "IPAddressPool" and .metadata.name == "public-webhooks")] | length' "$public_pool")" == '1' && \
  "$(yq ea -r 'select(.kind == "IPAddressPool" and .metadata.name == "public-webhooks") | .spec.addresses | length' "$public_pool")" == '1' && \
  "$(yq ea -r 'select(.kind == "IPAddressPool" and .metadata.name == "public-webhooks") | .spec.addresses[0]' "$public_pool")" == '192.168.90.39/32' && \
  "$(yq ea -r 'select(.kind == "IPAddressPool" and .metadata.name == "public-webhooks") | .spec.autoAssign' "$public_pool")" == 'false' ]] || {
  echo 'public-webhooks must contain only 192.168.90.39/32 with autoAssign=false.' >&2
  exit 1
}
[[ "$(yq -r '.metadata.name' "$public_certificate")" == 'hooks-lab-supermorphic-com' && \
  "$(yq -r '.spec.dnsNames | length' "$public_certificate")" == '1' && \
  "$(yq -r '.spec.dnsNames[0]' "$public_certificate")" == 'hooks.lab.supermorphic.com' && \
  "$(yq -r '.spec.issuerRef.name' "$public_certificate")" == 'letsencrypt-production' && \
  "$(yq -r '.spec.privateKey.algorithm' "$public_certificate")" == 'ECDSA' ]] || {
  echo 'The public Certificate must contain only hooks.lab.supermorphic.com.' >&2
  exit 1
}
[[ "$(yq ea -r '[select(.kind == "GatewayClass" and .metadata.name == "public-webhooks")] | length' "$public_gateway")" == '1' && \
  "$(yq ea -r 'select(.kind == "GatewayClass" and .metadata.name == "public-webhooks") | .spec.controllerName' "$public_gateway")" == 'gateway.envoyproxy.io/gatewayclass-controller' ]] || {
  echo 'The public GatewayClass must use the Envoy Gateway controller.' >&2
  exit 1
}
[[ "$(yq ea -r '[select(.kind == "Gateway" and .metadata.namespace == "networking-public" and .metadata.name == "public-webhooks")] | length' "$public_gateway")" == '1' && \
  "$(yq ea -r 'select(.kind == "Gateway" and .metadata.namespace == "networking-public" and .metadata.name == "public-webhooks") | .spec.gatewayClassName' "$public_gateway")" == 'public-webhooks' && \
  "$(yq ea -r 'select(.kind == "Gateway" and .metadata.namespace == "networking-public" and .metadata.name == "public-webhooks") | .spec.listeners | length' "$public_gateway")" == '1' && \
  "$(yq ea -r 'select(.kind == "Gateway" and .metadata.namespace == "networking-public" and .metadata.name == "public-webhooks") | .spec.listeners[0].hostname' "$public_gateway")" == 'hooks.lab.supermorphic.com' && \
  "$(yq ea -r 'select(.kind == "Gateway" and .metadata.namespace == "networking-public" and .metadata.name == "public-webhooks") | .spec.listeners[0].allowedRoutes.namespaces.from' "$public_gateway")" == 'Same' ]] || {
  echo 'The public listener must use its exact hostname and Same-namespace route admission.' >&2
  exit 1
}
[[ "$(yq ea -r 'select(.metadata.name == "public-webhook-route") | [.spec.dependsOn[].name] | sort | join(",")' "$public_ks")" == 'n8n,public-webhook-gateway' && \
  "$(yq ea -r 'select(.metadata.name == "public-webhook-route") | .spec.suspend' "$public_ks")" == 'true' ]] || {
  echo 'The public webhook route must depend on public-webhook-gateway and n8n while suspended.' >&2
  exit 1
}
[[ "$(yq -r '.metadata.namespace' "$public_route")" == 'networking-public' && \
  "$(yq -r '.spec.parentRefs | length' "$public_route")" == '1' && \
  "$(yq -r '.spec.parentRefs[0] | [.namespace, .name, .sectionName] | join(",")' "$public_route")" == 'networking-public,public-webhooks,https' && \
  "$(yq -r '.spec.rules | length' "$public_route")" == '1' && \
  "$(yq -r '.spec.rules[0].matches | length' "$public_route")" == '1' && \
  "$(yq -r '.spec.rules[0].matches[0].path | [.type, .value] | join(",")' "$public_route")" == 'Exact,/webhook/platform-canary' && \
  "$(yq -r '.spec.rules[0].backendRefs | length' "$public_route")" == '1' && \
  "$(yq -r '.spec.rules[0].backendRefs[0] | [.kind, .namespace, .name, .port] | join(",")' "$public_route")" == 'Service,automation,n8n,5678' ]] || {
  echo 'The public webhook route must be the exact platform-canary path to automation/n8n:5678.' >&2
  exit 1
}
[[ "$(yq -r '.annotationFilter' "$external_dns")" == 'external-dns.k8s.io/audience=internal' ]] || {
  echo 'The internal ExternalDNS controller must not publish the public webhook name.' >&2
  exit 1
}
echo 'n8n automation namespace source passed validation.'
