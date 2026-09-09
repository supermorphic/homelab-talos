#!/usr/bin/env bash
# Resolve, execute, and publish an explicit catalog-backed test campaign.
set -euo pipefail

source scripts/lib/common.sh
source scripts/test/lib/catalog.sh
source scripts/lib/lease.sh
require_bash

[[ "$#" -eq 2 ]] || {
  echo 'Usage: run-campaign.sh <plan|run|resume|scoped-plan|scoped-run|acceptance-plan|acceptance-run|acceptance-resume> <selection|campaign-run-id>' >&2
  exit 2
}

action="$1"
requested="$2"
scoped_mode=false
[[ "$action" != scoped-* ]] || scoped_mode=true
acceptance_mode=false
[[ "$action" != acceptance-* ]] || acceptance_mode=true
acceptance_scoped=false
repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
catalog="${TEST_CATALOG_PATH:-tests/catalog.yaml}"
results_root="${TEST_RESULTS_ROOT:-$repo_root/.test-results}"
campaigns_root="${TEST_CAMPAIGNS_ROOT:-$repo_root/.test-campaigns}"
kubeconfig="${KUBECONFIG:-$repo_root/.kube/config}"
talosconfig="${TALOSCONFIG:-$repo_root/.talos/config}"
scoped_preflight_bin="${TEST_SCOPED_PREFLIGHT_BIN:-$repo_root/scripts/test/scoped-campaign-preflight.sh}"
publish_bin="${TEST_CAMPAIGN_PUBLISH_BIN:-$repo_root/scripts/test/publish-report.sh}"
validate_run_bin="${TEST_CAMPAIGN_VALIDATE_RUN_BIN:-$repo_root/scripts/test/validate-run.sh}"
test_mode="${TEST_CAMPAIGN_TEST_MODE:-false}"
publish_attempts="${TEST_CAMPAIGN_PUBLISH_ATTEMPTS:-3}"
retry_delay="${TEST_CAMPAIGN_RETRY_DELAY_SECONDS:-2}"
campaign_id=''
campaign=''
manifest=''
lease_acquired=false
lease_holder=''
lease_failure=''
overall_failed=false
gate_failed=false
source_sha=''
flux_sha=''
plan_digest=''
selection=''
selection_type='campaign'

