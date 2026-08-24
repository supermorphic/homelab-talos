#!/usr/bin/env bash
# Offline guard test for scripts/test/scenarios/plex-network-policy.sh. A fake
# kubectl/dig/curl fixture proves the scenario's confirmation gate, run-scoped pod
# shape, hardened manifest, control-before-selected ordering, and cleanup on every
# exit path without touching a cluster.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
scenario="$repo_root/scripts/test/scenarios/plex-network-policy.sh"
verifier_exec_pattern=' exec plex-test-pod -c app -- /bin/bash -ceu '
pinned_image='ghcr.io/home-operations/plex:1.43.3.10828@sha256:0c0b6899339503af17cb190b25af6acf10f0030e2820985e16ee14ef428f49d7'

[[ -f "$scenario" ]] || {
  echo "Missing guarded scenario: $scenario" >&2
  exit 1
}

fixture="$(mktemp -d "${TMPDIR:-/tmp}/plex-network-policy-guard-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/manifests"
touch "$fixture/kubeconfig"

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$FAKE_KUBECTL_LOG"

if [[ "${FAKE_DIAGNOSTIC_CONTEXT:-false}" == 'true' &&
      " $* " != *' config get-contexts homelab-diagnostic '* &&
      " $* " != *' --context homelab-diagnostic '* ]]; then
  echo "Missing diagnostic context: $*" >&2
  exit 65
fi

case " $* " in
  *' config get-contexts homelab-diagnostic '*)
    [[ "${FAKE_DIAGNOSTIC_CONTEXT:-false}" == 'true' ]]
    ;;
  *' get svc kubernetes '*)
    printf '10.96.0.1'
    ;;
  *' get svc ntfy '*)
    printf '10.96.7.7'
    ;;
  *' get svc plex '*)
    printf '10.96.9.9'
    ;;
  *' --namespace media get service plex --output json'*)
    cat <<'JSON'
{
  "spec": {
    "type": "LoadBalancer",
    "externalTrafficPolicy": "Local",
    "allocateLoadBalancerNodePorts": false,
    "ports": [
      {
        "name": "http",
        "port": 32400,
        "protocol": "TCP",
        "targetPort": 32400
      }
    ]
  },
  "status": {
    "loadBalancer": {
      "ingress": [
        {
          "ip": "192.168.90.31"
        }
      ]
    }
  }
}
JSON
    ;;
  *' create --filename '*)
    file="${*: -1}"
    name="$(sed -n 's/^  name: //p' "$file" | head -n 1)"
    cp "$file" "$FAKE_MANIFEST_DIR/$name.yaml"
    printf 'pod/%s created\n' "$name"
    ;;
  *' wait '*)
    sleep "${FAKE_WAIT_SLEEP:-0}"
    ;;
  *' exec plex-policy-control-'*'/dev/tcp/10.96.9.9/32400'*)
    # The unrelated-probe ingress check must fail while the policy is enforced.
    [[ "${FAKE_INGRESS_REACHABLE:-false}" == 'true' ]]
    ;;
  *' exec plex-policy-control-'*'/dev/tcp/'*)
    [[ "${FAKE_CONTROL_OK:-true}" == 'true' ]]
    ;;
  *' exec plex-policy-selected-'*'/dev/tcp/'*)
    # A policy-selected pod must never reach the negative targets.
    [[ "${FAKE_SELECTED_OK:-false}" == 'true' ]]
    ;;
  *' --namespace flux-system get kustomization plex '*)
    printf 'True'
    ;;
  *' --namespace media get helmrelease plex '*)
    printf 'True'
    ;;
  *' --namespace media rollout status deployment/plex '*)
    printf '%s\n' 'deployment "plex" successfully rolled out'
    ;;
  *' --namespace media get pods '*)
    printf 'plex-test-pod'
    ;;
  *"$FAKE_VERIFIER_EXEC_PATTERN"*)
    exit 0
    ;;
  *' --namespace media get httproute plex '*)
    printf 'True'
    ;;
  *' delete pod '*)
    printf '%s\n' 'pod deleted'
    ;;
  *)
    echo "Unexpected kubectl invocation: $*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$fixture/bin/kubectl"

