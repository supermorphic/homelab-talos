#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

observer='scripts/diagnose/plex-network-observe.sh'
[[ -x "$observer" ]] || {
  echo "Missing executable observer: $observer" >&2
  exit 1
}

test_root="$(mktemp -d "${TMPDIR:-/tmp}/plex-network-observe-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/cilium" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf -v quoted_args ' %q' "$@"
printf 'cilium command%s\n' "$quoted_args" >>"$FAKE_COMMAND_LOG"

[[ "$#" -eq 4 \
  && "$1" == 'hubble' \
  && "$2" == 'port-forward' \
  && "$3" == '--kubeconfig' \
  && "$4" == "$FAKE_KUBECONFIG" ]] || exit 9

printf 'cilium port-forward start %s\n' "$BASHPID" >>"$FAKE_PROCESS_LOG"
trap 'printf "cilium port-forward term %s\n" "$BASHPID" >>"$FAKE_PROCESS_LOG"; /bin/sleep 0.05; printf "cilium port-forward exit %s\n" "$BASHPID" >>"$FAKE_PROCESS_LOG"; exit 0' TERM INT
while :; do
  /bin/sleep 1
done
EOF

cat >"$fake_bin/hubble" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf -v quoted_args ' %q' "$@"
printf 'hubble%s\n' "$quoted_args" >>"$FAKE_COMMAND_LOG"

case "${1:-}" in
  status)
    [[ "$#" -eq 3 && "$2" == '--server' && "$3" == 'localhost:4245' ]] || exit 9
    count=0
    [[ ! -f "$FAKE_STATUS_COUNT" ]] || read -r count <"$FAKE_STATUS_COUNT"
    count=$((count + 1))
    printf '%s\n' "$count" >"$FAKE_STATUS_COUNT"
    if [[ "${FAKE_HUBBLE_STATUS_MODE:-healthy}" == 'unavailable' ]]; then
      exit 1
    fi
    printf 'Healthcheck (via localhost:4245): Ok\n'
    ;;
  observe)
    [[ "$#" -eq 10 \
      && "$2" == '--server' \
      && "$3" == 'localhost:4245' \
      && "$4" == '--namespace' \
      && "$5" == 'media' \
      && "$6" == '--pod' \
      && "$7" == 'plex' \
      && "$8" == '--follow' \
      && "$9" == '--output' \
      && "${10}" == 'compact' ]] || exit 9
    printf 'hubble observe start %s\n' "$BASHPID" >>"$FAKE_PROCESS_LOG"
    : >"$FAKE_OBSERVE_READY"
    printf 'Aug 2 12:00:00.000 media/plex:32400 -> 192.0.2.10:50123 to-network FORWARDED (TCP Flags: ACK)\n'
    printf 'Aug 2 12:00:00.001 192.0.2.10:50123 -> media/plex:32400 to-endpoint FORWARDED (TCP Flags: ACK)\n'
    case "${FAKE_HUBBLE_OBSERVE_MODE:-follow}" in
      success)
        exit 0
        ;;
      failure)
        exit 23
        ;;
      follow)
        trap 'printf "hubble observe term %s\n" "$BASHPID" >>"$FAKE_PROCESS_LOG"; exit 143' TERM INT
        while :; do
          /bin/sleep 1
        done
        ;;
      *)
        exit 9
        ;;
    esac
    ;;
  *)
    exit 9
    ;;
esac
EOF

cat >"$fake_bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf -v quoted_args ' %q' "$@"
printf 'sleep%s\n' "$quoted_args" >>"$FAKE_COMMAND_LOG"
printf 'sleep start %s\n' "$BASHPID" >>"$FAKE_PROCESS_LOG"

if [[ "$#" -eq 1 && "$1" == '1' && "${FAKE_HUBBLE_STATUS_MODE:-healthy}" == 'unavailable' ]]; then
  exit 0
fi

