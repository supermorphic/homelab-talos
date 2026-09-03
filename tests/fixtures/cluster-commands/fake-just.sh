#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${CLUSTER_TEST_CALLS:?}"
if [[ -n "${CLUSTER_TEST_FAIL:-}" && "$*" == *"$CLUSTER_TEST_FAIL"* ]]; then
  exit 1
fi
