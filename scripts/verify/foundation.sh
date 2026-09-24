#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
source scripts/lib/network.sh
require_bash

[[ "$#" -eq 1 ]] || {
  echo 'Usage: foundation.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
foundation_names=(cert-manager cert-manager-config wildcard-certificate metallb metallb-config envoy-gateway internal-gateway external-dns-internal echo)
kc=(kubectl --kubeconfig "$kubeconfig")
if [[ -n "${RECOVERY_KUBE_CONTEXT:-}" ]]; then
  kc+=(--context "$RECOVERY_KUBE_CONTEXT")
fi
[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run just talos kubeconfig." >&2
  exit 1
}

if [[ -n "${RECOVERY_MODE:-}" ]]; then
  scripts/verify/flux.sh "$kubeconfig" supermorphic homelab-talos
else
  just kube flux-verify
fi
for name in "${foundation_names[@]}"; do
  "${kc[@]}" --namespace flux-system wait \
    --for=condition=Ready "kustomization/$name" --timeout=15m
  state="$("${kc[@]}" --namespace flux-system get kustomization "$name" --output json)"
  [[ "$(yq -r '.spec.suspend // false' - <<<"$state")" == 'false' ]]
  [[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$state")" == 'True' ]]
done

for deployment in cert-manager cert-manager-webhook cert-manager-cainjector; do
  "${kc[@]}" --namespace cert-manager rollout status "deployment/$deployment" --timeout=10m
  replicas="$("${kc[@]}" --namespace cert-manager get deployment "$deployment" --output json | yq -r '[.spec.replicas, (.status.availableReplicas // 0)] | join(" ")')"
  [[ "$replicas" == '2 2' ]]
done
"${kc[@]}" wait \
  --for=condition=Ready clusterissuer/letsencrypt-production --timeout=10m
"${kc[@]}" --namespace networking wait \
  --for=condition=Ready certificate/wildcard-lab-supermorphic-com --timeout=15m

controller="$("${kc[@]}" --namespace metallb-system get deployment metallb-controller --output json | yq -r '[.spec.replicas, (.status.availableReplicas // 0)] | join(" ")')"
[[ "$controller" == '1 1' ]]
speaker="$("${kc[@]}" --namespace metallb-system get daemonset metallb-speaker --output json | yq -r '[.status.desiredNumberScheduled, .status.numberReady, (.status.numberUnavailable // 0)] | join(" ")')"
[[ "$speaker" == '3 3 0' ]]
pool="$("${kc[@]}" --namespace metallb-system get ipaddresspool internal --output json)"
[[ "$(yq -r '.spec.addresses | join(" ")' - <<<"$pool")" == '192.168.90.30-192.168.90.38' ]]
[[ "$(yq -r '.spec.autoAssign' - <<<"$pool")" == 'false' ]]
frr_daemonset="$("${kc[@]}" --namespace metallb-system get daemonset frr-k8s-daemon --ignore-not-found --output name)"
assert_empty "$frr_daemonset" 'The FRR DaemonSet must remain absent.'

gateway_class="$("${kc[@]}" get gatewayclass internal --output json)"
[[ "$(yq -r '[.status.conditions[] | select(.type == "Accepted") | .status][0]' - <<<"$gateway_class")" == 'True' ]]
gateway="$("${kc[@]}" --namespace networking get gateway internal --output json)"
[[ "$(yq -r '[.status.conditions[] | select(.type == "Programmed") | .status][0]' - <<<"$gateway")" == 'True' ]]
[[ "$(yq -r '.status.addresses[].value' - <<<"$gateway" | sort -u)" == "$HOMELAB_GATEWAY_VIP" ]]
[[ "$(yq -r '.status.listeners[] | select(.name == "https") | [.conditions[] | select(.type == "Accepted") | .status][0]' - <<<"$gateway")" == 'True' ]]

envoy_services="$("${kc[@]}" --namespace envoy-gateway-system get services --output json)"
envoy_service="$(HOMELAB_GATEWAY_VIP="$HOMELAB_GATEWAY_VIP" yq -r '.items[] | select(.spec.type == "LoadBalancer" and (.status.loadBalancer.ingress[]?.ip == strenv(HOMELAB_GATEWAY_VIP))) | .metadata.name' - <<<"$envoy_services")"
[[ -n "$envoy_service" && "$(wc -l <<<"$envoy_service" | tr -d ' ')" == '1' ]]
envoy_deployments="$("${kc[@]}" --namespace envoy-gateway-system get deployments --output json)"
envoy_ready="$(yq -r '.items[] | select(.metadata.labels."gateway.envoyproxy.io/owning-gateway-name" == "internal") | [.spec.replicas, (.status.availableReplicas // 0)] | join(" ")' - <<<"$envoy_deployments")"
[[ "$envoy_ready" == '2 2' ]]

"${kc[@]}" --namespace external-dns rollout status deployment/external-dns-internal --timeout=10m
dns_deployment="$("${kc[@]}" --namespace external-dns get deployment external-dns-internal --output json)"
dns_deployment_file="$(mktemp "${TMPDIR:-/tmp}/homelab-talos-external-dns-deployment.XXXXXX")"
trap 'rm -f -- "$dns_deployment_file"' EXIT
printf '%s\n' "$dns_deployment" >"$dns_deployment_file"
scripts/validate/external-dns-provider-revisions.sh \
  kubernetes/apps/networking/external-dns/app/pihole-ca.crt \
  kubernetes/apps/networking/external-dns/app/pihole-password.sops.yaml \
  kubernetes/apps/networking/external-dns/app/values.yaml "$dns_deployment_file"
dns_args="$(yq -r '.spec.template.spec.containers[0].args[]' - <<<"$dns_deployment")"
for argument in \
  '--source=crd' \
  '--source=gateway-httproute' \
  '--provider=pihole' \
  '--registry=noop' \
  '--policy=upsert-only' \
  '--domain-filter=lab.supermorphic.com' \
  '--annotation-filter=external-dns.k8s.io/audience=internal' \
  '--gateway-name=internal' \
  '--pihole-api-version=6' \
  '--pihole-server=https://pi.hole'; do
  rg -Fx -- "$argument" <<<"$dns_args"
done
assert_command_finds_nothing \
  'The live external-dns arguments must not skip Pi-hole TLS verification.' \
  rg -Fx -- '--pihole-tls-skip-verify' <<<"$dns_args"
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "external-dns") | .env[] | select(.name == "SSL_CERT_FILE") | .value' - <<<"$dns_deployment")" == '/etc/ssl/pihole/tls_ca.crt' ]]
[[ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "pihole-ca") | .configMap.name' - <<<"$dns_deployment")" == 'pihole-ca' ]]
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "external-dns") | .volumeMounts[] | select(.name == "pihole-ca") | [.mountPath, .readOnly] | join(" ")' - <<<"$dns_deployment")" == '/etc/ssl/pihole true' ]]
live_pihole_ca="$("${kc[@]}" --namespace external-dns get configmap pihole-ca --output jsonpath='{.data.tls_ca\.crt}')"
[[ "$live_pihole_ca" == "$(<kubernetes/apps/networking/external-dns/app/pihole-ca.crt)" ]]

