#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
verifier="$repo_root/scripts/verify/agent-access.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/agent-access-verify-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"
touch "$fixture/kubeconfig" "$fixture/talosconfig"

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ " $* " == *' config get-contexts '* ]]; then
  context=''
  for argument in "$@"; do
    [[ "$argument" != homelab-* ]] || context="$argument"
  done
  case "${FAKE_LAYOUT}:${context}" in
    named:homelab-observer|named:homelab-diagnostic|partial:homelab-observer) exit 0 ;;
    *) exit 1 ;;
  esac
fi

[[ " $* " == *' auth can-i '* ]] || {
  echo "unexpected kubectl call: $*" >&2
  exit 64
}
printf '%q ' "$@" >>"$FAKE_CALL_LOG"
printf '\n' >>"$FAKE_CALL_LOG"

args=("$@")
verb=''
resource=''
subresource=''
namespace=''
all_namespaces=false
diagnostic=false
for ((index = 0; index < ${#args[@]}; index++)); do
  case "${args[$index]}" in
    --context|--as)
      identity="${args[$((index + 1))]}"
      [[ "$identity" != *homelab-diagnostic ]] || diagnostic=true
      ;;
    --context=*|--as=*)
      [[ "${args[$index]}" != *homelab-diagnostic ]] || diagnostic=true
      ;;
    can-i)
      verb="${args[$((index + 1))]}"
      resource="${args[$((index + 2))]}"
      ;;
    --subresource)
      subresource="${args[$((index + 1))]}"
      ;;
    --subresource=*)
      subresource="${args[$index]#--subresource=}"
      ;;
    --namespace)
      namespace="${args[$((index + 1))]}"
      ;;
    --namespace=*)
      namespace="${args[$index]#--namespace=}"
      ;;
    --all-namespaces|-A)
      all_namespaces=true
      ;;
  esac
done

case "$resource" in
  nodes|customresourcedefinitions.apiextensions.k8s.io|apiservices.apiregistration.k8s.io|\
  clusterissuers.cert-manager.io|ciliumclusterwidenetworkpolicies.cilium.io|\
  ciliumidentities.cilium.io|ciliumnodes.cilium.io|gatewayclasses.gateway.networking.k8s.io|\
  nodes.metrics.k8s.io|clusterrolebindings.rbac.authorization.k8s.io|\
  clusterroles.rbac.authorization.k8s.io|priorityclasses.scheduling.k8s.io|\
  csidrivers.storage.k8s.io|\
  storageclasses.storage.k8s.io|connectors.tailscale.com|dnsconfigs.tailscale.com|\
  proxyclasses.tailscale.com|proxygroups.tailscale.com|users)
    [[ -z "$namespace" && "$all_namespaces" == true ]] || {
      echo "cluster-scoped resource $resource did not use all-namespaces explicitly" >&2
      exit 65
    }
    ;;
  *)
    [[ -n "$namespace" && "$all_namespaces" == false ]] || {
      echo "namespaced resource $resource did not receive only its namespace" >&2
      exit 66
    }
    ;;
esac

# Match deployed API discovery: Cilium EndpointSlice is disabled and Gatus uses no
# CRD, so discovery-backed `kubectl auth can-i` rejects both absent resources.
case "$resource" in
  ciliumendpointslices.cilium.io)
    echo "the server doesn't have a resource type 'ciliumendpointslices' in group 'cilium.io'" >&2
    exit 1
    ;;
  endpoints.gatus.io)
    echo "the server doesn't have a resource type 'endpoints' in group 'gatus.io'" >&2
    exit 1
    ;;
esac

answer=yes
case "$verb:$resource:$subresource" in
  create:pods:exec|create:pods:portforward)
    [[ "$diagnostic" == true ]] || answer=no
    ;;
  get:secrets:*|create:*:*|patch:*:*|delete:*:*|bind:*:*|escalate:*:*|impersonate:*:*) answer=no ;;
esac
printf '%s\n' "$answer"
[[ "$answer" == yes ]] || exit 1
EOF
chmod +x "$fixture/bin/kubectl"

cat >"$fixture/bin/talosctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == version || "$1" == services ]] || exit 64
case "${FAKE_TALOS_FAILURE:-}:$1" in
  version:version) exit 70 ;;
  services:services) exit 71 ;;
esac
EOF
chmod +x "$fixture/bin/talosctl"

run_layout() {
  local layout="$1"
  local log="$fixture/$layout.log"
  : >"$log"
  if ! PATH="$fixture/bin:$PATH" FAKE_LAYOUT="$layout" FAKE_CALL_LOG="$log" \
    "$verifier" "$fixture/kubeconfig" "$fixture/talosconfig" >/dev/null; then
    echo "Verifier rejected the $layout layout while checking expected denials." >&2
    return 1
  fi
  [[ "$(wc -l <"$log" | tr -d ' ')" -gt 250 ]]
  printf '%s\n' "$log"
}

named_log="$(run_layout named)"
if rg -q -- '--as(=| )' "$named_log"; then
  echo 'Named-context layout unexpectedly used impersonation.' >&2
  exit 1
fi
rg -q -- '--context homelab-observer' "$named_log"
rg -q -- '--context homelab-diagnostic' "$named_log"
for context in homelab-observer homelab-diagnostic; do
  for verb in get list watch; do
    rg -q -- "--context $context auth can-i $verb priorityclasses.scheduling.k8s.io --all-namespaces" "$named_log"
  done
done

admin_log="$(run_layout admin)"
if rg -q -- '--context(=| )' "$admin_log"; then
  echo 'Admin fallback unexpectedly selected a named context.' >&2
  exit 1
fi
while IFS= read -r call; do
  rg -q -- '--as=system:serviceaccount:kube-system:homelab-(observer|diagnostic)' <<<"$call"
  rg -q -- '--as-group=system:authenticated' <<<"$call"
  rg -q -- '--as-group=system:serviceaccounts ' <<<"$call"
  rg -q -- '--as-group=system:serviceaccounts:kube-system' <<<"$call"
done <"$admin_log"

if PATH="$fixture/bin:$PATH" FAKE_LAYOUT=partial FAKE_CALL_LOG="$fixture/partial.log" \
  "$verifier" "$fixture/kubeconfig" "$fixture/talosconfig" >"$fixture/partial.out" 2>&1; then
  echo 'Partial scoped context layout unexpectedly passed.' >&2
  exit 1
fi
rg -q 'requires both scoped contexts or neither' "$fixture/partial.out"

for talos_failure in version services; do
  talos_failure_output="$fixture/talos-$talos_failure.out"
  if PATH="$fixture/bin:$PATH" FAKE_LAYOUT=named FAKE_CALL_LOG="$fixture/talos-$talos_failure.log" \
    FAKE_TALOS_FAILURE="$talos_failure" \
    "$verifier" "$fixture/kubeconfig" "$fixture/talosconfig" \
    >"$talos_failure_output" 2>&1; then
    echo "Talos $talos_failure failure unexpectedly passed." >&2
    exit 1
  fi
  rg -q "Talos reader $talos_failure inspection failed" "$talos_failure_output" || {
    echo "Talos $talos_failure failure lacked a boundary-specific diagnostic." >&2
    exit 1
  }
done

echo 'Agent access verifier credential-layout tests passed.'
