#!/usr/bin/env bash
# Prove Plex CiliumNetworkPolicy containment with two run-scoped probe Pods. The
# unselected control proves every negative target is otherwise reachable; the
# policy-selected probe (labelled app.kubernetes.io/name=plex) must be denied. An
# unrelated-probe check proves plex:32400 ingress is closed to everything outside
# the observed allow-list. Creates and deletes only the two run-scoped Pods.
set -euo pipefail

source scripts/lib/common.sh
require_bash

[[ "$#" -eq 1 ]] || {
  echo 'Usage: plex-network-policy.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
expected_confirmation='test:plex-network-policy'
namespace='media'
run_suffix="${EPOCHSECONDS}-$$"
control_pod="plex-policy-control-${run_suffix}"
selected_pod="plex-policy-selected-${run_suffix}"
image='ghcr.io/home-operations/plex:1.43.3.10828@sha256:0c0b6899339503af17cb190b25af6acf10f0030e2820985e16ee14ef428f49d7'
temp_dir="$(mktemp -d /tmp/homelab-talos-plex-network-policy.XXXXXX)"
kc=(kubectl --kubeconfig "$kubeconfig")
created=false

cleanup() {
  if [[ "$created" == 'true' ]]; then
    "${kc[@]}" --namespace "$namespace" delete pod "$control_pod" "$selected_pod" \
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
[[ "${PLEX_NETWORK_POLICY_CONFIRM:-}" == "$expected_confirmation" ]] || {
  echo "Refusing state-changing Plex network-policy test; set PLEX_NETWORK_POLICY_CONFIRM='$expected_confirmation' after reviewing its run-scoped Pod lifecycle." >&2
  exit 1
}
if "${kc[@]}" config get-contexts homelab-diagnostic --no-headers >/dev/null 2>&1; then
  kc+=(--context homelab-diagnostic)
fi

resolve_service_ip() {
  local service_namespace="$1" service="$2" address
  address="$("${kc[@]}" --namespace "$service_namespace" get svc "$service" \
    --output jsonpath='{.spec.clusterIP}')"
  [[ -n "$address" && "$address" != 'None' ]] || {
    echo "Cannot resolve Service $service.$service_namespace to a ClusterIP." >&2
    exit 1
  }
  printf '%s' "$address"
}

# Resolve every target before testing so a DNS failure is never mistaken for a
# policy denial.
api_address="$(resolve_service_ip default kubernetes)"
ntfy_address="$(resolve_service_ip ntfy ntfy)"
plex_address="$(resolve_service_ip media plex)"

render_probe() {
  local pod="$1" app_label="$2"
  cat >"$temp_dir/$pod.yaml" <<EOF
---
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  namespace: $namespace
  labels:
    app.kubernetes.io/name: $app_label
    app.kubernetes.io/instance: plex-network-policy-test
    homelab-talos/test: plex-network-policy
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
}

render_probe "$control_pod" 'plex-policy-control'
# Only the selected probe carries the Plex application label, so the CNP endpoint
# selector applies to it. The distinct instance label keeps Service plex from ever
# selecting either probe.
render_probe "$selected_pod" 'plex'

"${kc[@]}" create --filename "$temp_dir/$control_pod.yaml" >/dev/null
"${kc[@]}" create --filename "$temp_dir/$selected_pod.yaml" >/dev/null
created=true
"${kc[@]}" --namespace "$namespace" wait --for=condition=Ready \
  "pod/$control_pod" "pod/$selected_pod" --timeout=120s >/dev/null

probe_connect() {
  local pod="$1" address="$2" port="$3"
  "${kc[@]}" --namespace "$namespace" exec "$pod" -- \
    timeout 10 bash -c "</dev/tcp/$address/$port" >/dev/null 2>&1
}

# Negative egress matrix: each target must be reachable from the unselected
# control first, then unreachable from the policy-selected probe.
targets=(
  "$api_address:443"        # kubernetes.default.svc:443 — Kubernetes API
  "$ntfy_address:80"        # ntfy.ntfy.svc.cluster.local:80 — another namespace Service
  '192.168.90.1:443'        # UniFi gateway administration
  '192.168.30.6:443'        # NAS administration
)
for target in "${targets[@]}"; do
  address="${target%:*}"
  port="${target##*:}"
  if ! probe_connect "$control_pod" "$address" "$port"; then
    echo "Control target unreachable: $target; stopping rather than claiming policy success." >&2
    exit 1
  fi
  if probe_connect "$selected_pod" "$address" "$port"; then
    echo "Policy failure: the policy-selected probe reached $target." >&2
    exit 1
  fi
  echo "Egress to $target: control reachable, policy-selected probe denied."
done

# Ingress: an unrelated testing probe is outside the observed allow-list and must
# not reach plex.media.svc.cluster.local:32400.
if probe_connect "$control_pod" "$plex_address" 32400; then
  echo 'Policy failure: an unrelated testing probe reached plex.media.svc.cluster.local:32400.' >&2
  exit 1
fi
echo 'Ingress to plex.media.svc.cluster.local:32400: unrelated testing probe denied.'

# Plex itself must still pass its full read-only acceptance under enforcement.
scripts/verify/plex.sh "$kubeconfig"

cleanup
trap - EXIT INT TERM
echo 'Plex network containment test passed: negative egress targets denied to the policy-selected probe, Plex ingress closed to unrelated pods, verifier clean, run-scoped probes removed.'
