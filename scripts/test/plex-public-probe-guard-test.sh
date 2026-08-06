#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
scenario="$repo_root/scripts/test/scenarios/plex-public-probe.sh"
pinned_image='ghcr.io/home-operations/plex:1.43.3.10828@sha256:0c0b6899339503af17cb190b25af6acf10f0030e2820985e16ee14ef428f49d7'
fixture="$(mktemp -d "${TMPDIR:-/tmp}/plex-public-probe-guard-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/manifests"
touch "$fixture/kubeconfig" "$fixture/request-id"

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_KUBECTL_LOG"

if [[ " $* " == *' config get-contexts homelab-diagnostic --no-headers '* ]]; then
  exit 0
fi
[[ " $* " == *' --context homelab-diagnostic '* ]] || {
  echo "Missing diagnostic context: $*" >&2
  exit 65
}

case " $* " in
  *' create --filename '*)
    file="${*: -1}"
    name="$(yq -r '.metadata.name' "$file")"
    cp "$file" "$FAKE_MANIFEST_DIR/$name.yaml"
    printf 'pod/%s created\n' "$name"
    [[ "$FAKE_LAYOUT" != create-persisted-error ]]
    ;;
  *' --namespace testing wait --for=condition=Ready pod/'*)
    ;;
  *' --namespace envoy-gateway-system get deployments --selector gateway.envoyproxy.io/owning-gateway-namespace=networking-public,gateway.envoyproxy.io/owning-gateway-name=public --output json '*)
    cat <<'JSON'
{"apiVersion":"v1","kind":"List","items":[{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"envoy-public","namespace":"envoy-gateway-system","labels":{"gateway.envoyproxy.io/owning-gateway-namespace":"networking-public","gateway.envoyproxy.io/owning-gateway-name":"public"}},"spec":{"replicas":2},"status":{"availableReplicas":2}}]}
JSON
    ;;
  *' --namespace envoy-gateway-system get pods --selector gateway.envoyproxy.io/owning-gateway-namespace=networking-public,gateway.envoyproxy.io/owning-gateway-name=public --field-selector status.phase=Running --output json '*)
    cat <<'JSON'
{"apiVersion":"v1","kind":"List","items":[{"metadata":{"name":"envoy-public-a","namespace":"envoy-gateway-system","labels":{"gateway.envoyproxy.io/owning-gateway-namespace":"networking-public","gateway.envoyproxy.io/owning-gateway-name":"public"}},"status":{"phase":"Running","podIP":"10.244.1.10"}},{"metadata":{"name":"envoy-public-b","namespace":"envoy-gateway-system","labels":{"gateway.envoyproxy.io/owning-gateway-namespace":"networking-public","gateway.envoyproxy.io/owning-gateway-name":"public"}},"status":{"phase":"Running","podIP":"10.244.2.10"}}]}
JSON
    ;;
  *' --namespace testing exec plex-public-probe-'*' -- timeout 5 bash -c </dev/tcp/'*)
    [[ "$FAKE_LAYOUT" == admin-reachable ]]
    ;;
  *' --namespace testing exec plex-public-probe-'*' -- curl '*'https://plex.lab.supermorphic.com/identity?X-Plex-Token=plan-canary-not-a-secret'*)
    previous=''
    for argument in "$@"; do
      if [[ "$previous" == '--user-agent' ]]; then
        printf '%s' "$argument" >"$FAKE_AGENT_FILE"
      fi
      previous="$argument"
    done
    ;;
  *' --namespace envoy-gateway-system logs pod/envoy-public-'*' --container envoy --since=2m '*)
    [[ " $* " == *'pod/envoy-public-a'* ]] || exit 0
    agent="$(<"$FAKE_AGENT_FILE")"
    # Envoy regenerates x-request-id for untrusted downstream requests, so the logged
    # id is never the one the client sent. Emitting a fresh uuid here keeps the fixture
    # honest: correlation must survive an id the probe has never seen.
    envoy_request_id='b165c705-73a8-4692-94e4-eb2076501178'
    case "$FAKE_LAYOUT" in
      missing-canary)
        ;;
      stale-agent)
        printf '{"request_id":"%s","user_agent":"homelab-plex-public-canary/other-run","path":"/identity","downstream_remote_address":"10.244.0.5:43210"}\n' "$envoy_request_id"
        ;;
      no-request-id)
        printf '{"request_id":"","user_agent":"%s","path":"/identity","downstream_remote_address":"10.244.0.5:43210"}\n' "$agent"
        ;;
      leaked-token)
        printf '{"request_id":"%s","user_agent":"%s","path":"/identity?X-Plex-Token=plan-canary-not-a-secret","downstream_remote_address":"10.244.0.5:43210"}\n' "$envoy_request_id" "$agent"
        ;;
      *)
        printf '{"request_id":"%s","user_agent":"%s","path":"/identity","downstream_remote_address":"10.244.0.5:43210","x_forwarded_for":""}\n' "$envoy_request_id" "$agent"
        ;;
    esac
    ;;
  *' --namespace testing delete pod plex-public-probe-'*)
    [[ "$FAKE_LAYOUT" != delete-fails ]]
    ;;
  *)
    echo "Unexpected kubectl invocation: $*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$fixture/bin/kubectl"

