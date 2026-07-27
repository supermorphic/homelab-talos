#!/usr/bin/env bash

catalog_dispatch_entry() {
  local catalog="$1"
  local tier="$2"
  local target="$3"
  local scenario="$4"
  local matches count

  matches="$(
    TEST_TIER="$tier" TEST_TARGET="$target" TEST_SCENARIO="$scenario" \
      yq -o=json -I=0 '[
        .suites[] |
        select(has("dispatch")) |
        select(.metadata.tier == strenv(TEST_TIER)) |
        select(.metadata.target == strenv(TEST_TARGET)) |
        select(
          (strenv(TEST_SCENARIO) == "" and .metadata.scenario == null) or
          .metadata.scenario == strenv(TEST_SCENARIO)
        )
      ]' "$catalog"
  )"
  count="$(yq -r 'length' - <<<"$matches")"
  [[ "$count" -eq 1 ]] || {
    echo "Unknown or ambiguous test dispatch: tier=$tier target=$target scenario=${scenario:-<none>}." >&2
    return 2
  }
  yq -o=json -I=0 '.[0]' - <<<"$matches"
}
