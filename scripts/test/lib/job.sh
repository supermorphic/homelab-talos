#!/usr/bin/env bash

# Wait for a Kubernetes Job to reach either terminal condition. A failed Job is
# reported immediately with bounded logs instead of consuming the success timeout.
wait_for_job_terminal() {
  local job_name="$1" timeout_seconds="$2" poll_seconds="$3"
  shift 3
  local -a kubectl_command=("$@")
  local deadline job_json failed_row failed_reason failed_message complete_count

  [[ "$timeout_seconds" =~ ^[0-9]+$ && "$poll_seconds" =~ ^[0-9]+$ && \
    "${#kubectl_command[@]}" -gt 0 ]] || {
    echo "Invalid terminal Job wait arguments for $job_name." >&2
    return 2
  }
  deadline=$((SECONDS + timeout_seconds))

  while true; do
    job_json="$("${kubectl_command[@]}" get job "$job_name" --output json)" || {
      echo "Unable to read Job $job_name while waiting for a terminal condition." >&2
      return 2
    }
    failed_row="$(yq -p=json -r '.status.conditions[]? |
      select(.type == "Failed" and .status == "True") |
      [(.reason // "Unknown"), (.message // "No failure message")] | @tsv' - \
      <<<"$job_json")"
    if [[ -n "$failed_row" ]]; then
      IFS=$'\t' read -r failed_reason failed_message <<<"$failed_row"
      echo "Job $job_name failed: $failed_reason: $failed_message" >&2
      "${kubectl_command[@]}" logs "job/$job_name" --tail=80 >&2 ||
        echo "Bounded logs for failed Job $job_name were unavailable." >&2
      return 1
    fi
    complete_count="$(yq -p=json -r '[.status.conditions[]? |
      select(.type == "Complete" and .status == "True")] | length' - \
      <<<"$job_json")"
    [[ "$complete_count" == '0' ]] || return 0
    if ((SECONDS >= deadline)); then
      echo "Job $job_name did not reach a terminal condition within $timeout_seconds seconds." >&2
      return 124
    fi
    sleep "$poll_seconds"
  done
}
