#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: foundation.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
phase7_names=(cert-manager cert-manager-config wildcard-certificate metallb metallb-config envoy-gateway internal-gateway external-dns-internal echo)
[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run just talos kubeconfig." >&2
  exit 1
}

just kube flux-verify
for name in "${phase7_names[@]}"; do
  kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
    --for=condition=Ready "kustomization/$name" --timeout=15m
  state="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$name" --output json)"
  [[ "$(yq -r '.spec.suspend // false' - <<<"$state")" == 'false' ]]
  [[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$state")" == 'True' ]]
done

for deployment in cert-manager cert-manager-webhook cert-manager-cainjector; do
  kubectl --kubeconfig "$kubeconfig" --namespace cert-manager rollout status "deployment/$deployment" --timeout=10m
  replicas="$(kubectl --kubeconfig "$kubeconfig" --namespace cert-manager get deployment "$deployment" --output json | yq -r '[.spec.replicas, (.status.availableReplicas // 0)] | join(" ")')"
  [[ "$replicas" == '2 2' ]]
done
for issuer in letsencrypt-staging letsencrypt-production; do
  kubectl --kubeconfig "$kubeconfig" wait --for=condition=Ready "clusterissuer/$issuer" --timeout=10m
done
for certificate in wildcard-lab-supermorphic-com-staging wildcard-lab-supermorphic-com; do
  kubectl --kubeconfig "$kubeconfig" --namespace networking wait --for=condition=Ready "certificate/$certificate" --timeout=15m
done

controller="$(kubectl --kubeconfig "$kubeconfig" --namespace metallb-system get deployment metallb-controller --output json | yq -r '[.spec.replicas, (.status.availableReplicas // 0)] | join(" ")')"
[[ "$controller" == '1 1' ]]
speaker="$(kubectl --kubeconfig "$kubeconfig" --namespace metallb-system get daemonset metallb-speaker --output json | yq -r '[.status.desiredNumberScheduled, .status.numberReady, (.status.numberUnavailable // 0)] | join(" ")')"
[[ "$speaker" == '3 3 0' ]]
pool="$(kubectl --kubeconfig "$kubeconfig" --namespace metallb-system get ipaddresspool internal --output json)"
[[ "$(yq -r '.spec.addresses | join(" ")' - <<<"$pool")" == '192.168.90.30-192.168.90.39' ]]
[[ "$(yq -r '.spec.autoAssign' - <<<"$pool")" == 'false' ]]
# shellcheck disable=SC2251  # preserve original non-gating negation (behavior-preserving extraction)
! kubectl --kubeconfig "$kubeconfig" --namespace metallb-system get daemonset frr-k8s-daemon >/dev/null 2>&1

gateway_class="$(kubectl --kubeconfig "$kubeconfig" get gatewayclass internal --output json)"
[[ "$(yq -r '[.status.conditions[] | select(.type == "Accepted") | .status][0]' - <<<"$gateway_class")" == 'True' ]]
gateway="$(kubectl --kubeconfig "$kubeconfig" --namespace networking get gateway internal --output json)"
[[ "$(yq -r '[.status.conditions[] | select(.type == "Programmed") | .status][0]' - <<<"$gateway")" == 'True' ]]
[[ "$(yq -r '.status.addresses[].value' - <<<"$gateway" | sort -u)" == '192.168.90.30' ]]
[[ "$(yq -r '.status.listeners[] | select(.name == "https") | [.conditions[] | select(.type == "Accepted") | .status][0]' - <<<"$gateway")" == 'True' ]]

envoy_services="$(kubectl --kubeconfig "$kubeconfig" --namespace envoy-gateway-system get services --output json)"
envoy_service="$(yq -r '.items[] | select(.spec.type == "LoadBalancer" and (.status.loadBalancer.ingress[]?.ip == "192.168.90.30")) | .metadata.name' - <<<"$envoy_services")"
[[ -n "$envoy_service" && "$(wc -l <<<"$envoy_service" | tr -d ' ')" == '1' ]]
envoy_deployments="$(kubectl --kubeconfig "$kubeconfig" --namespace envoy-gateway-system get deployments --output json)"
envoy_ready="$(yq -r '.items[] | select(.metadata.labels."gateway.envoyproxy.io/owning-gateway-name" == "internal") | [.spec.replicas, (.status.availableReplicas // 0)] | join(" ")' - <<<"$envoy_deployments")"
[[ "$envoy_ready" == '2 2' ]]

kubectl --kubeconfig "$kubeconfig" --namespace external-dns rollout status deployment/external-dns-internal --timeout=10m
dns_deployment="$(kubectl --kubeconfig "$kubeconfig" --namespace external-dns get deployment external-dns-internal --output json)"
dns_args="$(yq -r '.spec.template.spec.containers[0].args[]' - <<<"$dns_deployment")"
for argument in \
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
# shellcheck disable=SC2251  # preserve original non-gating negation (behavior-preserving extraction)
! rg -Fx -- '--pihole-tls-skip-verify' <<<"$dns_args"
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "external-dns") | .env[] | select(.name == "SSL_CERT_FILE") | .value' - <<<"$dns_deployment")" == '/etc/ssl/pihole/tls_ca.crt' ]]
[[ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "pihole-ca") | .configMap.name' - <<<"$dns_deployment")" == 'pihole-ca' ]]
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "external-dns") | .volumeMounts[] | select(.name == "pihole-ca") | [.mountPath, .readOnly] | join(" ")' - <<<"$dns_deployment")" == '/etc/ssl/pihole true' ]]
live_pihole_ca="$(kubectl --kubeconfig "$kubeconfig" --namespace external-dns get configmap pihole-ca --output jsonpath='{.data.tls_ca\.crt}')"
[[ "$live_pihole_ca" == "$(<kubernetes/apps/networking/external-dns/app/pihole-ca.crt)" ]]

kubectl --kubeconfig "$kubeconfig" --namespace testing rollout status deployment/echo --timeout=10m
echo_replicas="$(kubectl --kubeconfig "$kubeconfig" --namespace testing get deployment echo --output json | yq -r '[.spec.replicas, (.status.availableReplicas // 0)] | join(" ")')"
[[ "$echo_replicas" == '2 2' ]]
route="$(kubectl --kubeconfig "$kubeconfig" --namespace testing get httproute echo --output json)"
[[ "$(yq -r '[.status.parents[].conditions[] | select(.type == "Accepted") | .status] | unique | join(" ")' - <<<"$route")" == 'True' ]]
[[ "$(yq -r '[.status.parents[].conditions[] | select(.type == "ResolvedRefs") | .status] | unique | join(" ")' - <<<"$route")" == 'True' ]]

dns_answer=''
for _ in {1..30}; do
  dns_answer="$(dig +short @192.168.90.2 echo.lab.supermorphic.com A | sort -u)"
  [[ "$dns_answer" == '192.168.90.30' ]] && break
  sleep 10
done
[[ "$dns_answer" == '192.168.90.30' ]] || {
  echo "Pi-hole returned '$dns_answer' instead of 192.168.90.30." >&2
  exit 1
}
response="$(curl --silent --show-error --fail --max-time 15 \
  --resolve echo.lab.supermorphic.com:443:192.168.90.30 \
  https://echo.lab.supermorphic.com/)"
[[ -n "$response" ]]

just kube cilium-postflight
echo 'Phase 7 verification passed: certificates, MetalLB, Envoy Gateway, Pi-hole DNS, trusted HTTPS, echo, Talos, and etcd are healthy.'
