#!/usr/bin/env bash
set -euo pipefail

[[ -z "${CAMPAIGN_TEST_LEASE_CALLS:-}" ]] || printf '%s\n' "$*" >>"$CAMPAIGN_TEST_LEASE_CALLS"

operation=''
for argument in "$@"; do
  case "$argument" in
    get|create|replace|config)
      operation="$argument"
      break
      ;;
  esac
done
case "$operation" in
  get)
    [[ -f "${CAMPAIGN_TEST_LEASE_STATE:?}" ]] || exit 1
    cat "${CAMPAIGN_TEST_LEASE_STATE:?}"
    ;;
  create)
    [[ ! -f "${CAMPAIGN_TEST_LEASE_STATE:?}" ]] || exit 1
    yq --output-format json '.metadata.resourceVersion = "1"' \
      >"$CAMPAIGN_TEST_LEASE_STATE"
    ;;
  replace)
    [[ -f "${CAMPAIGN_TEST_LEASE_STATE:?}" ]] || exit 1
    input="$(cat)"
    existing_version="$(yq -r '.metadata.resourceVersion' "$CAMPAIGN_TEST_LEASE_STATE")"
    input_version="$(yq -r '.metadata.resourceVersion' - <<<"$input")"
    [[ "$input_version" == "$existing_version" ]] || exit 1
    NEXT_VERSION="$((existing_version + 1))" \
      yq --output-format json \
        '.metadata.resourceVersion = strenv(NEXT_VERSION)' \
        <<<"$input" >"$CAMPAIGN_TEST_LEASE_STATE.next"
    mv "$CAMPAIGN_TEST_LEASE_STATE.next" "$CAMPAIGN_TEST_LEASE_STATE"
    ;;
  config)
    printf 'fixture-cluster'
    ;;
  *)
    echo "Unexpected fake Lease kubectl invocation: $*" >&2
    exit 2
    ;;
esac
