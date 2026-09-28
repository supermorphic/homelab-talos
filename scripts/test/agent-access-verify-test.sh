#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
verifier="$repo_root/$(yq -r '.suites[] | select(.metadata.id == "verification.agent-access") | .runner.implementation' "$repo_root/tests/catalog.yaml")"
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
    named:homelab-observer|named:homelab-diagnostic|named:homelab-report-publisher|partial:homelab-observer) exit 0 ;;
    *) exit 1 ;;
  esac
fi

positional=()
groups=()
context=''
impersonation=''
subresource=''
namespace=''
all_namespaces=false
diagnostic=false
publisher=false
resource_name=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --kubeconfig) shift ;;
    --kubeconfig=*) ;;
    --context) context="$2"; shift ;;
    --context=*) context="${1#*=}" ;;
    --as) impersonation="$2"; shift ;;
    --as=*) impersonation="${1#*=}" ;;
    --as-group) groups+=("$2"); shift ;;
    --as-group=*) groups+=("${1#*=}") ;;
    --subresource) subresource="$2"; shift ;;
    --subresource=*) subresource="${1#*=}" ;;
    --namespace|-n) namespace="$2"; shift ;;
    --namespace=*|-n=*) namespace="${1#*=}" ;;
    -n?*) namespace="${1#-n}" ;;
    --all-namespaces|-A|--all-namespaces=true|-A=true) all_namespaces=true ;;
    --all-namespaces=false|-A=false) all_namespaces=false ;;
    -*) echo "unexpected kubectl flag: $1" >&2; exit 64 ;;
    *) positional+=("$1") ;;
  esac
  shift
done
[[ "${#positional[@]}" -eq 4 && "${positional[0]} ${positional[1]}" == 'auth can-i' ]] || exit 64
verb="${positional[2]}"
resource="${positional[3]}"
if [[ "$FAKE_LAYOUT" == named ]]; then
  [[ -n "$context" && -z "$impersonation" && "${#groups[@]}" -eq 0 ]] || exit 65
  identity="$context"
else
  [[ -z "$context" && "$impersonation" == system:serviceaccount:kube-system:* ]] || exit 65
  [[ "$(printf '%s\n' "${groups[@]}" | LC_ALL=C sort)" == \
    $'system:authenticated\nsystem:serviceaccounts\nsystem:serviceaccounts:kube-system' ]] || exit 65
  identity="${impersonation#system:serviceaccount:kube-system:}"
fi
case "$identity" in
  homelab-observer) ;;
  homelab-diagnostic) diagnostic=true ;;
  homelab-report-publisher) publisher=true ;;
  *) exit 65 ;;
esac
request="$identity|$verb|$resource|${namespace:--}|${subresource:--}"
printf '%s\n' "$request" >>"$FAKE_CALL_LOG"
if [[ "$resource" == */* ]]; then
  resource_name="${resource#*/}"
  resource="${resource%%/*}"
fi

case "$resource" in
  nodes|persistentvolumes|customresourcedefinitions.apiextensions.k8s.io|apiservices.apiregistration.k8s.io|\
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
  dnsendpoints.externaldns.k8s.io)
    if [[ -n "$namespace" ]]; then
      [[ "$all_namespaces" == false ]] || exit 66
    else
      [[ "$all_namespaces" == true ]] || exit 66
    fi
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
if [[ "$publisher" == true ]]; then
  answer=no
  case "$verb:$resource:$subresource:$namespace:$resource_name" in
    get:deployments.apps::test-reports:test-reports|list:deployments.apps::test-reports:test-reports|\
    watch:deployments.apps::test-reports:test-reports|\
    get:pods::test-reports:|list:pods::test-reports:|create:pods:exec:test-reports:|\
    get:gitrepositories.source.toolkit.fluxcd.io::flux-system:flux-system|\
    get:leases.coordination.k8s.io::flux-system:homelab-test-report-publish-lock|\
    update:leases.coordination.k8s.io::flux-system:homelab-test-report-publish-lock)
      answer=yes
      ;;
  esac
else
  case "$verb:$resource:$subresource" in
    create:pods:exec|create:pods:portforward)
      answer=no
      if [[ "$diagnostic" == true ]]; then
        case "$subresource:$namespace" in
          exec:kube-system|exec:media|exec:homepage|exec:ntfy|exec:automation|          portforward:kube-system|portforward:media|portforward:monitoring) answer=yes ;;
        esac
      fi
      ;;
    get:secrets:*|create:*:*|patch:*:*|delete:*:*|bind:*:*|escalate:*:*|impersonate:*:*) answer=no ;;
  esac