[[ "$results_root" == /* ]] || results_root="$repo_root/$results_root"
[[ "$campaigns_root" == /* ]] || campaigns_root="$repo_root/$campaigns_root"
[[ "$publish_attempts" =~ ^[1-9][0-9]*$ ]]
[[ "$retry_delay" =~ ^[0-9]+$ ]]

if [[ "$test_mode" == 'true' ]]; then
  [[ "$scoped_mode" == 'true' || -n "${TEST_CAMPAIGN_SOURCE_CHECK_BIN:-}" ]] || {
    echo 'Campaign test mode requires TEST_CAMPAIGN_SOURCE_CHECK_BIN.' >&2
    exit 2
  }
  catalog_abs="$(cd "$(dirname "$catalog")" && pwd)/$(basename "$catalog")"
  [[ "$catalog_abs" != "$repo_root/tests/catalog.yaml" &&
    "$publish_bin" != "$repo_root/scripts/test/publish-report.sh" &&
    "$results_root" != "$repo_root"/* &&
    "$campaigns_root" != "$repo_root"/* ]] || {
    echo 'Campaign test mode refuses canonical catalog, publisher, or repository output roots.' >&2
    exit 2
  }
elif [[ "$test_mode" != 'false' ]]; then
  echo 'TEST_CAMPAIGN_TEST_MODE must be true or false.' >&2
  exit 2
fi
if [[ -n "${TEST_ACCEPTANCE_LINKED_WORKTREE:-}" ]]; then
  [[ "$test_mode" == 'true' ]] || {
    echo 'TEST_ACCEPTANCE_LINKED_WORKTREE is available only in campaign test mode.' >&2
    exit 2
  }
  case "$TEST_ACCEPTANCE_LINKED_WORKTREE" in
    true) acceptance_scoped=true ;;
    false) acceptance_scoped=false ;;
    *) echo 'TEST_ACCEPTANCE_LINKED_WORKTREE must be true or false.' >&2; exit 2 ;;
  esac
elif [[ "$acceptance_mode" == 'true' ]]; then
  git_dir="$(git rev-parse --path-format=absolute --git-dir)"
  common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
  if [[ "$git_dir" != "$common_dir" && "$git_dir" == "$common_dir"/worktrees/* ]]; then
    acceptance_scoped=true
  fi
fi
if [[ "$test_mode" != 'true' && -n "${TEST_SCOPED_PREFLIGHT_BIN:-}" ]]; then
  echo 'TEST_SCOPED_PREFLIGHT_BIN is available only in campaign test mode.' >&2
  exit 2
fi

random_hex() {
  od -An -N4 -tx1 /dev/urandom | tr -d ' \n'
}

source_state() {
  local remote_ref remote_sha head_sha revision deployed_sha

  if [[ "$scoped_mode" == 'true' ]]; then
    if [[ "$test_mode" != 'true' ]]; then
      [[ -z "$(git status --porcelain)" ]] || {
        echo 'Refusing scoped campaign: commit or stash all checkout changes first.' >&2
        return 1
      }
    fi
    head_sha="$(git rev-parse HEAD)"
    [[ "$head_sha" =~ ^[0-9a-f]{40}$ ]]
    printf '%s %s\n' "$head_sha" "$head_sha"
    return
  fi
  if [[ "$acceptance_mode" == 'true' ]]; then
    if [[ "$test_mode" == 'true' && -n "${TEST_CAMPAIGN_SOURCE_CHECK_BIN:-}" ]]; then
      "$TEST_CAMPAIGN_SOURCE_CHECK_BIN"
      return
    fi
    [[ -z "$(git status --porcelain)" ]] || {
      echo 'Refusing recorded acceptance: commit or stash all checkout changes first.' >&2
      return 1
    }
    head_sha="$(git rev-parse HEAD)"
    [[ "$head_sha" =~ ^[0-9a-f]{40}$ ]]
    printf '%s %s\n' "$head_sha" "$head_sha"
    return
  fi
  if [[ "$test_mode" == 'true' ]]; then
    "$TEST_CAMPAIGN_SOURCE_CHECK_BIN"
    return
  fi
  [[ -z "$(git status --porcelain)" ]] || {
    echo 'Refusing test campaign: commit or stash all checkout changes first.' >&2
    return 1
  }
  [[ -f "$kubeconfig" ]] || {
    echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
    return 1
  }
  remote_ref="$(git ls-remote --exit-code origin refs/heads/main)" || {
    echo 'Unable to query origin/main.' >&2
    return 1
  }
  read -r remote_sha _ <<<"$remote_ref"
  head_sha="$(git rev-parse HEAD)"
  [[ "$remote_sha" =~ ^[0-9a-f]{40}$ && "$head_sha" == "$remote_sha" ]] || {
    echo "Campaign source is not exact origin/main: HEAD=$head_sha origin/main=$remote_sha." >&2
    return 1
  }
  revision="$(
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
      get gitrepository flux-system \
      --output jsonpath='{.status.artifact.revision}'
  )"
  deployed_sha="${revision##*:}"
  [[ "$deployed_sha" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Flux artifact revision is invalid: $revision" >&2
    return 1
  }
  [[ "$deployed_sha" == "$remote_sha" ]] || {
    echo "Flux has not reconciled current main: origin/main=$remote_sha Flux=$deployed_sha." >&2
    return 1
  }
  printf '%s %s\n' "$remote_sha" "$deployed_sha"
}

selected_member_ids() {
  if [[ "$acceptance_mode" == 'true' && "$selection_type" == 'suite' ]]; then
    printf '%s\n' "$selection"
  else
    catalog_campaign_ids "$catalog" "$campaign"
  fi
}

selection_digest() {
  if [[ "$acceptance_mode" == 'true' ]]; then
    {
      printf '%s\n%s\n' "$selection_type" "$selection"
      while IFS= read -r digest_suite; do
        [[ -n "$digest_suite" ]] || continue
        printf '%s\n' "$digest_suite"
        catalog_entry_by_id "$catalog" "$digest_suite"
      done < <(selected_member_ids)
    } | sha256sum | awk '{print $1}'
  else
    catalog_campaign_digest "$catalog" "$campaign"
  fi
}

campaign_uses_test_lease() {
  [[ "$scoped_mode" != 'true' ]] || return 1
  [[ "$acceptance_mode" != 'true' || "$acceptance_scoped" != 'true' ]]
}

acceptance_suite_allowed() {
  local suite_id="$1"
  local entry tier scenario owner mutates

  entry="$(catalog_entry_by_id "$catalog" "$suite_id")" || return "$?"
  tier="$(yq -r '.metadata.tier' - <<<"$entry")"
  scenario="$(yq -r '.metadata.scenario // ""' - <<<"$entry")"
  owner="$(yq -r '.metadata.execution_owner' - <<<"$entry")"
  mutates="$(yq -r '.metadata.mutates_cluster' - <<<"$entry")"
  [[ "$tier" != 'diagnostics' && "$scenario" != 'diagnostics-self-test' ]] || {
    echo "Recorded acceptance excludes diagnostic suite: $suite_id." >&2
    return 1
  }
  if [[ "$acceptance_scoped" == 'true' ]]; then
    if [[ "$suite_id" != 'validation.ci' &&
      ("$owner" != 'shared' || "$mutates" != 'false' || "$tier" == 'offline') ]] &&
      ! catalog_campaign_ids "$catalog" scoped-verification |
        SUITE_ID="$suite_id" awk '$0 == ENVIRON["SUITE_ID"] { found = 1 } END { exit !found }'; then
      echo "Linked-worktree recorded acceptance accepts scoped-verification members, validation.ci, or non-mutating shared live suites: $suite_id. Use validation.ci to retain offline validation." >&2
      return 1
    fi
  fi
}

require_acceptance_confirmation() {
  local suite_id="$1"
  local entry confirmation_type variable expected

  entry="$(catalog_entry_by_id "$catalog" "$suite_id")"
  confirmation_type="$(yq -r '.confirmation.type' - <<<"$entry")"
  [[ "$confirmation_type" != 'exact' ]] || {
    variable="$(yq -r '.confirmation.variable' - <<<"$entry")"
    expected="$(yq -r '.confirmation.expected' - <<<"$entry")"
    [[ -n "$variable" && "${!variable:-}" == "$expected" ]] || {
      echo "Refusing recorded acceptance for $suite_id: set $variable to the documented exact value." >&2
      return 1
    }
  }
}

validate_recorded_acceptance_runs() {
  local expected_members expected_json actual_json suite_id run_id result cleanup recovery
  local run_dir

  expected_members="$(selected_member_ids)"
  expected_json="$(MEMBERS="$expected_members" yq -n -o=json -I=0 \
    '[strenv(MEMBERS) | split("\n")[] | select(. != "")]')"
  actual_json="$(yq -o=json -I=0 '.members' "$manifest")"
  [[ "$actual_json" == "$expected_json" ]] || {
    echo 'Recorded acceptance journal members do not match the frozen selection.' >&2
    return 1
  }
  yq -e '(.runs | length) == (.runs | unique_by(.suite_id) | length)' "$manifest" \
    >/dev/null || {
      echo 'Recorded acceptance journal contains duplicate suite runs.' >&2
      return 1
    }
  while IFS=$'\t' read -r suite_id run_id result cleanup recovery; do
    [[ -n "$suite_id" ]] || continue
    printf '%s\n' "$expected_members" |
      SUITE_ID="$suite_id" awk '$0 == ENVIRON["SUITE_ID"] { found = 1 } END { exit !found }' || {
        echo "Recorded acceptance journal contains unexpected suite: $suite_id." >&2
        return 1
      }
    run_dir="$results_root/$run_id"
    "$validate_run_bin" "$run_dir" >/dev/null || return 1
    [[ "$(yq -r '.suite.id' "$run_dir/environment.json")" == "$suite_id" &&
      "$(yq -r '.git.sha' "$run_dir/environment.json")" == "$source_sha" &&
      "$(yq -r '.result' "$run_dir/summary.json")" == "$result" &&
      "$(yq -r '.phases.cleanup.status // "not-required"' \
        "$run_dir/summary.json")" == "$cleanup" &&
      "$(yq -r '.phases.recovery.status // "not-required"' \
        "$run_dir/summary.json")" == "$recovery" ]] || {
        echo "Recorded acceptance journal does not match canonical run: $run_id." >&2
        return 1
      }
    [[ "$result" != 'broken' &&
      ("$cleanup" == 'passed' || "$cleanup" == 'not-required') &&
      ("$recovery" == 'passed' || "$recovery" == 'not-required') ]] || {
        echo "Recorded acceptance cannot resume unsafe canonical run: $run_id." >&2
        return 1
      }
  done < <(yq -r '.runs[] | [
    .suite_id, .run_id, .result, .cleanup, .recovery
  ] | @tsv' "$manifest")
}

require_source_snapshot() {
  local expected_source="$1"
  local expected_flux="$2"
  local state current_source current_flux

  state="$(source_state)" || return "$?"
  read -r current_source current_flux <<<"$state"
  if [[ "$acceptance_mode" == 'true' ]]; then
    [[ "$current_source" == "$expected_source" ]] || {
      echo "Recorded acceptance source drifted: expected HEAD=$expected_source, got $current_source." >&2
      return 1
    }
    return 0
  fi
  [[ "$current_source" == "$expected_source" && "$current_flux" == "$expected_flux" ]] || {
    echo "Campaign source drifted: expected main/Flux=$expected_source/$expected_flux, got $current_source/$current_flux." >&2
    return 1
  }
}

expected_published_confirmation() {
  printf 'run-publish:%s:%s:%s\n' \
    "$campaign" "${source_sha:0:12}" "$plan_digest"
}

print_frozen_inputs() {
  local campaign_entry count description mutates disruptive

  if [[ "$acceptance_mode" == 'true' && "$selection_type" == 'suite' ]]; then
    campaign_entry="$(catalog_entry_by_id "$catalog" "$selection")"
    description="Recorded acceptance for $selection"
    mutates="$(yq -r '.metadata.mutates_cluster' - <<<"$campaign_entry")"
    disruptive="$(yq -r '.metadata.tier == "resilience"' - <<<"$campaign_entry")"
  else
    campaign_entry="$(catalog_campaign_entry "$catalog" "$campaign")"
    description="$(yq -r '.description' - <<<"$campaign_entry")"
    mutates="$(yq -r '.mutates_cluster' - <<<"$campaign_entry")"
    disruptive="$(yq -r '.disruptive' - <<<"$campaign_entry")"
  fi
  count="$(selected_member_ids | wc -l | tr -d ' ')"
  if [[ "$acceptance_mode" == 'true' ]]; then
    echo 'Campaign: recorded-acceptance'
    echo "Selection: $selection"
  else
    echo "Campaign: $campaign"
  fi
  echo "Description: $description"
  echo "Suites: $count"
  echo "Source: $source_sha"
  if [[ "$acceptance_mode" == 'true' ]]; then
    echo 'Flux: evaluated at publication'
  else
    echo "Flux: $flux_sha"
  fi
  echo "Plan digest: $plan_digest"
  if [[ "$acceptance_mode" == 'true' && "$acceptance_scoped" == 'true' ]]; then
    echo 'Mode: recorded acceptance (scoped worktree)'
  elif [[ "$acceptance_mode" == 'true' ]]; then
    echo 'Mode: recorded acceptance (operator)'
  elif [[ "$scoped_mode" == 'true' ]]; then
    echo 'Mode: scoped local-only'
  else
    echo 'Mode: operator published'
  fi
  echo "Mutates cluster: $mutates"
  echo "Disruptive: $disruptive"
  echo
  selected_member_ids | nl -w2 -s'. '
}

print_plan() {
  local confirmation

  print_frozen_inputs
  echo
  echo 'Run with:'
  if [[ "$acceptance_mode" == 'true' ]]; then
    printf 'mise exec -- just test acceptance %s\n' "$selection"
  elif [[ "$scoped_mode" == 'true' ]]; then
    echo 'mise exec -- just test scoped-campaign'
  else
    confirmation="$(expected_published_confirmation)"
    printf "TEST_CAMPAIGN_CONFIRM='%s' mise exec -- just test campaign %s\n" \
      "$confirmation" "$campaign"
  fi
}

initialize_manifest() {
  local members members_json campaign_entry execution_mode mutates disruptive manifest_campaign flux_json

  manifest_campaign="$campaign"
  if [[ "$acceptance_mode" == 'true' ]]; then
    manifest_campaign='recorded-acceptance'
    execution_mode='recorded-acceptance-operator'
    [[ "$acceptance_scoped" != 'true' ]] || execution_mode='recorded-acceptance-scoped'
  else
    execution_mode="$(yq -r '.execution_mode // "operator-published"' \
      - <<<"$(catalog_campaign_entry "$catalog" "$campaign")")"
  fi
  campaign_id="$(date -u +%Y%m%dT%H%M%SZ)-${manifest_campaign}-$(random_hex)"
  manifest="$campaigns_root/$campaign_id/campaign.json"
  mkdir -p "$(dirname "$manifest")/logs"
  members="$(selected_member_ids)"
  members_json="$(
    MEMBERS="$members" yq --null-input --output-format json -I=0 \
      '[strenv(MEMBERS) | split("\n")[] | select(. != "")]'
  )"
  if [[ "$acceptance_mode" == 'true' && "$selection_type" == 'suite' ]]; then
    campaign_entry="$(catalog_entry_by_id "$catalog" "$selection")"
    mutates="$(yq -r '.metadata.mutates_cluster' - <<<"$campaign_entry")"
    disruptive="$(yq -r '.metadata.tier == "resilience"' - <<<"$campaign_entry")"
  else
    campaign_entry="$(catalog_campaign_entry "$catalog" "$campaign")"
    mutates="$(yq -r '.mutates_cluster' - <<<"$campaign_entry")"
    disruptive="$(yq -r '.disruptive' - <<<"$campaign_entry")"
  fi
  flux_json="$(FLUX_SHA="$flux_sha" yq -n -o=json 'strenv(FLUX_SHA)')"
  [[ "$acceptance_mode" != 'true' ]] || flux_json='null'
  CAMPAIGN_ID="$campaign_id" CAMPAIGN="$manifest_campaign" PLAN_DIGEST="$plan_digest" \
  SOURCE_SHA="$source_sha" FLUX_JSON="$flux_json" MEMBERS_JSON="$members_json" \
  EXECUTION_MODE="$execution_mode" MUTATES="$mutates" DISRUPTIVE="$disruptive" \
  STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    yq --null-input --output-format json --indent 2 '{
      "schema_version": 1,
      "campaign_id": strenv(CAMPAIGN_ID),
      "campaign": strenv(CAMPAIGN),
      "execution_mode": strenv(EXECUTION_MODE),
      "plan_digest": strenv(PLAN_DIGEST),
      "source_sha": strenv(SOURCE_SHA),
      "flux_sha": (strenv(FLUX_JSON) | from_json),
      "mutates_cluster": strenv(MUTATES) == "true",
      "disruptive": strenv(DISRUPTIVE) == "true",
      "started_at": strenv(STARTED_AT),
      "finished_at": null,
      "status": "running",
      "result": null,
      "stop_reason": null,
      "members": (strenv(MEMBERS_JSON) | from_json),
      "runs": []
    }' >"$manifest"
  if [[ "$acceptance_mode" == 'true' ]]; then
    SELECTION="$selection" SELECTION_TYPE="$selection_type" \
      yq --output-format json --indent 2 -i '
        .selection = strenv(SELECTION) |
        .selection_type = strenv(SELECTION_TYPE)
      ' "$manifest"
  fi
}

finish_manifest() {
  local status="$1"
  local result="$2"
  local reason="${3:-}"
  local reason_json='null'
  [[ -z "$reason" ]] ||
    reason_json="$(JSON_VALUE="$reason" yq -n -o=json 'strenv(JSON_VALUE)')"
  STATUS="$status" RESULT="$result" REASON_JSON="$reason_json" \
  FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    yq --output-format json --indent 2 -i '
      .status = strenv(STATUS) |
      .result = strenv(RESULT) |
      .stop_reason = (strenv(REASON_JSON) | from_json) |
      .finished_at = strenv(FINISHED_AT)
    ' "$manifest"
}

append_run() {
  local suite_id="$1"
  local run_id="$2"
  local result="$3"
  local cleanup="$4"
  local recovery="$5"

  SUITE_ID="$suite_id" RUN_ID="$run_id" RESULT="$result" \
  CLEANUP="$cleanup" RECOVERY="$recovery" \
  RECORDED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    yq --output-format json --indent 2 -i '.runs += [{
      "suite_id": strenv(SUITE_ID),
      "run_id": strenv(RUN_ID),
      "result": strenv(RESULT),
      "cleanup": strenv(CLEANUP),
      "recovery": strenv(RECOVERY),
      "recorded_at": strenv(RECORDED_AT),
      "publish_status": "pending",
      "url": null
    }]' "$manifest"
}

update_publish() {
  local run_id="$1"
  local status="$2"
  local url="${3:-}"
  local url_json='null'

  [[ -z "$url" ]] ||
    url_json="$(JSON_VALUE="$url" yq -n -o=json 'strenv(JSON_VALUE)')"
  RUN_ID="$run_id" STATUS="$status" URL_JSON="$url_json" \
    yq --output-format json --indent 2 -i '
      (.runs[] | select(.run_id == strenv(RUN_ID)) | .publish_status) =
        strenv(STATUS) |
      (.runs[] | select(.run_id == strenv(RUN_ID)) | .url) =
        (strenv(URL_JSON) | from_json)
    ' "$manifest"
}

print_summary() {
  echo
  echo "Campaign results: $campaign_id"
  printf '%-48s %-8s %-11s %s\n' SUITE RESULT PUBLISH URL
  yq -r '.runs[] | [
    .suite_id, .result, .publish_status, (.url // "-")
  ] | @tsv' "$manifest" |
    while IFS=$'\t' read -r suite result publish url; do
      printf '%-48s %-8s %-11s %s\n' "$suite" "$result" "$publish" "$url"
    done
  echo "Manifest: $manifest"
  if [[ "$(yq -r '.status' "$manifest")" == 'publish-failed' ]]; then
    echo 'Resume with:'
    if [[ "$acceptance_mode" == 'true' ]]; then
      printf 'mise exec -- just test acceptance-resume %s\n' "$campaign_id"
    else
      printf "TEST_CAMPAIGN_CONFIRM='resume-publish:%s' mise exec -- just test campaign-resume %s\n" \
      "$campaign_id" "$campaign_id"
    fi
  elif [[ "$acceptance_mode" == 'true' &&
    "$(yq -r '.stop_reason // ""' "$manifest")" == \
      'unsafe-child-publication-failed' ]]; then
    echo 'Retry retained evidence publication without continuing the campaign:'
    while IFS= read -r failed_run_id; do
      [[ -n "$failed_run_id" ]] || continue
      printf 'mise exec -- just test acceptance-publish %s\n' "$failed_run_id"
    done < <(yq -r '.runs[] | select(.publish_status == "failed") | .run_id' \
      "$manifest")
  fi
}

# Invoked directly and through the EXIT trap below.
# shellcheck disable=SC2329
cleanup_campaign() {
  campaign_uses_test_lease || return 0
  stop_test_lease_renewal 2>/dev/null || true
  if [[ "$lease_acquired" == 'true' ]]; then
    release_test_lease "$kubeconfig" "$lease_holder" >/dev/null 2>&1 || {
      echo 'Warning: could not release the campaign test Lease.' >&2
    }
    lease_acquired=false
  fi
}

# Invoked through the signal traps below.
# shellcheck disable=SC2329
handle_signal() {
  local signal="$1"
  trap - EXIT INT TERM
  [[ -z "$manifest" || ! -f "$manifest" ]] ||
    finish_manifest broken broken "interrupted-$signal"
  cleanup_campaign
  case "$signal" in
    INT) exit 130 ;;
    TERM) exit 143 ;;
  esac
}

trap cleanup_campaign EXIT
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

acquire_campaign_lease() {
  campaign_uses_test_lease || return 0
  if [[ "${TEST_CAMPAIGN_SKIP_LEASE:-false}" == 'true' ]]; then
    [[ "$test_mode" == 'true' ]] || {
      echo 'TEST_CAMPAIGN_SKIP_LEASE is available only in test mode.' >&2
      return 2
    }
    return 0
  fi
  lease_holder="campaign:$campaign_id"
  lease_failure="$(dirname "$manifest")/lease-renewal-failed"
  acquire_test_lease "$kubeconfig" "$lease_holder"
  lease_acquired=true
  start_test_lease_renewal "$kubeconfig" "$lease_holder" "$lease_failure"
  export TEST_CAMPAIGN_LEASE_HOLDER="$lease_holder"
  export TEST_CAMPAIGN_LEASE_FAILURE_MARKER="$lease_failure"
}

require_campaign_lease() {
  campaign_uses_test_lease || return 0
  if [[ "${TEST_CAMPAIGN_SKIP_LEASE:-false}" == 'true' ]]; then
    return 0
  fi
  [[ ! -e "$lease_failure" ]] || {
    echo 'Campaign test Lease renewal failed.' >&2
    return 1
  }
  verify_test_lease_holder "$kubeconfig" "$lease_holder"
}

resolve_member_command() {
  local suite_id="$1"
  local entry command latest_published

  entry="$(catalog_entry_by_id "$catalog" "$suite_id")"
  command="$(yq -r '.runner.command' - <<<"$entry")"
  [[ "$command" == *'mise exec -- just '* ]] || {
    echo "Campaign member has an unsafe runner command: $suite_id" >&2
    return 2
  }
  if [[ "$command" == *'<run-id>'* ]]; then
    latest_published="$(
      yq -r '[.runs[] | select(.publish_status == "published" or
        .publish_status == "idempotent")] | last | .run_id // ""' "$manifest"
    )"
    [[ -n "$latest_published" ]] || {
      echo "$suite_id requires a previously published campaign run." >&2
      return 1
    }
    command="${command//<run-id>/$latest_published}"
  fi
  [[ "$command" != *'<'* && "$command" != *'>'* ]] || {
    echo "Campaign member contains an unresolved command placeholder: $suite_id" >&2
    return 2
  }
  printf '%s\n' "$command"
}

publish_run() {
  local run_id="$1"
  local result_file="$2"
  local attempt publish_status url

  rm -f "$result_file"
  for ((attempt = 1; attempt <= publish_attempts; attempt++)); do
    publish_exit=0
    if [[ "$acceptance_mode" == 'true' ]]; then
      TEST_RESULTS_ROOT="$results_root" \
      TEST_PUBLISH_RESULT_FILE="$result_file" \
      TEST_REPORT_PUBLICATION_CONTEXT=recorded-acceptance \
      TEST_REPORT_REQUIRE_AUTHORITATIVE=false \
      KUBECONFIG="$kubeconfig" \
        "$publish_bin" "$run_id" || publish_exit="$?"
    else
      TEST_RESULTS_ROOT="$results_root" \
      TEST_PUBLISH_RESULT_FILE="$result_file" \
      TEST_REPORT_REQUIRE_AUTHORITATIVE=true \
      TEST_REPORT_PUBLISH_CONFIRM="publish:test-report:$run_id" \
      KUBECONFIG="$kubeconfig" \
        "$publish_bin" "$run_id" || publish_exit="$?"
    fi
    if [[ "$publish_exit" -eq 0 && -f "$result_file" ]]; then
      publish_status="$(yq -r '.status' "$result_file")"
      url="$(yq -r '.url' "$result_file")"
      [[ "$publish_status" == 'published' || "$publish_status" == 'idempotent' ]]
      [[ "$url" == https://tests.lab.supermorphic.com/reports/*/awesome/ ||
        "$test_mode" == 'true' ]]
      update_publish "$run_id" "$publish_status" "$url"
      return 0
    fi
    [[ "$attempt" -eq "$publish_attempts" ]] || sleep "$retry_delay"
  done
  update_publish "$run_id" failed
  return 1
}

