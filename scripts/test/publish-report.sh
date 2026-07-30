#!/usr/bin/env bash
# Guarded operator publisher. Structured archive state belongs to Python; this
# shell owns the confirmation, deployed-source guard, Lease, and kubectl stream.
set -euo pipefail

source scripts/lib/common.sh
require_bash

[[ "$#" -eq 1 ]] || {
  echo 'Usage: publish-report.sh <canonical-run-id>' >&2
  exit 2
}

run_id="$1"
[[ "$run_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}-(agent|github-actions|operator)-[0-9a-f]{8}$ ]] || {
  echo "Invalid canonical run ID: $run_id" >&2
  exit 2
}
expected_confirmation="publish:test-report:$run_id"
[[ "${TEST_REPORT_PUBLISH_CONFIRM:-}" == "$expected_confirmation" ]] || {
  echo 'Refusing to publish test evidence.' >&2
  echo "Set TEST_REPORT_PUBLISH_CONFIRM='$expected_confirmation' after reviewing the run." >&2
  exit 1
}

repo_root="$(git rev-parse --show-toplevel)"
results_root="${TEST_RESULTS_ROOT:-$repo_root/.test-results}"
reports_root="${TEST_REPORTS_ROOT:-$repo_root/.test-reports}"
[[ "$results_root" == /* ]] || results_root="$repo_root/$results_root"
[[ "$reports_root" == /* ]] || reports_root="$repo_root/$reports_root"
run_dir="$results_root/$run_id"
report_dir="$reports_root/$run_id"
kubeconfig="${KUBECONFIG:-$repo_root/.kube/config}"
report_url="https://tests.lab.supermorphic.com/reports/$run_id/awesome/"

write_publish_result() {
  local status="$1"
  local output="${TEST_PUBLISH_RESULT_FILE:-}"
  local output_dir temporary

  [[ -n "$output" ]] || return 0
  [[ "$output" == /* ]] || {
    echo 'TEST_PUBLISH_RESULT_FILE must be an absolute path.' >&2
    return 2
  }
  output_dir="$(dirname "$output")"
  [[ -d "$output_dir" ]] || {
    echo "TEST_PUBLISH_RESULT_FILE parent directory does not exist: $output_dir" >&2
    return 2
  }
  temporary="${output}.tmp.$$"
  RUN_ID="$run_id" STATUS="$status" REPORT_URL="$report_url" \
    yq --null-input --output-format json '{
      "schema_version": 1,
      "run_id": strenv(RUN_ID),
      "status": strenv(STATUS),
      "url": strenv(REPORT_URL)
    }' >"$temporary"
  mv "$temporary" "$output"
}

scripts/test/validate-run.sh "$run_dir"
[[ "$(yq -r '.git.dirty' "$run_dir/environment.json")" == 'false' ]] || {
  echo 'Refusing to publish a run captured from a dirty checkout.' >&2
  exit 1
}
run_sha="$(yq -r '.git.sha' "$run_dir/environment.json")"
[[ "$run_sha" =~ ^[0-9a-f]{40}$ ]] || {
  echo 'Canonical environment does not contain a full lowercase Git SHA.' >&2
  exit 1
}
git cat-file -e "${run_sha}^{commit}" 2>/dev/null || {
  echo "Canonical run commit is not available locally: $run_sha" >&2
  exit 1
}

echo 'Scanning canonical test evidence for secrets.'
gitleaks dir --redact --no-banner --max-archive-depth 1 "$run_dir"

[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run just talos kubeconfig." >&2
  exit 1
}

source scripts/lib/rollout.sh
require_deployed_source 'test report publication' \
  tests/mod.just \
  tests/config/allurerc.yaml \
  scripts/test/allure_report.py \
  scripts/test/generate-allure-report.sh \
  scripts/test/lib/lease.sh \
  scripts/test/publish-report.sh \
  scripts/test/report_publish.py \
  scripts/test/validate-run.sh \
  kubernetes/apps/monitoring/test-reports

workspace="$(mktemp -d "${TMPDIR:-/tmp}/homelab-report-publish.XXXXXX")"
lease_acquired=false
lease_failure="$workspace/lease-renewal-failed"
cleanup() {
  stop_test_lease_renewal 2>/dev/null || true
  if [[ "$lease_acquired" == 'true' ]]; then
    release_test_lease "$kubeconfig" "publish:$run_id" >/dev/null 2>&1 || {
      echo 'Warning: could not release the test-report publication Lease.' >&2
    }
  fi
  rm -rf -- "$workspace"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

export TEST_LEASE_NAMESPACE='flux-system'
export TEST_LEASE_NAME='homelab-test-report-publish-lock'
source scripts/test/lib/lease.sh
acquire_test_lease "$kubeconfig" "publish:$run_id"
lease_acquired=true
start_test_lease_renewal "$kubeconfig" "publish:$run_id" "$lease_failure"

kubectl --kubeconfig "$kubeconfig" --namespace test-reports \
  rollout status deployment/test-reports --timeout=3m
for document in catalog.json state.json history.jsonl; do
  kubectl --kubeconfig "$kubeconfig" --namespace test-reports \
    exec deployment/test-reports -c caddy -- \
    cat "/srv/state/current/$document" >"$workspace/$document"
done

read_deployed_revisions() {
  local remote_ref flux_revision
  remote_ref="$(git ls-remote --exit-code origin refs/heads/main)"
  read -r origin_main_sha _ <<<"$remote_ref"
  [[ "$origin_main_sha" =~ ^[0-9a-f]{40}$ ]]
  flux_revision="$(
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
      get gitrepository flux-system \
      --output jsonpath='{.status.artifact.revision}'
  )"
  flux_main_sha="${flux_revision##*:}"
  [[ "$flux_main_sha" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Flux artifact revision does not end in a full Git SHA: $flux_revision" >&2
    return 1
  }
}

require_authoritative_revisions() {
  [[ "$origin_main_sha" == "$run_sha" && "$flux_main_sha" == "$run_sha" ]] || {
    echo "Refusing campaign publication: run=$run_sha origin/main=$origin_main_sha Flux=$flux_main_sha." >&2
    return 1
  }
}

read_deployed_revisions
if [[ "${TEST_REPORT_REQUIRE_AUTHORITATIVE:-false}" == 'true' ]]; then
  require_authoritative_revisions
fi

ALLURE_HISTORY_PATH="$workspace/history.jsonl" \
  scripts/test/generate-allure-report.sh "$run_id"
[[ ! -e "$lease_failure" ]] || {
  echo 'Publication Lease renewal failed while generating Allure.' >&2
  exit 1
}

bundle="$workspace/bundle"
archive="$workspace/bundle.tar"
prepare_result="$(
  uv run --locked --no-dev python scripts/test/report_publish.py \
    --run-dir "$run_dir" \
    --report-dir "$report_dir" \
    --remote-catalog "$workspace/catalog.json" \
    --remote-state "$workspace/state.json" \
    --history "$workspace/history.jsonl" \
    --origin-main-sha "$origin_main_sha" \
    --flux-main-sha "$flux_main_sha" \
    --output-dir "$bundle" \
    --archive "$archive" \
    --now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
)"
if [[ "$(yq -r '.status' - <<<"$prepare_result")" == 'idempotent' ]]; then
  echo "Report is already published with identical canonical content: $run_id"
  release_test_lease "$kubeconfig" "publish:$run_id"
  lease_acquired=false
  write_publish_result idempotent
  exit 0
fi
generation="$(yq -r '.generation' - <<<"$prepare_result")"
[[ "$generation" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]]

echo 'Scanning the exact publication bundle for secrets.'
gitleaks dir --redact --no-banner --max-archive-depth 1 "$bundle"
[[ ! -e "$lease_failure" ]] || {
  echo 'Publication Lease renewal failed before the cluster stream.' >&2
  exit 1
}
if [[ "${TEST_REPORT_REQUIRE_AUTHORITATIVE:-false}" == 'true' ]]; then
  read_deployed_revisions
  require_authoritative_revisions
fi

kubectl --kubeconfig "$kubeconfig" --namespace test-reports \
  exec -i deployment/test-reports -c caddy -- \
  /bin/sh /opt/test-reports/install-report.sh "$run_id" "$generation" \
  <"$archive"
[[ ! -e "$lease_failure" ]] || {
  echo 'Publication Lease renewal failed during the cluster stream.' >&2
  exit 1
}

remote_digest="$(
  kubectl --kubeconfig "$kubeconfig" --namespace test-reports \
    exec deployment/test-reports -c caddy -- \
    sha256sum "/srv/artifacts/$run_id.tar.gz" |
    awk '{print $1}'
)"
local_digest="$(sha256sum "$bundle/artifact/$run_id.tar.gz" | awk '{print $1}')"
[[ "$remote_digest" == "$local_digest" ]] || {
  echo 'Published canonical artifact checksum does not match the local bundle.' >&2
  exit 1
}

release_test_lease "$kubeconfig" "publish:$run_id"
lease_acquired=false
write_publish_result published
echo "Published $run_id at $report_url"
