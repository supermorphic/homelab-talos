#!/usr/bin/env bash

write_environment() {
  local output_dir="$1"
  local started_at="$2"
  local finished_at="$3"
  local tier="$4"
  local target="$5"
  local scenario="$6"
  local namespace="$7"
  local cluster_version="$8"
  local confirmation_type="$9"
  local git_revision git_dirty chainsaw_version kubectl_version

  git_revision="$(git rev-parse HEAD)"
  git_dirty=false
  [[ -z "$(git status --porcelain)" ]] || git_dirty=true
  chainsaw_version="$(chainsaw version | awk '/^Version:/ {print $2}')"
  kubectl_version="$(kubectl version --client --output json | yq -r '.clientVersion.gitVersion')"

  STARTED_AT="$started_at" \
  FINISHED_AT="$finished_at" \
  GIT_REVISION="$git_revision" \
  GIT_DIRTY="$git_dirty" \
  CHAINSAW_VERSION="$chainsaw_version" \
  KUBECTL_VERSION="$kubectl_version" \
  CLUSTER_VERSION="$cluster_version" \
  TEST_TIER="$tier" \
  TEST_TARGET="$target" \
  TEST_SCENARIO="$scenario" \
  TEST_NAMESPACE="$namespace" \
  CONFIRMATION_TYPE="$confirmation_type" \
    yq --null-input --output-format json '{
      "schemaVersion": 1,
      "startedAt": strenv(STARTED_AT),
      "finishedAt": strenv(FINISHED_AT),
      "git": {
        "revision": strenv(GIT_REVISION),
        "dirty": strenv(GIT_DIRTY) == "true"
      },
      "tools": {
        "chainsaw": strenv(CHAINSAW_VERSION),
        "kubectl": strenv(KUBECTL_VERSION)
      },
      "cluster": {
        "kubernetesVersion": strenv(CLUSTER_VERSION),
        "namespace": strenv(TEST_NAMESPACE),
        "node": null,
        "podUid": null
      },
      "test": ({
        "tier": strenv(TEST_TIER),
        "target": strenv(TEST_TARGET),
        "scenario": strenv(TEST_SCENARIO)
      } | del(.scenario | select(. == ""))),
      "confirmationTokenType": strenv(CONFIRMATION_TYPE)
    }' >"$output_dir/environment.json"
}

# Derive a resilience run's recovery/cleanup status from the recovery.json a scenario's
# orchestrator writes into the run dir. Missing or unparseable → not-classified, so a
# scenario that never recorded an outcome cannot silently read as a pass. This is kept
# separate from the primary assertion so a failed recovery is reported, never masked.
resilience_recovery_status() {
  local run_dir="$1"
  local file="$run_dir/recovery.json"
  [[ -f "$file" ]] || { echo 'not-classified'; return; }
  yq -r '.status // "not-classified"' "$file" 2>/dev/null || echo 'not-classified'
}

write_summary() {
  local output_dir="$1"
  local primary_status="$2"
  local primary_exit_code="$3"
  local assertion_status="$4"
  local diagnostics_status="$5"
  local cleanup_status="$6"
  local recovery_status="$7"

  PRIMARY_STATUS="$primary_status" \
  PRIMARY_EXIT_CODE="$primary_exit_code" \
  ASSERTION_STATUS="$assertion_status" \
  DIAGNOSTICS_STATUS="$diagnostics_status" \
  CLEANUP_STATUS="$cleanup_status" \
  RECOVERY_STATUS="$recovery_status" \
    yq --null-input --output-format json '{
      "schemaVersion": 1,
      "primary": {
        "status": strenv(PRIMARY_STATUS),
        "exitCode": strenv(PRIMARY_EXIT_CODE) | tonumber
      },
      "safety": {"status": "passed"},
      "infrastructure": {"status": "not-classified"},
      "assertion": {"status": strenv(ASSERTION_STATUS)},
      "externalDependency": {"status": "not-applicable"},
      "cleanup": {"status": strenv(CLEANUP_STATUS)},
      "recovery": {"status": strenv(RECOVERY_STATUS)},
      "diagnostics": {"status": strenv(DIAGNOSTICS_STATUS)}
    }' >"$output_dir/summary.json"
}
