#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
verifier="$repo_root/scripts/verify/cilium.sh"
values="$repo_root/kubernetes/apps/kube-system/cilium/app/values.yaml"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/cilium-verify-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"
touch "$fixture/kubeconfig"

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$FAKE_CALL_LOG"
printf '\n' >>"$FAKE_CALL_LOG"

if [[ " $* " == *' config get-contexts homelab-diagnostic --no-headers '* ]]; then
  [[ "$FAKE_LAYOUT" == named ]]
  exit
fi
if [[ "$FAKE_LAYOUT" == named && " $* " != *' --context homelab-diagnostic '* ]]; then
  echo 'named layout omitted the diagnostic context' >&2
  exit 65
fi
if [[ "$FAKE_LAYOUT" == admin && " $* " == *' --context '* ]]; then
  echo 'admin layout unexpectedly selected a context' >&2
  exit 66
fi

case " $* " in
  *' config view --minify '*) printf 'https://192.168.90.20:6443' ;;
  *' get helmrelease cilium '*)
    printf '%s\n' "{\"metadata\":{\"generation\":1},\"status\":{\"observedGeneration\":1,\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}],\"history\":[{\"chartName\":\"cilium\",\"chartVersion\":\"${FAKE_CHART_VERSION:-1.19.6+b8d600c542c9}\"}]}}"
    ;;
  *' get ocirepository cilium '*)
    printf '%s\n' '{"status":{"artifact":{"revision":"1.19.6@sha256:b8d600c542c97dc8652429e12487ecce922d73de9785505457a8f653833e75f9"}}}'
    ;;
  *' get configmap cilium-values '*) cat "$FAKE_VALUES" ;;
  *' get nodes --output json '*)
    printf '%s\n' '{"items":[{"metadata":{"name":"nuc1"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"nuc2"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"nuc3"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    ;;
  *' get daemonset cilium --output json '*)
    printf '%s\n' '{"status":{"desiredNumberScheduled":3,"numberReady":3,"numberUnavailable":0}}'
    ;;
  *' get deployment cilium-operator --output json '*)
    printf '%s\n' '{"spec":{"replicas":2},"status":{"availableReplicas":2}}'
    ;;
  *' get deployment hubble-relay --output json '*)
    printf '%s\n' '{"spec":{"replicas":1},"status":{"availableReplicas":1}}'
    ;;
  *' get deployment coredns --output json '*)
    printf '%s\n' '{"status":{"availableReplicas":1}}'
    ;;
  *' get daemonset kube-proxy '*|*' get deployment hubble-ui '*|*' get daemonset cilium-envoy '*) ;;
  *) echo "Unexpected kubectl request: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$fixture/bin/kubectl"

cat >"$fixture/bin/cilium" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$FAKE_CALL_LOG"
printf '\n' >>"$FAKE_CALL_LOG"
if [[ "$FAKE_LAYOUT" == named ]]; then
  [[ " $* " == *' --context homelab-diagnostic '* ]]
else
  [[ " $* " != *' --context '* ]]
fi
if [[ " $* " == *' --output json '* ]]; then
  printf '%s\n' '{"pod_state":{"hubble-relay":{"Desired":1,"Ready":1,"Available":1,"Unavailable":0}},"cilium_status":[{"hubble":{"state":"Ok"}}],"errors":{"hubble-relay":{"hubble-relay":{"Errors":[],"Warnings":[]}}}}'
fi
EOF
chmod +x "$fixture/bin/cilium"

cat >"$fixture/bin/just" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'kube cilium-postflight' ]]
EOF
chmod +x "$fixture/bin/just"

run_layout() {
  local layout="$1"
  local chart_version="${2:-1.19.6+b8d600c542c9}"
  local log="$fixture/$layout.log"
  : >"$log"
  PATH="$fixture/bin:$PATH" \
  FAKE_CALL_LOG="$log" \
  FAKE_LAYOUT="$layout" \
  FAKE_CHART_VERSION="$chart_version" \
  FAKE_VALUES="$values" \
    "$verifier" "$fixture/kubeconfig" "$values" >"$fixture/$layout.out" || return "$?"
  printf '%s\n' "$log"
}

named_log="$(run_layout named)"
rg -q -- 'status .*--context homelab-diagnostic' "$named_log"
admin_log="$(run_layout admin)"
if rg -q -- '--context' "$admin_log"; then
  echo 'Cilium admin fallback unexpectedly selected a named context.' >&2
  exit 1
fi

if run_layout admin 1.19.6+aaaaaaaaaaaa >"$fixture/chart-drift.out" 2>&1; then
  echo 'Cilium verifier accepted a drifted live chart version.' >&2
  exit 1
fi
rg -Fq 'Cilium Helm chart version: expected 1.19.6+b8d600c542c9, got 1.19.6+aaaaaaaaaaaa' \
  "$fixture/chart-drift.out"

echo 'Cilium diagnostic-context verifier tests passed.'