run_member() {
  local suite_id="$1"
  local command run_id_file publish_result_file log_file run_id run_dir
  local command_exit result cleanup recovery unsafe_child=false

  command="$(resolve_member_command "$suite_id")" || return 20
  run_id_file="$(dirname "$manifest")/${suite_id}.run-id"
  publish_result_file="$(dirname "$manifest")/${suite_id}.publish.json"
  log_file="$(dirname "$manifest")/logs/${suite_id}.log"
  rm -f "$run_id_file" "$publish_result_file"

  echo
  echo "=== campaign $campaign: $suite_id ==="
  command_exit=0
  if [[ "$scoped_mode" == 'true' ]]; then
    TEST_RUN_ID_FILE="$run_id_file" \
    TEST_RESULTS_ROOT="$results_root" \
    TEST_KUBECONFIG="$kubeconfig" \
    KUBECONFIG="$kubeconfig" \
      bash -o pipefail -c "$command" >"$log_file" 2>&1 || command_exit="$?"
  else
    TEST_RUN_ID_FILE="$run_id_file" \
    TEST_RESULTS_ROOT="$results_root" \
    TEST_KUBECONFIG="$kubeconfig" \
    KUBECONFIG="$kubeconfig" \
      bash -o pipefail -c "$command" 2>&1 | tee "$log_file" ||
      command_exit="${PIPESTATUS[0]}"
  fi

  [[ -f "$run_id_file" ]] || {
    echo "$suite_id did not emit TEST_RUN_ID_FILE (exit $command_exit)." >&2
    return 20
  }
  run_id="$(tr -d '\r\n' <"$run_id_file")"
  [[ "$run_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}-(agent|github-actions|operator)-[0-9a-f]{8}$ ]] || {
    echo "$suite_id emitted an invalid canonical run ID: $run_id" >&2
    return 20
  }
  run_dir="$results_root/$run_id"
  "$validate_run_bin" "$run_dir" || return 20
  [[ "$(yq -r '.suite.id' "$run_dir/environment.json")" == "$suite_id" ]] || {
    echo "$suite_id emitted a canonical run for a different suite." >&2
    return 20
  }
  if [[ "$acceptance_mode" == 'true' &&
    "$(yq -r '.git.sha' "$run_dir/environment.json")" != "$source_sha" ]]; then
    echo "$suite_id emitted a canonical run for a different source revision." >&2
    return 20
  fi
  result="$(yq -r '.result' "$run_dir/summary.json")"
  cleanup="$(yq -r '.phases.cleanup.status // "not-required"' "$run_dir/summary.json")"
  recovery="$(yq -r '.phases.recovery.status // "not-required"' "$run_dir/summary.json")"
  append_run "$suite_id" "$run_id" "$result" "$cleanup" "$recovery"

  if [[ "$result" == 'passed' && "$command_exit" -ne 0 ]]; then
    echo "$suite_id exited $command_exit but emitted a passed canonical result." >&2
    return 20
  fi
  if [[ "$result" != 'passed' && "$command_exit" -eq 0 ]]; then
    echo "$suite_id exited 0 but emitted a non-passing canonical result ($result)." >&2
  fi

  if [[ "$result" == 'broken' ]] ||
    [[ "$cleanup" != 'passed' && "$cleanup" != 'not-required' ]] ||
    [[ "$recovery" != 'passed' && "$recovery" != 'not-required' ]]; then
    unsafe_child=true
  fi

  if ! require_campaign_lease; then
    update_publish "$run_id" not-published-lease-lost
    return 25
  fi
  if ! require_source_snapshot "$source_sha" "$flux_sha"; then
    update_publish "$run_id" not-published-source-drift
    return 23
  fi
  if [[ "$scoped_mode" == 'true' ]]; then
    update_publish "$run_id" local-only
  elif ! publish_run "$run_id" "$publish_result_file"; then
    require_source_snapshot "$source_sha" "$flux_sha" || return 23
    [[ "$unsafe_child" != 'true' ]] || return 26
    return 22
  fi

  [[ "$unsafe_child" != 'true' ]] || return 20

  if [[ "$result" == 'failed' ]]; then
    overall_failed=true
    case "$(yq -r '.metadata.tier' - <<<"$(catalog_entry_by_id "$catalog" "$suite_id")")" in
      offline|smoke) gate_failed=true ;;
    esac
  fi
  [[ "$suite_id" != 'validation.ci' || "$result" == 'passed' ]] || return 24
  return 0
}

