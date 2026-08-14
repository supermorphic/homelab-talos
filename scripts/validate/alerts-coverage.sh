#!/usr/bin/env bash
set -euo pipefail

# Every alert defined anywhere in the tree must be asserted by name in a promtool fixture.
# File-level association is not enough: media-alerts already has a fixture, so a new
# untested alert added to it would pass a per-file check while never having its PromQL run.
# Tracking individual alert names is what makes this an invariant rather than a formality.
mapfile -t rule_files < <(
  rg --files kubernetes/apps | rg '\.yaml$' \
    | xargs rg -l '^kind: PrometheusRule' 2>/dev/null | sort
)
[[ "${#rule_files[@]}" -gt 0 ]] || {
  echo 'No PrometheusRule files found; the discovery glob is wrong.' >&2
  exit 1
}

# -N suppresses the `---` document separators yq emits between input files. Without it
# every run would carry a bogus "---" alert name that can never be covered.
mapfile -t defined < <(
  yq -N -r '.spec.groups[].rules[] | select(has("alert")) | .alert' "${rule_files[@]}" \
    | rg -v '^\s*$' | sort -u
)
mapfile -t asserted < <(
  rg --no-filename '^\s*alertname:\s*' tests/prometheus \
    | sed 's/.*alertname:[[:space:]]*//' | tr -d '"' | rg -v '^\s*$' | sort -u
)
[[ "${#defined[@]}" -gt 0 ]] || { echo 'No alerts found; the discovery glob is wrong.' >&2; exit 1; }

mapfile -t uncovered < <(comm -23 \
  <(printf '%s\n' "${defined[@]}") <(printf '%s\n' "${asserted[@]}"))

if [[ "${#uncovered[@]}" -gt 0 ]]; then
  echo 'These alerts have no promtool assertion:' >&2
  printf '  %s\n' "${uncovered[@]}" >&2
  echo 'Add a case to the matching tests/prometheus/<domain>-alerts_test.yaml.' >&2
  exit 1
fi

echo "Alert coverage: all ${#defined[@]} alerts are asserted by name in promtool fixtures."
