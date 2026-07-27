#!/usr/bin/env bash

resolve_execution_origin() {
  local origin="${TEST_EXECUTION_ORIGIN:-}"
  if [[ -z "$origin" && "${GITHUB_ACTIONS:-false}" == 'true' ]]; then
    origin='github-actions'
  fi
  [[ -n "$origin" ]] || origin='operator'
  case "$origin" in
    agent|github-actions|operator) echo "$origin" ;;
    *)
      echo "Invalid TEST_EXECUTION_ORIGIN '$origin' (expected agent, github-actions, or operator)." >&2
      return 2
      ;;
  esac
}

resolve_git_branch() {
  local branch="${1:-}"
  [[ -n "$branch" ]] || branch="${GITHUB_HEAD_REF:-}"
  [[ -n "$branch" ]] || branch="${GITHUB_REF_NAME:-}"
  [[ -n "$branch" ]] || branch='detached'
  echo "$branch"
}

create_run_directory() {
  local results_root="$1"
  local origin="$2"
  local timestamp short_revision random_suffix run_id run_dir

  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  short_revision="$(git rev-parse --short=12 HEAD)"
  random_suffix="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  run_id="${timestamp}-${short_revision}-${origin}-${random_suffix}"
  run_dir="${results_root}/${run_id}"
  mkdir -p "$results_root"
  mkdir "$run_dir"
  mkdir "$run_dir/logs" "$run_dir/diagnostics"
  RUN_ID="$run_id" yq --null-input --output-format json '{
    "schema_version": 1,
    "run_id": strenv(RUN_ID),
    "artifacts": []
  }' >"$run_dir/evidence.json"
  echo "$run_dir"
}

