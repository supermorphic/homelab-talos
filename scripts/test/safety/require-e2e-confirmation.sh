#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: require-e2e-confirmation.sh <registered-target>' >&2
  exit 2
}

target="$1"
expected="e2e:${target}"

[[ "${CLUSTER_E2E_CONFIRM:-}" == "$expected" ]] || {
  echo "Refusing state-changing E2E target ${target}: set CLUSTER_E2E_CONFIRM=${expected} after reviewing its ownership and teardown rules." >&2
  exit 1
}
