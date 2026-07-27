#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
source scripts/test/lib/results.sh
require_bash

run_dir="${1:-}"
[[ -n "$run_dir" && -d "$run_dir" ]] || {
  echo 'Usage: validate-run.sh <canonical-run-directory>' >&2
  exit 2
}
[[ ! -L "$run_dir" ]] || {
  echo "Run directory must not be a symlink: $run_dir" >&2
  exit 1
}

run_id="$(basename "$run_dir")"
max_evidence_bytes="${TEST_RESULT_MAX_FILE_BYTES:-104857600}"
[[ "$max_evidence_bytes" =~ ^[1-9][0-9]*$ ]] || {
  echo 'TEST_RESULT_MAX_FILE_BYTES must be a positive integer.' >&2
  exit 2
}
[[ "$run_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}-(agent|github-actions|operator)-[0-9a-f]{8}$ ]] || {
  echo "Run directory has an invalid canonical ID: $run_id" >&2
  exit 1
}

expected_root=$'diagnostics\nenvironment.json\nevidence.json\njunit.xml\nlogs\nsummary.json'
actual_root="$(
  find "$run_dir" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort
)"
[[ "$actual_root" == "$expected_root" ]] || {
  echo "Run root does not match the canonical six-entry structure: $run_dir" >&2
  diff -u <(printf '%s\n' "$expected_root") <(printf '%s\n' "$actual_root") >&2 || true
  exit 1
}

for directory in logs diagnostics; do
  [[ -d "$run_dir/$directory" && ! -L "$run_dir/$directory" ]] || {
    echo "Canonical path must be a real directory: $directory" >&2
    exit 1
  }
done
for document in junit.xml summary.json environment.json evidence.json; do
  [[ -f "$run_dir/$document" && ! -L "$run_dir/$document" ]] || {
    echo "Canonical path must be a regular file: $document" >&2
    exit 1
  }
done

