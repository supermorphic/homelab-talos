#!/usr/bin/env bash
set -euo pipefail

state_file="${FAKE_TEST_LEASE_STATE:?}"
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
    [[ -f "$state_file" ]] || exit 1
    cat "$state_file"
    ;;
  create)
    [[ ! -f "$state_file" ]] || exit 1
    input="$(cat)"
    yq --output-format json '.metadata.resourceVersion = "1"' \
      <<<"$input" >"$state_file"
    ;;
  replace)
    [[ -f "$state_file" ]] || exit 1
    input="$(cat)"
    existing_version="$(yq -r '.metadata.resourceVersion' "$state_file")"
    input_version="$(yq -r '.metadata.resourceVersion' - <<<"$input")"
    [[ "$input_version" == "$existing_version" ]]
    NEXT_VERSION="$((existing_version + 1))" \
      yq --output-format json \
        '.metadata.resourceVersion = strenv(NEXT_VERSION)' \
        <<<"$input" >"${state_file}.next"
    mv "${state_file}.next" "$state_file"
    ;;
  config)
    printf 'fixture-cluster'
    ;;
  *)
    echo "Unexpected fake Lease kubectl invocation: $*" >&2
    exit 2
    ;;
esac