write_environment() {
  local output_dir="$1"
  local run_id="$2"
  local entry_json="$3"
  local execution_origin="$4"
  local started_at="$5"
  local finished_at="$6"
  local namespace="$7"
  local kubeconfig="$8"
  local confirmation_variable="$9"
  local git_sha git_branch git_dirty host_os host_arch
  local chainsaw_version kubectl_version yq_version cluster_name cluster_version
  local flux_revision nodes version_json cluster_name_json cluster_version_json
  local flux_revision_json confirmation_json

  git_sha="$(git rev-parse HEAD)"
  git_branch="$(resolve_git_branch "$(git branch --show-current)")"
  git_dirty=false
  [[ -z "$(git status --porcelain)" ]] || git_dirty=true
  host_os="$(uname -s)"
  host_arch="$(uname -m)"
  chainsaw_version="$(chainsaw version 2>/dev/null | awk '/^Version:/ {print $2}' || true)"
  kubectl_version="$(kubectl version --client --output json 2>/dev/null |
    yq -r '.clientVersion.gitVersion // "unavailable"' || true)"
  yq_version="$(yq --version 2>/dev/null | awk '{print $NF}' || true)"
  [[ -n "$chainsaw_version" ]] || chainsaw_version='unavailable'
  [[ -n "$kubectl_version" ]] || kubectl_version='unavailable'
  [[ -n "$yq_version" ]] || yq_version='unavailable'

  cluster_name='unavailable'
  cluster_version='unavailable'
  flux_revision='unavailable'
  nodes=''
  if [[ -f "$kubeconfig" ]]; then
    cluster_name="$(kubectl --kubeconfig "$kubeconfig" config view --minify \
      --output jsonpath='{.clusters[0].name}' 2>/dev/null || true)"
    version_json="$(kubectl --kubeconfig "$kubeconfig" version --output json 2>/dev/null || true)"
    if [[ -n "$version_json" ]]; then
      cluster_version="$(yq -r '.serverVersion.gitVersion // "unavailable"' - <<<"$version_json")"
    fi
    flux_revision="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
      get gitrepository flux-system --output jsonpath='{.status.artifact.revision}' \
      2>/dev/null || true)"
    nodes="$(kubectl --kubeconfig "$kubeconfig" get nodes \
      --output jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
      2>/dev/null || true)"
  fi
  [[ -n "$cluster_name" ]] || cluster_name='unavailable'
  [[ -n "$flux_revision" ]] || flux_revision='unavailable'
  cluster_name_json='null'
  cluster_version_json='null'
  flux_revision_json='null'
  confirmation_json='null'
  if [[ "$cluster_name" != 'unavailable' ]]; then
    cluster_name_json="$(JSON_VALUE="$cluster_name" yq -n -o=json 'strenv(JSON_VALUE)')"
  fi
  if [[ "$cluster_version" != 'unavailable' ]]; then
    cluster_version_json="$(JSON_VALUE="$cluster_version" yq -n -o=json 'strenv(JSON_VALUE)')"
  fi
  if [[ "$flux_revision" != 'unavailable' ]]; then
    flux_revision_json="$(JSON_VALUE="$flux_revision" yq -n -o=json 'strenv(JSON_VALUE)')"
  fi
  if [[ "$confirmation_variable" != 'none' && "$confirmation_variable" != 'command' ]]; then
    confirmation_json="$(JSON_VALUE="$confirmation_variable" yq -n -o=json 'strenv(JSON_VALUE)')"
  fi

  RUN_ID="$run_id" \
  ENTRY_JSON="$entry_json" \
  EXECUTION_ORIGIN="$execution_origin" \
  STARTED_AT="$started_at" \
  FINISHED_AT="$finished_at" \
  GIT_SHA="$git_sha" \
  GIT_BRANCH="$git_branch" \
  GIT_DIRTY="$git_dirty" \
  HOST_OS="$host_os" \
  HOST_ARCH="$host_arch" \
  CHAINSAW_VERSION="$chainsaw_version" \
  KUBECTL_VERSION="$kubectl_version" \
  YQ_VERSION="$yq_version" \
  CLUSTER_NAME_JSON="$cluster_name_json" \
  CLUSTER_VERSION_JSON="$cluster_version_json" \
  FLUX_REVISION_JSON="$flux_revision_json" \
  CLUSTER_NODES="$nodes" \
  TEST_NAMESPACE="$namespace" \
  CONFIRMATION_JSON="$confirmation_json" \
    yq --null-input --output-format json '{
      "schema_version": 1,
      "run_id": strenv(RUN_ID),
      "execution_origin": strenv(EXECUTION_ORIGIN),
      "start": strenv(STARTED_AT),
      "end": strenv(FINISHED_AT),
      "git": {
        "sha": strenv(GIT_SHA),
        "branch": strenv(GIT_BRANCH),
        "dirty": strenv(GIT_DIRTY) == "true"
      },
      "host": {
        "os": strenv(HOST_OS),
        "architecture": strenv(HOST_ARCH)
      },
      "tools": {
        "chainsaw": strenv(CHAINSAW_VERSION),
        "kubectl": strenv(KUBECTL_VERSION),
        "yq": strenv(YQ_VERSION)
      },
      "cluster": {
        "name": (strenv(CLUSTER_NAME_JSON) | from_json),
        "kubernetes_version": (strenv(CLUSTER_VERSION_JSON) | from_json),
        "namespace": strenv(TEST_NAMESPACE),
        "flux_revision": (strenv(FLUX_REVISION_JSON) | from_json),
        "nodes": (strenv(CLUSTER_NODES) | split("\n") | map(select(. != ""))),
        "node": null,
        "pod_uid": null
      },
      "suite": (strenv(ENTRY_JSON) | from_json | .metadata),
      "confirmation_variable": (strenv(CONFIRMATION_JSON) | from_json)
    }' >"$output_dir/environment.json"
}

# Derive a state-changing run's recovery/cleanup status from recovery.json. Missing,
# unparseable, unfinished, or unknown values become not-classified.
recorded_recovery_status() {
  local run_dir="$1"
  local file="$run_dir/recovery.json"
  local status
  [[ -f "$file" ]] || { echo 'not-classified'; return; }
  status="$(yq -r '.status // "not-classified"' "$file" 2>/dev/null)" || {
    echo 'not-classified'
    return
  }
  case "$status" in
    passed|failed|not-required) echo "$status" ;;
    *) echo 'not-classified' ;;
  esac
}

