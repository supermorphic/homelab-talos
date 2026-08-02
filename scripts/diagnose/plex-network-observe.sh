#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 2 ]] || {
  echo 'Usage: plex-network-observe.sh <kubeconfig> <duration-seconds>' >&2
  exit 2
}

kubeconfig="$1"
duration="$2"

[[ -f "$kubeconfig" ]] || {
  echo "Kubeconfig is not a file: $kubeconfig" >&2
  exit 2
}
[[ "$duration" =~ ^[0-9]+$ && "$duration" -ge 1 && "$duration" -le 600 ]] || {
  echo 'Duration must be an integer from 1 through 600 seconds.' >&2
  exit 2
}

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/plex-network-observe.XXXXXX")"
port_forward_pid=''
observe_pid=''
timer_pid=''
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  local pid
  for pid in "$timer_pid" "$observe_pid" "$port_forward_pid"; do
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf -- "$temp_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cilium hubble port-forward --kubeconfig "$kubeconfig" >/dev/null 2>&1 &
port_forward_pid=$!

hubble_ready='false'
for _ in {1..15}; do
  if hubble status --server localhost:4245 >/dev/null 2>&1; then
    hubble_ready='true'
    break
  fi
  sleep 1
done
[[ "$hubble_ready" == 'true' ]]

timeout_started="$temp_dir/observe-timeout-started"
timeout_signaled="$temp_dir/observe-timeout-signaled"
hubble observe \
  --server localhost:4245 \
  --namespace media \
  --pod plex \
  --follow \
  --output compact &
observe_pid=$!

(
  sleep "$duration"
  : >"$timeout_started"
  if kill -TERM "$observe_pid" 2>/dev/null; then
    : >"$timeout_signaled"
  fi
) &
timer_pid=$!

set +e
wait "$observe_pid"
observe_status=$?
set -e
observe_pid=''
if [[ -f "$timeout_started" ]]; then
  wait "$timer_pid" 2>/dev/null || true
else
  kill "$timer_pid" 2>/dev/null || true
  wait "$timer_pid" 2>/dev/null || true
fi
timer_pid=''

if [[ "$observe_status" == '0' ]]; then
  exit 0
fi
if [[ "$observe_status" == '143' && -f "$timeout_signaled" ]]; then
  exit 0
fi
exit "$observe_status"