retry_pending_publications() {
  local run_id publish_result_file

  while IFS= read -r run_id; do
    [[ -n "$run_id" ]] || continue
    publish_result_file="$(dirname "$manifest")/resume-${run_id}.publish.json"
    require_source_snapshot "$source_sha" "$flux_sha" || return 23
    if ! publish_run "$run_id" "$publish_result_file"; then
      require_source_snapshot "$source_sha" "$flux_sha" || return 23
      return 22
    fi
  done < <(yq -r '.runs[] |
    select(.publish_status != "published" and .publish_status != "idempotent") |
    .run_id' "$manifest")
}

execute_remaining_members() {
  local suite_id entry mutates member_status

  while IFS= read -r suite_id; do
    [[ -n "$suite_id" ]] || continue
    if SUITE_ID="$suite_id" yq -e \
      '.runs[] | select(.suite_id == strenv(SUITE_ID))' \
      "$manifest" >/dev/null 2>&1; then
      continue
    fi
    require_campaign_lease || {
      finish_manifest broken broken lease-lost-before-suite
      return 2
    }
    require_source_snapshot "$source_sha" "$flux_sha" || {
      finish_manifest stopped broken source-drift-before-suite
      return 2
    }
    if [[ "$acceptance_mode" == 'true' ]] &&
      ! require_acceptance_confirmation "$suite_id"; then
      finish_manifest stopped broken missing-suite-confirmation
      return 2
    fi
    entry="$(catalog_entry_by_id "$catalog" "$suite_id")"
    mutates="$(yq -r '.metadata.mutates_cluster' - <<<"$entry")"
    if [[ "$gate_failed" == 'true' && "$mutates" == 'true' ]]; then
      finish_manifest failed failed gated-after-validation-or-smoke-failure
      return 1
    fi

    if run_member "$suite_id"; then
      member_status=0
    else
      member_status="$?"
    fi
    case "$member_status" in
      0) ;;
      20)
        finish_manifest broken broken unsafe-child-result
        return 2
        ;;
      22)
        finish_manifest publish-failed broken publication-failed
        return 2
        ;;
      23)
        finish_manifest stopped broken source-drift-after-suite
        return 2
        ;;
      24)
        finish_manifest failed failed validation-gate-failed
        return 1
        ;;
      25)
        finish_manifest broken broken lease-lost-after-suite
        return 2
        ;;
      26)
        finish_manifest broken broken unsafe-child-publication-failed
        return 2
        ;;
      *)
        finish_manifest broken broken "unexpected-member-status-$member_status"
        return 2
        ;;
    esac
  done < <(selected_member_ids)

  if [[ "$overall_failed" == 'true' ]]; then
    finish_manifest completed failed
    return 1
  fi
  finish_manifest completed passed
  return 0
}

