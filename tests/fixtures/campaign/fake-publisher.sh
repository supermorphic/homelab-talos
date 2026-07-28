#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]]
run_id="$1"
printf '%s\n' "$run_id" >>"${CAMPAIGN_TEST_PUBLISH_CALLS:?}"
if [[ -e "${CAMPAIGN_TEST_PUBLISH_FAILURE_MARKER:-/nonexistent}" ]]; then
  echo 'Fixture publication failure.' >&2
  exit 1
fi

output="${TEST_PUBLISH_RESULT_FILE:?}"
RUN_ID="$run_id" yq --null-input --output-format json '{
  "schema_version": 1,
  "run_id": strenv(RUN_ID),
  "status": "published",
  "url": ("https://fixture.invalid/reports/" + strenv(RUN_ID) + "/awesome/")
}' >"$output"
