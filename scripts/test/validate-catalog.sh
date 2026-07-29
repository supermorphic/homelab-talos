#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
source scripts/test/lib/catalog.sh
require_bash

catalog="${1:-tests/catalog.yaml}"
[[ -f "$catalog" ]] || {
  echo "Missing test catalog: $catalog" >&2
  exit 1
}

yq -e '
  .schema_version == 2 and
  (.suites | type == "!!seq") and
  (.suites | length > 0) and
  ((.executions.ci | type) == "!!seq") and
  (.executions.ci | length > 0) and
  (.campaigns | type == "!!map") and
  (.campaigns | length > 0)
' \
  "$catalog" >/dev/null || {
  echo 'Test catalog must have schema_version=2 plus suites, executions.ci, and campaigns.' >&2
  exit 1
}

duplicate_ids="$(yq -r '.suites[].metadata.id' "$catalog" | LC_ALL=C sort | uniq -d)"
[[ -z "$duplicate_ids" ]] || {
  echo "Duplicate test catalog IDs: $duplicate_ids" >&2
  exit 1
}

duplicate_dispatches="$(
  yq -r '.suites[] | select(has("dispatch")) |
    [.metadata.tier, .metadata.target, (.metadata.scenario // "<none>")] | join("|")' "$catalog" |
    LC_ALL=C sort | uniq -d
)"
[[ -z "$duplicate_dispatches" ]] || {
  echo "Duplicate test dispatch tuples: $duplicate_dispatches" >&2
  exit 1
}

suite_count="$(yq -r '.suites | length' "$catalog")"
for ((index = 0; index < suite_count; index++)); do
  entry="$(yq -o=json -I=0 ".suites[$index]" "$catalog")"
  id="$(yq -r '.metadata.id' - <<<"$entry")"

  [[ "$id" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || {
    echo "Catalog entry $index has invalid id '$id'." >&2
    exit 1
  }

  for field in source framework suite tier target scope intent execution_owner; do
    value="$(FIELD="$field" yq -r '.metadata[strenv(FIELD)] // ""' - <<<"$entry")"
    [[ -n "$value" ]] || {
      echo "Catalog entry $id is missing non-empty $field." >&2
      exit 1
    }
  done

  source_name="$(yq -r '.metadata.source' - <<<"$entry")"
  framework="$(yq -r '.metadata.framework' - <<<"$entry")"
  tier="$(yq -r '.metadata.tier' - <<<"$entry")"
  scope="$(yq -r '.metadata.scope' - <<<"$entry")"
  intent="$(yq -r '.metadata.intent' - <<<"$entry")"
  target="$(yq -r '.metadata.target' - <<<"$entry")"
  owner="$(yq -r '.metadata.execution_owner' - <<<"$entry")"
  strategy="$(yq -r '.native_results.strategy // ""' - <<<"$entry")"
  confirmation_type="$(yq -r '.confirmation.type // ""' - <<<"$entry")"
  mutates="$(yq -r '.metadata.mutates_cluster' - <<<"$entry")"
  implementation="$(yq -r '.runner.implementation // ""' - <<<"$entry")"
  command="$(yq -r '.runner.command // ""' - <<<"$entry")"

  [[ "$source_name" =~ ^(validation|verification|test|chainsaw|diagnostics|probe|sonobuoy)$ ]] || {
    echo "Catalog entry $id has invalid source '$source_name'." >&2
    exit 1
  }
  [[ "$framework" =~ ^(just|bash|python|chainsaw|sonobuoy|conftest|kubeconform|mixed)$ ]] || {
    echo "Catalog entry $id has invalid framework '$framework'." >&2
    exit 1
  }
  [[ "$tier" =~ ^(offline|verification|smoke|integration|e2e|resilience|diagnostics|measurement|conformance)$ ]] || {
    echo "Catalog entry $id has invalid tier '$tier'." >&2
    exit 1
  }
  [[ "$scope" =~ ^(repository|cluster|system|network|storage|application)$ ]] || {
    echo "Catalog entry $id has invalid scope '$scope'." >&2
    exit 1
  }
  [[ "$intent" =~ ^(regression|acceptance|feature|resilience|diagnostic|measurement|conformance)$ ]] || {
    echo "Catalog entry $id has invalid intent '$intent'." >&2
    exit 1
  }
  [[ "$target" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || {
    echo "Catalog entry $id has invalid target '$target'." >&2
    exit 1
  }
  [[ "$owner" == 'shared' || "$owner" == 'human' ]] || {
    echo "Catalog entry $id has invalid execution_owner '$owner'." >&2
    exit 1
  }
  [[ "$strategy" =~ ^(aggregate|wrapper-junit|native-junit|chainsaw-junit-step|sonobuoy-junit)$ ]] || {
    echo "Catalog entry $id has invalid native result strategy '$strategy'." >&2
    exit 1
  }
  [[ "$mutates" == 'true' || "$mutates" == 'false' ]] || {
    echo "Catalog entry $id must set mutates_cluster to a boolean." >&2
    exit 1
  }
  [[ "$confirmation_type" =~ ^(none|command|exact)$ ]] || {
    echo "Catalog entry $id has invalid confirmation type '$confirmation_type'." >&2
    exit 1
  }
  if [[ "$mutates" == 'true' && "$confirmation_type" == 'none' ]]; then
    echo "Mutating catalog entry $id must declare command or exact confirmation." >&2
    exit 1
  fi
  if [[ "$confirmation_type" == 'exact' ]]; then
    variable="$(yq -r '.confirmation.variable // ""' - <<<"$entry")"
    expected="$(yq -r '.confirmation.expected // ""' - <<<"$entry")"
    [[ "$variable" =~ ^[A-Z][A-Z0-9_]+$ && -n "$expected" ]] || {
      echo "Exact-confirmation entry $id needs a variable name and expected shape." >&2
      exit 1
    }
    [[ "$command" == *"$variable=$expected"* ]] || {
      echo "Exact-confirmation entry $id command does not expose its declared guard." >&2
      exit 1
    }
  else
    yq -e '.confirmation.variable == null and .confirmation.expected == null' \
      - <<<"$entry" >/dev/null || {
      echo "Non-exact entry $id must not declare confirmation variable/value metadata." >&2
      exit 1
    }
  fi
  [[ "$command" == *'mise exec -- just '* ]] || {
    echo "Catalog entry $id must expose a pinned mise + just command." >&2
    exit 1
  }
  [[ "$command" =~ ^([A-Z][A-Z0-9_]*=[a-zA-Z0-9._:/\<\>-]+[[:space:]]+)*mise[[:space:]]exec[[:space:]]--[[:space:]]just[[:space:]][a-zA-Z0-9_.-]+([[:space:]][a-zA-Z0-9._:/\<\>-]+)*$ ]] || {
    echo "Catalog entry $id runner command is not a safe literal mise + just invocation." >&2
    exit 1
  }
  [[ -e "$implementation" ]] || {
    echo "Catalog entry $id points to missing implementation '$implementation'." >&2
    exit 1
  }

  scenario_type="$(yq -r '.metadata.scenario | type' - <<<"$entry")"
  [[ "$scenario_type" == '!!null' || "$scenario_type" == '!!str' ]] || {
    echo "Catalog entry $id scenario must be a string or null." >&2
    exit 1
  }
  scenario="$(yq -r '.metadata.scenario // ""' - <<<"$entry")"
  [[ -z "$scenario" || "$scenario" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || {
    echo "Catalog entry $id has invalid scenario '$scenario'." >&2
    exit 1
  }

  if yq -e 'has("dispatch")' - <<<"$entry" >/dev/null 2>&1; then
    mode="$(yq -r '.dispatch.mode // ""' - <<<"$entry")"
    path="$(yq -r '.dispatch.path // ""' - <<<"$entry")"
    [[ "$mode" == 'chainsaw' || "$mode" == 'diagnostics' || "$mode" == 'direct' ]] || {
      echo "Catalog entry $id has invalid dispatch mode '$mode'." >&2
      exit 1
    }
    [[ -n "$path" && "$path" != /* && "$path" != *'..'* && -e "$path" ]] || {
      echo "Catalog entry $id has unsafe or missing dispatch path '$path'." >&2
      exit 1
    }
    if [[ "$mode" == 'chainsaw' ]]; then
      selector="$(yq -r '.dispatch.selector // ""' - <<<"$entry")"
      [[ "$path" == tests/chainsaw/* && "$selector" =~ ^homelab-talos/suite=[a-z0-9-]+$ ]] || {
        echo "Chainsaw entry $id has an invalid path or selector." >&2
        exit 1
      }
      matching_tests=0
      selector_value="${selector#*=}"
      while IFS= read -r test_file; do
        if [[ "$(yq -r '.metadata.labels."homelab-talos/suite"' "$test_file")" == "$selector_value" ]]; then
          matching_tests=$((matching_tests + 1))
        fi
      done < <(find "$path" -type f -name 'chainsaw-test.yaml' -print | LC_ALL=C sort)
      [[ "$matching_tests" -gt 0 ]] || {
        echo "Chainsaw entry $id selects no test documents." >&2
        exit 1
      }
    elif [[ "$mode" == 'direct' ]]; then
      runtime="$(yq -r '.dispatch.runtime // ""' - <<<"$entry")"
      [[ "$runtime" == 'bash' || "$runtime" == 'uv-python' ]] || {
        echo "Direct entry $id has unsupported runtime '$runtime'." >&2
        exit 1
      }
      if [[ "$runtime" == 'bash' ]]; then
        [[ "$framework" == 'bash' && -x "$path" ]] || {
          echo "Direct Bash entry $id must name an executable Bash implementation." >&2
          exit 1
        }
      else
        [[ "$framework" == 'python' && "$path" == *.py ]] || {
          echo "Direct Python entry $id must name a Python implementation." >&2
          exit 1
        }
      fi
      [[ "$path" == scripts/test/scenarios/* || "$path" == tests/probes/* ]] || {
        echo "Direct entry $id must use an allowlisted scenario/probe path." >&2
        exit 1
      }
      yq -e '(.dispatch.args | type) == "!!seq" and
        ([.dispatch.args[] | select(type != "!!str")] | length) == 0 and
        .dispatch.selector == null' - <<<"$entry" >/dev/null || {
        echo "Direct entry $id must use a string argument vector and no selector." >&2
        exit 1
      }
    fi
  fi
done

expected_campaign_names=$'conformance-certified\nconformance-quick\ne2e\nfull\nintegration\nprobes\nresilience\nsmoke\nstandard\nvalidation\nverification\nweekly'
actual_campaign_names="$(catalog_campaign_names "$catalog" | LC_ALL=C sort)"
[[ "$actual_campaign_names" == "$expected_campaign_names" ]] || {
  echo 'Test catalog campaign names differ from the supported public interface.' >&2
  diff -u <(printf '%s\n' "$expected_campaign_names") \
    <(printf '%s\n' "$actual_campaign_names") >&2 || true
  exit 1
}

while IFS= read -r campaign; do
  [[ -n "$campaign" ]] || continue
  campaign_entry="$(catalog_campaign_entry "$catalog" "$campaign")"
  yq -e '
    (.description | type == "!!str" and length > 0) and
    (.mutates_cluster | type == "!!bool") and
    (.disruptive | type == "!!bool") and
    ((.members // []) | type == "!!seq") and
    ((.includes // []) | type == "!!seq") and
    (((.members // []) | length) + ((.includes // []) | length) > 0) and
    ([.members[]? | select(type != "!!str")] | length == 0) and
    ([.includes[]? | select(type != "!!str")] | length == 0) and
    ((.coverage // []) | type == "!!seq") and
    ([.coverage[]? | select(type != "!!str")] | length == 0)
  ' - <<<"$campaign_entry" >/dev/null || {
    echo "Campaign $campaign has invalid metadata or member/include arrays." >&2
    exit 1
  }

  while IFS= read -r member; do
    [[ -n "$member" ]] || continue
    catalog_entry_by_id "$catalog" "$member" >/dev/null || {
      echo "Campaign $campaign references an unknown suite: $member" >&2
      exit 1
    }
  done < <(yq -r '.members[]?, .coverage[]?' - <<<"$campaign_entry")
  while IFS= read -r include; do
    [[ -n "$include" ]] || continue
    catalog_campaign_entry "$catalog" "$include" >/dev/null || {
      echo "Campaign $campaign includes an unknown campaign: $include" >&2
      exit 1
    }
  done < <(yq -r '.includes[]?' - <<<"$campaign_entry")

  resolved_ids="$(catalog_campaign_ids "$catalog" "$campaign")" || exit "$?"
  duplicate_members="$(printf '%s\n' "$resolved_ids" | LC_ALL=C sort | uniq -d)"
  [[ -z "$duplicate_members" ]] || {
    echo "Campaign $campaign resolves duplicate suite IDs: $duplicate_members" >&2
    exit 1
  }

  derived_mutates=false
  derived_disruptive=false
  while IFS= read -r member; do
    [[ -n "$member" ]] || continue
    member_entry="$(catalog_entry_by_id "$catalog" "$member")"
    [[ "$(yq -r '.metadata.mutates_cluster' - <<<"$member_entry")" != 'true' ]] ||
      derived_mutates=true
    [[ "$(yq -r '.metadata.tier' - <<<"$member_entry")" != 'resilience' ]] ||
      derived_disruptive=true
  done <<<"$resolved_ids"
  [[ "$(yq -r '.mutates_cluster' - <<<"$campaign_entry")" == "$derived_mutates" ]] || {
    echo "Campaign $campaign mutates_cluster does not match its resolved members." >&2
    exit 1
  }
  [[ "$(yq -r '.disruptive' - <<<"$campaign_entry")" == "$derived_disruptive" ]] || {
    echo "Campaign $campaign disruptive does not match its resolved members." >&2
    exit 1
  }
done < <(catalog_campaign_names "$catalog")

assert_exact_lines() {
  local description="$1"
  local expected="$2"
  local actual="$3"
  [[ "$actual" == "$expected" ]] || {
    echo "$description differs from the explicit catalog contract." >&2
    diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
    return 1
  }
}

assert_campaign_covers_tier() {
  local campaign="$1"
  local tier="$2"
  local field="${3:-members}"
  local expected actual
  expected="$(TIER="$tier" CAMPAIGN="$campaign" yq -r '
    .suites[] |
    select(.metadata.tier == strenv(TIER)) |
    select(
      strenv(CAMPAIGN) != "smoke" or
      .metadata.id != "chainsaw.smoke.cluster.diagnostics-self-test"
    ) |
    .metadata.id
  ' "$catalog" | LC_ALL=C sort)"
  actual="$(CAMPAIGN="$campaign" FIELD="$field" yq -r \
    '.campaigns[strenv(CAMPAIGN)][strenv(FIELD)][]' "$catalog" | LC_ALL=C sort)"
  assert_exact_lines "Campaign $campaign $field" "$expected" "$actual"
}

assert_campaign_covers_tier verification verification
assert_campaign_covers_tier integration integration
assert_campaign_covers_tier e2e e2e
assert_campaign_covers_tier resilience resilience
assert_campaign_covers_tier probes measurement
assert_campaign_covers_tier smoke smoke coverage

conformance_expected="$(yq -r \
  '.suites[] | select(.metadata.tier == "conformance") | .metadata.id' \
  "$catalog" | LC_ALL=C sort)"
conformance_actual="$(
  {
    catalog_campaign_ids "$catalog" conformance-quick
    catalog_campaign_ids "$catalog" conformance-certified
  } | LC_ALL=C sort
)"
assert_exact_lines 'Conformance campaigns' "$conformance_expected" "$conformance_actual"

[[ "$(yq -r '.campaigns.validation.members | join("\n")' "$catalog")" == \
  'validation.ci' ]] || {
  echo 'Campaign validation must execute only the aggregate validation.ci suite.' >&2
  exit 1
}
[[ "$(yq -r '.campaigns.standard.includes | join("\n")' "$catalog")" == \
  $'validation\nsmoke\ne2e\nconformance-quick' ]] || {
  echo 'Campaign standard must be validation, smoke, e2e, then conformance-quick.' >&2
  exit 1
}
[[ "$(yq -r '.campaigns.weekly.includes | join("\n")' "$catalog")" == \
  $'standard\nverification\nintegration\nprobes\nresilience' ]] || {
  echo 'Campaign weekly has an unexpected composition.' >&2
  exit 1
}
[[ "$(yq -r '.campaigns.full.includes | join("\n")' "$catalog")" == \
  $'weekly\nconformance-certified' ]] || {
  echo 'Campaign full must extend weekly with certified conformance.' >&2
  exit 1
}
expected_smoke=$'chainsaw.smoke.cluster.default\nchainsaw.smoke.media.qbittorrent\nchainsaw.smoke.media.qbit-manage\nchainsaw.smoke.platform.all'
actual_smoke="$(yq -r '.campaigns.smoke.members[]' "$catalog")"
assert_exact_lines 'Campaign smoke aggregate ordering' "$expected_smoke" "$actual_smoke"
expected_resilience=$'test.flux-restart\ntest.portainer-persistence\nchainsaw.resilience.qbittorrent-vpn-disconnect\nchainsaw.resilience.qbittorrent-pod-recreation\nchainsaw.resilience.plex-cross-node-reschedule\nchainsaw.resilience.test-reports-persistence\nchainsaw.resilience.tailscale-subnet-router-replica-recovery\ntest.resilience.plex-node-reboot'
actual_resilience="$(yq -r '.campaigns.resilience.members[]' "$catalog")"
assert_exact_lines 'Campaign resilience ordering' \
  "$expected_resilience" "$actual_resilience"

duplicate_ci_ids="$(yq -r '.executions.ci[]' "$catalog" | LC_ALL=C sort | uniq -d)"
[[ -z "$duplicate_ci_ids" ]] || {
  echo "Duplicate executions.ci suite IDs: $duplicate_ci_ids" >&2
  exit 1
}
ci_command_count="$(yq -r '.executions.ci | length' "$catalog")"
while IFS= read -r ci_id; do
  matches="$(
    CI_ID="$ci_id" yq -r \
      '[.suites[] |
        select(.metadata.id == strenv(CI_ID) and
          .metadata.source == "validation" and
          .runner.command != "mise exec -- just ci")] | length' \
      "$catalog"
  )"
  [[ "$matches" -eq 1 ]] || {
    echo "CI execution ID must resolve to one child validation suite: $ci_id" >&2
    exit 1
  }
done < <(yq -r '.executions.ci[]' "$catalog")
catalog_ci_count="$(
  yq -r '[.suites[] |
    select(.metadata.source == "validation" and
      .runner.command != "mise exec -- just ci")] | length' "$catalog"
)"
[[ "$catalog_ci_count" -eq "$ci_command_count" ]] || {
  echo "Validation catalog/executions.ci count differs: catalog=$catalog_ci_count ci=$ci_command_count." >&2
  exit 1
}

while IFS= read -r test_file; do
  test_dir="$(dirname "$test_file")"
  TEST_DIR="$test_dir" yq -e \
    '.suites[] | select(.metadata.framework == "chainsaw" and .dispatch.path == strenv(TEST_DIR))' \
    "$catalog" >/dev/null || {
    echo "Chainsaw document $test_file has no exact catalog dispatch entry." >&2
    exit 1
  }
done < <(find tests/chainsaw -type f -name 'chainsaw-test.yaml' -print | LC_ALL=C sort)

printf 'Test catalog passed validation: suites=%s.\n' "$suite_count"
