#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source scripts/lib/network.sh

[[ "$#" -eq 1 ]] || {
  echo 'Usage: plex-public.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run just talos kubeconfig." >&2
  exit 1
}

kc=(kubectl --kubeconfig "$kubeconfig")
if "${kc[@]}" config get-contexts homelab-diagnostic --no-headers >/dev/null 2>&1; then
  kc+=(--context homelab-diagnostic)
fi

public_namespace='networking-public'
public_gateway='public'
public_host='plex.lab.supermorphic.com'
alternate_host='echo.lab.supermorphic.com'
owner_selector='gateway.envoyproxy.io/owning-gateway-namespace=networking-public,gateway.envoyproxy.io/owning-gateway-name=public'

condition_status() {
  local condition_type="$1"
  CONDITION_TYPE="$condition_type" yq -r \
    '[.status.conditions[]? | select(.type == strenv(CONDITION_TYPE)) | .status] | unique | join(" ")'
}

route_parent_condition_status() {
  local condition_type="$1"
  local gateway_namespace="$2"
  local gateway_name="$3"
  CONDITION_TYPE="$condition_type" \
    GATEWAY_NAMESPACE="$gateway_namespace" \
    GATEWAY_NAME="$gateway_name" \
    yq -r \
    '[.status.parents[]? |
      select(.parentRef.namespace == strenv(GATEWAY_NAMESPACE) and .parentRef.name == strenv(GATEWAY_NAME)) |
      .conditions[]? | select(.type == strenv(CONDITION_TYPE)) | .status] |
      unique | join(" ")'
}

if ! declare -F tcp_probe >/dev/null; then
  tcp_probe() {
    local host="$1"
    local port="$2"
    # The child bash expands its positional parameters inside /dev/tcp.
    # shellcheck disable=SC2016
    timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/$2"' bash "$host" "$port" >/dev/null 2>&1
  }
fi

if ! declare -F tls_without_sni >/dev/null; then
  tls_without_sni() {
    local host="$1"
    local port="$2"
    local response
    response="$(
      printf 'GET /identity HTTP/1.1\r\nHost: plex.lab.supermorphic.com\r\nConnection: close\r\n\r\n' |
        timeout 5 openssl s_client -quiet -noservername -connect "${host}:${port}" 2>/dev/null || true
    )"
    rg -q '^HTTP/' <<<"$response"
  }
fi

kustomization="$("${kc[@]}" --namespace flux-system get kustomization public-gateway --output json)"
[[ "$(yq -r '.spec.suspend // false' - <<<"$kustomization")" == 'false' ]] || {
  echo 'public-gateway Kustomization is suspended.' >&2
  exit 1
}
[[ "$(condition_status Ready <<<"$kustomization")" == 'True' ]] || {
  echo 'public-gateway Kustomization is not Ready.' >&2
  exit 1
}

certificate="$("${kc[@]}" --namespace "$public_namespace" get certificate plex-lab-supermorphic-com --output json)"
[[ "$(condition_status Ready <<<"$certificate")" == 'True' ]] || {
  echo 'Public Plex Certificate is not Ready.' >&2
  exit 1
}

gateway_class="$("${kc[@]}" get gatewayclass "$public_gateway" --output json)"
[[ "$(condition_status Accepted <<<"$gateway_class")" == 'True' ]] || {
  echo 'Public GatewayClass is not Accepted.' >&2
  exit 1
}

gateway="$("${kc[@]}" --namespace "$public_namespace" get gateway "$public_gateway" --output json)"
[[ "$(condition_status Programmed <<<"$gateway")" == 'True' ]] || {
  echo 'Public Gateway is not Programmed.' >&2
  exit 1
}
[[ "$(yq -r '.status.addresses[]?.value' - <<<"$gateway" | sort -u)" == "$HOMELAB_PUBLIC_GATEWAY_VIP" ]] || {
  echo "Public Gateway is not programmed at $HOMELAB_PUBLIC_GATEWAY_VIP." >&2
  exit 1
}
[[ "$(yq -r '[.status.listeners[]? | select(.name == "https") | .conditions[]? | select(.type == "Accepted") | .status] | unique | join(" ")' - <<<"$gateway")" == 'True' ]] || {
  echo 'Public Gateway HTTPS listener is not Accepted.' >&2
  exit 1
}

