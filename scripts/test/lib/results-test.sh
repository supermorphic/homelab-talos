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
  resilience \
  fixture \
  flux-system \
  unavailable \
  CLUSTER_CHAOS_CONFIRM

write_summary "$result_dir" failed 7 not-classified passed not-required not-required

yq -e '
  .schemaVersion == 1 and
  .test.tier == "resilience" and
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
