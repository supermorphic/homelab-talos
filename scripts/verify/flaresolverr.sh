#!/usr/bin/env bash
set -euo pipefail

# Live acceptance for FlareSolverr. It has NO HTTPRoute/DNS/gateway path (in-cluster only),
# so instead of a gateway probe we port-forward the ClusterIP Service and hit GET / directly,
# asserting the "FlareSolverr is ready!" JSON. Diagnostic tier; NOT part of just ci.
# NOTE: this proves the service is UP — it does NOT prove any Cloudflare-protected indexer
# (e.g. 1337x) works. That is a manual Prowlarr proxy + indexer test, by design.
[[ "$#" -eq 1 ]] || {
  echo 'Usage: flaresolverr.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
ns='media'
local_port='18191'
kc=(kubectl --kubeconfig "$kubeconfig")
if "${kc[@]}" config get-contexts homelab-diagnostic --no-headers >/dev/null 2>&1; then
  kc+=(--context homelab-diagnostic)
fi

[[ "$("${kc[@]}" --namespace flux-system get kustomization flaresolverr --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'flaresolverr Kustomization not Ready.' >&2; exit 1; }
[[ "$("${kc[@]}" --namespace "$ns" get helmrelease flaresolverr --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'flaresolverr HelmRelease not Ready.' >&2; exit 1; }
"${kc[@]}" --namespace "$ns" rollout status deployment/flaresolverr --timeout=5m

# Service must have at least one ready endpoint address.
endpoints="$("${kc[@]}" --namespace "$ns" get endpoints flaresolverr --output jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
[[ -n "$endpoints" ]] || { echo 'flaresolverr Service has no ready endpoints.' >&2; exit 1; }

# In-cluster probe via a port-forward to the ClusterIP Service on :8191.
"${kc[@]}" --namespace "$ns" port-forward svc/flaresolverr "${local_port}:8191" >/dev/null 2>&1 &
pf_pid="$!"
trap 'kill "$pf_pid" 2>/dev/null || true' EXIT

ready=false
for _ in {1..24}; do
  body="$(curl --silent --fail "http://127.0.0.1:${local_port}/" 2>/dev/null || true)"
  if [[ -n "$body" ]] && printf '%s' "$body" | yq -r '.msg' 2>/dev/null | rg -q 'FlareSolverr is ready'; then
    ready=true
    version="$(printf '%s' "$body" | yq -r '.version // "unknown"' 2>/dev/null)"
    break
  fi
  sleep 5
done
[[ "$ready" == 'true' ]] || { echo 'flaresolverr GET / did not return the ready JSON over the port-forward.' >&2; exit 1; }

echo "FlareSolverr live acceptance passed (Ready, rollout, Service endpoints, GET / ready; version ${version}). Next (manual, not verified here): add it as a Prowlarr Indexer Proxy and tag 1337x."