trap 'printf "sleep term %s\n" "$BASHPID" >>"$FAKE_PROCESS_LOG"; exit 143' TERM INT
while [[ ! -f "$FAKE_OBSERVE_READY" ]]; do
  /bin/sleep 0.01
done
[[ "${FAKE_SLEEP_MODE:-timeout}" == 'wait' ]] || exit 0
/bin/sleep 2
EOF

cat >"$fake_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf -v quoted_args ' %q' "$@"
printf 'kubectl%s\n' "$quoted_args" >>"$FAKE_COMMAND_LOG"
exit 97
EOF

chmod +x "$fake_bin/cilium" "$fake_bin/hubble" "$fake_bin/sleep" "$fake_bin/kubectl"

scenario_dir=''
command_log=''
process_log=''
kubeconfig=''
status_count=''
observe_ready=''
output=''
run_status=0

new_scenario() {
  local name="$1"
  scenario_dir="$test_root/$name"
  command_log="$scenario_dir/commands.log"
  process_log="$scenario_dir/processes.log"
  kubeconfig="$scenario_dir/kubeconfig"
  status_count="$scenario_dir/status-count"
  observe_ready="$scenario_dir/observe-ready"
  output="$scenario_dir/output"
  mkdir -p "$scenario_dir/tmp"
  : >"$command_log"
  : >"$process_log"
  : >"$kubeconfig"
}

run_observer() {
  local duration="$1"
  local status_mode="${2:-healthy}"
  local observe_mode="${3:-follow}"
  local sleep_mode="${4:-timeout}"

  set +e
  PATH="$fake_bin:$PATH" \
    TMPDIR="$scenario_dir/tmp" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_PROCESS_LOG="$process_log" \
    FAKE_KUBECONFIG="$kubeconfig" \
    FAKE_STATUS_COUNT="$status_count" \
    FAKE_OBSERVE_READY="$observe_ready" \
    FAKE_HUBBLE_STATUS_MODE="$status_mode" \
    FAKE_HUBBLE_OBSERVE_MODE="$observe_mode" \
    FAKE_SLEEP_MODE="$sleep_mode" \
    "$observer" "$kubeconfig" "$duration" >"$output" 2>&1
  run_status=$?
  set -e
}

assert_forbidden_absent() {
  if rg -qi -e '(^|[[:space:]])(kubectl|create|apply|patch|delete|rollout|suspend|resume)([[:space:]]|$)' "$command_log"; then
    echo "Observer used a forbidden command in $scenario_dir." >&2
    exit 1
  fi
}

assert_same_process_received_term() {
  local component="$1"
  local start_pid
  local term_pid

  start_pid="$(rg -o "^${component} start [0-9]+$" "$process_log" | rg -o '[0-9]+$')"
  term_pid="$(rg -o "^${component} term [0-9]+$" "$process_log" | rg -o '[0-9]+$')"
  [[ -n "$start_pid" && "$start_pid" == "$term_pid" ]]
}

assert_port_forward_waited() {
  local start_pid
  local exit_pid

  start_pid="$(rg -o '^cilium port-forward start [0-9]+$' "$process_log" | rg -o '[0-9]+$')"
  exit_pid="$(rg -o '^cilium port-forward exit [0-9]+$' "$process_log" | rg -o '[0-9]+$')"
  [[ -n "$start_pid" && "$start_pid" == "$exit_pid" ]]
}

assert_temp_dir_empty() {
  [[ -z "$(find "$scenario_dir/tmp" -mindepth 1 -print -quit)" ]]
}

assert_rejected() {
  local name="$1"
  shift
  new_scenario "$name"
  set +e
  PATH="$fake_bin:$PATH" \
    TMPDIR="$scenario_dir/tmp" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_PROCESS_LOG="$process_log" \
    FAKE_KUBECONFIG="$kubeconfig" \
    FAKE_STATUS_COUNT="$status_count" \
    FAKE_OBSERVE_READY="$observe_ready" \
    "$observer" "$@" >"$output" 2>&1
  run_status=$?
  set -e
  [[ "$run_status" -ne 0 ]]
  [[ ! -s "$command_log" ]]
}

