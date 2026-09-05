#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

workflow=.github/workflows/ci.yml
checkout_action='actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'
mise_action='jdx/mise-action@dad1bfd3df957f44999b559dd69dc1671cb4e9ea'
upload_action='actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'

# A missing shadow job is the initial RED. The authoritative full CI job and its
# unfiltered pull-request trigger must remain present throughout the rollout.
mise exec -- yq -e '((.on.pull_request.branches | length) == 1) and
  .on.pull_request.branches[0] == "main" and
  (.on.pull_request | has("paths") | not) and
  (.on.pull_request | has("paths-ignore") | not) and
  (.jobs.ci != null) and (.jobs.plan-shadow != null)' "$workflow" >/dev/null

mise exec -- yq -e '
  (.on | has("pull_request_target") | not) and
  .on.workflow_dispatch == null and
  .permissions.contents == "read" and
  (.permissions | length) == 1 and
  (.jobs.ci.steps | map(select(.run == "mise exec -- just ci")) | length) == 1
' "$workflow" >/dev/null

# These GitHub expressions are literal workflow values, not shell expansions.
# shellcheck disable=SC2016
CHECKOUT_ACTION="$checkout_action" MISE_ACTION="$mise_action" \
	mise exec -- yq -e '
  (.jobs.plan-shadow.steps | map(select(.uses == strenv(CHECKOUT_ACTION))) | length) == 1 and
  (.jobs.plan-shadow.steps[] | select(.uses == strenv(CHECKOUT_ACTION)) | .with.ref) ==
    "${{ github.event_name == '\''pull_request'\'' && github.event.pull_request.head.sha || github.sha }}" and
  (.jobs.plan-shadow.steps[] | select(.uses == strenv(CHECKOUT_ACTION)) | .with."fetch-depth") == 0 and
  (.jobs.plan-shadow.steps[] | select(.uses == strenv(CHECKOUT_ACTION)) | .with."persist-credentials") == false and
  (.jobs.plan-shadow.steps | map(select(.uses == strenv(MISE_ACTION))) | length) == 1
' "$workflow" >/dev/null

# shellcheck disable=SC2016
mise exec -- yq -e '
  (.jobs.plan-shadow.steps | map(select(
    .if == "github.event_name == '\''pull_request'\''" and
    (.run | contains("git cat-file -e \"${{ github.event.pull_request.base.sha }}^{commit}\"")) and
    (.run | contains("git fetch --no-tags origin \"${{ github.event.pull_request.base.sha }}\""))
  )) | length) == 1 and
  (.jobs.plan-shadow.steps | map(select(
    .if == "github.event_name == '\''pull_request'\''" and
    (.run | contains("mise exec -- just test ci-plan")) and
    (.run | contains("\"${{ github.event.pull_request.base.sha }}\"")) and
    (.run | contains("\"${{ github.event.pull_request.head.sha }}\"")) and
    (.run | contains("\"$RUNNER_TEMP/ci-plan.json\""))
  )) | length) == 1 and
  (.jobs.plan-shadow.steps | map(select(
    .if == "github.event_name == '\''workflow_dispatch'\''" and
    (.run | contains("mise exec -- just test ci-plan-full")) and
    ((.run | split("\"${{ github.sha }}\"") | length) == 3) and
    (.run | contains("\"$RUNNER_TEMP/ci-plan.json\""))
  )) | length) == 1
' "$workflow" >/dev/null

# shellcheck disable=SC2016
UPLOAD_ACTION="$upload_action" mise exec -- yq -e '
  (.jobs.plan-shadow.steps | map(select(
    .uses == strenv(UPLOAD_ACTION) and
    .if == "always()" and
    .with.name == "ci-plan-shadow-${{ github.run_id }}-${{ github.run_attempt }}" and
    .with.path == "${{ runner.temp }}/ci-plan.json" and
    .with."if-no-files-found" == "warn"
  )) | length) == 1
' "$workflow" >/dev/null

if rg -q '\$\{\{[[:space:]]*secrets\.' "$workflow"; then
	echo 'The CI workflow must not pass secrets to shadow planning.' >&2
	exit 1
fi

echo 'CI workflow contract tests passed.'
