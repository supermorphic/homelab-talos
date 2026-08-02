#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 3 ]]
[[ -z "${TEST_SCOPED_PREFLIGHT_CALLS:-}" ]] ||
  printf '%s\n' "$*" >>"$TEST_SCOPED_PREFLIGHT_CALLS"