assert_rejected no-arguments
assert_rejected one-argument "$kubeconfig"
assert_rejected extra-argument "$kubeconfig" 5 extra
assert_rejected zero-duration "$kubeconfig" 0
assert_rejected too-long-duration "$kubeconfig" 601
assert_rejected non-numeric-duration "$kubeconfig" nope
assert_rejected missing-kubeconfig "$scenario_dir/does-not-exist" 5

new_scenario timeout
run_observer 7
[[ "$run_status" -eq 0 ]]
rg -q "^cilium command hubble port-forward --kubeconfig ${kubeconfig}$" "$command_log"
rg -q '^hubble status --server localhost:4245$' "$command_log"
rg -q '^hubble observe --server localhost:4245 --namespace media --pod plex --follow --output compact$' "$command_log"
rg -q '^sleep 7$' "$command_log"
rg -q 'media/plex:32400.*FORWARDED.*TCP' "$output"
assert_same_process_received_term 'hubble observe'
assert_same_process_received_term 'cilium port-forward'
assert_port_forward_waited
assert_forbidden_absent
assert_temp_dir_empty

new_scenario early-success
run_observer 8 healthy success wait
[[ "$run_status" -eq 0 ]]
if rg -q '^hubble observe term ' "$process_log"; then
  echo 'Naturally completed Hubble observer was unexpectedly terminated.' >&2
  exit 1
fi
assert_same_process_received_term 'cilium port-forward'
assert_port_forward_waited
assert_forbidden_absent
assert_temp_dir_empty

new_scenario early-failure
run_observer 9 healthy failure wait
[[ "$run_status" -ne 0 ]]
assert_same_process_received_term 'cilium port-forward'
assert_port_forward_waited
assert_forbidden_absent
assert_temp_dir_empty

new_scenario unavailable
run_observer 10 unavailable follow timeout
[[ "$run_status" -ne 0 ]]
status_calls="$(rg -c '^hubble status --server localhost:4245$' "$command_log")"
sleep_calls="$(rg -c '^sleep 1$' "$command_log")"
if [[ "$status_calls" -ne 15 || "$sleep_calls" -ne 15 ]]; then
  echo "Expected 15 readiness attempts, got $status_calls status and $sleep_calls sleep calls:" >&2
  while IFS= read -r command; do
    printf '  %s\n' "$command" >&2
  done <"$command_log"
  exit 1
fi
if rg -q '^hubble observe ' "$command_log"; then
  echo 'Observer started before Hubble became ready.' >&2
  exit 1
fi
assert_same_process_received_term 'cilium port-forward'
assert_port_forward_waited
assert_forbidden_absent
assert_temp_dir_empty

new_scenario interrupt
PATH="$fake_bin:$PATH" \
  TMPDIR="$scenario_dir/tmp" \
  FAKE_COMMAND_LOG="$command_log" \
  FAKE_PROCESS_LOG="$process_log" \
  FAKE_KUBECONFIG="$kubeconfig" \
  FAKE_STATUS_COUNT="$status_count" \
  FAKE_OBSERVE_READY="$observe_ready" \
  FAKE_HUBBLE_STATUS_MODE=healthy \
  FAKE_HUBBLE_OBSERVE_MODE=follow \
  FAKE_SLEEP_MODE=wait \
  "$observer" "$kubeconfig" 11 >"$output" 2>&1 &
runner_pid=$!
for _ in {1..100}; do
  [[ -f "$observe_ready" ]] && break
  /bin/sleep 0.01
done
[[ -f "$observe_ready" ]]
kill -TERM "$runner_pid"
set +e
wait "$runner_pid"
run_status=$?
set -e
[[ "$run_status" -eq 143 ]]
assert_same_process_received_term 'hubble observe'
assert_same_process_received_term 'cilium port-forward'
assert_port_forward_waited
assert_forbidden_absent
assert_temp_dir_empty

echo 'Plex network observer tests passed.'