recorded_phase_status() {
  local run_dir="$1"
  local phase="$2"
  local file="$run_dir/${phase}.json"
  local status
  [[ "$phase" == 'assertion' || "$phase" == 'external-dependency' ]] || {
    echo 'not-classified'
    return
  }
  [[ -f "$file" ]] || { echo 'not-classified'; return; }
  status="$(yq -r '.status // "not-classified"' "$file" 2>/dev/null)" || {
    echo 'not-classified'
    return
  }
  case "$status" in
    passed|failed|not-applicable|not-classified) echo "$status" ;;
    *) echo 'not-classified' ;;
  esac
}

read_junit_counts() {
  local junit_file="$1"
  local report_json tests failures errors skipped passed
  report_json="$(yq --input-format xml --output-format json '.' "$junit_file")" || return 1
  tests="$(yq -r \
    '[.. | select((type == "!!map") and has("testcase")) | .testcase] | flatten | length' \
    - <<<"$report_json")"
  failures="$(yq -r \
    '[.. | select((type == "!!map") and has("failure"))] | length' \
    - <<<"$report_json")"
  errors="$(yq -r \
    '[.. | select((type == "!!map") and has("error"))] | length' \
    - <<<"$report_json")"
  skipped="$(yq -r \
    '[.. | select((type == "!!map") and has("skipped"))] | length' \
    - <<<"$report_json")"
  for count in "$tests" "$failures" "$errors" "$skipped"; do
    [[ "$count" =~ ^[0-9]+$ ]] || return 1
  done
  passed=$((tests - failures - errors - skipped))
  [[ "$tests" -gt 0 && "$passed" -ge 0 ]] || return 1
  printf '%s %s %s %s %s\n' "$tests" "$failures" "$errors" "$skipped" "$passed"
}

write_single_case_junit() {
  local output_file="$1"
  local suite_name="$2"
  local case_name="$3"
  local result="$4"
  local duration="$5"
  local failures=0 errors=0 body=''
  case "$result" in
    passed) ;;
    failed)
      failures=1
      body='<failure message="diagnostic collection failed"/>'
      ;;
    broken)
      errors=1
      body='<error message="diagnostic harness failed"/>'
      ;;
    *) return 2 ;;
  esac
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<testsuites name="%s" tests="1" failures="%s" errors="%s" skipped="0" time="%s">\n' \
      "$suite_name" "$failures" "$errors" "$duration"
    printf '  <testsuite name="%s" tests="1" failures="%s" errors="%s" skipped="0" time="%s">\n' \
      "$suite_name" "$failures" "$errors" "$duration"
    printf '    <testcase classname="%s" name="%s" time="%s">%s</testcase>\n' \
      "$suite_name" "$case_name" "$duration" "$body"
    printf '  </testsuite>\n</testsuites>\n'
  } >"$output_file"
}

write_result_case_junit() {
  local output_file="$1"
  local suite_name="$2"
  local case_name="$3"
  local result="$4"
  local duration="$5"
  local failures=0 errors=0 skipped=0 body=''

  [[ "$suite_name" =~ ^[a-zA-Z0-9_.-]+$ ]] || return 2
  [[ "$case_name" =~ ^[a-zA-Z0-9_.:-]+$ ]] || return 2
  case "$result" in
    passed) ;;
    failed)
      failures=1
      body='<failure message="command assertion failed"/>'
      ;;
    broken)
      errors=1
      body='<error message="test harness failed"/>'
      ;;
    skipped)
      skipped=1
      body='<skipped message="not executed after fail-fast stop"/>'
      ;;
    *) return 2 ;;
  esac
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<testsuites name="%s" tests="1" failures="%s" errors="%s" skipped="%s" time="%s">\n' \
      "$suite_name" "$failures" "$errors" "$skipped" "$duration"
    printf '  <testsuite name="%s" tests="1" failures="%s" errors="%s" skipped="%s" time="%s">\n' \
      "$suite_name" "$failures" "$errors" "$skipped" "$duration"
    printf '    <testcase classname="%s" name="%s" time="%s">%s</testcase>\n' \
      "$suite_name" "$case_name" "$duration" "$body"
    printf '  </testsuite>\n</testsuites>\n'
  } >"$output_file"
}

