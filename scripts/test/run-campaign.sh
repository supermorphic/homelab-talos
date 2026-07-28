#!/usr/bin/env bash
# Resolve, execute, and publish an explicit catalog-backed test campaign.
set -euo pipefail

source scripts/lib/common.sh
source scripts/test/lib/catalog.sh
source scripts/test/lib/lease.sh
require_bash

[[ "$#" -eq 2 ]] || {
  echo 'Usage: run-campaign.sh <plan|run|resume> <campaign|campaign-run-id>' >&2
  exit 2
}

action="$1"
requested="$2"
repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
catalog="${TEST_CATALOG_PATH:-tests/catalog.yaml}"
results_root="${TEST_RESULTS_ROOT:-$repo_root/.test-results}"
campaigns_root="${TEST_CAMPAIGNS_ROOT:-$repo_root/.test-campaigns}"
kubeconfig="${KUBECONFIG:-$repo_root/.kube/config}"
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

[[ "$results_root" == /* ]] || results_root="$repo_root/$results_root"
[[ "$campaigns_root" == /* ]] || campaigns_root="$repo_root/$campaigns_root"
[[ "$publish_attempts" =~ ^[1-9][0-9]*$ ]]
[[ "$retry_delay" =~ ^[0-9]+$ ]]

if [[ "$test_mode" == 'true' ]]; then
  [[ -n "${TEST_CAMPAIGN_SOURCE_CHECK_BIN:-}" ]] || {
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

random_hex() {
  od -An -N4 -tx1 /dev/urandom | tr -d ' \n'
}

source_state() {
  local remote_ref remote_sha head_sha revision deployed_sha

  if [[ "$test_mode" == 'true' ]]; then
    "$TEST_CAMPAIGN_SOURCE_CHECK_BIN"
    return
  fi
  [[ -z "$(git status --porcelain)" ]] || {
    echo 'Refusing test campaign: commit or stash all worktree changes first.' >&2
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

require_source_snapshot() {
  local expected_source="$1"
  local expected_flux="$2"
  local state current_source current_flux

  state="$(source_state)" || return "$?"
  read -r current_source current_flux <<<"$state"
  [[ "$current_source" == "$expected_source" &&
    "$current_flux" == "$expected_flux" ]] || {
    echo "Campaign source drifted: expected main/Flux=$expected_source/$expected_flux, got $current_source/$current_flux." >&2
    return 1
  }
}

derive_plex_placement() {
  local node ip

  if [[ "$test_mode" == 'true' && -n "${TEST_CAMPAIGN_PLEX_PLACEMENT_BIN:-}" ]]; then
    "$TEST_CAMPAIGN_PLEX_PLACEMENT_BIN"
    return
  fi
  node="$(
    kubectl --kubeconfig "$kubeconfig" --namespace media \
      get pod --selector app.kubernetes.io/name=plex \
      --output jsonpath='{.items[0].spec.nodeName}'
  )"
  case "$node" in
    nuc1) ip='192.168.90.10' ;;
    nuc2) ip='192.168.90.11' ;;
    nuc3) ip='192.168.90.12' ;;
    *)
      echo "Plex is on unexpected node '${node:-<none>}'." >&2
      return 1
      ;;
  esac
  printf '%s %s\n' "$node" "$ip"
}

campaign_has_suite() {
  local suite_id="$1"
  catalog_campaign_ids "$catalog" "$campaign" | rg -qx --fixed-strings "$suite_id"
}

expected_confirmation() {
  if campaign_has_suite test.resilience.plex-node-reboot; then
    printf 'run-publish:%s:%s:%s\n' \
      "$campaign" "${source_sha:0:12}" "$plan_digest"
  else
    printf 'run-publish:%s\n' "$campaign"
  fi
}

print_plan() {
  local campaign_entry confirmation count

  campaign_entry="$(catalog_campaign_entry "$catalog" "$campaign")"
  confirmation="$(expected_confirmation)"
  count="$(catalog_campaign_ids "$catalog" "$campaign" | wc -l | tr -d ' ')"
  echo "Campaign: $campaign"
  echo "Description: $(yq -r '.description' - <<<"$campaign_entry")"
  echo "Suites: $count"
  echo "Source: $source_sha"
  echo "Flux: $flux_sha"
  echo "Plan digest: $plan_digest"
  echo "Mutates cluster: $(yq -r '.mutates_cluster' - <<<"$campaign_entry")"
  echo "Disruptive: $(yq -r '.disruptive' - <<<"$campaign_entry")"
  if campaign_has_suite test.resilience.plex-node-reboot; then
    echo 'Plex reboot target: resolved immediately before the final reboot scenario'
  fi
  echo
  catalog_campaign_ids "$catalog" "$campaign" | nl -w2 -s'. '
  echo
  echo 'Run with:'
  printf "TEST_CAMPAIGN_CONFIRM='%s' mise exec -- just test campaign %s\n" \
    "$confirmation" "$campaign"
}

initialize_manifest() {
  local members members_json campaign_entry

  campaign_id="$(date -u +%Y%m%dT%H%M%SZ)-${campaign}-$(random_hex)"
  manifest="$campaigns_root/$campaign_id/campaign.json"
  mkdir -p "$(dirname "$manifest")/logs"
  members="$(catalog_campaign_ids "$catalog" "$campaign")"
  members_json="$(
    MEMBERS="$members" yq --null-input --output-format json -I=0 \
      '[strenv(MEMBERS) | split("\n")[] | select(. != "")]'
  )"
  campaign_entry="$(catalog_campaign_entry "$catalog" "$campaign")"
  CAMPAIGN_ID="$campaign_id" CAMPAIGN="$campaign" PLAN_DIGEST="$plan_digest" \
  SOURCE_SHA="$source_sha" FLUX_SHA="$flux_sha" MEMBERS_JSON="$members_json" \
  MUTATES="$(yq -r '.mutates_cluster' - <<<"$campaign_entry")" \
  DISRUPTIVE="$(yq -r '.disruptive' - <<<"$campaign_entry")" \
  STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    yq --null-input --output-format json --indent 2 '{
      "schema_version": 1,
      "campaign_id": strenv(CAMPAIGN_ID),
      "campaign": strenv(CAMPAIGN),
      "plan_digest": strenv(PLAN_DIGEST),
      "source_sha": strenv(SOURCE_SHA),
      "flux_sha": strenv(FLUX_SHA),
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
    printf "TEST_CAMPAIGN_CONFIRM='resume-publish:%s' mise exec -- just test campaign-resume %s\n" \
      "$campaign_id" "$campaign_id"
  fi
}

# Invoked directly and through the EXIT trap below.
# shellcheck disable=SC2329
cleanup_campaign() {
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
  local entry command latest_published placement current_node current_ip

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
  if [[ "$command" == *'<node>'* || "$command" == *'<ip>'* ]]; then
    placement="$(derive_plex_placement)"
    read -r current_node current_ip <<<"$placement"
    command="${command//<node>/$current_node}"
    command="${command//<ip>/$current_ip}"
    echo "Plex reboot target resolved immediately before disruption: $current_node ($current_ip)."
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
    TEST_RESULTS_ROOT="$results_root" \
    TEST_PUBLISH_RESULT_FILE="$result_file" \
    TEST_REPORT_REQUIRE_AUTHORITATIVE=true \
    TEST_REPORT_PUBLISH_CONFIRM="publish:test-report:$run_id" \
    KUBECONFIG="$kubeconfig" \
      "$publish_bin" "$run_id" || publish_exit="$?"
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
  local command_exit result cleanup recovery

  command="$(resolve_member_command "$suite_id")" || return 20
  run_id_file="$(dirname "$manifest")/${suite_id}.run-id"
  publish_result_file="$(dirname "$manifest")/${suite_id}.publish.json"
  log_file="$(dirname "$manifest")/logs/${suite_id}.log"
  rm -f "$run_id_file" "$publish_result_file"

  echo
  echo "=== campaign $campaign: $suite_id ==="
  command_exit=0
  TEST_RUN_ID_FILE="$run_id_file" \
  TEST_RESULTS_ROOT="$results_root" \
  TEST_KUBECONFIG="$kubeconfig" \
  KUBECONFIG="$kubeconfig" \
    bash -o pipefail -c "$command" 2>&1 | tee "$log_file" ||
    command_exit="${PIPESTATUS[0]}"

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
  result="$(yq -r '.result' "$run_dir/summary.json")"
  cleanup="$(yq -r '.phases.cleanup.status // "not-required"' "$run_dir/summary.json")"
  recovery="$(yq -r '.phases.recovery.status // "not-required"' "$run_dir/summary.json")"
  append_run "$suite_id" "$run_id" "$result" "$cleanup" "$recovery"

  if ! require_campaign_lease; then
    update_publish "$run_id" not-published-lease-lost
    return 25
  fi
  if ! require_source_snapshot "$source_sha" "$flux_sha"; then
    update_publish "$run_id" not-published-source-drift
    return 23
  fi
  if ! publish_run "$run_id" "$publish_result_file"; then
    require_source_snapshot "$source_sha" "$flux_sha" || return 23
    return 22
  fi

  if [[ "$result" == 'failed' ]]; then
    overall_failed=true
    case "$(yq -r '.metadata.tier' - <<<"$(catalog_entry_by_id "$catalog" "$suite_id")")" in
      offline|smoke) gate_failed=true ;;
    esac
  fi
  [[ "$result" != 'broken' ]] || return 20
  [[ "$cleanup" == 'passed' || "$cleanup" == 'not-required' ]] || return 20
  [[ "$recovery" == 'passed' || "$recovery" == 'not-required' ]] || return 20
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
      *)
        finish_manifest broken broken "unexpected-member-status-$member_status"
        return 2
        ;;
    esac
  done < <(catalog_campaign_ids "$catalog" "$campaign")

  if [[ "$overall_failed" == 'true' ]]; then
    finish_manifest completed failed
    return 1
  fi
  finish_manifest completed passed
  return 0
}

prepare_new_campaign() {
  local state confirmation

  campaign="$requested"
  catalog_campaign_entry "$catalog" "$campaign" >/dev/null
  [[ "$test_mode" == 'true' ]] || scripts/test/validate-catalog.sh "$catalog" >/dev/null
  plan_digest="$(catalog_campaign_digest "$catalog" "$campaign")"
  state="$(source_state)"
  read -r source_sha flux_sha <<<"$state"
  [[ "$source_sha" =~ ^[0-9a-f]{40}$ && "$flux_sha" =~ ^[0-9a-f]{40}$ ]] || {
    echo 'Campaign source check did not return two full Git SHAs.' >&2
    exit 1
  }
  confirmation="$(expected_confirmation)"
  if [[ "$action" == 'plan' ]]; then
    print_plan
    exit 0
  fi
  [[ "${TEST_CAMPAIGN_CONFIRM:-}" == "$confirmation" ]] || {
    echo "Refusing campaign $campaign." >&2
    echo "Run 'mise exec -- just test campaign-plan $campaign' and use its exact confirmation." >&2
    exit 1
  }
  initialize_manifest
}

prepare_resume() {
  local state current_digest status current_source current_flux

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
  [[ "${TEST_CAMPAIGN_CONFIRM:-}" == "resume-publish:$campaign_id" ]] || {
    echo "Set TEST_CAMPAIGN_CONFIRM='resume-publish:$campaign_id' to resume." >&2
    exit 1
  }
  status="$(yq -r '.status' "$manifest")"
  [[ "$status" == 'publish-failed' ]] || {
    echo "Campaign $campaign_id is not resumable (status=$status)." >&2
    exit 1
  }
  campaign="$(yq -r '.campaign' "$manifest")"
  source_sha="$(yq -r '.source_sha' "$manifest")"
  flux_sha="$(yq -r '.flux_sha' "$manifest")"
  plan_digest="$(yq -r '.plan_digest' "$manifest")"
  current_digest="$(catalog_campaign_digest "$catalog" "$campaign")"
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
  [[ "$current_source" == "$source_sha" && "$current_flux" == "$flux_sha" ]] || {
    echo 'Campaign source is stale and cannot be resumed.' >&2
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
  plan|run) prepare_new_campaign ;;
  resume) prepare_resume ;;
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
if [[ "$action" == 'resume' ]]; then
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