cat >"$fixture/bin/dig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '192.168.90.30'
EOF
chmod +x "$fixture/bin/dig"

cat >"$fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fixture/bin/curl"

kubectl_log="$fixture/kubectl.log"
output="$fixture/output"

run_scenario() {
  : >"$kubectl_log"
  rm -rf -- "$fixture/manifests"
  mkdir -p "$fixture/manifests"
  set +e
  PATH="$fixture/bin:$PATH" \
    FAKE_KUBECTL_LOG="$kubectl_log" \
    FAKE_MANIFEST_DIR="$fixture/manifests" \
    FAKE_VERIFIER_EXEC_PATTERN="$verifier_exec_pattern" \
    FAKE_DIAGNOSTIC_CONTEXT="${FAKE_DIAGNOSTIC_CONTEXT:-false}" \
    FAKE_WAIT_SLEEP="${FAKE_WAIT_SLEEP:-0}" \
    FAKE_CONTROL_OK="${FAKE_CONTROL_OK:-true}" \
    FAKE_SELECTED_OK="${FAKE_SELECTED_OK:-false}" \
    FAKE_INGRESS_REACHABLE="${FAKE_INGRESS_REACHABLE:-false}" \
    PLEX_NETWORK_POLICY_CONFIRM="${PLEX_NETWORK_POLICY_CONFIRM:-}" \
    "$scenario" "$fixture/kubeconfig" >"$output" 2>&1
  local status="$?"
  set -e
  return "$status"
}

line_number() {
  local line
  line="$(rg -n -m 1 -F "$1" "$kubectl_log" | cut -d: -f1 || true)"
  [[ -n "$line" ]] || {
    echo "Expected kubectl invocation missing: $1" >&2
    cat "$kubectl_log" >&2
    exit 1
  }
  printf '%s' "$line"
}

assert_pod_manifest() {
  local file="$1" app_label="$2"
  [[ "$(yq -r '.kind' "$file")" == 'Pod' ]]
  [[ "$(yq -r '.metadata.namespace' "$file")" == 'media' ]]
  [[ "$(yq -r '.metadata.labels."app.kubernetes.io/name"' "$file")" == "$app_label" ]]
  [[ "$(yq -r '.metadata.labels."app.kubernetes.io/instance"' "$file")" == 'plex-network-policy-test' ]]
  [[ "$(yq -r '.metadata.labels."homelab-talos/test"' "$file")" == 'plex-network-policy' ]]
  [[ "$(yq -r '.spec.restartPolicy' "$file")" == 'Never' ]]
  [[ "$(yq -r '.spec.automountServiceAccountToken' "$file")" == 'false' ]]
  [[ "$(yq -r '.spec.securityContext.runAsNonRoot' "$file")" == 'true' ]]
  [[ "$(yq -r '.spec.securityContext.runAsUser' "$file")" == '568' ]]
  [[ "$(yq -r '.spec.securityContext.runAsGroup' "$file")" == '568' ]]
  [[ "$(yq -r '.spec.securityContext.seccompProfile.type' "$file")" == 'RuntimeDefault' ]]
  [[ "$(yq -r '.spec.containers | length' "$file")" == '1' ]]
  [[ "$(yq -r '.spec.containers[0].image' "$file")" == "$pinned_image" ]]
  [[ "$(yq -r '.spec.containers[0].securityContext.allowPrivilegeEscalation' "$file")" == 'false' ]]
  [[ "$(yq -r '.spec.containers[0].securityContext.readOnlyRootFilesystem' "$file")" == 'true' ]]
  [[ "$(yq -r '.spec.containers[0].securityContext.capabilities.drop | join(",")' "$file")" == 'ALL' ]]
}