merge_junit_reports() {
  local output_file="$1"
  local suite_name="$2"
  shift 2
  [[ "$#" -gt 0 ]] || return 2
  uv run --locked python scripts/test/junit_tools.py merge \
    --output "$output_file" \
    --suite "$suite_name" \
    "$@"
}

append_lifecycle_junit() {
  local junit_file="$1"
  local suite_id="$2"
  local external_dependency_status="$3"
  local cleanup_status="$4"
  local recovery_status="$5"
  local diagnostics_status="$6"
  local run_result="$7"
  local counts tests failures errors skipped _passed
  local fragment output phase name status body finalization_status
  local phase_lines='' phase_tests=0 phase_errors=0 phase_skipped=0

  [[ "$suite_id" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || return 2
  for status in "$external_dependency_status" "$cleanup_status" \
    "$recovery_status" "$diagnostics_status"; do
    [[ "$status" =~ ^(passed|failed|not-classified|not-applicable|not-required)$ ]] || {
      echo "Unsupported lifecycle status '$status'." >&2
      return 2
    }
  done
  [[ "$run_result" =~ ^(passed|failed|broken)$ ]] || return 2
  finalization_status='passed'
  [[ "$run_result" != 'broken' ]] || finalization_status='failed'
  for phase in \
    "external-dependency:$external_dependency_status" \
    "cleanup:$cleanup_status" \
    "recovery:$recovery_status" \
    "diagnostics:$diagnostics_status" \
    "finalization:$finalization_status"; do
    name="${phase%%:*}"
    status="${phase#*:}"
    body=''
    case "$status" in
      passed)
        ;;
      failed|not-classified)
        body="<error message=\"phase status: ${status}\"/>"
        phase_errors=$((phase_errors + 1))
        ;;
      not-applicable|not-required)
        body="<skipped message=\"phase status: ${status}\"/>"
        phase_skipped=$((phase_skipped + 1))
        ;;
    esac
    phase_lines+="$(printf \
      '    <testcase classname="%s.lifecycle" name="%s" time="0">%s</testcase>' \
      "$suite_id" "$name" "$body")"$'\n'
    phase_tests=$((phase_tests + 1))
  done

  counts="$(read_junit_counts "$junit_file")" || return 1
  read -r tests failures errors skipped _passed <<<"$counts"
  fragment="$(mktemp "${TMPDIR:-/tmp}/homelab-junit-fragment.XXXXXX")"
  output="$(mktemp "${TMPDIR:-/tmp}/homelab-junit-output.XXXXXX")"
  {
    printf '  <testsuite name="%s.lifecycle" tests="%s" failures="0"' \
      "$suite_id" "$phase_tests"
    printf ' errors="%s" skipped="%s" time="0">\n' "$phase_errors" "$phase_skipped"
    printf '%s' "$phase_lines"
    printf '  </testsuite>\n'
  } >"$fragment"

  tests=$((tests + phase_tests))
  errors=$((errors + phase_errors))
  skipped=$((skipped + phase_skipped))
  if ! awk \
    -v tests="$tests" \
    -v failures="$failures" \
    -v errors="$errors" \
    -v skipped="$skipped" '
      FNR == NR {
        fragment = fragment $0 ORS
        next
      }
      /<testsuites([ >])/ {
        line = $0
        attributes[1] = "tests"
        values[1] = tests
        attributes[2] = "failures"
        values[2] = failures
        attributes[3] = "errors"
        values[3] = errors
        attributes[4] = "skipped"
        values[4] = skipped
        for (field_index = 1; field_index <= 4; field_index++) {
          pattern = attributes[field_index] "=\"[^\"]*\""
          replacement = attributes[field_index] "=\"" values[field_index] "\""
          if (line ~ pattern) {
            sub(pattern, replacement, line)
          } else {
            sub(/>$/, " " replacement ">", line)
          }
        }
        print line
        next
      }
      /<\/testsuites>/ {
        printf "%s", fragment
      }
      { print }
    ' "$fragment" "$junit_file" >"$output"; then
    rm -f -- "$fragment" "$output"
    return 1
  fi
  if ! mv "$output" "$junit_file"; then
    rm -f -- "$fragment" "$output"
    return 1
  fi
  rm -f -- "$fragment"
}

