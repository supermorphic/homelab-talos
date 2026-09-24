#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 6 && "$1" == --kubeconfig && "$3" == get &&
  "$4" == nodes && "$5" == --output && "$6" == json ]] || exit 64
[[ "${DISRUPTION_TEST_API_FAILURE:-false}" != true ]] || exit 1
[[ -z "${DISRUPTION_TEST_CALL_LOG:-}" ]] || printf '%s\n' "$*" >>"$DISRUPTION_TEST_CALL_LOG"
cat "${DISRUPTION_TEST_NODES:?}"