assert_cleanup_ran() {
  rg -q -F ' delete pod ' "$kubectl_log" || {
    echo 'Scenario exited without deleting its run-scoped pods.' >&2
    cat "$kubectl_log" >&2
    exit 1
  }
  local delete_line
  delete_line="$(rg -F ' delete pod ' "$kubectl_log")"
  control_name="$(basename "$fixture/manifests"/plex-policy-control-*.yaml .yaml 2>/dev/null || true)"
  selected_name="$(basename "$fixture/manifests"/plex-policy-selected-*.yaml .yaml 2>/dev/null || true)"
  if [[ -n "$control_name" && -n "$selected_name" ]]; then
    [[ "$delete_line" == *"$control_name"* && "$delete_line" == *"$selected_name"* ]] || {
      echo "Cleanup did not name exactly the two run-scoped pods: $delete_line" >&2
      exit 1
    }
  fi
  if [[ "$delete_line" == *'--all'* || "$delete_line" == *'--selector'* ]]; then
    echo "Cleanup must delete only the two run-scoped pods, got: $delete_line" >&2
    exit 1
  fi
}

cd "$repo_root"

echo '1. The scenario refuses to run without the exact confirmation.'
if run_scenario; then
  echo 'Scenario ran without PLEX_NETWORK_POLICY_CONFIRM.' >&2
  exit 1
fi
rg -q 'Refusing' "$output"
[[ ! -s "$kubectl_log" ]] || {
  echo 'Scenario invoked kubectl before the confirmation gate.' >&2
  cat "$kubectl_log" >&2
  exit 1
}

echo '2. A wrong confirmation value is equally refused.'
if PLEX_NETWORK_POLICY_CONFIRM='test:something-else' run_scenario; then
  echo 'Scenario ran with a wrong confirmation value.' >&2
  exit 1
fi
rg -q 'Refusing' "$output"
[[ ! -s "$kubectl_log" ]]

echo '3. Available diagnostic credentials are selected for every cluster operation.'
if ! FAKE_DIAGNOSTIC_CONTEXT=true \
  PLEX_NETWORK_POLICY_CONFIRM='test:plex-network-policy' run_scenario; then
  echo 'Scenario did not select the available homelab-diagnostic context.' >&2
  cat "$output" >&2
  exit 1
fi

echo '4. Happy path: control proves each target, the selected pod is denied, and the verifier runs last.'
if ! PLEX_NETWORK_POLICY_CONFIRM='test:plex-network-policy' run_scenario; then
  echo 'Happy-path scenario run failed.' >&2
  cat "$output" >&2
  exit 1
fi
rg -q 'network containment' "$output"

control_manifest="$(printf '%s\n' "$fixture/manifests"/plex-policy-control-*.yaml)"
selected_manifest="$(printf '%s\n' "$fixture/manifests"/plex-policy-selected-*.yaml)"
[[ -f "$control_manifest" && -f "$selected_manifest" ]]
[[ "$(find "$fixture/manifests" -type f -name '*.yaml' | wc -l | tr -d ' ')" == '2' ]]
control_name="$(basename "$control_manifest" .yaml)"
selected_name="$(basename "$selected_manifest" .yaml)"
[[ "$control_name" =~ ^plex-policy-control-[0-9]+-[0-9]+$ ]]
[[ "$selected_name" =~ ^plex-policy-selected-[0-9]+-[0-9]+$ ]]
assert_pod_manifest "$control_manifest" 'plex-policy-control'
assert_pod_manifest "$selected_manifest" 'plex'

first_create="$(line_number ' create --filename ')"
[[ "$(line_number ' get svc kubernetes ')" -lt "$first_create" ]]
[[ "$(line_number ' get svc ntfy ')" -lt "$first_create" ]]
[[ "$(line_number ' get svc plex ')" -lt "$first_create" ]]
[[ "$(line_number ' wait ')" -gt "$first_create" ]]

previous=0
for target in '10.96.0.1/443' '10.96.7.7/80' '192.168.90.1/443'; do
  control_line="$(line_number "exec $control_name -- timeout 10 bash -c </dev/tcp/$target")"
  selected_line="$(line_number "exec $selected_name -- timeout 10 bash -c </dev/tcp/$target")"
  [[ "$control_line" -gt "$previous" ]]
  [[ "$control_line" -lt "$selected_line" ]]
  previous="$selected_line"
