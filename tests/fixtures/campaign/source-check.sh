#!/usr/bin/env bash
set -euo pipefail

state_file="${CAMPAIGN_TEST_SOURCE_STATE:?}"
count=0
[[ ! -f "$state_file" ]] || count="$(cat "$state_file")"
count=$((count + 1))
printf '%s\n' "$count" >"$state_file"

source_sha='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
if [[ -n "${CAMPAIGN_TEST_DRIFT_AT:-}" &&
  "$count" -ge "$CAMPAIGN_TEST_DRIFT_AT" ]]; then
  source_sha='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
fi
printf '%s %s\n' "$source_sha" "$source_sha"
