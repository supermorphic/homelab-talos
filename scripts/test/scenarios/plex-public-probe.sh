#!/usr/bin/env bash
# Guarded pre-DNAT isolation and access-log canary for the dedicated public Envoy.
# Creates one hardened run-scoped Pod and removes exactly that Pod on every exit.
set -euo pipefail

# shellcheck disable=SC1091
source scripts/lib/common.sh
# shellcheck disable=SC1091
source scripts/lib/network.sh
require_bash

[[ "$#" -eq 1 ]] || {
  echo 'Usage: plex-public-probe.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
expected_confirmation='test:plex-public-probe'
namespace='testing'
run_suffix="${EPOCHSECONDS}-$$"
probe_pod="plex-public-probe-${run_suffix}"
# Envoy regenerates x-request-id for untrusted downstream requests, so a client-supplied
# value never reaches the access log and cannot correlate the canary. The User-Agent is
# logged verbatim, so it carries the run-scoped correlator instead.
canary_agent="homelab-plex-public-canary/${run_suffix}"
canary='plan-canary-not-a-secret'
host='plex.lab.supermorphic.com'
image='ghcr.io/home-operations/plex:1.43.3.10828@sha256:0c0b6899339503af17cb190b25af6acf10f0030e2820985e16ee14ef428f49d7'
owner_selector='gateway.envoyproxy.io/owning-gateway-namespace=networking-public,gateway.envoyproxy.io/owning-gateway-name=public'
temp_dir="$(mktemp -d /tmp/homelab-talos-plex-public-probe.XXXXXX)"
kc=(kubectl --kubeconfig "$kubeconfig")
cleanup_required=false

cleanup() {
  if [[ "$cleanup_required" == 'true' ]]; then
    "${kc[@]}" --namespace "$namespace" delete pod "$probe_pod" \
      --ignore-not-found --wait=true --timeout=2m >/dev/null 2>&1 || true
  fi
  rm -rf -- "$temp_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run just talos kubeconfig." >&2
  exit 1
}
[[ "${PLEX_PUBLIC_PROBE_CONFIRM:-}" == "$expected_confirmation" ]] || {
  echo "Refusing state-changing Plex public probe; set PLEX_PUBLIC_PROBE_CONFIRM='$expected_confirmation' after reviewing its one-Pod lifecycle and stdout-log read." >&2
  exit 1
}
if "${kc[@]}" config get-contexts homelab-diagnostic --no-headers >/dev/null 2>&1; then
  kc+=(--context homelab-diagnostic)
fi

cat >"$temp_dir/$probe_pod.yaml" <<EOF
---
apiVersion: v1
kind: Pod
metadata:
  name: $probe_pod
  namespace: $namespace
  labels:
    app.kubernetes.io/name: plex-public-probe
    app.kubernetes.io/instance: $probe_pod
    homelab-talos/test: plex-public-probe
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 568
    runAsGroup: 568
    fsGroup: 568
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: $image
      command:
        - sleep
        - infinity
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
        limits:
          memory: 128Mi
EOF

# Mark cleanup required before create: an API server may persist the Pod even when
# kubectl returns an ambiguous timeout or transport error.
cleanup_required=true
"${kc[@]}" create --filename "$temp_dir/$probe_pod.yaml" >/dev/null
"${kc[@]}" --namespace "$namespace" wait --for=condition=Ready "pod/$probe_pod" --timeout=120s >/dev/null

deployments="$("${kc[@]}" --namespace envoy-gateway-system get deployments \
  --selector "$owner_selector" --output json)"
[[ "$(yq -r '.items | length' - <<<"$deployments")" == '1' ]] || {
  echo 'Expected exactly one public-owned Envoy Deployment.' >&2
  exit 1
}

pods="$("${kc[@]}" --namespace envoy-gateway-system get pods \
  --selector "$owner_selector" --field-selector status.phase=Running --output json)"
mapfile -t envoy_pods < <(yq -r '.items[] | [.metadata.name, .status.podIP] | @tsv' - <<<"$pods")
[[ "${#envoy_pods[@]}" -gt 0 ]] || {
  echo 'No running public-owned Envoy Pods were found.' >&2
  exit 1
}

for envoy_pod in "${envoy_pods[@]}"; do
  IFS=$'\t' read -r _ pod_ip <<<"$envoy_pod"
  [[ -n "$pod_ip" ]] || {
    echo 'A public-owned Envoy Pod has no Pod IP.' >&2
    exit 1
  }
  for port in 9901 19000; do
    if "${kc[@]}" --namespace "$namespace" exec "$probe_pod" -- \
      timeout 5 bash -c "</dev/tcp/$pod_ip/$port" >/dev/null 2>&1; then
      echo "Envoy admin endpoint reachable from the probe on TCP $port." >&2
      exit 1
    fi
  done
done

"${kc[@]}" --namespace "$namespace" exec "$probe_pod" -- \
  curl --silent --show-error --fail --max-time 15 \
  --user-agent "$canary_agent" \
  --resolve "$host:443:$HOMELAB_PUBLIC_GATEWAY_VIP" \
  "https://$host/identity?X-Plex-Token=$canary" >/dev/null || {
  echo 'Plex public canary request failed through the dedicated VIP.' >&2
  exit 1
}

matching_entry=''
for _ in {1..15}; do
  for envoy_pod in "${envoy_pods[@]}"; do
    IFS=$'\t' read -r pod_name _ <<<"$envoy_pod"
    while IFS= read -r log_line; do
      [[ -n "$log_line" ]] || continue
      line_agent="$(yq -r '.user_agent // ""' - <<<"$log_line" 2>/dev/null || true)"
      if [[ "$line_agent" == "$canary_agent" ]]; then
        matching_entry="$log_line"
        break 2
      fi
    done < <("${kc[@]}" --namespace envoy-gateway-system logs "pod/$pod_name" \
      --container envoy --since=2m 2>/dev/null || true)
  done
  [[ -n "$matching_entry" ]] && break
  sleep 1
done

[[ -n "$matching_entry" ]] || {
  echo 'No attributable public Envoy access-log canary appeared.' >&2
  exit 1
}
if rg -q -F -- "$canary" <<<"$matching_entry" ||
  rg -q -F -- 'X-Plex-Token' <<<"$matching_entry" ||
  rg -q -F -- '?' <<<"$matching_entry"; then
  echo 'Public Envoy access log leaked query or token material.' >&2
  exit 1
fi
[[ "$(yq -r '.path // ""' - <<<"$matching_entry")" == '/identity' ]] || {
  echo 'Public Envoy access-log canary did not record the query-free /identity path.' >&2
  exit 1
}
# Envoy must have minted its own request id. An empty field would mean the access log
# cannot correlate a session at all, which is the whole point of §9 attribution.
[[ -n "$(yq -r '.request_id // ""' - <<<"$matching_entry")" ]] || {
  echo 'Public Envoy access-log canary carries no request id for attribution.' >&2
  exit 1
}
downstream_address="$(yq -r '.downstream_remote_address // ""' - <<<"$matching_entry")"
forwarded_for="$(yq -r '.x_forwarded_for // ""' - <<<"$matching_entry")"
[[ -n "$downstream_address" && "$downstream_address" != '-' ]] || \
  [[ -n "$forwarded_for" && "$forwarded_for" != '-' ]] || {
  echo 'Public Envoy access-log canary lacks source attribution.' >&2
  exit 1
}
if ! "${kc[@]}" --namespace "$namespace" delete pod "$probe_pod" \
  --ignore-not-found --wait=true --timeout=2m >/dev/null; then
  echo 'Failed to remove the run-scoped Plex public probe.' >&2
  exit 1
fi
cleanup_required=false
rm -rf -- "$temp_dir"
trap - EXIT INT TERM
echo 'Plex public admin isolation and token-safe access-log canary passed; the run-scoped probe was removed.'
