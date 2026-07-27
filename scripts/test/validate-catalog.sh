#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
require_bash

catalog="${1:-tests/catalog.yaml}"
[[ -f "$catalog" ]] || {
  echo "Missing test catalog: $catalog" >&2
  exit 1
}

yq -e '.schema_version == 1 and (.suites | type == "!!seq") and (.suites | length > 0)' \
  "$catalog" >/dev/null || {
  echo 'Test catalog must have schema_version=1 and a non-empty suites array.' >&2
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
  [[ "$framework" =~ ^(just|bash|chainsaw|sonobuoy)$ ]] || {
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
  [[ "$strategy" =~ ^(aggregate|wrapper-junit|chainsaw-junit-step|sonobuoy-junit)$ ]] || {
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
    [[ "$mode" == 'chainsaw' || "$mode" == 'diagnostics' ]] || {
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
    fi
  fi
done

ci_commands="$(
  awk '
    $0 == "ci:" { in_ci = 1; next }
    in_ci && /^[^[:space:]#]/ { exit }
    in_ci && /^[[:space:]]+just / {
      sub(/^[[:space:]]+just /, "mise exec -- just ")
      print
    }
  ' .justfile
)"
[[ -n "$ci_commands" ]] || {
  echo 'Could not discover the just ci command list.' >&2
  exit 1
}
ci_command_count=0
while IFS= read -r ci_command; do
  [[ -n "$ci_command" ]] || continue
  ci_command_count=$((ci_command_count + 1))
  matches="$(
    CI_COMMAND="$ci_command" yq -r \
      '[.suites[] |
        select(.metadata.source == "validation" and
          .runner.command == strenv(CI_COMMAND))] | length' \
      "$catalog"
  )"
  [[ "$matches" -eq 1 ]] || {
    echo "CI command must have exactly one validation catalog entry: $ci_command" >&2
    exit 1
  }
done <<<"$ci_commands"
catalog_ci_count="$(
  yq -r '[.suites[] |
    select(.metadata.source == "validation" and
      .runner.command != "mise exec -- just ci")] | length' "$catalog"
)"
[[ "$catalog_ci_count" -eq "$ci_command_count" ]] || {
  echo "Validation catalog/just ci count differs: catalog=$catalog_ci_count ci=$ci_command_count." >&2
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