classify_run_result() {
  local primary_exit_code="$1"
  local junit_status="$2"
  local diagnostics_status="$3"
  local cleanup_status="$4"
  if [[ "$junit_status" == 'invalid' || "$junit_status" == 'errors' ]]; then
    echo broken
  elif [[ "$diagnostics_status" != 'passed' ]]; then
    echo broken
  elif [[ "$cleanup_status" != 'passed' && "$cleanup_status" != 'not-required' ]]; then
    echo broken
  elif [[ "$junit_status" == 'failures' ]]; then
    echo failed
  elif [[ "$primary_exit_code" -ne 0 ]]; then
    echo broken
  else
    echo passed
  fi
}

write_summary() {
  local output_dir="$1"
  local run_id="$2"
  local entry_json="$3"
  local execution_origin="$4"
  local started_at="$5"
  local finished_at="$6"
  local duration_seconds="$7"
  local result="$8"
  local primary_exit_code="$9"
  local assertion_status="${10}"
  local diagnostics_status="${11}"
  local cleanup_status="${12}"
  local recovery_status="${13}"
  local external_dependency_status="${14}"
  local cluster_name="${15}"
  local counts tests failures errors skipped passed git_sha cluster_name_json

  counts="$(read_junit_counts "$output_dir/junit.xml")"
  read -r tests failures errors skipped passed <<<"$counts"
  git_sha="$(git rev-parse HEAD)"
  cluster_name_json='null'
  if [[ "$cluster_name" != 'unavailable' ]]; then
    cluster_name_json="$(JSON_VALUE="$cluster_name" yq -n -o=json 'strenv(JSON_VALUE)')"
  fi

  RUN_ID="$run_id" \
  ENTRY_JSON="$entry_json" \
  EXECUTION_ORIGIN="$execution_origin" \
  STARTED_AT="$started_at" \
  FINISHED_AT="$finished_at" \
  DURATION_SECONDS="$duration_seconds" \
  RUN_RESULT="$result" \
  PRIMARY_EXIT_CODE="$primary_exit_code" \
  ASSERTION_STATUS="$assertion_status" \
  DIAGNOSTICS_STATUS="$diagnostics_status" \
  CLEANUP_STATUS="$cleanup_status" \
  RECOVERY_STATUS="$recovery_status" \
  EXTERNAL_DEPENDENCY_STATUS="$external_dependency_status" \
  CLUSTER_NAME_JSON="$cluster_name_json" \
  TESTS="$tests" FAILURES="$failures" ERRORS="$errors" SKIPPED="$skipped" PASSED="$passed" \
  GIT_SHA="$git_sha" \
    yq --null-input --output-format json '{
      "schema_version": 1,
      "run_id": strenv(RUN_ID),
      "source": (strenv(ENTRY_JSON) | from_json | .metadata.source),
      "framework": (strenv(ENTRY_JSON) | from_json | .metadata.framework),
      "suite": (strenv(ENTRY_JSON) | from_json | .metadata.suite),
      "tier": (strenv(ENTRY_JSON) | from_json | .metadata.tier),
      "target": (strenv(ENTRY_JSON) | from_json | .metadata.target),
      "scenario": (strenv(ENTRY_JSON) | from_json | .metadata.scenario),
      "scope": (strenv(ENTRY_JSON) | from_json | .metadata.scope),
      "intent": (strenv(ENTRY_JSON) | from_json | .metadata.intent),
      "git_sha": strenv(GIT_SHA),
      "execution_origin": strenv(EXECUTION_ORIGIN),
      "cluster": (strenv(CLUSTER_NAME_JSON) | from_json),
      "node": null,
      "start": strenv(STARTED_AT),
      "end": strenv(FINISHED_AT),
      "duration_seconds": (strenv(DURATION_SECONDS) | tonumber),
      "result": strenv(RUN_RESULT),
      "junit": {
        "tests": (strenv(TESTS) | tonumber),
        "failures": (strenv(FAILURES) | tonumber),
        "errors": (strenv(ERRORS) | tonumber),
        "skipped": (strenv(SKIPPED) | tonumber),
        "passed": (strenv(PASSED) | tonumber)
      },
      "suites": [{
        "id": (strenv(ENTRY_JSON) | from_json | .metadata.id),
        "result": strenv(RUN_RESULT),
        "tests": (strenv(TESTS) | tonumber),
        "failures": (strenv(FAILURES) | tonumber),
        "errors": (strenv(ERRORS) | tonumber),
        "skipped": (strenv(SKIPPED) | tonumber)
      }],
      "phases": {
        "primary": {
          "status": strenv(RUN_RESULT),
          "exit_code": (strenv(PRIMARY_EXIT_CODE) | tonumber)
        },
        "assertion": {"status": strenv(ASSERTION_STATUS)},
        "external_dependency": {"status": strenv(EXTERNAL_DEPENDENCY_STATUS)},
        "cleanup": {"status": strenv(CLEANUP_STATUS)},
        "recovery": {"status": strenv(RECOVERY_STATUS)},
        "diagnostics": {"status": strenv(DIAGNOSTICS_STATUS)}
      }
    }' >"$output_dir/summary.json"
}