prepare_new_campaign() {
  local state confirmation execution_mode

  campaign="$requested"
  execution_mode="$(yq -r '.execution_mode // "operator-published"' \
    - <<<"$(catalog_campaign_entry "$catalog" "$campaign")")"
  if [[ "$scoped_mode" == 'true' ]]; then
    [[ "$campaign" == 'scoped-verification' && "$execution_mode" == 'scoped-local' ]] || {
      echo 'Scoped local-only mode accepts only scoped-verification.' >&2
      exit 2
    }
  elif [[ "$campaign" == 'scoped-verification' || "$execution_mode" == 'scoped-local' ]]; then
    echo 'scoped-verification requires scoped local-only mode.' >&2
    exit 2
  fi
  if [[ "$scoped_mode" == 'true' ]]; then
    "$scoped_preflight_bin" "$repo_root" "$kubeconfig" "$talosconfig"
  fi
  [[ "$test_mode" == 'true' ]] || scripts/test/validate-catalog.sh "$catalog" >/dev/null
  plan_digest="$(catalog_campaign_digest "$catalog" "$campaign")"
  state="$(source_state)"
  read -r source_sha flux_sha <<<"$state"
  [[ "$source_sha" =~ ^[0-9a-f]{40}$ && "$flux_sha" =~ ^[0-9a-f]{40}$ ]] || {
    echo 'Campaign source check did not return two full Git SHAs.' >&2
    exit 1
  }
  if [[ "$action" == 'plan' || "$action" == 'scoped-plan' ]]; then
    print_plan
    exit 0
  fi
  if [[ "$scoped_mode" == 'true' ]]; then
    print_frozen_inputs
  else
    confirmation="$(expected_published_confirmation)"
    [[ "${TEST_CAMPAIGN_CONFIRM:-}" == "$confirmation" ]] || {
      echo "Refusing campaign $campaign." >&2
      echo 'Run its plan recipe and set TEST_CAMPAIGN_CONFIRM to the exact value.' >&2
      exit 1
    }
  fi
  initialize_manifest
}

