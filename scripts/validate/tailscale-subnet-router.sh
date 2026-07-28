#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/network.sh

base='kubernetes/apps/networking/tailscale-operator'
ks="$base/ks.yaml"
connector="$base/subnet-router/connector.yaml"
proxyclass="$base/subnet-router/proxyclass.yaml"
kust="$base/subnet-router/kustomization.yaml"
temp_dir="$(mktemp -d /tmp/homelab-talos-tailscale-subnet-router-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$connector" "$proxyclass" "$kust"; do
  [[ -f "$f" ]] || { echo "Missing Tailscale subnet-router source: $f" >&2; exit 1; }
done
rg -qx '  - ./tailscale-operator/ks.yaml' kubernetes/apps/networking/kustomization.yaml || {
  echo 'Refusing: ./tailscale-operator/ks.yaml is not listed in the networking kustomization.' >&2
  exit 1
}

# The subnet-router Flux Kustomization lives alongside the operator/proxygroup ones in
# ks.yaml. It is a tailscale.com CRD instance, so (like the ProxyGroup) it must depend on
# the operator (CRD present) and point at the subnet-router overlay. It ships STAGED
# suspended: activation is a deliberate later flip after the tailnet ACL owns tag:lab-router.
sr='select(.metadata.name == "tailscale-operator-subnet-router")'
[[ "$(yq ea "$sr | [.spec.dependsOn[].name] | sort | join(\",\")" "$ks")" == 'tailscale-operator' ]]
[[ "$(yq ea "$sr | .spec.path" "$ks")" == './kubernetes/apps/networking/tailscale-operator/subnet-router' ]]
sr_suspend="$(yq ea "$sr | .spec.suspend" "$ks")"
[[ "$sr_suspend" == 'true' || "$sr_suspend" == 'false' ]]

# Connector: hostnamePrefix (NOT hostname) is mandatory for replicas > 1; HA replicas;
# references the node-spreading ProxyClass; carries the dedicated router tag.
[[ "$(yq -r '.kind' "$connector")" == 'Connector' ]]
[[ "$(yq -r '.spec.hostnamePrefix' "$connector")" == 'lab-subnet-router' ]]
[[ "$(yq -r '.spec.hostname // "absent"' "$connector")" == 'absent' ]] || {
  echo 'Refusing: Connector must use hostnamePrefix, not hostname, for replicas > 1.' >&2
  exit 1
}
[[ "$(yq -r '.spec.replicas' "$connector")" -ge 2 ]]
[[ "$(yq -r '.spec.proxyClass' "$connector")" == 'lab-subnet-router' ]]
yq -r '.spec.tags[]' "$connector" | rg -qx 'tag:lab-router' || {
  echo 'Refusing: Connector must carry tag:lab-router.' >&2
  exit 1
}

# Least-privilege gate (security-critical): advertise EXACTLY the Pi-hole and Gateway /32s.
# Never the LAN /24, the Pod CIDR (10.244.), the Service CIDR (10.96.), or any non-/32.
mapfile -t routes < <(yq -r '.spec.subnetRouter.advertiseRoutes[]' "$connector" | sort)
expected_routes="${HOMELAB_DNS_RESOLVER}/32"$'\n'"192.168.90.30/32"
got_routes="$(printf '%s\n' "${routes[@]}")"
[[ "$got_routes" == "$expected_routes" ]] || {
  echo "Refusing: advertiseRoutes must be exactly ${HOMELAB_DNS_RESOLVER}/32 and 192.168.90.30/32." >&2
  echo "Found:" >&2; printf '  %s\n' "${routes[@]}" >&2
  exit 1
}
for r in "${routes[@]}"; do
  [[ "$r" == */32 ]] || { echo "Refusing: non-/32 route advertised: $r" >&2; exit 1; }
  case "$r" in
    10.244.*|10.96.*|192.168.90.0/*|*/8|*/16|*/24)
      echo "Refusing: forbidden broad/CIDR route advertised: $r" >&2; exit 1 ;;
  esac
done

# ProxyClass: hard node spread with an explicit pod label the constraint selects, so the
# operator schedules one replica per Talos node. No silent ScheduleAnyway downgrade.
[[ "$(yq -r '.kind' "$proxyclass")" == 'ProxyClass' ]]
[[ "$(yq -r '.metadata.name' "$proxyclass")" == 'lab-subnet-router' ]]
pod_label="$(yq -r '.spec.statefulSet.pod.labels."tailscale.supermorphic.com/component"' "$proxyclass")"
[[ "$pod_label" == 'lab-subnet-router' ]]
tsc='.spec.statefulSet.pod.topologySpreadConstraints[0]'
[[ "$(yq -r "$tsc.labelSelector.matchLabels.\"tailscale.supermorphic.com/component\"" "$proxyclass")" == 'lab-subnet-router' ]]
[[ "$(yq -r "$tsc.maxSkew" "$proxyclass")" == '1' ]]
[[ "$(yq -r "$tsc.topologyKey" "$proxyclass")" == 'kubernetes.io/hostname' ]]
[[ "$(yq -r "$tsc.whenUnsatisfiable" "$proxyclass")" == 'DoNotSchedule' ]]

# No Funnel anywhere in the overlay.
if rg -qi 'funnel' "$base/subnet-router"; then
  echo 'Refusing: the subnet-router overlay must not reference Funnel.' >&2
  exit 1
fi

kustomize build "$base/subnet-router" >/dev/null

echo 'Tailscale subnet-router source, staged Kustomization wiring, hostnamePrefix HA Connector, exact /32 least-privilege routes, node-spreading ProxyClass, no-Funnel guard, and render passed validation.'
