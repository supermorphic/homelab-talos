#!/usr/bin/env bash
# Generate and serve one local Allure report until the operator presses Ctrl+C.
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: open-allure-report.sh <run-id|latest>' >&2
  exit 2
}

repo_root="$(git rev-parse --show-toplevel)"
results_root="${TEST_RESULTS_ROOT:-.test-results}"
reports_root="${TEST_REPORTS_ROOT:-.test-reports}"
[[ "$results_root" == /* ]] || results_root="$repo_root/$results_root"
[[ "$reports_root" == /* ]] || reports_root="$repo_root/$reports_root"
requested="$1"

if [[ "$requested" == 'latest' ]]; then
  run_id="$(uv run --locked --no-dev python scripts/test/allure_report.py latest \
    --results-root "$results_root")"
else
  run_id="$requested"
fi

scripts/test/generate-allure-report.sh "$run_id"
allure open "$reports_root/$run_id/awesome"