prepare_new_acceptance() {
  local state suite_id

  selection="$requested"
  if [[ "$selection" == 'scoped-verification' ]]; then
    selection_type='campaign'
    campaign='scoped-verification'
    while IFS= read -r suite_id; do
      [[ -n "$suite_id" ]] || continue
      acceptance_suite_allowed "$suite_id" || exit "$?"
    done < <(selected_member_ids)
  else
    selection_type='suite'
    campaign='recorded-acceptance'
    acceptance_suite_allowed "$selection" || exit "$?"
  fi
  if [[ "$acceptance_scoped" == 'true' ]]; then
    "$scoped_preflight_bin" "$repo_root" "$kubeconfig" "$talosconfig"
  fi
  [[ "$test_mode" == 'true' ]] || scripts/test/validate-catalog.sh "$catalog" >/dev/null
  plan_digest="$(selection_digest)"
  state="$(source_state)"
  read -r source_sha flux_sha <<<"$state"
  [[ "$source_sha" =~ ^[0-9a-f]{40}$ && "$flux_sha" =~ ^[0-9a-f]{40}$ ]] || {
    echo 'Recorded acceptance source check did not return two full Git SHAs.' >&2
    exit 1
  }
  if [[ "$action" == 'acceptance-plan' ]]; then
    print_plan
    exit 0
  fi
  print_frozen_inputs
  initialize_manifest
}

