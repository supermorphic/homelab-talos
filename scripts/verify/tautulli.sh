#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/network.sh

[[ "$#" -eq 1 ]] || { echo 'Usage: tautulli.sh <kubeconfig>' >&2; exit 2; }
kubeconfig="$1"
ns='media'
host='tautulli.lab.supermorphic.com'
gateway_ip="$HOMELAB_GATEWAY_VIP"
temp_dir="$(mktemp -d /tmp/homelab-talos-tautulli-verify.XXXXXX)"
proxy_pid=''
cleanup() {
  [[ -z "$proxy_pid" ]] || kill "$proxy_pid" >/dev/null 2>&1 || true
  rm -rf -- "$temp_dir"
}
trap cleanup EXIT

[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization tautulli --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'tautulli Kustomization not Ready.' >&2; exit 1; }
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get helmrelease tautulli --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'tautulli HelmRelease not Ready.' >&2; exit 1; }
kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status deployment/tautulli --timeout=5m

accepted=false
for _ in {1..24}; do
  [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get httproute tautulli --output jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" == 'True' ]] && { accepted=true; break; }
  sleep 5
done
[[ "$accepted" == 'true' ]] || { echo 'tautulli HTTPRoute was not Accepted.' >&2; exit 1; }
[[ "$(dig +short @"$HOMELAB_DNS_RESOLVER" "$host" A | sort -u)" == "$gateway_ip" ]] || { echo "DNS for $host does not resolve to $gateway_ip." >&2; exit 1; }

# kubectl proxy is read-only here. The API server originates the request to the ClusterIP
# Service, giving an exact direct-Service status without depending on tools in the app image.
kubectl --kubeconfig "$kubeconfig" proxy --address 127.0.0.1 --port 0 >"$temp_dir/proxy.log" 2>&1 &
proxy_pid="$!"
proxy_port=''
for _ in {1..20}; do
  proxy_port="$(sed -nE 's/^Starting to serve on 127\.0\.0\.1:([0-9]+)$/\1/p' "$temp_dir/proxy.log")"
  [[ -n "$proxy_port" ]] && break
  kill -0 "$proxy_pid" 2>/dev/null || { cat "$temp_dir/proxy.log" >&2; exit 1; }
  sleep 1
done
[[ -n "$proxy_port" ]] || { echo 'kubectl proxy did not publish a local port.' >&2; exit 1; }
service_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 15 --max-redirs 0 "http://127.0.0.1:${proxy_port}/api/v1/namespaces/media/services/tautulli/proxy/status")"
[[ "$service_status" == '200' ]] || { echo "tautulli /status returned $service_status through the in-cluster Service proxy, expected exact 200." >&2; exit 1; }

gateway_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 15 --max-redirs 0 --resolve "$host:443:$gateway_ip" "https://$host/status")"
[[ "$gateway_status" == '200' ]] || { echo "tautulli /status returned $gateway_status through the gateway, expected exact 200." >&2; exit 1; }

echo "Tautulli liveness passed: resources Ready, route Accepted, DNS correct, and /status returned exact $service_status through the Service and $gateway_status through the gateway."
