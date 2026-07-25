#!/usr/bin/env bash
set -euo pipefail

source scripts/test/lib/results.sh

result_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-chainsaw-results-test.XXXXXX")"
cleanup() {
  rm -f "$result_dir/environment.json" "$result_dir/summary.json"
  rmdir "$result_dir"
}
trap cleanup EXIT

export CLUSTER_CHAOS_CONFIRM='chaos:must-not-appear'

write_environment "$result_dir" \
  '2026-07-24T00:00:00Z' \
  '2026-07-24T00:00:01Z' \
  smoke \
  cluster \
  '' \
  flux-system \
  unavailable \
  CLUSTER_CHAOS_CONFIRM

yq -e '
  .test.tier == "smoke" and
  .test.target == "cluster" and
  (.test | has("scenario") | not)
' "$result_dir/environment.json" >/dev/null

write_environment "$result_dir" \
  '2026-07-24T00:00:00Z' \
  '2026-07-24T00:00:01Z' \
  smoke \
  cluster \
  diagnostics-self-test \
  flux-system \
  unavailable \
  CLUSTER_CHAOS_CONFIRM

write_summary "$result_dir" failed 7 not-classified passed not-required not-required

yq -e '
  .schemaVersion == 1 and
  .test.tier == "smoke" and
  .test.target == "cluster" and
  .test.scenario == "diagnostics-self-test" and
  .confirmationTokenType == "CLUSTER_CHAOS_CONFIRM" and
  .cluster.namespace == "flux-system"
' "$result_dir/environment.json" >/dev/null

yq -e '
  .schemaVersion == 1 and
  .primary.status == "failed" and
  .primary.exitCode == 7 and
  .diagnostics.status == "passed"
' "$result_dir/summary.json" >/dev/null

if rg --fixed-strings --quiet 'must-not-appear' "$result_dir"; then
  echo 'Result artifacts exposed the confirmation token value.' >&2
  exit 1
fi

# resilience_recovery_status: missing recovery.json must not read as a pass.
[[ "$(resilience_recovery_status "$result_dir")" == 'not-classified' ]] || {
  echo 'Missing recovery.json should classify as not-classified.' >&2
  exit 1
}
# A recorded failed recovery is surfaced verbatim.
printf '{"status":"failed","reason":"self-test"}\n' >"$result_dir/recovery.json"
[[ "$(resilience_recovery_status "$result_dir")" == 'failed' ]] || {
  echo 'recovery.json status=failed should be read as failed.' >&2
  exit 1
}

# The separation invariant (forced cleanup-failure, item 4b): a failed recovery is
# recorded in summary.json WITHOUT flipping a passing primary assertion.
recovery_status="$(resilience_recovery_status "$result_dir")"
write_summary "$result_dir" passed 0 passed passed "$recovery_status" "$recovery_status"
yq -e '
  .primary.status == "passed" and
  .assertion.status == "passed" and
  .recovery.status == "failed" and
  .cleanup.status == "failed"
' "$result_dir/summary.json" >/dev/null || {
  echo 'A failed recovery must be recorded separately without masking a passing primary.' >&2
  exit 1
}
rm -f "$result_dir/recovery.json"
