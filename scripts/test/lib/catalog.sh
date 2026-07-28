#!/usr/bin/env bash

catalog_entry_by_id() {
  local catalog="$1"
  local suite_id="$2"
  local matches count

  matches="$(
    SUITE_ID="$suite_id" yq -o=json -I=0 \
      '[.suites[] | select(.metadata.id == strenv(SUITE_ID))]' "$catalog"
  )"
  count="$(yq -r 'length' - <<<"$matches")"
  [[ "$count" -eq 1 ]] || {
    echo "Unknown or ambiguous catalog suite ID: $suite_id." >&2
    return 2
  }
  yq -o=json -I=0 '.[0]' - <<<"$matches"
}

catalog_execution_ids() {
  local catalog="$1"
  local execution="$2"
  EXECUTION="$execution" yq -r \
    '.executions[strenv(EXECUTION)][]' "$catalog"
}

catalog_campaign_names() {
  local catalog="$1"
  yq -r '.campaigns | keys | .[]' "$catalog"
}

catalog_campaign_entry() {
  local catalog="$1"
  local campaign="$2"
  local entry

  entry="$(
    CAMPAIGN="$campaign" yq -o=json -I=0 \
      '.campaigns[strenv(CAMPAIGN)] // null' "$catalog"
  )"
  [[ "$entry" != 'null' ]] || {
    echo "Unknown test campaign: $campaign." >&2
    return 2
  }
  printf '%s\n' "$entry"
}

_catalog_campaign_ids() {
  local catalog="$1"
  local campaign="$2"
  local ancestry="$3"
  local entry include member

  [[ "|$ancestry|" != *"|$campaign|"* ]] || {
    echo "Test campaign include cycle: ${ancestry//|/ -> } -> $campaign." >&2
    return 2
  }
  entry="$(catalog_campaign_entry "$catalog" "$campaign")" || return "$?"
  while IFS= read -r include; do
    [[ -n "$include" ]] || continue
    _catalog_campaign_ids "$catalog" "$include" "${ancestry:+$ancestry|}$campaign" ||
      return "$?"
  done < <(yq -r '.includes[]?' - <<<"$entry")
  while IFS= read -r member; do
    [[ -n "$member" ]] || continue
    printf '%s\n' "$member"
  done < <(yq -r '.members[]?' - <<<"$entry")
}

catalog_campaign_ids() {
  local catalog="$1"
  local campaign="$2"
  _catalog_campaign_ids "$catalog" "$campaign" ''
}

catalog_campaign_digest() {
  local catalog="$1"
  local campaign="$2"
  local resolved

  resolved="$(catalog_campaign_ids "$catalog" "$campaign")" || return "$?"
  printf '%s\n' "$resolved" | sha256sum | awk '{print $1}'
}

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