write_multi_summary() {
  local output_dir="$1"
  local run_id="$2"
  local entry_json="$3"
  local execution_origin="$4"
  local started_at="$5"
  local finished_at="$6"
  local duration_seconds="$7"
  local result="$8"
  local primary_exit_code="$9"
  local suites_json="${10}"
  local counts tests failures errors skipped passed git_sha assertion_status

  counts="$(read_junit_counts "$output_dir/junit.xml")"
  read -r tests failures errors skipped passed <<<"$counts"
  git_sha="$(git rev-parse HEAD)"
  assertion_status='not-classified'
  [[ "$result" != 'passed' ]] || assertion_status='passed'
  [[ "$result" != 'failed' ]] || assertion_status='failed'

  RUN_ID="$run_id" \
  ENTRY_JSON="$entry_json" \
  EXECUTION_ORIGIN="$execution_origin" \
  STARTED_AT="$started_at" \
  FINISHED_AT="$finished_at" \
  DURATION_SECONDS="$duration_seconds" \
  RUN_RESULT="$result" \
  ASSERTION_STATUS="$assertion_status" \
  PRIMARY_EXIT_CODE="$primary_exit_code" \
  SUITES_JSON="$suites_json" \
  TESTS="$tests" FAILURES="$failures" ERRORS="$errors" SKIPPED="$skipped" PASSED="$passed" \
  GIT_SHA="$git_sha" \
    yq --null-input --output-format json '{
      "schema_version": 1,
      "run_id": strenv(RUN_ID),
      "source": (strenv(ENTRY_JSON) | from_json | .metadata.source),
      "framework": (strenv(ENTRY_JSON) | from_json | .metadata.framework),
      "suite": (strenv(ENTRY_JSON) | from_json | .metadata.suite),
      "tier": (strenv(ENTRY_JSON) | from_json | .metadata.tier),
      "target": (strenv(ENTRY_JSON) | from_json | .metadata.target),
      "scenario": (strenv(ENTRY_JSON) | from_json | .metadata.scenario),
      "scope": (strenv(ENTRY_JSON) | from_json | .metadata.scope),
      "intent": (strenv(ENTRY_JSON) | from_json | .metadata.intent),
      "git_sha": strenv(GIT_SHA),
      "execution_origin": strenv(EXECUTION_ORIGIN),
      "cluster": null,
      "node": null,
      "start": strenv(STARTED_AT),
      "end": strenv(FINISHED_AT),
      "duration_seconds": (strenv(DURATION_SECONDS) | tonumber),
      "result": strenv(RUN_RESULT),
      "junit": {
        "tests": (strenv(TESTS) | tonumber),
        "failures": (strenv(FAILURES) | tonumber),
        "errors": (strenv(ERRORS) | tonumber),
        "skipped": (strenv(SKIPPED) | tonumber),
        "passed": (strenv(PASSED) | tonumber)
      },
      "suites": (strenv(SUITES_JSON) | from_json),
      "phases": {
        "primary": {
          "status": strenv(RUN_RESULT),
          "exit_code": (strenv(PRIMARY_EXIT_CODE) | tonumber)
        },
        "assertion": {"status": strenv(ASSERTION_STATUS)},
        "external_dependency": {"status": "not-applicable"},
        "cleanup": {"status": "not-required"},
        "recovery": {"status": "not-required"},
        "diagnostics": {"status": "passed"}
      }
    }' >"$output_dir/summary.json"
}