fi
if [[ -n "${FAKE_AUTH_EXPECTED:-}" && "$answer" == "$FAKE_AUTH_EXPECTED" ]]; then
  printf '%s\n' "$request" >>"$FAKE_FAULT_LOG"
  [[ -z "$FAKE_AUTH_REPLY" ]] || printf '%s\n' "$FAKE_AUTH_REPLY"
  exit "$FAKE_AUTH_STATUS"
fi
printf '%s\n' "$answer"
[[ "$answer" == yes ]] || exit 1
EOF
chmod +x "$fixture/bin/kubectl"

cat >"$fixture/bin/talosctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == version || "$1" == services ]] || exit 64
[[ -z "${FAKE_TALOS_LOG:-}" ]] || printf '%s\n' "$1" >>"$FAKE_TALOS_LOG"
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
  printf '%s\n' "$log"
}

named_log="$(run_layout named)"
# The catalog declares the scoped campaign's required reads independently of this
# verifier. Check emitted requests so shell refactors cannot change the contract.
# shellcheck disable=SC2016 # yq evaluates $group inside its expression.
while IFS= read -r resource; do
  for context in homelab-observer homelab-diagnostic; do
    for verb in get list watch; do
      rg -Fq -- "$context|$verb|$resource|" "$named_log" || {
        echo "Missing $context $verb request for $resource." >&2
        exit 1
      }
    done
  done