prepare_resume() {
  local state current_digest status current_source current_flux execution_mode

  campaign_id="$requested"
  [[ "$campaign_id" =~ ^[0-9]{8}T[0-9]{6}Z-[a-z0-9-]+-[0-9a-f]{8}$ ]] || {
    echo "Invalid campaign run ID: $campaign_id" >&2
    exit 2
  }
  manifest="$campaigns_root/$campaign_id/campaign.json"
  [[ -f "$manifest" ]] || {
    echo "Missing campaign manifest: $manifest" >&2
    exit 1
  }
  campaign="$(yq -r '.campaign' "$manifest")"
  execution_mode="$(yq -r '.execution_mode // "operator-published"' "$manifest")"
  if [[ "$acceptance_mode" == 'true' ]]; then
    case "$execution_mode" in
      recorded-acceptance-scoped)
        [[ "$acceptance_scoped" == 'true' ]] || {
          echo 'Scoped recorded acceptance must resume from a linked worktree.' >&2
          exit 1
        }
        ;;
      recorded-acceptance-operator)
        [[ "$acceptance_scoped" != 'true' ]] || {
          echo 'Operator recorded acceptance cannot resume from a linked worktree.' >&2
          exit 1
        }
        ;;
      *)
        echo 'Only recorded acceptance journals can use acceptance-resume.' >&2
        exit 1
        ;;
    esac
    selection="$(yq -r '.selection // ""' "$manifest")"
    selection_type="$(yq -r '.selection_type // ""' "$manifest")"
    [[ "$selection_type" == 'suite' || "$selection_type" == 'campaign' ]] || {
      echo 'Recorded acceptance journal has an invalid selection type.' >&2
      exit 1
    }
    if [[ "$selection_type" == 'campaign' ]]; then
      [[ "$selection" == 'scoped-verification' ]] || {
        echo 'Recorded acceptance journal has an unsupported campaign selection.' >&2
        exit 1
      }
      campaign="$selection"
    else
      campaign='recorded-acceptance'
    fi
    while IFS= read -r completed_suite; do
      [[ -n "$completed_suite" ]] || continue
      acceptance_suite_allowed "$completed_suite" || exit "$?"
    done < <(selected_member_ids)
    [[ "$acceptance_scoped" != 'true' ]] ||
      "$scoped_preflight_bin" "$repo_root" "$kubeconfig" "$talosconfig"
  else
    [[ "$campaign" != 'scoped-verification' && "$execution_mode" != 'scoped-local' ]] || {
      echo 'scoped-local campaigns cannot be resumed or published.' >&2
      exit 1
    }
    [[ "${TEST_CAMPAIGN_CONFIRM:-}" == "resume-publish:$campaign_id" ]] || {
      echo "Set TEST_CAMPAIGN_CONFIRM='resume-publish:$campaign_id' to resume." >&2
      exit 1
    }
  fi
  status="$(yq -r '.status' "$manifest")"
  [[ "$status" == 'publish-failed' ]] || {
    echo "Campaign $campaign_id is not resumable (status=$status)." >&2
    exit 1
  }
  source_sha="$(yq -r '.source_sha' "$manifest")"
  flux_sha="$(yq -r '.flux_sha' "$manifest")"
  plan_digest="$(yq -r '.plan_digest' "$manifest")"
  current_digest="$(selection_digest)"
  [[ "$current_digest" == "$plan_digest" ]] || {
    echo 'Campaign catalog membership changed; start a new campaign.' >&2
    exit 1
  }
  state="$(source_state)"
  read -r current_source current_flux <<<"$state"
  [[ "$current_source" =~ ^[0-9a-f]{40}$ &&
    "$current_flux" =~ ^[0-9a-f]{40}$ ]] || {
    echo 'Campaign source check did not return two full Git SHAs.' >&2
    exit 1
  }
  if [[ "$acceptance_mode" == 'true' ]]; then
    [[ "$current_source" == "$source_sha" ]] || {
      echo 'Recorded acceptance source is stale and cannot be resumed.' >&2
      exit 1
    }
  else
    [[ "$current_source" == "$source_sha" && "$current_flux" == "$flux_sha" ]] || {
      echo 'Campaign source is stale and cannot be resumed.' >&2
      exit 1
    }
  fi
  [[ "$acceptance_mode" != 'true' ]] || validate_recorded_acceptance_runs || {
    echo 'Recorded acceptance journal is unsafe to resume.' >&2
    exit 1
  }
  overall_failed=false
  gate_failed=false
  while IFS=$'\t' read -r completed_suite completed_result; do
    [[ "$completed_result" == 'failed' ]] || continue
    overall_failed=true
    case "$(yq -r '.metadata.tier' - <<<"$(
      catalog_entry_by_id "$catalog" "$completed_suite"
    )")" in
      offline|smoke) gate_failed=true ;;
    esac
  done < <(yq -r '.runs[] | [.suite_id, .result] | @tsv' "$manifest")
  STATUS=running yq --output-format json --indent 2 -i \
    '.status = strenv(STATUS) | .finished_at = null | .stop_reason = null' \
    "$manifest"
}

