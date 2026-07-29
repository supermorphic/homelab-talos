#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/network.sh

[[ "$#" -eq 1 ]] || {
  echo 'Usage: tailscale-subnet-router.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
ns='tailscale'
connector='lab-subnet-router'
sel='tailscale.supermorphic.com/component=lab-subnet-router'
expected_routes="${HOMELAB_DNS_RESOLVER}/32,${HOMELAB_GATEWAY_VIP}/32"
kc=(kubectl --kubeconfig "$kubeconfig")

# Flux: the staged subnet-router Kustomization is Ready (i.e. activated / resumed).
[[ "$("${kc[@]}" --namespace flux-system get kustomization tailscale-operator-subnet-router --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
  echo 'tailscale-operator-subnet-router Kustomization is not Ready (still suspended, or failed).' >&2
  exit 1
}

"${kc[@]}" get connector "$connector" >/dev/null 2>&1 || { echo "Connector $connector is missing." >&2; exit 1; }

# The Connector, its two devices, and its two pods are eventually consistent: the operator
# creates the tailnet devices and Pods asynchronously after the object applies, so poll
# rather than one-shot (a fresh `just bootstrap` reconcile reaches Ready before the second
# replica has registered). ~2 min budget each.
connector_ready=false
device_count=0
for _ in {1..24}; do
  [[ "$("${kc[@]}" get connector "$connector" --output jsonpath='{.status.conditions[?(@.type=="ConnectorReady")].status}' 2>/dev/null)" == 'True' ]] || { sleep 5; continue; }
  device_count="$("${kc[@]}" get connector "$connector" --output jsonpath='{.status.devices}' 2>/dev/null | yq -p json -r 'length' 2>/dev/null || echo 0)"
  [[ "${device_count:-0}" -eq 2 ]] && { connector_ready=true; break; }
  sleep 5
done
[[ "$connector_ready" == 'true' ]] || {
  echo "Connector $connector is not ConnectorReady with 2 devices (last device count: ${device_count:-0})." >&2
  exit 1
}

# HA node spread: two Ready subnet-router pods on two DISTINCT Talos nodes. Pods are found
# by the ProxyClass-applied component label, independent of the operator's StatefulSet name.
running=0
distinct=0
for _ in {1..24}; do
  running="$("${kc[@]}" --namespace "$ns" get pods --selector "$sel" \
    --output jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c . || true)"
  distinct="$("${kc[@]}" --namespace "$ns" get pods --selector "$sel" \
    --output jsonpath='{range .items[?(@.status.phase=="Running")]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u | grep -c . || true)"
  [[ "${running:-0}" -ge 2 && "${distinct:-0}" -ge 2 ]] && break
  sleep 5
done
[[ "${running:-0}" -ge 2 ]] || { echo "Only ${running:-0} running subnet-router pods (want 2)." >&2; exit 1; }
[[ "${distinct:-0}" -ge 2 ]] || {
  echo "subnet-router pods share a node (distinct nodes: ${distinct:-0}); the ProxyClass hard node spread is not satisfied — a node is likely unavailable." >&2
  exit 1
}

# Config correctness (always present, independent of tailnet approval): the Connector must
# ADVERTISE exactly the two /32s. Route *exposure* additionally requires manual approval and
# is checked separately below.
spec_routes="$("${kc[@]}" get connector "$connector" --output jsonpath='{.spec.subnetRouter.advertiseRoutes}' 2>/dev/null | yq -p json -r '. | sort | join(",")' 2>/dev/null || true)"
[[ "$spec_routes" == "$expected_routes" ]] || {
  echo "Connector advertises [$spec_routes]; want exactly $expected_routes." >&2
  exit 1
}

# Route EXPOSURE (`.status.subnetRoutes`) reflects only routes APPROVED in the Admin Console.
# Approval is a manual gate (docs/tailscale-lab-domain.md, gate 3) that Kubernetes/Flux
# cannot perform, so an empty value here is EXPECTED right after bootstrap and is reported,
# not failed. A non-empty value that does not match, however, is a real misconfiguration.
exposed_routes="$("${kc[@]}" get connector "$connector" --output jsonpath='{.status.subnetRoutes}' 2>/dev/null | yq -p json -r '. | sort | join(",")' 2>/dev/null || true)"
routes_exposed=false
if [[ -z "$exposed_routes" || "$exposed_routes" == 'null' ]]; then
  echo "NOTE: no routes exposed to the tailnet yet — the two /32s are advertised but await manual approval."
  echo "      Approve ${HOMELAB_DNS_RESOLVER}/32 and ${HOMELAB_GATEWAY_VIP}/32 on BOTH lab-subnet-router-* devices (gate 3)."
elif [[ "$exposed_routes" == "$expected_routes" ]]; then
  routes_exposed=true
  echo "Routes exposed to the tailnet (approved): $exposed_routes."
else
  echo "Connector exposes routes [$exposed_routes]; expected exactly $expected_routes (or none, pre-approval)." >&2
  exit 1
fi

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
echo "Tailscale subnet-router acceptance passed: Kustomization Ready, ConnectorReady, 2 devices, 2 pods on distinct nodes, advertises exactly the two /32s, Gateway Programmed, homepage HTTPRoute Accepted (routes exposed to tailnet: $routes_exposed)."
echo
echo 'MANUAL (mandatory — Kubernetes status CANNOT drive Tailscale Admin Console approval):'
echo '  1. In Admin Console -> Machines, open BOTH lab-subnet-router-* devices and approve'
echo "     ONLY ${HOMELAB_DNS_RESOLVER}/32 and ${HOMELAB_GATEWAY_VIP}/32 on EACH replica (both must be approved"
echo '     for real failover). Confirm neither advertises any other subnet. Re-run this verify'
echo '     afterward to see "routes exposed to tailnet: true".'
echo "  2. Ensure the restricted split-DNS nameserver ${HOMELAB_DNS_RESOLVER} is configured for search"
echo '     domain lab.supermorphic.com.'
echo '  3. From a tailnet client OFF the home LAN, run the client acceptance probe in'
echo '     docs/tailscale-lab-domain.md (scutil --dns / tailscale dns status, route -n get'
echo "     ${HOMELAB_GATEWAY_VIP}, dscacheutil, curl -I without -k), then the Tailscale-off negative"
echo '     test. See docs/tailscale-lab-domain.md.'
