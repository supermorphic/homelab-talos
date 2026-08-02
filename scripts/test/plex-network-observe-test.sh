#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

observer='scripts/diagnose/plex-network-observe.sh'
[[ -x "$observer" ]] || {
  echo "Missing executable observer: $observer" >&2
  exit 1
}

[[ "$#" -le 1 ]] || {
  echo 'Usage: plex-network-observe-test.sh [case]' >&2
  exit 2
}
requested_case="${1:-all}"

should_run() {
  [[ "$requested_case" == 'all' || "$requested_case" == "$1" ]]
}

test_root="$(mktemp -d "${TMPDIR:-/tmp}/plex-network-observe-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

fake_bin="$test_root/bin"
fake_bash_env="$test_root/bash-env"
mkdir -p "$fake_bin"

cat >"$fake_bash_env" <<'EOF'
fake_emit_event() {
  printf '%s %s %s\n' "$1" "$2" "$3" >"$FAKE_EVENT_FIFO"
}

fake_timer_stop() {
  trap - TERM INT
  printf 'timer term %s\n' "$BASHPID" >>"$FAKE_PROCESS_LOG"
  fake_emit_event timer_term "$BASHPID" "$PPID"
  IFS= read -r _ <"$FAKE_TIMER_EXIT_GATE"
  printf 'timer exit %s\n' "$BASHPID" >>"$FAKE_PROCESS_LOG"
  exit 143
}

sleep() {
  printf 'sleep %q\n' "$1" >>"$FAKE_COMMAND_LOG"
  if [[ "$1" == '1' && "${FAKE_HUBBLE_STATUS_MODE:-healthy}" == 'unavailable' ]]; then
    printf 'readiness sleep %s\n' "$BASHPID" >>"$FAKE_PROCESS_LOG"
    return 0
  fi

  trap fake_timer_stop TERM INT
  printf 'timer start %s\n' "$BASHPID" >>"$FAKE_PROCESS_LOG"
  fake_emit_event timer_start "$BASHPID" "$PPID"
  IFS= read -r _ <"$FAKE_TIMER_GATE"
  printf 'timer release %s\n' "$BASHPID" >>"$FAKE_PROCESS_LOG"
  trap - TERM INT
}
EOF

cat >"$fake_bin/cilium" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf -v quoted_args ' %q' "$@"
printf 'cilium command%s\n' "$quoted_args" >>"$FAKE_COMMAND_LOG"

context_args=0
if [[ "${5:-}" == '--context' ]]; then
  [[ "${6:-}" == 'homelab-diagnostic' ]] || exit 9
  context_args=2
fi
[[ "$#" -eq $((4 + context_args)) \
  && "$1" == 'hubble' \
  && "$2" == 'port-forward' \
  && "$3" == '--kubeconfig' \
  && "$4" == "$FAKE_KUBECONFIG" ]] || exit 9

cilium_stop() {
  trap - TERM INT
  printf 'cilium port-forward term %s\n' "$BASHPID" >>"$FAKE_PROCESS_LOG"
  fake_emit_event cilium_term "$BASHPID" "$PPID"
  IFS= read -r _ <"$FAKE_CILIUM_EXIT_GATE"
  printf 'cilium port-forward exit %s\n' "$BASHPID" >>"$FAKE_PROCESS_LOG"
  exit 0
}

trap cilium_stop TERM INT
printf 'cilium port-forward start %s\n' "$BASHPID" >>"$FAKE_PROCESS_LOG"
fake_emit_event cilium_start "$BASHPID" "$PPID"
printf 'ready\n' >"$FAKE_CILIUM_READY"
IFS= read -r _ <"$FAKE_CILIUM_HOLD"
EOF

cat >"$fake_bin/hubble" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf -v quoted_args ' %q' "$@"
printf 'hubble%s\n' "$quoted_args" >>"$FAKE_COMMAND_LOG"