done < <(yq -r '
  .campaigns.scoped-verification.access.required_core_read_resources[],
  (.campaigns.scoped-verification.access.required_read_rules |
    to_entries | .[] | .key as $group | .value[] | . + "." + $group)
' "$repo_root/tests/catalog.yaml")

# Check emitted requests for the exceptional grants and denials.
expect_request() {
  local context="$1" verb="$2" resource="$3" scope="$4" subresource="$5"
  local request="$context|$verb|$resource|$scope|$subresource"
  rg -Fxq -- "$request" "$named_log" || {
    echo "Missing authorization request: $request" >&2
    exit 1
  }
}
for context in homelab-observer homelab-diagnostic; do
  expect_request "$context" get pods kube-system -
  expect_request "$context" list deployments.apps flux-system -
  expect_request "$context" watch statefulsets.apps monitoring -
  expect_request "$context" get pods kube-system log
  expect_request "$context" list dnsendpoints.externaldns.k8s.io - -
  for verb in get list watch; do
    expect_request "$context" "$verb" referencegrants.gateway.networking.k8s.io automation -
  done
done
for verb in get list watch; do
  expect_request homelab-report-publisher "$verb" deployments.apps/test-reports test-reports -
done
expect_request homelab-report-publisher get pods test-reports -
expect_request homelab-report-publisher list pods test-reports -
expect_request homelab-report-publisher create pods test-reports exec
expect_request homelab-report-publisher get gitrepositories.source.toolkit.fluxcd.io/flux-system flux-system -
expect_request homelab-report-publisher get leases.coordination.k8s.io/homelab-test-report-publish-lock flux-system -
expect_request homelab-report-publisher update leases.coordination.k8s.io/homelab-test-report-publish-lock flux-system -
for scope in kube-system media homepage ntfy automation; do
  expect_request homelab-diagnostic create pods "$scope" exec
done
for scope in kube-system media monitoring; do
  expect_request homelab-diagnostic create pods "$scope" portforward
done

while read -r context verb resource scope subresource; do
  expect_request "$context" "$verb" "$resource" "$scope" "$subresource"
done <<'DENIED_REQUESTS'
homelab-report-publisher get secrets test-reports -
homelab-report-publisher create pods test-reports portforward
homelab-report-publisher create pods kube-system exec
homelab-report-publisher create configmaps test-reports -
homelab-report-publisher patch deployments.apps/test-reports test-reports -
homelab-report-publisher delete pods test-reports -
homelab-report-publisher list gitrepositories.source.toolkit.fluxcd.io flux-system -
homelab-report-publisher get gitrepositories.source.toolkit.fluxcd.io/another-source flux-system -
homelab-report-publisher create leases.coordination.k8s.io/homelab-test-report-publish-lock flux-system -
homelab-report-publisher patch leases.coordination.k8s.io/homelab-test-report-publish-lock flux-system -
homelab-report-publisher update leases.coordination.k8s.io/another-lock flux-system -
homelab-report-publisher update leases.coordination.k8s.io flux-system -
homelab-report-publisher bind clusterroles.rbac.authorization.k8s.io - -
homelab-report-publisher escalate clusterroles.rbac.authorization.k8s.io - -
homelab-report-publisher impersonate users - -
homelab-observer get secrets kube-system -
homelab-observer create pods kube-system exec
homelab-observer create pods kube-system portforward
homelab-observer create configmaps kube-system -
homelab-observer patch deployments.apps kube-system -
homelab-observer delete deployments.apps kube-system -
homelab-observer delete pods kube-system -
homelab-diagnostic get secrets kube-system -
homelab-diagnostic create kustomizations.kustomize.toolkit.fluxcd.io flux-system -
homelab-diagnostic patch kustomizations.kustomize.toolkit.fluxcd.io flux-system -
homelab-diagnostic delete kustomizations.kustomize.toolkit.fluxcd.io flux-system -
DENIED_REQUESTS
for scope in openbao flux-system automation-data longhorn-system; do
  expect_request homelab-diagnostic create pods "$scope" exec
  expect_request homelab-diagnostic create pods "$scope" portforward
done
expect_request homelab-diagnostic create pods monitoring exec
for scope in homepage ntfy automation; do
  expect_request homelab-diagnostic create pods "$scope" portforward
done
for context in homelab-observer homelab-diagnostic; do
  for verb in bind escalate impersonate; do
    resource=clusterroles.rbac.authorization.k8s.io
    [[ "$verb" != impersonate ]] || resource=users
    expect_request "$context" "$verb" "$resource" - -
  done
  expect_request "$context" create rolebindings.rbac.authorization.k8s.io kube-system -
  expect_request "$context" patch leases.coordination.k8s.io flux-system -
  expect_request "$context" patch replicas.longhorn.io longhorn-system -
  expect_request "$context" patch settings.longhorn.io longhorn-system -
done
admin_log="$(run_layout admin)"
# The fake validates the identity selection and groups before writing normalized
# fields. Both credential layouts must cover the same authorization requests.
diff -u <(LC_ALL=C sort -u "$named_log") <(LC_ALL=C sort -u "$admin_log")

# Unexpected grants, denials, malformed output and client errors must stop the
# verifier before another request or Talos inspection. A marker proves the
# injected response was consumed, independent of diagnostic wording.
while read -r layout scenario expected reply status; do
  [[ "$reply" != EMPTY ]] || reply=''
  fault_log="$fixture/$layout-$scenario.fault"
  call_log="$fixture/$layout-$scenario.calls"
  talos_log="$fixture/$layout-$scenario.talos"
  if PATH="$fixture/bin:$PATH" FAKE_LAYOUT="$layout" FAKE_CALL_LOG="$call_log" \
    FAKE_AUTH_EXPECTED="$expected" FAKE_AUTH_REPLY="$reply" FAKE_AUTH_STATUS="$status" \
    FAKE_FAULT_LOG="$fault_log" FAKE_TALOS_LOG="$talos_log" \
    "$verifier" "$fixture/kubeconfig" "$fixture/talosconfig" \
    >"$fixture/$layout-$scenario.out" 2>&1; then
    echo "Verifier accepted $scenario with $layout credentials." >&2
    exit 1
  fi
  [[ -s "$fault_log" && ! -s "$talos_log" ]]
  [[ "$(wc -l <"$fault_log" | tr -d ' ')" -eq 1 ]]
  [[ "$(tail -n 1 "$call_log")" == "$(cat "$fault_log")" ]]
done <<'AUTH_FAILURES'
named unexpected-grant no yes 0
named unexpected-denial yes no 1
named empty-client-error yes EMPTY 70
named malformed-output yes maybe 0
named allowed-client-error yes yes 70
named denied-client-error no no 70
named denial-with-success-status no no 0
admin unexpected-grant no yes 0
admin unexpected-denial yes no 1
AUTH_FAILURES

if PATH="$fixture/bin:$PATH" FAKE_LAYOUT=partial FAKE_CALL_LOG="$fixture/partial.log" \
  "$verifier" "$fixture/kubeconfig" "$fixture/talosconfig" >"$fixture/partial.out" 2>&1; then
  echo 'Partial scoped context layout unexpectedly passed.' >&2
  exit 1
fi
[[ ! -s "$fixture/partial.log" ]]

for talos_failure in version services; do
  talos_failure_output="$fixture/talos-$talos_failure.out"
  if PATH="$fixture/bin:$PATH" FAKE_LAYOUT=named FAKE_CALL_LOG="$fixture/talos-$talos_failure.log" \
    FAKE_TALOS_FAILURE="$talos_failure" \
    FAKE_TALOS_LOG="$fixture/talos-$talos_failure.calls" \
    "$verifier" "$fixture/kubeconfig" "$fixture/talosconfig" \
    >"$talos_failure_output" 2>&1; then
    echo "Talos $talos_failure failure unexpectedly passed." >&2
    exit 1
  fi
  [[ "$(tail -n 1 "$fixture/talos-$talos_failure.calls")" == "$talos_failure" ]]
done

mise exec -- python "$repo_root/scripts/test/agent-access-kubectl-contract.py"

echo 'Agent access verifier credential-layout tests passed.'