RUN_ID="$run_id" yq -e '
  .schema_version == 1 and
  .run_id == strenv(RUN_ID) and
  ([.source, .framework, .suite, .tier, .target, .scope, .intent, .git_sha] |
    map(. != null and . != "") | all) and
  (.scenario == null or ((.scenario | type) == "!!str" and .scenario != "")) and
  (.execution_origin | test("^(agent|github-actions|operator)$")) and
  (.start | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
  (.end | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
  ((.duration_seconds | type) == "!!int" and .duration_seconds >= 0) and
  (.result | test("^(passed|failed|broken|skipped)$")) and
  (.junit | [.tests, .failures, .errors, .skipped, .passed] |
    map(type == "!!int" and . >= 0) | all) and
  .junit.tests > 0 and
  .junit.tests == (.junit.failures + .junit.errors + .junit.skipped + .junit.passed) and
  (
    (.result == "passed" and .junit.failures == 0 and .junit.errors == 0) or
    (.result == "failed" and .junit.failures > 0 and .junit.errors == 0) or
    (.result == "broken" and .junit.errors > 0) or
    (.result == "skipped" and .junit.failures == 0 and .junit.errors == 0 and
      .junit.passed == 0 and .junit.skipped > 0)
  ) and
  ((.suites | type) == "!!seq" and (.suites | length) > 0) and
  ([.suites[] |
    (.id != null and .id != "") and
    (.result | test("^(passed|failed|broken|skipped)$")) and
    ([.tests, .failures, .errors, .skipped] |
      map((type == "!!int") and (. >= 0)) | all)
  ] | all) and
  ((.phases | type) == "!!map")
' "$run_dir/summary.json" >/dev/null || {
  echo "summary.json violates canonical schema v1: $run_dir" >&2
  exit 1
}

RUN_ID="$run_id" yq -e '
  .schema_version == 1 and
  .run_id == strenv(RUN_ID) and
  (.execution_origin | test("^(agent|github-actions|operator)$")) and
  (.start | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
  (.end | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
  (.git.sha != null and .git.sha != "") and
  ((.git.branch | type) == "!!str") and
  ((.git.dirty | type) == "!!bool") and
  (.host.os != null and .host.os != "") and
  (.host.architecture != null and .host.architecture != "") and
  ((.tools | type) == "!!map") and
  ((.cluster | type) == "!!map") and
  (.suite.id != null and .suite.id != "") and
  (.confirmation_variable == null or
    (.confirmation_variable | test("^[A-Z][A-Z0-9_]+$")))
' "$run_dir/environment.json" >/dev/null || {
  echo "environment.json violates canonical schema v1: $run_dir" >&2
  exit 1
}

summary_origin="$(yq -r '.execution_origin' "$run_dir/summary.json")"
environment_origin="$(yq -r '.execution_origin' "$run_dir/environment.json")"
id_origin="${run_id#*-*-}"
id_origin="${id_origin%-*}"
[[ "$summary_origin" == "$environment_origin" && "$summary_origin" == "$id_origin" ]] || {
  echo 'Execution origin differs between run ID, summary, and environment.' >&2
  exit 1
}
[[ "$(yq -r '.git_sha' "$run_dir/summary.json")" == \
  "$(yq -r '.git.sha' "$run_dir/environment.json")" ]] || {
  echo 'Git SHA differs between summary and environment.' >&2
  exit 1
}
summary_suite_count="$(yq -r '.suites | length' "$run_dir/summary.json")"
if [[ "$summary_suite_count" -eq 1 ]]; then
  [[ "$(yq -r '.suites[0].id' "$run_dir/summary.json")" == \
    "$(yq -r '.suite.id' "$run_dir/environment.json")" ]] || {
    echo 'Suite ID differs between summary and environment.' >&2
    exit 1
  }
fi
for field in source framework suite tier target scenario scope intent; do
  summary_value="$(FIELD="$field" yq -o=json -I=0 '.[strenv(FIELD)]' \
    "$run_dir/summary.json")"
  environment_value="$(FIELD="$field" yq -o=json -I=0 '.suite[strenv(FIELD)]' \
    "$run_dir/environment.json")"
  [[ "$summary_value" == "$environment_value" ]] || {
    echo "Suite metadata '$field' differs between summary and environment." >&2
    exit 1
  }
done

counts="$(read_junit_counts "$run_dir/junit.xml")" || {
  echo "junit.xml is invalid or contains no test cases: $run_dir" >&2
  exit 1
}
read -r tests failures errors skipped passed <<<"$counts"
summary_counts="$(yq -r \
  '[.junit.tests, .junit.failures, .junit.errors, .junit.skipped, .junit.passed] | join(" ")' \
  "$run_dir/summary.json")"
[[ "$summary_counts" == "$tests $failures $errors $skipped $passed" ]] || {
  echo 'JUnit counts differ from summary.json.' >&2
  exit 1
}
duplicate_suite_ids="$(yq -r '.suites[].id' "$run_dir/summary.json" |
  LC_ALL=C sort | uniq -d)"
[[ -z "$duplicate_suite_ids" ]] || {
  echo "summary.json contains duplicate suite IDs: $duplicate_suite_ids" >&2
  exit 1
}
suite_tests=0
suite_failures=0
suite_errors=0
suite_skipped=0
while IFS=$'\t' read -r suite_test suite_failure suite_error suite_skip; do
  suite_tests=$((suite_tests + suite_test))
  suite_failures=$((suite_failures + suite_failure))
  suite_errors=$((suite_errors + suite_error))
  suite_skipped=$((suite_skipped + suite_skip))
done < <(yq -r '.suites[] |
  [.tests, .failures, .errors, .skipped] | @tsv' "$run_dir/summary.json")
[[ "$suite_tests $suite_failures $suite_errors $suite_skipped" == \
  "$tests $failures $errors $skipped" ]] || {
  echo 'Per-suite counts do not sum to the canonical JUnit totals.' >&2
  exit 1
}

RUN_ID="$run_id" yq -e '
  .schema_version == 1 and
  .run_id == strenv(RUN_ID) and
  ((.artifacts | type) == "!!seq") and
  ([.artifacts[].path] | unique | length) == (.artifacts | length)
' "$run_dir/evidence.json" >/dev/null || {
  echo "evidence.json violates canonical schema v1: $run_dir" >&2
  exit 1
}

temporary="$(mktemp -d "${TMPDIR:-/tmp}/homelab-run-validation.XXXXXX")"
trap 'rm -rf -- "$temporary"' EXIT
indexed="$temporary/indexed"
actual="$temporary/actual"
: >"$indexed"
while IFS= read -r relative; do
  [[ "$relative" =~ ^(logs|diagnostics)/ &&
    ! "$relative" =~ (^|/)\.\.(/|$) &&
    "$relative" != /* ]] || {
    echo "Unsafe evidence path: $relative" >&2
    exit 1
  }
  [[ -f "$run_dir/$relative" && ! -L "$run_dir/$relative" ]] || {
    echo "Evidence path is missing, not regular, or a symlink: $relative" >&2
    exit 1
  }
  evidence_size="$(wc -c <"$run_dir/$relative" | tr -d '[:space:]')"
  [[ "$evidence_size" -le "$max_evidence_bytes" ]] || {
    echo "Evidence file exceeds ${max_evidence_bytes} bytes: $relative" >&2
    exit 1
  }
  printf '%s\n' "$relative" >>"$indexed"
done < <(yq -r '.artifacts[].path' "$run_dir/evidence.json")
LC_ALL=C sort -o "$indexed" "$indexed"
find "$run_dir/logs" "$run_dir/diagnostics" -type l -print -quit | rg -q . && {
  echo 'Evidence directories must not contain symlinks.' >&2
  exit 1
}
: >"$actual"
while IFS= read -r file; do
  printf '%s\n' "${file#"$run_dir"/}" >>"$actual"
done < <(find "$run_dir/logs" "$run_dir/diagnostics" -type f -print)
LC_ALL=C sort -o "$actual" "$actual"
diff -u "$actual" "$indexed" >/dev/null || {
  echo 'evidence.json must index every logs/ and diagnostics/ file exactly once.' >&2
  diff -u "$actual" "$indexed" >&2 || true
  exit 1
}

printf 'Canonical test run passed validation: %s.\n' "$run_id"
