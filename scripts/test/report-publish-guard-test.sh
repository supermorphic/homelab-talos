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

# Explicit recorded acceptance supplies execution intent itself. It must get as
# far as canonical validation without needing the operator-only confirmation.
recorded_output="$fixture/recorded.log"
if TEST_RESULTS_ROOT="$fixture/results" \
  TEST_REPORT_PUBLICATION_CONTEXT=recorded-acceptance \
  "$repo_root/scripts/test/publish-report.sh" "$run_id" \
  >"$recorded_output" 2>&1; then
  echo 'Recorded acceptance accepted an incomplete canonical run.' >&2
  exit 1
fi
if rg -q 'Refusing to publish test evidence' "$recorded_output"; then
  echo 'Recorded acceptance still requires operator publication confirmation.' >&2
  exit 1
fi
rg -q 'Run root does not match the canonical six-entry structure' "$recorded_output"

if TEST_REPORT_PUBLICATION_CONTEXT=unknown \
  TEST_REPORT_PUBLISH_CONFIRM="publish:test-report:$run_id" \
  "$repo_root/scripts/test/publish-report.sh" "$run_id" \
  >"$fixture/unknown.log" 2>&1; then
  echo 'Publisher accepted an unknown publication context.' >&2
  exit 1
fi
rg -q 'Unknown report publication context' "$fixture/unknown.log"

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

# Publication selects only its dedicated context without changing the observer
# default. This synthetic kubeconfig never contacts a cluster.
cat >"$fixture/kubeconfig" <<'YAML'
apiVersion: v1
kind: Config
clusters:
  - name: homelab
    cluster: {server: 'https://192.0.2.1:6443'}
contexts:
  - name: homelab-observer
    context: {cluster: homelab, user: homelab-observer}
  - name: homelab-report-publisher
    context: {cluster: homelab, user: homelab-report-publisher}
users:
  - name: homelab-observer
    user: {token: synthetic-observer}
  - name: homelab-report-publisher
    user: {token: synthetic-publisher}
current-context: homelab-observer
YAML
source scripts/test/lib/report-publication.sh
select_report_publication_context "$fixture/kubeconfig" true
[[ "$report_publication_context" == homelab-report-publisher ]]
[[ "$(publication_kubectl --kubeconfig "$fixture/kubeconfig" config view --minify \
  --output 'jsonpath={.contexts[0].context.user}')" == homelab-report-publisher ]]
[[ "$(kubectl --kubeconfig "$fixture/kubeconfig" config current-context)" == homelab-observer ]]
yq -i '(.contexts[] | select(.name == "homelab-report-publisher") | .context.user) = "homelab-observer"' "$fixture/kubeconfig"
if select_report_publication_context "$fixture/kubeconfig" true >"$fixture/mapping.log" 2>&1; then
  echo 'Publication accepted a context mapped to a different identity.' >&2
  exit 1
fi
rg -q 'must use the homelab-report-publisher identity' "$fixture/mapping.log"
yq -i 'del(.contexts[] | select(.name == "homelab-report-publisher"))' "$fixture/kubeconfig"
if select_report_publication_context "$fixture/kubeconfig" true >"$fixture/access.log" 2>&1; then
  echo 'Publication fell back to observer when the publisher context was absent.' >&2
  exit 1
fi
rg -q 'homelab-report-publisher' "$fixture/access.log"
yq -i '
  .contexts = [{"name": "fixture-operator", "context": {"cluster": "homelab", "user": "fixture-operator"}}] |
  .users = [{"name": "fixture-operator", "user": {"token": "synthetic-operator"}}] |
  ."current-context" = "fixture-operator"
' "$fixture/kubeconfig"
select_report_publication_context "$fixture/kubeconfig" false
[[ "$report_publication_context" == fixture-operator ]]
if select_report_publication_context "$fixture/kubeconfig" true >"$fixture/linked.log" 2>&1; then
  echo 'A linked worktree accepted an operator context as a publication fallback.' >&2
  exit 1
fi

echo 'Test-report intent, secret scan, and publication identity guards passed.'
