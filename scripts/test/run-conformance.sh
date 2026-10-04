#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -le 1 ]] || {
  echo 'Usage: run-conformance.sh [selected-invocation-kubeconfig]' >&2
  exit 2
}
if [[ "$#" -eq 1 && "$1" != '@test-kubeconfig@' ]]; then
  [[ -n "${TEST_ACCESS_CONFIG:-}" && "$1" == "$TEST_ACCESS_CONFIG" ]] || {
    echo 'Conformance selects credentials from the catalog; an unbound config is not accepted.' >&2
    exit 2
  }
fi
mode="${MODE:-quick}"
case "$mode" in
  quick) suite_id='conformance.quick' ;;
  certified) suite_id='conformance.certified' ;;
  *)
    echo "MODE must be 'quick' (default) or 'certified', got '$mode'." >&2
    exit 2
    ;;
esac
exec scripts/test/run-catalog-suite.sh "$suite_id" -- \
  scripts/test/run-sonobuoy.sh "$mode" '@test-kubeconfig@'
