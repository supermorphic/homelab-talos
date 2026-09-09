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
  scoped-nested)
    suite_id='verification.metrics-server'
    command=(bash -c '"${CAMPAIGN_TEST_REPO_ROOT:?}/scripts/test/run-catalog-suite.sh" verification.cilium -- true')
    ;;
  acceptance-pass)
    suite_id='verification.metrics-server'
    command=(true)
    ;;
  acceptance-fail)
    suite_id='verification.cilium'
    command=(bash -c 'exit 7')
    ;;
  acceptance-operator)
    suite_id='test.ntfy-publish'
    command=(true)
    ;;
  acceptance-shared)
    suite_id='test.nocodb-local-integration'
    command=(true)
    ;;
  acceptance-validation)
    suite_id='validation.ci'
    command=(true)
    ;;
  acceptance-source-mismatch)
    suite_id='verification.metrics-server'
    command=(true)
    ;;
  acceptance-broken)
    suite_id='verification.metrics-server'
    command=("${CAMPAIGN_TEST_REPO_ROOT:?}/tests/fixtures/campaign/broken-child.sh")
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
if [[ "$target" == acceptance-source-mismatch ]]; then
  "${CAMPAIGN_TEST_REPO_ROOT:?}/scripts/test/run-catalog-suite.sh" \
    "$suite_id" -- "${command[@]}"
  run_id="$(tr -d '\r\n' <"${TEST_RUN_ID_FILE:?}")"
  SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    yq -i '.git.sha = strenv(SHA)' \
    "${TEST_RESULTS_ROOT:?}/$run_id/environment.json"
  exit 0
fi
exec "${CAMPAIGN_TEST_REPO_ROOT:?}/scripts/test/run-catalog-suite.sh" \
  "$suite_id" -- "${command[@]}"
