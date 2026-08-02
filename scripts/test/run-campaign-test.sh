#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/homelab-campaign-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
catalog="$fixture/catalog.yaml"
cp tests/catalog.yaml "$catalog"
yq -i '
  .campaigns.fixture = {
    "description": "Campaign runner fixture",
    "mutates_cluster": false,
    "disruptive": false,
    "members": [
      "verification.metrics-server",
      "verification.cilium"
    ]
  } |
  (.suites[] | select(.metadata.id == "verification.metrics-server") |
    .runner.command) = "mise exec -- just fixture pass" |
  (.suites[] | select(.metadata.id == "verification.cilium") |
    .runner.command) = "mise exec -- just fixture fail" |
  .campaigns."scoped-verification".members = [
    "verification.metrics-server",
    "verification.cilium"
  ]
' "$catalog"
mkdir -p "$fixture/bin"
ln -s "$repo_root/tests/fixtures/campaign/fake-mise.sh" "$fixture/bin/mise"
touch "$fixture/kubeconfig"

plan_output="$fixture/plan.log"
CAMPAIGN_TEST_SOURCE_STATE="$fixture/plan-source-state" \
TEST_CATALOG_PATH="$catalog" \
TEST_CAMPAIGN_TEST_MODE=true \
TEST_CAMPAIGN_SOURCE_CHECK_BIN="$repo_root/tests/fixtures/campaign/source-check.sh" \
TEST_CAMPAIGN_PUBLISH_BIN="$repo_root/tests/fixtures/campaign/fake-publisher.sh" \
TEST_RESULTS_ROOT="$fixture/plan-results" \
TEST_CAMPAIGNS_ROOT="$fixture/plan-campaigns" \
KUBECONFIG="$fixture/kubeconfig" \
  "$repo_root/scripts/test/run-campaign.sh" plan fixture >"$plan_output"
rg -q '^ 1\. verification.metrics-server$' "$plan_output"
rg -q "^TEST_CAMPAIGN_CONFIRM='run-publish:fixture'" "$plan_output"

run_fixture_campaign() {
  local root="$1"
  shift
  mkdir -p "$root"
  touch "$root/commands" "$root/publishes"
  PATH="$fixture/bin:$PATH" \
  CAMPAIGN_TEST_REPO_ROOT="$repo_root" \
  CAMPAIGN_TEST_COMMAND_CALLS="$root/commands" \
  CAMPAIGN_TEST_PUBLISH_CALLS="$root/publishes" \
  CAMPAIGN_TEST_SOURCE_STATE="$root/source-state" \
  TEST_CATALOG_PATH="$catalog" \
  TEST_RESULTS_ROOT="$root/results" \
  TEST_CAMPAIGNS_ROOT="$root/campaigns" \
  TEST_CAMPAIGN_TEST_MODE=true \
  TEST_CAMPAIGN_SKIP_LEASE=true \
  TEST_CAMPAIGN_SOURCE_CHECK_BIN="$repo_root/tests/fixtures/campaign/source-check.sh" \
  TEST_CAMPAIGN_PUBLISH_BIN="$repo_root/tests/fixtures/campaign/fake-publisher.sh" \
  TEST_CAMPAIGN_PUBLISH_ATTEMPTS=1 \
  TEST_CAMPAIGN_RETRY_DELAY_SECONDS=0 \
  TEST_EXECUTION_ORIGIN=agent \
  KUBECONFIG="$fixture/kubeconfig" \
  TEST_CAMPAIGN_CONFIRM=run-publish:fixture \
    "$@" "$repo_root/scripts/test/run-campaign.sh" run fixture
}

complete_root="$fixture/complete"
set +e
run_fixture_campaign "$complete_root" env >"$fixture/complete.log" 2>&1
complete_exit="$?"
set -e
[[ "$complete_exit" -eq 1 ]]
complete_manifest="$(find "$complete_root/campaigns" -name campaign.json -print)"
[[ "$(yq -r '.status' "$complete_manifest")" == 'completed' ]] || {
  sed -n '1,240p' "$fixture/complete.log" >&2
  exit 1
}
[[ "$(yq -r '.result' "$complete_manifest")" == 'failed' ]]
[[ "$(yq -r '.runs | length' "$complete_manifest")" == '2' ]]
[[ "$(yq -r '[.runs[].publish_status] | unique | join(",")' \
  "$complete_manifest")" == 'published' ]]
[[ "$(cat "$complete_root/commands")" == $'pass\nfail' ]]
[[ "$(wc -l <"$complete_root/publishes" | tr -d ' ')" == '2' ]]

