#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/test/lib/job.sh
source scripts/test/lib/job.sh

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/n8n-job-wait-test.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

complete_kubectl() {
  case "$1" in
    get)
      printf '%s\n' '{"status":{"conditions":[{"type":"Complete","status":"True"}]}}'
      ;;
    logs)
      printf '%s\n' 'logs must not be requested for a successful Job' >&2
      return 1
      ;;
    *) return 2 ;;
  esac
}

failed_kubectl() {
  case "$1" in
    get)
      printf '%s\n' '{"status":{"conditions":[{"type":"FailureTarget","status":"True","reason":"BackoffLimitExceeded","message":"Job reached its backoff limit"},{"type":"Failed","status":"True","reason":"BackoffLimitExceeded","message":"Job reached its backoff limit"}]}}'
      ;;
    logs)
      printf '%s\n' 'restore_stage=dump-restore'
      ;;
    *) return 2 ;;
  esac
}

running_kubectl() {
  case "$1" in
    get) printf '%s\n' '{"status":{"active":1,"conditions":[]}}' ;;
    logs) return 1 ;;
    *) return 2 ;;
  esac
}

wait_for_job_terminal fixture-complete 30 0 complete_kubectl

failed_status=0
wait_for_job_terminal fixture-failed 30 0 failed_kubectl \
  >"$temp_dir/failed.stdout" 2>"$temp_dir/failed.stderr" || failed_status="$?"
[[ "$failed_status" -eq 1 ]] || {
  echo "Failed Job returned status $failed_status instead of 1." >&2
  exit 1
}
rg -Fq 'Job fixture-failed failed: BackoffLimitExceeded: Job reached its backoff limit' \
  "$temp_dir/failed.stderr"
rg -Fq 'restore_stage=dump-restore' "$temp_dir/failed.stderr"

timeout_status=0
wait_for_job_terminal fixture-running 0 0 running_kubectl \
  >"$temp_dir/timeout.stdout" 2>"$temp_dir/timeout.stderr" || timeout_status="$?"
[[ "$timeout_status" -eq 124 ]] || {
  echo "Timed-out Job returned status $timeout_status instead of 124." >&2
  exit 1
}
rg -Fq 'Job fixture-running did not reach a terminal condition within 0 seconds.' \
  "$temp_dir/timeout.stderr"

echo 'n8n assurance Job terminal-state fixtures passed.'
