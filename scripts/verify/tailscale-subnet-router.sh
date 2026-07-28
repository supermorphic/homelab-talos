#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/network.sh

[[ "$#" -eq 1 ]] || {
  echo 'Usage: tailscale-subnet-router.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
ns='tailscale'
kc=(kubectl --kubeconfig "$kubeconfig")

# Flux: the staged subnet-router Kustomization is Ready (i.e. activated / resumed).
[[ "$("${kc[@]}" --namespace flux-system get kustomization tailscale-operator-subnet-router --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
  echo 'tailscale-operator-subnet-router Kustomization is not Ready (still suspended, or failed).' >&2
  exit 1
}

# Connector: exists and ConnectorReady=True.
"${kc[@]}" get connector lab-subnet-router >/dev/null 2>&1 || { echo 'Connector lab-subnet-router is missing.' >&2; exit 1; }
[[ "$("${kc[@]}" get connector lab-subnet-router --output jsonpath='{.status.conditions[?(@.type=="ConnectorReady")].status}' 2>/dev/null)" == 'True' ]] || {
  echo 'Connector lab-subnet-router is not ConnectorReady.' >&2
  exit 1
}

# HA: two managed devices, and exactly the two intended /32 routes exposed to the tailnet.
device_count="$("${kc[@]}" get connector lab-subnet-router --output jsonpath='{.status.devices}' 2>/dev/null | yq -p json -r 'length' 2>/dev/null || echo 0)"
[[ "${device_count:-0}" -eq 2 ]] || { echo "Connector reports ${device_count:-0} devices (want 2)." >&2; exit 1; }
routes="$("${kc[@]}" get connector lab-subnet-router --output jsonpath='{.status.subnetRoutes}' 2>/dev/null | yq -p json -r '. | sort | join(",")' 2>/dev/null || true)"
[[ "$routes" == "${HOMELAB_DNS_RESOLVER}/32,${HOMELAB_GATEWAY_VIP}/32" ]] || {
  echo "Connector exposes routes [$routes]; want exactly ${HOMELAB_DNS_RESOLVER}/32,${HOMELAB_GATEWAY_VIP}/32." >&2
  exit 1
}

# HA node spread: two Ready subnet-router pods on two DISTINCT Talos nodes. Pods are found
# by the ProxyClass-applied component label, independent of the operator's StatefulSet name.
sel='tailscale.supermorphic.com/component=lab-subnet-router'
ready_pods="$("${kc[@]}" --namespace "$ns" get pods --selector "$sel" \
  --output jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c . || true)"
[[ "${ready_pods:-0}" -ge 2 ]] || { echo "Only ${ready_pods:-0} running subnet-router pods (want 2)." >&2; exit 1; }
distinct_nodes="$("${kc[@]}" --namespace "$ns" get pods --selector "$sel" \
  --output jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u | grep -c . || true)"
[[ "${distinct_nodes:-0}" -ge 2 ]] || {
  echo "subnet-router pods share a node (distinct nodes: ${distinct_nodes:-0}); node-level HA is not satisfied." >&2
  exit 1
}

# The application path the routes serve must itself be healthy.
[[ "$("${kc[@]}" --namespace networking get gateway internal --output jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)" == 'True' ]] || {
  echo 'Envoy Gateway internal is not Programmed.' >&2
  exit 1
}
[[ "$("${kc[@]}" --namespace monitoring get httproute homepage --output jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" == 'True' ]] || {
  echo 'Representative HTTPRoute monitoring/homepage is not Accepted.' >&2
  exit 1
}

# Soft: the restricted resolver answers the lab zone (best-effort; needs LAN/tailnet path).
if command -v dig >/dev/null 2>&1; then
  answer="$(dig +short +time=3 +tries=1 @"$HOMELAB_DNS_RESOLVER" homepage.lab.supermorphic.com A 2>/dev/null || true)"
  if [[ "$answer" == *"$HOMELAB_GATEWAY_VIP"* ]]; then
    echo "Pi-hole resolver answers homepage.lab.supermorphic.com -> $HOMELAB_GATEWAY_VIP."
  else
    echo "WARN: Pi-hole $HOMELAB_DNS_RESOLVER did not return $HOMELAB_GATEWAY_VIP for homepage.lab.supermorphic.com (got: ${answer:-none}); check from a host with LAN/tailnet access." >&2
  fi
fi

just kube foundation-verify
echo 'Tailscale subnet-router acceptance passed: Kustomization Ready, ConnectorReady, 2 devices, exactly the two /32 routes, 2 pods on distinct nodes, Gateway Programmed, homepage HTTPRoute Accepted.'
echo
echo 'MANUAL (mandatory — Kubernetes status CANNOT prove Tailscale Admin Console approval):'
echo '  1. In Admin Console -> Machines, open BOTH lab-subnet-router-* devices and approve'
echo "     ONLY ${HOMELAB_DNS_RESOLVER}/32 and ${HOMELAB_GATEWAY_VIP}/32 on EACH replica (both must be approved"
echo '     for real failover). Confirm neither advertises any other subnet.'
echo "  2. Ensure the restricted split-DNS nameserver ${HOMELAB_DNS_RESOLVER} is configured for search"
echo '     domain lab.supermorphic.com.'
echo '  3. From a tailnet client OFF the home LAN, run the client acceptance probe in'
echo '     docs/tailscale-lab-domain.md (scutil --dns / tailscale dns status, route -n get'
echo "     ${HOMELAB_GATEWAY_VIP}, dscacheutil, curl -I without -k), then the Tailscale-off negative"
echo '     test. See docs/tailscale-lab-domain.md.'