cat >"$fixture/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fixture/bin/sleep"

kubectl_log="$fixture/kubectl.log"
output="$fixture/output"

run_scenario() {
  local layout="${1:-happy}"
  : >"$kubectl_log"
  : >"$fixture/request-id"
  rm -rf -- "$fixture/manifests"
  mkdir -p "$fixture/manifests"
  set +e
  PATH="$fixture/bin:$PATH" \
    FAKE_LAYOUT="$layout" \
    FAKE_KUBECTL_LOG="$kubectl_log" \
    FAKE_MANIFEST_DIR="$fixture/manifests" \
    FAKE_AGENT_FILE="$fixture/canary-agent" \
    PLEX_PUBLIC_PROBE_CONFIRM="${PLEX_PUBLIC_PROBE_CONFIRM:-}" \
    "$scenario" "$fixture/kubeconfig" >"$output" 2>&1
  local status="$?"
  set -e
  return "$status"
}

assert_cleanup() {
  local manifest name
  manifest="$(find "$fixture/manifests" -type f -name 'plex-public-probe-*.yaml' -print -quit)"
  [[ -n "$manifest" ]] || {
    echo 'Scenario did not create its run-scoped manifest.' >&2
    exit 1
  }
  name="$(basename "$manifest" .yaml)"
  rg -F -q -- "--namespace testing delete pod $name --ignore-not-found --wait=true --timeout=2m" "$kubectl_log" || {
    echo 'Scenario did not delete exactly its run-scoped probe.' >&2
    cat "$kubectl_log" >&2
    exit 1
  }
  if rg -q -- ' delete pod .*--all| delete pod .*--selector' "$kubectl_log"; then
    echo 'Scenario used broad pod cleanup.' >&2
    exit 1
  fi
}

echo '1. The scenario refuses missing and incorrect confirmations before cluster access.'
if run_scenario; then
  echo 'Scenario ran without confirmation.' >&2
  exit 1
fi
rg -F -q 'Refusing state-changing Plex public probe' "$output"
[[ ! -s "$kubectl_log" ]]
if PLEX_PUBLIC_PROBE_CONFIRM='test:wrong-probe' run_scenario; then
  echo 'Scenario ran with an incorrect confirmation.' >&2
  exit 1
fi
[[ ! -s "$kubectl_log" ]]