case "${1:-}" in
  status)
    [[ "$#" -eq 3 && "$2" == '--server' && "$3" == 'localhost:4245' ]] || exit 9
    IFS= read -r ready <"$FAKE_CILIUM_READY"
    printf '%s\n' "$ready" >"$FAKE_CILIUM_READY"
    count=0
    [[ ! -f "$FAKE_STATUS_COUNT" ]] || read -r count <"$FAKE_STATUS_COUNT"
    count=$((count + 1))
    printf '%s\n' "$count" >"$FAKE_STATUS_COUNT"
    [[ "${FAKE_HUBBLE_STATUS_MODE:-healthy}" != 'unavailable' ]] || exit 1
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

    observe_stop() {
      local exit_status=143
      trap - TERM INT
      [[ "${FAKE_HUBBLE_OBSERVE_MODE:-follow}" != 'failure-on-term' ]] || exit_status=23
      printf 'hubble observe term %s\n' "$BASHPID" >>"$FAKE_PROCESS_LOG"
      fake_emit_event observe_term "$BASHPID" "$PPID"
      IFS= read -r _ <"$FAKE_OBSERVE_EXIT_GATE"
      printf 'hubble observe exit %s %s\n' "$BASHPID" "$exit_status" >>"$FAKE_PROCESS_LOG"
      exit "$exit_status"
    }

    trap observe_stop TERM INT
    printf 'hubble observe start %s\n' "$BASHPID" >>"$FAKE_PROCESS_LOG"
    fake_emit_event observe_start "$BASHPID" "$PPID"
    printf 'Aug 2 12:00:00.000 media/plex:32400 -> 192.0.2.10:50123 to-network FORWARDED (TCP Flags: ACK)\n'
    printf 'Aug 2 12:00:00.001 192.0.2.10:50123 -> media/plex:32400 to-endpoint FORWARDED (TCP Flags: ACK)\n'

    case "${FAKE_HUBBLE_OBSERVE_MODE:-follow}" in
      success)
        IFS= read -r _ <"$FAKE_OBSERVE_HOLD"
        printf 'hubble observe exit %s 0\n' "$BASHPID" >>"$FAKE_PROCESS_LOG"
        exit 0
        ;;
      failure)
        IFS= read -r _ <"$FAKE_OBSERVE_HOLD"
        printf 'hubble observe exit %s 23\n' "$BASHPID" >>"$FAKE_PROCESS_LOG"
        exit 23
        ;;
      follow|failure-on-term)
        IFS= read -r _ <"$FAKE_OBSERVE_HOLD"
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

cat >"$fake_bin/cluster-client-deny" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
client="${0##*/}"
printf -v quoted_args ' %q' "$@"
printf 'cluster-client %s%s\n' "$client" "$quoted_args" >>"$FAKE_COMMAND_LOG"
exit 97
EOF

cat >"$fake_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf -v quoted_args ' %q' "$@"
printf 'kubectl%s\n' "$quoted_args" >>"$FAKE_COMMAND_LOG"

if [[ "${1:-}" == 'mutation-probe' ]]; then
  printf 'cluster-client kubectl%s\n' "$quoted_args" >>"$FAKE_COMMAND_LOG"
  exit 97
fi

[[ "$#" -eq 6 \
  && "$1" == '--kubeconfig' \
  && "$2" == "$FAKE_KUBECONFIG" \
  && "$3" == 'config' \
  && "$4" == 'get-contexts' \
  && "$5" == 'homelab-diagnostic' \
  && "$6" == '--no-headers' ]] || exit 9
[[ "$FAKE_KUBECONFIG_LAYOUT" == 'scoped' ]]
EOF

for client in flux helm talosctl talhelper kustomize; do
  cp "$fake_bin/cluster-client-deny" "$fake_bin/$client"
done
chmod +x "$fake_bin/cilium" "$fake_bin/hubble" "$fake_bin/cluster-client-deny" \
  "$fake_bin/kubectl" "$fake_bin/flux" "$fake_bin/helm" "$fake_bin/talosctl" \
  "$fake_bin/talhelper" "$fake_bin/kustomize"

scenario_dir=''
command_log=''
process_log=''
kubeconfig=''
status_count=''
output=''
event_fifo=''
timer_gate=''
timer_exit_gate=''
observe_hold=''
observe_exit_gate=''
cilium_hold=''
cilium_exit_gate=''
cilium_ready=''
run_status=0
scenario_fds_open='false'
kubeconfig_layout='operator'

close_scenario_fds() {
  [[ "$scenario_fds_open" == 'true' ]] || return 0
  exec 20>&- 21>&- 22>&- 23>&- 24>&- 25>&- 26>&- 27>&-
  scenario_fds_open='false'
}

