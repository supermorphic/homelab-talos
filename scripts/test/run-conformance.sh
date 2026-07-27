#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: run-conformance.sh <kubeconfig>' >&2
  exit 2
}
kubeconfig="$1"
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
  scripts/test/run-sonobuoy.sh "$mode" "$kubeconfig"