deployments="$("${kc[@]}" --namespace envoy-gateway-system get deployments --selector "$owner_selector" --output json)"
[[ "$(yq -r '.items | length' - <<<"$deployments")" == '1' ]] || {
  echo 'Expected exactly one public-owned Envoy Deployment.' >&2
  exit 1
}
[[ "$(yq -r '.items[0] | [.spec.replicas, (.status.availableReplicas // 0)] | join(" ")' - <<<"$deployments")" == '2 2' ]] || {
  echo 'Public Envoy Deployment is not 2/2 available.' >&2
  exit 1
}

services="$("${kc[@]}" --namespace envoy-gateway-system get services --selector "$owner_selector" --output json)"
[[ "$(yq -r '.items | length' - <<<"$services")" == '1' ]] || {
  echo 'Expected exactly one public-owned Envoy Service.' >&2
  exit 1
}
[[ "$(yq -r '.items[0].spec.ports | map([(.port | tostring), .protocol] | join("/")) | sort | join(" ")' - <<<"$services")" == '443/TCP' ]] || {
  echo 'Public Envoy Service must expose only TCP 443.' >&2
  exit 1
}
[[ "$(yq -r '.items[0].status.loadBalancer.ingress[]?.ip' - <<<"$services" | sort -u)" == "$HOMELAB_PUBLIC_GATEWAY_VIP" ]] || {
  echo "Public Envoy Service does not have the sole VIP $HOMELAB_PUBLIC_GATEWAY_VIP." >&2
  exit 1
}

public_route="$("${kc[@]}" --namespace media get httproute plex-public --output json)"
for condition in Accepted ResolvedRefs; do
  [[ "$(route_parent_condition_status "$condition" "$public_namespace" "$public_gateway" <<<"$public_route")" == 'True' ]] || {
    echo "media/plex-public is not $condition by networking-public/public." >&2
    exit 1
  }
done

internal_route="$("${kc[@]}" --namespace media get httproute plex --output json)"
[[ "$(route_parent_condition_status Accepted networking internal <<<"$internal_route")" == 'True' ]] || {
  echo 'Internal media/plex route is not Accepted.' >&2
  exit 1
}

curl --silent --show-error --fail --max-time 15 \
  --resolve "$public_host:443:$HOMELAB_PUBLIC_GATEWAY_VIP" \
  "https://$public_host/identity" >/dev/null || {
  echo 'Plex /identity is not reachable through the public gateway VIP.' >&2
  exit 1
}

if curl --insecure --silent --show-error --fail --max-time 5 \
  --resolve "$alternate_host:443:$HOMELAB_PUBLIC_GATEWAY_VIP" \
  "https://$alternate_host/" >/dev/null 2>&1; then
  echo 'Public Envoy served an alternate SNI hostname.' >&2
  exit 1
fi

if tls_without_sni "$HOMELAB_PUBLIC_GATEWAY_VIP" 443; then
  echo 'Public Envoy completed TLS without SNI.' >&2
  exit 1
fi

if curl --silent --show-error --max-time 5 \
  "http://$HOMELAB_PUBLIC_GATEWAY_VIP:443/" >/dev/null 2>&1; then
  echo 'Public Envoy served raw-IP HTTP on TCP 443.' >&2
  exit 1
fi

for port in 80 32400 9901 19000; do
  if tcp_probe "$HOMELAB_PUBLIC_GATEWAY_VIP" "$port"; then
    echo "Public gateway VIP unexpectedly accepted TCP $port." >&2
    exit 1
  fi
done

[[ "$(dig +short @"$HOMELAB_DNS_RESOLVER" "$public_host" A | sort -u)" == "$HOMELAB_GATEWAY_VIP" ]] || {
  echo "Internal Pi-hole no longer resolves $public_host to $HOMELAB_GATEWAY_VIP." >&2
  exit 1
}

just kube foundation-verify
just kube gatus-verify
just kube plex-verify

echo 'Plex public isolation verification passed: dedicated resources ready at .39, only TLS 443 serves the Plex hostname, negative routes are closed, and internal acceptance remains healthy.'