new_scenario() {
  local name="$1"
  kubeconfig_layout="${2:-operator}"
  close_scenario_fds
  scenario_dir="$test_root/$name"
  command_log="$scenario_dir/commands.log"
  process_log="$scenario_dir/processes.log"
  kubeconfig="$scenario_dir/kubeconfig"
  status_count="$scenario_dir/status-count"
  output="$scenario_dir/output"
  event_fifo="$scenario_dir/events"
  timer_gate="$scenario_dir/timer-gate"
  timer_exit_gate="$scenario_dir/timer-exit-gate"
  observe_hold="$scenario_dir/observe-hold"
  observe_exit_gate="$scenario_dir/observe-exit-gate"
  cilium_hold="$scenario_dir/cilium-hold"
  cilium_exit_gate="$scenario_dir/cilium-exit-gate"
  cilium_ready="$scenario_dir/cilium-ready"

  mkdir -p "$scenario_dir/tmp"
  : >"$command_log"
  : >"$process_log"
  : >"$kubeconfig"
  mkfifo "$event_fifo" "$timer_gate" "$timer_exit_gate" "$observe_hold" \
    "$observe_exit_gate" "$cilium_hold" "$cilium_exit_gate" "$cilium_ready"
  exec 20<>"$event_fifo"
  exec 21<>"$timer_gate"
  exec 22<>"$timer_exit_gate"
  exec 23<>"$observe_hold"
  exec 24<>"$observe_exit_gate"
  exec 25<>"$cilium_hold"
  exec 26<>"$cilium_exit_gate"
  exec 27<>"$cilium_ready"
  scenario_fds_open='true'
}

run_observer() {
  local duration="$1"
  local status_mode="${2:-healthy}"
  local observe_mode="${3:-follow}"

  set +e
  PATH="$fake_bin:$PATH" \
    BASH_ENV="$fake_bash_env" \
    TMPDIR="$scenario_dir/tmp" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_PROCESS_LOG="$process_log" \
    FAKE_KUBECONFIG="$kubeconfig" \
    FAKE_KUBECONFIG_LAYOUT="$kubeconfig_layout" \
    FAKE_STATUS_COUNT="$status_count" \
    FAKE_EVENT_FIFO="$event_fifo" \
    FAKE_TIMER_GATE="$timer_gate" \
    FAKE_TIMER_EXIT_GATE="$timer_exit_gate" \
    FAKE_OBSERVE_HOLD="$observe_hold" \
    FAKE_OBSERVE_EXIT_GATE="$observe_exit_gate" \
    FAKE_CILIUM_HOLD="$cilium_hold" \
    FAKE_CILIUM_EXIT_GATE="$cilium_exit_gate" \
    FAKE_CILIUM_READY="$cilium_ready" \
    FAKE_HUBBLE_STATUS_MODE="$status_mode" \
    FAKE_HUBBLE_OBSERVE_MODE="$observe_mode" \
    "$observer" "$kubeconfig" "$duration" >"$output" 2>&1
  run_status=$?
  set -e
}

coordinate_early_exit() {
  local event pid parent
  local observe_started='false'
  local timer_started='false'
  local observe_released='false'
  local timer_exited='false'
  local cilium_exited='false'

  while [[ "$timer_exited" != 'true' || "$cilium_exited" != 'true' ]]; do
    IFS=' ' read -r event pid parent <&20
    case "$event" in
      observe_start)
        observe_started='true'
        ;;
      timer_start)
        timer_started='true'
        ;;
      timer_term)
        printf 'release\n' >&22
        timer_exited='true'
        ;;
      cilium_term)
        printf 'release\n' >&26
        cilium_exited='true'
        ;;
    esac
    if [[ "$observe_started" == 'true' && "$timer_started" == 'true' && "$observe_released" != 'true' ]]; then
      printf 'release\n' >&23
      observe_released='true'
    fi
  done
}

coordinate_timeout() {
  local event pid parent
  local observe_started='false'
  local timer_started='false'
  local timer_released='false'
  local observe_exited='false'
  local cilium_exited='false'

  while [[ "$observe_exited" != 'true' || "$cilium_exited" != 'true' ]]; do
    IFS=' ' read -r event pid parent <&20
    case "$event" in
      observe_start)
        observe_started='true'
        ;;
      timer_start)
        timer_started='true'
        ;;
      observe_term)
        printf 'release\n' >&24
        observe_exited='true'
        ;;
      cilium_term)
        printf 'release\n' >&26
        cilium_exited='true'
        ;;
    esac
    if [[ "$observe_started" == 'true' && "$timer_started" == 'true' && "$timer_released" != 'true' ]]; then
      printf 'release\n' >&21
      timer_released='true'
    fi
  done
}

