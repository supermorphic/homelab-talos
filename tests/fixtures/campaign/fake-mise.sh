#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 5 && "$1" == 'exec' && "$2" == '--' &&
  "$3" == 'just' && "$4" == 'fixture' ]] || {
  echo "Unexpected fake mise invocation: $*" >&2
  exit 2
}

target="$5"
case "$target" in
  pass)
    suite_id='verification.metrics-server'
    command=(true)
    ;;
  fail)
    suite_id='verification.cilium'
    command=(bash -c 'exit 7')
    ;;
  scoped-pass)
    suite_id='verification.metrics-server'
    command=(bash -c 'echo SCOPED_CHILD_OUTPUT')
    ;;
  scoped-fail)
    suite_id='verification.cilium'
    command=(bash -c 'exit 7')
    ;;
  scoped-exit-mismatch)
    suite_id='verification.metrics-server'
    command=(true)
    ;;
  scoped-result-mismatch)
    suite_id='verification.metrics-server'
    command=(bash -c 'exit 7')
    ;;
  *)
    echo "Unknown fixture target: $target" >&2
    exit 2
    ;;
esac

printf '%s\n' "$target" >>"${CAMPAIGN_TEST_COMMAND_CALLS:?}"
if [[ "$target" == scoped-exit-mismatch ]]; then
  "${CAMPAIGN_TEST_REPO_ROOT:?}/scripts/test/run-catalog-suite.sh" \
    "$suite_id" -- "${command[@]}"
  exit 7
fi
if [[ "$target" == scoped-result-mismatch ]]; then
  "${CAMPAIGN_TEST_REPO_ROOT:?}/scripts/test/run-catalog-suite.sh" \
    "$suite_id" -- "${command[@]}" || true
  exit 0
fi
exec "${CAMPAIGN_TEST_REPO_ROOT:?}/scripts/test/run-catalog-suite.sh" \
  "$suite_id" -- "${command[@]}"