resume_root="$fixture/resume"
mkdir -p "$resume_root"
touch "$resume_root/publish-failure"
set +e
CAMPAIGN_TEST_PUBLISH_FAILURE_MARKER="$resume_root/publish-failure" \
  run_fixture_campaign "$resume_root" env >"$fixture/resume-start.log" 2>&1
initial_resume_exit="$?"
set -e
[[ "$initial_resume_exit" -eq 2 ]]
resume_manifest="$(find "$resume_root/campaigns" -name campaign.json -print)"
resume_id="$(yq -r '.campaign_id' "$resume_manifest")"
[[ "$(yq -r '.status' "$resume_manifest")" == 'publish-failed' ]]
[[ "$(cat "$resume_root/commands")" == 'pass' ]]
rm "$resume_root/publish-failure"
set +e
PATH="$fixture/bin:$PATH" \
CAMPAIGN_TEST_REPO_ROOT="$repo_root" \
CAMPAIGN_TEST_COMMAND_CALLS="$resume_root/commands" \
CAMPAIGN_TEST_PUBLISH_CALLS="$resume_root/publishes" \
CAMPAIGN_TEST_SOURCE_STATE="$resume_root/source-state" \
TEST_CATALOG_PATH="$catalog" \
TEST_RESULTS_ROOT="$resume_root/results" \
TEST_CAMPAIGNS_ROOT="$resume_root/campaigns" \
TEST_CAMPAIGN_TEST_MODE=true \
TEST_CAMPAIGN_SKIP_LEASE=true \
TEST_CAMPAIGN_SOURCE_CHECK_BIN="$repo_root/tests/fixtures/campaign/source-check.sh" \
TEST_CAMPAIGN_PUBLISH_BIN="$repo_root/tests/fixtures/campaign/fake-publisher.sh" \
TEST_CAMPAIGN_PUBLISH_ATTEMPTS=1 \
TEST_CAMPAIGN_RETRY_DELAY_SECONDS=0 \
TEST_EXECUTION_ORIGIN=agent \
KUBECONFIG="$fixture/kubeconfig" \
TEST_CAMPAIGN_CONFIRM="resume-publish:$resume_id" \
  "$repo_root/scripts/test/run-campaign.sh" resume "$resume_id" \
  >"$fixture/resume-finish.log" 2>&1
resume_exit="$?"
set -e
[[ "$resume_exit" -eq 1 ]]
[[ "$(yq -r '.status' "$resume_manifest")" == 'completed' ]] || {
  sed -n '1,240p' "$fixture/resume-finish.log" >&2
  exit 1
}
[[ "$(yq -r '.runs | length' "$resume_manifest")" == '2' ]]
[[ "$(cat "$resume_root/commands")" == $'pass\nfail' ]]

drift_root="$fixture/drift"
set +e
CAMPAIGN_TEST_DRIFT_AT=3 \
  run_fixture_campaign "$drift_root" env >"$fixture/drift.log" 2>&1
drift_exit="$?"
set -e
[[ "$drift_exit" -eq 2 ]]
drift_manifest="$(find "$drift_root/campaigns" -name campaign.json -print)"
[[ "$(yq -r '.status' "$drift_manifest")" == 'stopped' ]]
[[ "$(yq -r '.stop_reason' "$drift_manifest")" == 'source-drift-after-suite' ]]
[[ "$(yq -r '.runs[0].publish_status' "$drift_manifest")" == \
  'not-published-source-drift' ]]
[[ ! -s "$drift_root/publishes" ]]

scoped_root="$fixture/scoped"
mkdir -p "$scoped_root"
touch "$scoped_root/publishes" "$scoped_root/lease-calls" "$scoped_root/source-calls"
yq -i '
  (.suites[] | select(.metadata.id == "verification.metrics-server") |
    .runner.command) = "mise exec -- just fixture scoped-pass" |
  (.suites[] | select(.metadata.id == "verification.cilium") |
    .runner.command) = "mise exec -- just fixture scoped-fail"
' "$catalog"
scoped_plan="$scoped_root/plan.log"
PATH="$fixture/bin:$PATH" \
CAMPAIGN_TEST_REPO_ROOT="$repo_root" \
CAMPAIGN_TEST_COMMAND_CALLS="$scoped_root/commands" \
CAMPAIGN_TEST_PUBLISH_CALLS="$scoped_root/publishes" \
TEST_CATALOG_PATH="$catalog" \
TEST_RESULTS_ROOT="$scoped_root/results" \
TEST_CAMPAIGNS_ROOT="$scoped_root/campaigns" \
TEST_CAMPAIGN_TEST_MODE=true \
TEST_CAMPAIGN_PUBLISH_BIN="$repo_root/tests/fixtures/campaign/fake-publisher.sh" \
TEST_EXECUTION_ORIGIN=agent \
KUBECONFIG="$fixture/kubeconfig" \
  "$repo_root/scripts/test/run-campaign.sh" scoped-plan scoped-verification \
  >"$scoped_plan"