coordinate_signal() {
  local signal_name="$1"
  local event pid parent
  local observe_parent=''
  local timer_started='false'
  local signal_sent='false'
  local timer_exited='false'
  local observe_exited='false'
  local cilium_exited='false'

  while [[ "$timer_exited" != 'true' || "$observe_exited" != 'true' || "$cilium_exited" != 'true' ]]; do
    IFS=' ' read -r event pid parent <&20
    case "$event" in
      observe_start)
        observe_parent="$parent"
        ;;
      timer_start)
        timer_started='true'
        ;;
      timer_term)
        printf 'release\n' >&22
        timer_exited='true'
        ;;
      observe_term)
        printf 'release\n' >&24
        observe_exited='true'
        ;;
      cilium_term)
        printf 'release\n' >&26
        cilium_exited='true'
        ;;
    esac
    if [[ -n "$observe_parent" && "$timer_started" == 'true' && "$signal_sent" != 'true' ]]; then
      kill -"$signal_name" "$observe_parent"
      signal_sent='true'
    fi
  done
}

coordinate_unavailable() {
  local event pid parent
  while IFS=' ' read -r event pid parent <&20; do
    if [[ "$event" == 'cilium_term' ]]; then
      printf 'release\n' >&26
      return 0
    fi
  done
}

process_pid() {
  local component="$1"
  local phase="$2"
  local pid
  pid="$(rg -m1 -o "^${component} ${phase} [0-9]+" "$process_log" | rg -o '[0-9]+$' || true)"
  [[ -n "$pid" ]] || {
    echo "Missing $component $phase lifecycle event in $scenario_dir." >&2
    return 1
  }
  printf '%s\n' "$pid"
}

assert_same_lifecycle_pid() {
  local component="$1"
  shift
  local expected_pid=''
  local phase pid
  for phase in "$@"; do
    pid="$(process_pid "$component" "$phase")"
    [[ -z "$expected_pid" ]] && expected_pid="$pid"
    [[ "$pid" == "$expected_pid" ]] || {
      echo "$component lifecycle changed PID: expected $expected_pid, got $pid for $phase." >&2
      exit 1
    }
  done
}

assert_pid_reaped() {
  local component="$1"
  local pid
  pid="$(process_pid "$component" start)"
  if kill -0 "$pid" 2>/dev/null; then
    echo "$component PID $pid remains live or unreaped." >&2
    exit 1
  fi
}

assert_forbidden_absent() {
  if rg -qi -e '(^|[[:space:]])(flux|helm|talosctl|talhelper|kustomize|create|apply|patch|delete|rollout|suspend|resume)([[:space:]]|$)' "$command_log"; then
    echo "Observer used a forbidden command in $scenario_dir." >&2
    exit 1
  fi
}

assert_temp_dir_empty() {
  [[ -z "$(find "$scenario_dir/tmp" -mindepth 1 -print -quit)" ]]
}

assert_common_cleanup() {
  assert_same_lifecycle_pid 'cilium port-forward' start term exit
  assert_pid_reaped 'cilium port-forward'
  assert_forbidden_absent
  assert_temp_dir_empty
}

assert_rejected() {
  local name="$1"
  shift
  new_scenario "$name"
  set +e
  PATH="$fake_bin:$PATH" BASH_ENV="$fake_bash_env" \
    TMPDIR="$scenario_dir/tmp" FAKE_COMMAND_LOG="$command_log" \
    FAKE_PROCESS_LOG="$process_log" "$observer" "$@" >"$output" 2>&1
  run_status=$?
  set -e
  [[ "$run_status" -ne 0 ]]
  [[ ! -s "$command_log" ]]
}

if should_run tool-isolation; then
  new_scenario tool-isolation
  for client in kubectl flux helm talosctl talhelper kustomize; do
    set +e
    PATH="$fake_bin:/bin:/usr/bin" FAKE_COMMAND_LOG="$command_log" "$client" mutation-probe >/dev/null 2>&1
    run_status=$?
    set -e
    if [[ "$run_status" -ne 97 ]]; then
      echo "Controlled fake for $client returned $run_status instead of 97." >&2
      exit 1
    fi
    rg -q "^cluster-client ${client} mutation-probe$" "$command_log"
  done
fi

if should_run validation; then
  assert_rejected no-arguments
  assert_rejected one-argument "$kubeconfig"
  assert_rejected extra-argument "$kubeconfig" 5 extra
  assert_rejected zero-duration "$kubeconfig" 0
  assert_rejected too-long-duration "$kubeconfig" 601
  assert_rejected non-numeric-duration "$kubeconfig" nope
  assert_rejected missing-kubeconfig "$scenario_dir/does-not-exist" 5
fi

