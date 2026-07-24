#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: require-chaos-confirmation.sh <registered-target>' >&2
  exit 2
}

target="$1"
expected="chaos:${target}"

[[ "${CLUSTER_CHAOS_CONFIRM:-}" == "$expected" ]] || {
  echo "Refusing resilience target ${target}: set CLUSTER_CHAOS_CONFIRM=${expected} after reviewing the recovery procedure." >&2
  exit 1
}
