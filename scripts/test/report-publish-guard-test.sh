#!/usr/bin/env bash
set -euo pipefail

source scripts/test/lib/results.sh

repo_root="$(git rev-parse --show-toplevel)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/homelab-report-publish-guard.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
sha="$(git rev-parse HEAD)"
run_id="20260727T120000Z-${sha:0:12}-operator-deadbeef"
run_dir="$fixture/results/$run_id"
mkdir -p "$run_dir/logs" "$run_dir/diagnostics"

confirmation_output="$fixture/confirmation.log"
if TEST_RESULTS_ROOT="$fixture/results" \
  "$repo_root/scripts/test/publish-report.sh" "$run_id" \
  >"$confirmation_output" 2>&1; then
  echo 'Publisher accepted a missing run-scoped confirmation.' >&2
  exit 1
fi
rg -q 'Refusing to publish test evidence' "$confirmation_output"

write_result_case_junit \
  "$run_dir/junit.xml" validation.fixture fixture passed 1
RUN_ID="$run_id" SHA="$sha" yq --null-input --output-format json '{
    "schema_version": 1,
    "run_id": strenv(RUN_ID),
    "source": "validation",
    "framework": "bash",
    "suite": "fixture",
    "tier": "offline",
    "target": "fixture",
    "scenario": "source",
    "scope": "repository",
    "intent": "regression",
    "git_sha": strenv(SHA),
    "execution_origin": "operator",
    "start": "2026-07-27T12:00:00Z",
    "end": "2026-07-27T12:00:01Z",
    "duration_seconds": 1,
    "result": "passed",
    "junit": {"tests": 1, "failures": 0, "errors": 0, "skipped": 0, "passed": 1},
    "suites": [{
      "id": "validation.fixture",
      "result": "passed",
      "tests": 1,
      "failures": 0,
      "errors": 0,
      "skipped": 0
    }],
    "phases": {}
  }' >"$run_dir/summary.json"
RUN_ID="$run_id" SHA="$sha" yq --null-input --output-format json '{
    "schema_version": 1,
    "run_id": strenv(RUN_ID),
    "execution_origin": "operator",
    "start": "2026-07-27T12:00:00Z",
    "end": "2026-07-27T12:00:01Z",
    "git": {"sha": strenv(SHA), "branch": "fixture", "dirty": false},
    "host": {"os": "fixture", "architecture": "fixture"},
    "tools": {},
    "cluster": {},
    "suite": {
      "id": "validation.fixture",
      "source": "validation",
      "framework": "bash",
      "suite": "fixture",
      "tier": "offline",
      "target": "fixture",
      "scenario": "source",
      "scope": "repository",
      "intent": "regression"
    },
    "confirmation_variable": null
  }' >"$run_dir/environment.json"
first='A1b2C3d4E5f6G7h8I9j0'
second='K1l2M3n4O5p6Q7r8'
printf 'api_%s = "%s%s"\n' key "$first" "$second" >"$run_dir/logs/evidence.log"
RUN_ID="$run_id" yq --null-input --output-format json '{
    "schema_version": 1,
    "run_id": strenv(RUN_ID),
    "artifacts": [{"path": "logs/evidence.log"}]
  }' >"$run_dir/evidence.json"

output="$fixture/output.log"
if TEST_RESULTS_ROOT="$fixture/results" \
  KUBECONFIG="$fixture/does-not-exist" \
  TEST_REPORT_PUBLISH_CONFIRM="publish:test-report:$run_id" \
  "$repo_root/scripts/test/publish-report.sh" "$run_id" >"$output" 2>&1; then
  echo 'Publisher accepted canonical evidence containing a secret.' >&2
  exit 1
fi
rg -q 'leaks found: 1' "$output" || {
  echo 'Publisher did not fail at its canonical-evidence secret scan.' >&2
  sed -n '1,120p' "$output" >&2
  exit 1
}
if rg -q 'Missing .*kube/config|does-not-exist' "$output"; then
  echo 'Publisher reached kubeconfig validation before rejecting secret evidence.' >&2
  exit 1
fi

echo 'Test-report confirmation and secret-scan guard passed.'
