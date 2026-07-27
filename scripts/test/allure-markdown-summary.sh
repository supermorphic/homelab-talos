#!/usr/bin/env bash
# Render one canonical run as a GitHub-compatible Markdown summary.
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: allure-markdown-summary.sh <run-id|latest>' >&2
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
scripts/test/validate-run.sh "$results_root/$run_id" >/dev/null

report_generated=false
[[ -f "$reports_root/$run_id/awesome/index.html" ]] && report_generated=true
uv run --locked --no-dev python scripts/test/allure_report.py markdown \
  --results-root "$results_root" \
  --run-id "$run_id" \
  --report-generated "$report_generated"