echo '2. The happy path uses one hardened probe and both exact Envoy owner labels.'
PLEX_PUBLIC_PROBE_CONFIRM='test:plex-public-probe' run_scenario
manifest="$(find "$fixture/manifests" -type f -name 'plex-public-probe-*.yaml' -print -quit)"
[[ "$(find "$fixture/manifests" -type f | wc -l | tr -d ' ')" == '1' ]]
[[ "$(yq -r '.kind' "$manifest")" == 'Pod' ]]
[[ "$(yq -r '.metadata.namespace' "$manifest")" == 'testing' ]]
[[ "$(yq -r '.metadata.name' "$manifest")" =~ ^plex-public-probe-[0-9]+-[0-9]+$ ]]
[[ "$(yq -r '.spec.automountServiceAccountToken' "$manifest")" == 'false' ]]
[[ "$(yq -r '.spec.restartPolicy' "$manifest")" == 'Never' ]]
[[ "$(yq -r '.spec.securityContext | [.runAsNonRoot, .runAsUser, .runAsGroup, .seccompProfile.type] | join(" ")' "$manifest")" == 'true 568 568 RuntimeDefault' ]]
[[ "$(yq -r '.spec.containers | length' "$manifest")" == '1' ]]
[[ "$(yq -r '.spec.containers[0].image' "$manifest")" == "$pinned_image" ]]
[[ "$(yq -r '.spec.containers[0].securityContext | [.allowPrivilegeEscalation, .readOnlyRootFilesystem, (.capabilities.drop | join(","))] | join(" ")' "$manifest")" == 'false true ALL' ]]
rg -F -q -- '--selector gateway.envoyproxy.io/owning-gateway-namespace=networking-public,gateway.envoyproxy.io/owning-gateway-name=public' "$kubectl_log"
rg -F -q -- '/dev/tcp/10.244.1.10/9901' "$kubectl_log"
rg -F -q -- '/dev/tcp/10.244.1.10/19000' "$kubectl_log"
rg -F -q -- '/dev/tcp/10.244.2.10/9901' "$kubectl_log"
rg -F -q -- '/dev/tcp/10.244.2.10/19000' "$kubectl_log"
rg -F -q -- 'https://plex.lab.supermorphic.com/identity?X-Plex-Token=plan-canary-not-a-secret' "$kubectl_log"
rg -F -q -- '--resolve plex.lab.supermorphic.com:443:192.168.90.39' "$kubectl_log"
rg -F -q -- '--container envoy --since=2m' "$kubectl_log"
rg -F -q -- 'token-safe access-log canary passed' "$output"
assert_cleanup

echo '3. Reachable admin ports fail closed and still clean up.'
if PLEX_PUBLIC_PROBE_CONFIRM='test:plex-public-probe' run_scenario admin-reachable; then
  echo 'Scenario passed with a reachable Envoy admin port.' >&2
  exit 1
fi
rg -F -q 'Envoy admin endpoint reachable' "$output"
assert_cleanup

echo '4. A matching log entry containing the canary token fails and still cleans up.'
if PLEX_PUBLIC_PROBE_CONFIRM='test:plex-public-probe' run_scenario leaked-token; then
  echo 'Scenario passed although the canary token appeared in the access log.' >&2
  exit 1
fi
rg -F -q 'Public Envoy access log leaked query or token material.' "$output"
assert_cleanup

echo '5. A missing canary entry fails and still cleans up.'
if PLEX_PUBLIC_PROBE_CONFIRM='test:plex-public-probe' run_scenario missing-canary; then
  echo 'Scenario passed without an attributable canary log entry.' >&2
  exit 1
fi
rg -F -q 'No attributable public Envoy access-log canary appeared.' "$output"
assert_cleanup

echo '6. A canary entry from a different run does not satisfy this run.'
if PLEX_PUBLIC_PROBE_CONFIRM='test:plex-public-probe' run_scenario stale-agent; then
  echo 'Scenario matched a canary entry belonging to a different run.' >&2
  exit 1
fi
rg -F -q 'No attributable public Envoy access-log canary appeared.' "$output"
assert_cleanup

echo '7. A canary entry without a request id fails attribution.'
if PLEX_PUBLIC_PROBE_CONFIRM='test:plex-public-probe' run_scenario no-request-id; then
  echo 'Scenario accepted a canary entry with no request id.' >&2
  exit 1
fi
rg -F -q 'carries no request id for attribution.' "$output"
assert_cleanup

echo '8. An ambiguous create failure still deletes the exact possibly persisted Pod.'
if PLEX_PUBLIC_PROBE_CONFIRM='test:plex-public-probe' run_scenario create-persisted-error; then
  echo 'Scenario passed after an ambiguous create failure.' >&2
  exit 1
fi
assert_cleanup

echo '9. A happy-path deletion failure prevents a success claim.'
if PLEX_PUBLIC_PROBE_CONFIRM='test:plex-public-probe' run_scenario delete-fails; then
  echo 'Scenario claimed success although its probe deletion failed.' >&2
  exit 1
fi
rg -F -q 'Failed to remove the run-scoped Plex public probe.' "$output"
assert_cleanup

echo 'Plex public probe guard tests passed.'
