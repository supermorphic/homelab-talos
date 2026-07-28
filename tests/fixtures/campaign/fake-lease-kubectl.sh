#!/usr/bin/env bash
set -euo pipefail

operation=''
for argument in "$@"; do
  case "$argument" in
    get|config)
      operation="$argument"
      break
      ;;
  esac
done
case "$operation" in
  get)
    cat "${CAMPAIGN_TEST_LEASE_STATE:?}"
    ;;
  config)
    printf 'fixture-cluster'
    ;;
  *)
    echo "Unexpected fake Lease kubectl invocation: $*" >&2
    exit 2
    ;;
esac