if should_run timeout; then
  new_scenario timeout
  coordinate_timeout &
  coordinator_pid=$!
  run_observer 7
  wait "$coordinator_pid"
  [[ "$run_status" -eq 0 ]]
  rg -q "^cilium command hubble port-forward --kubeconfig ${kubeconfig}$" "$command_log"
  rg -q '^hubble status --server localhost:4245$' "$command_log"
  rg -q '^hubble observe --server localhost:4245 --namespace media --pod plex --follow --output compact$' "$command_log"
  rg -q '^sleep 7$' "$command_log"
  rg -q 'media/plex:32400.*FORWARDED.*TCP' "$output"
  assert_same_lifecycle_pid timer start release
  assert_pid_reaped timer
  assert_same_lifecycle_pid 'hubble observe' start term exit
  assert_pid_reaped 'hubble observe'
  assert_common_cleanup
fi

if should_run diagnostic-context; then
  new_scenario diagnostic-context scoped
  coordinate_early_exit &
  coordinator_pid=$!
  run_observer 8 healthy success
  wait "$coordinator_pid"
  [[ "$run_status" -eq 0 ]]
  rg -q "^kubectl --kubeconfig ${kubeconfig} config get-contexts homelab-diagnostic --no-headers$" "$command_log"
  rg -q "^cilium command hubble port-forward --kubeconfig ${kubeconfig} --context homelab-diagnostic$" "$command_log"
  assert_same_lifecycle_pid timer start term exit
  assert_pid_reaped timer
  assert_same_lifecycle_pid 'hubble observe' start exit
  assert_pid_reaped 'hubble observe'
  assert_common_cleanup
fi

if should_run early-success; then
  new_scenario early-success
  coordinate_early_exit &
  coordinator_pid=$!
  run_observer 8 healthy success
  wait "$coordinator_pid"
  [[ "$run_status" -eq 0 ]]
  assert_same_lifecycle_pid timer start term exit
  assert_pid_reaped timer
  assert_same_lifecycle_pid 'hubble observe' start exit
  assert_pid_reaped 'hubble observe'
  assert_common_cleanup
fi

if should_run early-failure; then
  new_scenario early-failure
  coordinate_early_exit &
  coordinator_pid=$!
  run_observer 9 healthy failure
  wait "$coordinator_pid"
  if [[ "$run_status" -ne 23 ]]; then
    echo "Expected early Hubble failure status 23, got $run_status." >&2
    exit 1
  fi
  assert_same_lifecycle_pid timer start term exit
  assert_pid_reaped timer
  assert_same_lifecycle_pid 'hubble observe' start exit
  assert_pid_reaped 'hubble observe'
  assert_common_cleanup
fi

if should_run coincident-failure; then
  new_scenario coincident-failure
  coordinate_timeout &
  coordinator_pid=$!
  run_observer 10 healthy failure-on-term
  wait "$coordinator_pid"
  if [[ "$run_status" -ne 23 ]]; then
    echo "Expected coincident Hubble failure status 23, got $run_status." >&2
    exit 1
  fi
  assert_same_lifecycle_pid timer start release
  assert_pid_reaped timer
  assert_same_lifecycle_pid 'hubble observe' start term exit
  assert_pid_reaped 'hubble observe'
  assert_common_cleanup
fi

if should_run unavailable; then
  new_scenario unavailable
  coordinate_unavailable &
  coordinator_pid=$!
  run_observer 10 unavailable follow
  wait "$coordinator_pid"
  [[ "$run_status" -ne 0 ]]
  [[ "$(rg -c '^hubble status --server localhost:4245$' "$command_log")" -eq 15 ]]
  [[ "$(rg -c '^sleep 1$' "$command_log")" -eq 15 ]]
  if rg -q '^hubble observe ' "$command_log"; then
    echo 'Observer started before Hubble became ready.' >&2
    exit 1
  fi
  assert_common_cleanup
fi

run_signal_case() {
  local name="$1"
  local signal_name="$2"
  local expected_status="$3"
  new_scenario "$name"
  coordinate_signal "$signal_name" &
  coordinator_pid=$!
  run_observer 11 healthy follow
  wait "$coordinator_pid"
  if [[ "$run_status" -ne "$expected_status" ]]; then
    echo "Expected $signal_name observer status $expected_status, got $run_status." >&2
    exit 1
  fi
  assert_same_lifecycle_pid timer start term exit
  assert_pid_reaped timer
  assert_same_lifecycle_pid 'hubble observe' start term exit
  assert_pid_reaped 'hubble observe'
  assert_common_cleanup
}

if should_run term; then
  run_signal_case term TERM 143
fi

if should_run int; then
  run_signal_case int INT 130
fi

close_scenario_fds
echo 'Plex network observer tests passed.'
