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

normalise_resource_path() {
  local path="$1"
  while [[ "$path" == ./* ]]; do
    path="${path#./}"
  done
  printf '%s\n' "$path"
}

validate_selected_sops_secret() {
  local owner="$1" resource="$2" target="$3" expected_name="$4"
  local expected_namespace="$5" expected_keys="$6" expected_recipient selected_resource
  local normalised_resource normalised_selected_resource selected=false
  local -a expected_recipients candidate_recipients

  [[ -f "$owner" ]] || return 0
  normalised_resource="$(normalise_resource_path "$resource")"
  while IFS= read -r selected_resource; do
    normalised_selected_resource="$(normalise_resource_path "$selected_resource")"
    [[ "$normalised_selected_resource" != "$normalised_resource" ]] || selected=true
  done < <(yq -r '.resources[]?' "$owner")
  [[ "$selected" == true ]] || return 0
  [[ -f "$target" ]] || {
    echo "Missing selected n8n SOPS Secret: $target." >&2
    exit 1
  }
  # shellcheck disable=SC2016 # yq reads target through its env() function.
  mapfile -t expected_recipients < <(
    target="$target" yq -r \
      '.creation_rules[] | select(.path_regex as $rule | env(target) | test($rule)) | .age' \
      .sops.yaml
  )
  [[ "${#expected_recipients[@]}" -eq 1 && -n "${expected_recipients[0]}" && \
    "${expected_recipients[0]}" != 'null' ]] || {
    echo "Unable to select exactly one SOPS age recipient for $target." >&2
    exit 1
  }
  expected_recipient="${expected_recipients[0]}"
  [[ "$(sops filestatus "$target" | yq -r '.encrypted')" == 'true' ]] || {
    echo "Selected n8n SOPS Secret is not encrypted: $target." >&2
    exit 1
  }
  mapfile -t candidate_recipients < <(yq -r '.sops.age[].recipient' "$target" | sort -u)
  [[ "${#candidate_recipients[@]}" -eq 1 && \
    "${candidate_recipients[0]}" == "$expected_recipient" ]] || {
    echo "Selected n8n SOPS Secret has an unexpected age recipient: $target." >&2
    exit 1
  }
  [[ "$(yq -r 'has("data") | not' "$target")" == 'true' ]] || {
    echo "Selected n8n SOPS Secret must not contain data: $target." >&2
    exit 1
  }
  [[ "$(yq -r 'keys | sort | join(",")' "$target")" == \
    'apiVersion,kind,metadata,sops,stringData,type' ]] || {
    echo "Selected n8n SOPS Secret has an unexpected top-level schema: $target." >&2
    exit 1
  }
  [[ "$(yq -r '.metadata | keys | sort | join(",")' "$target")" == 'name,namespace' && \
    "$(yq -r '.apiVersion' "$target")" == 'v1' && \
    "$(yq -r '.kind' "$target")" == 'Secret' && \
    "$(yq -r '.metadata.name' "$target")" == "$expected_name" && \
    "$(yq -r '.metadata.namespace' "$target")" == "$expected_namespace" && \
    "$(yq -r '.type' "$target")" == 'Opaque' ]] || {
    echo "Selected n8n SOPS Secret has an unexpected Secret contract: $target." >&2
    exit 1
  }
  [[ "$(yq -r '.stringData | keys | sort | join(",")' "$target")" == "$expected_keys" ]] || {
    echo "Selected n8n SOPS Secret has an unexpected key set: $target." >&2
    exit 1
  }
}

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

validate_selected_sops_secret \
  "$base/n8n/app/kustomization.yaml" './n8n-runtime.sops.yaml' \
  "$base/n8n/app/n8n-runtime.sops.yaml" n8n-runtime automation \
  'N8N_ENCRYPTION_KEY,N8N_HOST,N8N_PORT,N8N_PROTOCOL'
validate_selected_sops_secret \
  "$base/n8n-postgresql/app/kustomization.yaml" './postgresql-credentials.sops.yaml' \
  "$base/n8n-postgresql/app/postgresql-credentials.sops.yaml" postgresql-credentials automation \
  'backup-password,exporter-dsn,exporter-password,n8n-password,postgres-superuser-password'
validate_selected_sops_secret \
  'kubernetes/apps/monitoring/gatus/app/kustomization.yaml' './n8n-canary.sops.yaml' \
  'kubernetes/apps/monitoring/gatus/app/n8n-canary.sops.yaml' n8n-canary gatus token

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