normalize_native_artifacts() {
  local run_dir="$1"
  local run_id="$2"
  local phase_file
  mkdir -p "$run_dir/diagnostics/phases" "$run_dir/diagnostics/manifests" \
    "$run_dir/diagnostics/timelines"

  if [[ -f "$run_dir/evidence.json" ]] &&
    ! RUN_ID="$run_id" yq -e \
      '.schema_version == 1 and .run_id == strenv(RUN_ID) and (.artifacts | type == "!!seq")' \
      "$run_dir/evidence.json" >/dev/null 2>&1; then
    mv "$run_dir/evidence.json" "$run_dir/diagnostics/scenario-evidence.json"
  fi

  for phase_file in recovery assertion external-dependency cleanup; do
    if [[ -f "$run_dir/${phase_file}.json" ]]; then
      mv "$run_dir/${phase_file}.json" "$run_dir/diagnostics/phases/${phase_file}.json"
    fi
  done
  if [[ -d "$run_dir/manifests" ]]; then
    find "$run_dir/manifests" -mindepth 1 -maxdepth 1 -exec mv {} "$run_dir/diagnostics/manifests/" \;
    rmdir "$run_dir/manifests"
  fi
}

write_evidence_index() {
  local run_dir="$1"
  local run_id="$2"
  local paths=''
  local relative file

  if find "$run_dir/logs" "$run_dir/diagnostics" -type l -print -quit | rg -q .; then
    echo 'Evidence directories must not contain symlinks.' >&2
    return 1
  fi

  while IFS= read -r file; do
    relative="${file#"$run_dir"/}"
    [[ -n "$relative" && "$relative" != /* && "$relative" != *'..'* ]] || {
      echo "Unsafe evidence path: $relative" >&2
      return 1
    }
    paths+="${paths:+$'\n'}$relative"
  done < <(find "$run_dir/logs" "$run_dir/diagnostics" -type f -print | LC_ALL=C sort)

  RUN_ID="$run_id" EVIDENCE_PATHS="$paths" \
    yq --null-input --output-format json '{
      "schema_version": 1,
      "run_id": strenv(RUN_ID),
      "artifacts": (
        strenv(EVIDENCE_PATHS) |
        split("\n") |
        map(select(. != "") | {"path": .})
      )
    }' >"$run_dir/evidence.json"
}

result_exit_code() {
  local primary_exit_code="$1"
  local run_result="$2"
  if [[ "$primary_exit_code" -ne 0 ]]; then
    echo "$primary_exit_code"
  elif [[ "$run_result" == 'passed' ]]; then
    echo 0
  else
    echo 1
  fi
}
