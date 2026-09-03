#!/usr/bin/env bash
# Dispatch a registered live suite to either Chainsaw or a direct, typed backend.
set -euo pipefail

source scripts/lib/common.sh
source scripts/test/lib/catalog.sh
require_bash

[[ "$#" -ge 2 && "$#" -le 3 ]] || {
  echo 'Usage: run-live-suite.sh <smoke|integration|e2e|resilience|diagnostics> <registered-target> [registered-scenario]' >&2
  exit 2
}

tier="$1"
target="$2"
scenario="${3:-}"
node_target=''
if [[ "$tier" == 'resilience' && "$target" == 'node-abrupt-loss' ]]; then
  node_target="$scenario"
  scenario=''
  case "$node_target" in
    nuc1|nuc2|nuc3) ;;
    *)
      echo 'node-abrupt-loss requires one target: nuc1, nuc2, or nuc3.' >&2
      exit 2
      ;;
  esac
fi
catalog='tests/catalog.yaml'
entry_json="$(catalog_dispatch_entry "$catalog" "$tier" "$target" "$scenario")" || exit "$?"
mode="$(yq -r '.dispatch.mode' - <<<"$entry_json")"

if [[ "$mode" == 'chainsaw' || "$mode" == 'diagnostics' ]]; then
  exec scripts/test/run-chainsaw.sh "$tier" "$target" ${scenario:+"$scenario"}
fi

[[ "$mode" == 'direct' ]] || {
  echo "Unsupported live-suite dispatch mode: $mode" >&2
  exit 2
}

suite_id="$(yq -r '.metadata.id' - <<<"$entry_json")"
runtime="$(yq -r '.dispatch.runtime' - <<<"$entry_json")"
path="$(yq -r '.dispatch.path' - <<<"$entry_json")"
mapfile -t dispatch_args < <(yq -r '.dispatch.args[]?' - <<<"$entry_json")
if [[ -n "$node_target" ]]; then
  dispatch_args=("$node_target" "${dispatch_args[@]}")
fi

case "$runtime" in
  bash)
    exec scripts/test/run-catalog-suite.sh "$suite_id" -- \
      "$path" "${dispatch_args[@]}"
    ;;
  uv-python)
    exec scripts/test/run-catalog-suite.sh "$suite_id" -- \
      uv run --locked --no-dev python "$path" "${dispatch_args[@]}"
    ;;
  *)
    echo "Unsupported direct runtime '$runtime' for $suite_id." >&2
    exit 2
    ;;
esac