case "$action" in
  plan|run|scoped-plan|scoped-run) prepare_new_campaign ;;
  acceptance-plan|acceptance-run) prepare_new_acceptance ;;
  resume|acceptance-resume) prepare_resume ;;
  *)
    echo "Unknown campaign action: $action" >&2
    exit 2
    ;;
esac

acquire_campaign_lease || {
  [[ -z "$manifest" || ! -f "$manifest" ]] ||
    finish_manifest broken broken lease-acquisition-failed
  exit 2
}

campaign_exit=0
if [[ "$action" == 'resume' || "$action" == 'acceptance-resume' ]]; then
  if retry_pending_publications; then
    retry_status=0
  else
    retry_status="$?"
  fi
  case "$retry_status" in
    0) ;;
    22)
      finish_manifest publish-failed broken publication-failed
      campaign_exit=2
      ;;
    23)
      finish_manifest stopped broken source-drift-during-resume
      campaign_exit=2
      ;;
    *)
      finish_manifest broken broken resume-failed
      campaign_exit=2
      ;;
  esac
fi
if [[ "$campaign_exit" -eq 0 ]]; then
  if execute_remaining_members; then
    campaign_exit=0
  else
    campaign_exit="$?"
  fi
fi
print_summary
exit "$campaign_exit"