done
if rg -q -F '/dev/tcp/192.168.30.6/' "$kubectl_log"; then
  echo 'Scenario still probed the unreachable Room Alert endpoint.' >&2
  exit 1
fi
ingress_line="$(line_number "exec $control_name -- timeout 10 bash -c </dev/tcp/10.96.9.9/32400")"
[[ "$ingress_line" -gt "$previous" ]]
verify_line="$(line_number ' get kustomization plex ')"
[[ "$verify_line" -gt "$ingress_line" ]]
[[ "$(line_number ' delete pod ')" -gt "$verify_line" ]]
assert_cleanup_ran

echo '5. A control target failure stops the run before any selected-pod probe.'
if FAKE_CONTROL_OK=false PLEX_NETWORK_POLICY_CONFIRM='test:plex-network-policy' run_scenario; then
  echo 'Scenario succeeded although the control target was unreachable.' >&2
  exit 1
fi
rg -q 'Control target unreachable' "$output"
if rg -q ' exec plex-policy-selected-' "$kubectl_log"; then
  echo 'Scenario probed from the selected pod after a control failure.' >&2
  exit 1
fi
assert_cleanup_ran

echo '6. A selected pod reaching a negative target fails the run.'
if FAKE_SELECTED_OK=true PLEX_NETWORK_POLICY_CONFIRM='test:plex-network-policy' run_scenario; then
  echo 'Scenario succeeded although the selected pod reached a denied target.' >&2
  exit 1
fi
rg -q 'reached' "$output"
assert_cleanup_ran

echo '7. An unrelated probe reaching Plex on 32400 fails the run.'
if FAKE_INGRESS_REACHABLE=true PLEX_NETWORK_POLICY_CONFIRM='test:plex-network-policy' run_scenario; then
  echo 'Scenario succeeded although an unrelated pod reached plex:32400.' >&2
  exit 1
fi
rg -q 'reached plex' "$output"
assert_cleanup_ran

for signal in TERM INT; do
  expected=143
  [[ "$signal" == 'INT' ]] && expected=130
  echo "8. SIG$signal mid-run still deletes exactly the two run-scoped pods (exit $expected)."
  : >"$kubectl_log"
  rm -rf -- "$fixture/manifests"
  mkdir -p "$fixture/manifests"
  # The scenario must run in this shell's foreground: a backgrounded child inherits
  # SIGINT ignored and could never install its INT trap. A background watcher
  # signals it once it blocks on the pod wait.
  (
    for _ in {1..100}; do
      [[ -f "$kubectl_log" ]] && rg -q ' wait ' "$kubectl_log" 2>/dev/null && break
      sleep 0.1
    done
    target="$(pgrep -f 'scenarios/plex-network-policy.sh' | head -n 1 || true)"
    [[ -n "$target" ]] && kill -"$signal" "$target" 2>/dev/null || true
  ) &
  watcher_pid="$!"
  set +e
  PATH="$fixture/bin:$PATH" \
    FAKE_KUBECTL_LOG="$kubectl_log" \
    FAKE_MANIFEST_DIR="$fixture/manifests" \
    FAKE_VERIFIER_EXEC_PATTERN="$verifier_exec_pattern" \
    FAKE_WAIT_SLEEP=5 \
    PLEX_NETWORK_POLICY_CONFIRM='test:plex-network-policy' \
    "$scenario" "$fixture/kubeconfig" >"$output" 2>&1
  signal_status="$?"
  set -e
  wait "$watcher_pid" 2>/dev/null || true
  rg -q ' wait ' "$kubectl_log" || {
    echo 'Scenario never reached the pod wait; cannot prove mid-run signal cleanup.' >&2
    exit 1
  }
  [[ "$signal_status" == "$expected" ]] || {
    echo "Scenario exited $signal_status on SIG$signal; expected $expected." >&2
    cat "$output" >&2
    exit 1
  }
  assert_cleanup_ran
done

echo 'Plex network-policy scenario guard test passed.'