"${kc[@]}" --namespace testing rollout status deployment/echo --timeout=10m
echo_replicas="$("${kc[@]}" --namespace testing get deployment echo --output json | yq -r '[.spec.replicas, (.status.availableReplicas // 0)] | join(" ")')"
[[ "$echo_replicas" == '2 2' ]]
route="$("${kc[@]}" --namespace testing get httproute echo --output json)"
[[ "$(yq -r '[.status.parents[].conditions[] | select(.type == "Accepted") | .status] | unique | join(" ")' - <<<"$route")" == 'True' ]]
[[ "$(yq -r '[.status.parents[].conditions[] | select(.type == "ResolvedRefs") | .status] | unique | join(" ")' - <<<"$route")" == 'True' ]]

dns_answer=''
for _ in {1..30}; do
  dns_answer="$(dig +short @"$HOMELAB_DNS_RESOLVER" echo.lab.supermorphic.com A | sort -u)"
  [[ "$dns_answer" == "$HOMELAB_GATEWAY_VIP" ]] && break
  sleep 10
done
[[ "$dns_answer" == "$HOMELAB_GATEWAY_VIP" ]] || {
  echo "Pi-hole returned '$dns_answer' instead of $HOMELAB_GATEWAY_VIP." >&2
  exit 1
}
response="$(curl --silent --show-error --fail --max-time 15 \
  --resolve "echo.lab.supermorphic.com:443:$HOMELAB_GATEWAY_VIP" \
  https://echo.lab.supermorphic.com/)"
[[ -n "$response" ]]

if [[ -n "${RECOVERY_MODE:-}" ]]; then
  scripts/verify/cilium-postflight.sh "$kubeconfig" "$RECOVERY_KUBE_CONTEXT" \
    "$RECOVERY_TALOSCONFIG" "$RECOVERY_TALOS_CONTEXT" "$RECOVERY_TALOS_ENDPOINTS"
else
  just kube cilium-postflight
fi
echo 'Internal foundation verification passed: certificates, MetalLB, Envoy Gateway, Pi-hole DNS, trusted HTTPS, echo, Talos, and etcd are healthy.'
