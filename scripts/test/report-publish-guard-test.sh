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

source scripts/test/lib/report-publication.sh
confirmation_output="$fixture/confirmation.log"
if TEST_RESULTS_ROOT="$fixture/results" \
  TEST_REPORT_PUBLISH_CONFIRM="publish:test-report:$run_id" \
  "$repo_root/scripts/test/publish-report.sh" "$run_id" \
  >"$confirmation_output" 2>&1; then
  echo 'Publisher accepted an incomplete canonical run.' >&2
  exit 1
fi
rg -q 'Run root does not match the canonical six-entry structure' "$confirmation_output"

# The public publisher must derive scoped intent from its worktree, not an
# environment variable that a caller can set. Outside a linked worktree the
# exact run confirmation remains required.
if TEST_REPORT_PUBLICATION_CONTEXT=recorded-acceptance \
  require_report_publication_confirmation false "$run_id" \
  >"$fixture/manual-missing.log" 2>&1; then
  echo 'Operator publication accepted a forged scoped context.' >&2
  exit 1
fi
rg -q 'Refusing to publish test evidence' "$fixture/manual-missing.log"
if TEST_REPORT_PUBLISH_CONFIRM=wrong \
  require_report_publication_confirmation false "$run_id" \
  >"$fixture/manual-wrong.log" 2>&1; then
  echo 'Operator publication accepted a wrong confirmation.' >&2
  exit 1
fi
TEST_REPORT_PUBLISH_CONFIRM="publish:test-report:$run_id" \
  require_report_publication_confirmation false "$run_id"
require_report_publication_confirmation true "$run_id"

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

(
  export TEST_LEASE_NAMESPACE=flux-system
  export TEST_LEASE_NAME=homelab-test-report-publish-lock
  source scripts/lib/lease.sh

  publication_lease="$fixture/publication-lease.json"
  disruption_lease="$fixture/disruption-lease.json"
  now="$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)"
  NOW="$now" yq --null-input --output-format json '{
    "apiVersion": "coordination.k8s.io/v1",
    "kind": "Lease",
    "metadata": {
      "namespace": "flux-system",
      "name": "homelab-test-run-lock",
      "resourceVersion": "11"
    },
    "spec": {
      "holderIdentity": "node:maintenance:node-a:run-42",
      "leaseDurationSeconds": 90,
      "acquireTime": strenv(NOW),
      "renewTime": strenv(NOW)
    }
  }' >"$disruption_lease"
  cp "$disruption_lease" "$fixture/disruption-lease-before.json"

  lease_kubectl() {
    local _kubeconfig="$1"
    shift
    local operation='' lease_name='' input existing_version input_version
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        get)
          operation='get'
          lease_name="$3"
          break
          ;;
        create|replace)
          operation="$1"
          break
          ;;
        *) shift ;;
      esac
    done
    case "$operation" in
      get)
        [[ "$lease_name" == homelab-test-report-publish-lock ]] || return 64
        [[ -f "$publication_lease" ]] || return 1
        cat "$publication_lease"
        ;;
      create)
        input="$(cat)"
        [[ "$(yq -r '.metadata.name' - <<<"$input")" == \
          homelab-test-report-publish-lock ]] || return 64
        yq --output-format json '.metadata.resourceVersion = "1"' \
          <<<"$input" >"$publication_lease"
        ;;
      replace)
        input="$(cat)"
        existing_version="$(yq -r '.metadata.resourceVersion' "$publication_lease")"
        input_version="$(yq -r '.metadata.resourceVersion' - <<<"$input")"
        [[ "$input_version" == "$existing_version" ]] || return 1
        NEXT_VERSION="$((existing_version + 1))" \
          yq --output-format json \
            '.metadata.resourceVersion = strenv(NEXT_VERSION)' \
            <<<"$input" >"$publication_lease"
        ;;
      *) return 64 ;;
    esac
  }

  acquire_test_lease fixture-kubeconfig publish:fixture
  release_test_lease fixture-kubeconfig publish:fixture
  [[ "$(yq -r '.metadata.name' "$publication_lease")" == \
    homelab-test-report-publish-lock ]]
  [[ "$(yq -r '.spec.holderIdentity // ""' "$publication_lease")" == '' ]]
  cmp "$fixture/disruption-lease-before.json" "$disruption_lease"
)

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
