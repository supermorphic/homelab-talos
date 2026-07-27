#!/usr/bin/env bash
# Validate and generate one static Allure Awesome report from a canonical run.
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: generate-allure-report.sh <run-id|latest>' >&2
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
[[ "$run_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}-(agent|github-actions|operator)-[0-9a-f]{8}$ ]] || {
  echo "Invalid canonical run ID: $run_id" >&2
  exit 2
}

run_dir="$results_root/$run_id"
scripts/test/validate-run.sh "$run_dir"

workspace="$(mktemp -d "${TMPDIR:-/tmp}/homelab-allure-stage.XXXXXX")"
mkdir -p "$reports_root"
staged_report="$(mktemp -d "$reports_root/.${run_id}.XXXXXX")"
cleanup() {
  rm -rf -- "$workspace" "$staged_report"
}
trap cleanup EXIT

uv run --locked --no-dev python scripts/test/allure_report.py stage \
  --results-root "$results_root" \
  --run-id "$run_id" \
  --workspace "$workspace"
cp "$repo_root/tests/config/allurerc.yaml" "$workspace/allurerc.yaml"

# Allure resolves global attachment globs from the process working directory.
(
  cd "$workspace"
  allure awesome \
    --config "$workspace/allurerc.yaml" \
    --output "$staged_report/awesome" \
    --report-name "Homelab Talos · $run_id" \
    allure-results
)

[[ -f "$staged_report/awesome/index.html" ]] || {
  echo 'Allure did not generate the expected static entrypoint.' >&2
  exit 1
}

final_report="$reports_root/$run_id"
if [[ -e "$final_report" ]]; then
  [[ -d "$final_report" && ! -L "$final_report" ]] || {
    echo "Refusing to replace unsafe report path: $final_report" >&2
    exit 1
  }
  rm -rf -- "$final_report"
fi
mv "$staged_report" "$final_report"

echo "Allure report generated: $final_report/awesome/index.html"
