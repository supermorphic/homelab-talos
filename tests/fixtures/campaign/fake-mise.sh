#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == 'exec -- just talos readerconfig' ]]; then
  exec "${CAMPAIGN_TEST_REPO_ROOT:?}/tests/fixtures/test-access/fake-mise.sh" "$@"
fi

[[ -z "${TEST_CAMPAIGN_CONFIRM+x}" ]] || {
  echo 'Campaign confirmation leaked into a child suite.' >&2
  exit 2
}

[[ "$#" -eq 5 && "$1" == 'exec' && "$2" == '--' &&
  "$3" == 'just' && "$4" == 'fixture' ]] || {
  echo "Unexpected fake mise invocation: $*" >&2
  exit 2
}

[[ -z "${TEST_KUBECONFIG:-}" && -z "${TEST_ACCESS_CONFIG:-}" && "$KUBECONFIG" == /dev/null ]] || {
  echo 'Campaign passed orchestration credentials to a suite.' >&2
  exit 2
}
[[ -z "${TEST_ACCESS_PURPOSE_CONFIG+x}" && -z "${observer_kubeconfig+x}" &&
   -z "${coordinator_kubeconfig+x}" ]]
target="$5"
case "$target" in
  pass)
    suite_id='verification.metrics-server'
    command=(true)
    ;;
  attended)
    suite_id='verification.metrics-server'
    command=(python "${CAMPAIGN_TEST_ATTENDED_BACKEND:?}")
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
    # Expansion belongs to the child shell.
    # shellcheck disable=SC2016
    command=(bash -c '"${CAMPAIGN_TEST_REPO_ROOT:?}/scripts/test/run-catalog-suite.sh" verification.flux -- true')
    ;;
  mutating-pass)
    suite_id='test.cilium-connectivity'
    command=(true)
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
  acceptance-agent)
    # Run the real wrapper and scenario up to its missing-authority boundary.
    # The record coordinator must leave this suite's Lease ownership to the scenario.
    unset OPENBAO_OPERATOR_KUBECONFIG
    suite_id='test.agent-credentials'
    command=(uv run --locked python -m scripts.test.scenarios.agent_credentials)
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

case "$suite_id" in
  verification.cilium|test.cilium-connectivity|test.agent-credentials)
    [[ "${TALOSCONFIG:-}" == "$CAMPAIGN_TEST_REPO_ROOT/.talos/config" ]] || {
      echo 'Campaign did not select its declared Talos reader path.' >&2
      exit 2
    }
    ;;
  *)
    [[ -z "${TALOSCONFIG:-}" ]] || {
      echo 'Campaign passed Talos access without a declared prerequisite.' >&2
      exit 2
    }
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
