#!/usr/bin/env bash
set -euo pipefail

source scripts/test/lib/results.sh

repo_root="$(git rev-parse --show-toplevel)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/homelab-allure-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
results_dir="$fixture_root/allure-results"
attachments_dir="$fixture_root/attachments"
report_dir="$fixture_root/report"
mkdir -p "$results_dir" "$attachments_dir"

declare -a fragments=()
for result in passed failed broken skipped; do
  fragment="$fixture_root/$result.xml"
  write_result_case_junit \
    "$fragment" \
    validation.allure-fixture \
    "$result" \
    "$result" \
    0
  fragments+=("$fragment")
done
merge_junit_reports \
  "$results_dir/junit.xml" \
  validation.allure-fixture \
  "${fragments[@]}"
printf '%s\n' 'sanitized Allure attachment fixture' >"$attachments_dir/fixture.log"
cp "$repo_root/tests/config/allurerc.yaml" "$fixture_root/allurerc.yaml"

(
  cd "$fixture_root"
  allure awesome \
    --config "$fixture_root/allurerc.yaml" \
    --output "$report_dir" \
    allure-results >/dev/null
)

[[ -f "$report_dir/index.html" ]]
yq -e '
  .stats.total == 4 and
  .stats.passed == 1 and
  .stats.failed == 1 and
  .stats.broken == 1 and
  .stats.skipped == 1
' "$report_dir/summary.json" >/dev/null
yq -e '
  (.attachments | length) == 1 and
  .attachments[0].name == "fixture.log"
' "$report_dir/widgets/globals.json" >/dev/null

echo 'Allure Awesome passed/failed/broken/skipped fixture passed.'