rg -q "TEST_SCOPED_CAMPAIGN_CONFIRM='run-local:scoped-verification'" "$scoped_plan"
rg -q '^Mode: scoped local-only$' "$scoped_plan"

set +e
PATH="$fixture/bin:$PATH" \
CAMPAIGN_TEST_REPO_ROOT="$repo_root" \
CAMPAIGN_TEST_COMMAND_CALLS="$scoped_root/commands" \
CAMPAIGN_TEST_PUBLISH_CALLS="$scoped_root/publishes" \
TEST_CATALOG_PATH="$catalog" \
TEST_RESULTS_ROOT="$scoped_root/results" \
TEST_CAMPAIGNS_ROOT="$scoped_root/campaigns" \
TEST_CAMPAIGN_TEST_MODE=true \
TEST_CAMPAIGN_PUBLISH_BIN="$repo_root/tests/fixtures/campaign/fake-publisher.sh" \
TEST_LEASE_KUBECTL="$repo_root/tests/fixtures/campaign/forbidden-kubectl.sh" \
FORBIDDEN_KUBECTL_CALLS="$scoped_root/lease-calls" \
TEST_CAMPAIGN_SOURCE_CHECK_BIN="$repo_root/tests/fixtures/campaign/forbidden-source-check.sh" \
FORBIDDEN_SOURCE_CALLS="$scoped_root/source-calls" \
TEST_EXECUTION_ORIGIN=agent \
KUBECONFIG="$fixture/kubeconfig" \
TEST_SCOPED_CAMPAIGN_CONFIRM=run-local:scoped-verification \
  "$repo_root/scripts/test/run-campaign.sh" scoped-run scoped-verification \
  >"$scoped_root/run.log" 2>&1
scoped_exit="$?"
set -e
[[ "$scoped_exit" -eq 1 ]]
scoped_manifest="$(find "$scoped_root/campaigns" -name campaign.json -print)"
[[ "$(yq -r '.status' "$scoped_manifest")" == 'completed' ]]
[[ "$(yq -r '.result' "$scoped_manifest")" == 'failed' ]]
[[ "$(yq -r '.runs | length' "$scoped_manifest")" == '2' ]]
[[ "$(yq -r '[.runs[].publish_status] | unique | join(",")' \
  "$scoped_manifest")" == 'local-only' ]]
[[ "$(cat "$scoped_root/commands")" == $'scoped-pass\nscoped-fail' ]]
[[ ! -s "$scoped_root/publishes" ]]
[[ ! -s "$scoped_root/lease-calls" ]]
[[ ! -s "$scoped_root/source-calls" ]]
if rg -q 'SCOPED_CHILD_OUTPUT' "$scoped_root/run.log"; then
  echo 'Scoped campaign streamed child output to the terminal.' >&2
  exit 1
fi
while IFS= read -r run_dir; do
  "$repo_root/scripts/test/validate-run.sh" "$run_dir"
done < <(find "$scoped_root/results" -mindepth 1 -maxdepth 1 -type d -print)

if TEST_CATALOG_PATH="$catalog" TEST_CAMPAIGN_TEST_MODE=true \
  TEST_RESULTS_ROOT="$fixture/wrong-mode-results" \
  TEST_CAMPAIGNS_ROOT="$fixture/wrong-mode-campaigns" \
  TEST_CAMPAIGN_SOURCE_CHECK_BIN="$repo_root/tests/fixtures/campaign/source-check.sh" \
  TEST_CAMPAIGN_PUBLISH_BIN="$repo_root/tests/fixtures/campaign/fake-publisher.sh" \
  KUBECONFIG="$fixture/kubeconfig" \
    "$repo_root/scripts/test/run-campaign.sh" run scoped-verification \
    >"$fixture/wrong-mode.out" 2>&1; then
  echo 'Operator/published mode unexpectedly accepted scoped-verification.' >&2
  exit 1
fi
rg -q 'scoped-verification requires scoped local-only mode' "$fixture/wrong-mode.out"

echo 'Catalog-backed campaign coordinator tests passed.'
