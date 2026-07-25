#!/usr/bin/env bash
set -euo pipefail

runner='scripts/test/run-chainsaw.sh'

expect_dispatch_rejection() {
  local description="$1"
  shift
  local exit_code

  set +e
  "$runner" "$@" >/dev/null 2>&1
  exit_code="$?"
  set -e

  [[ "$exit_code" -eq 2 ]] || {
    echo "${description}: expected dispatch exit 2, got ${exit_code}." >&2
    exit 1
  }
}

expect_dispatch_rejection 'all is not a registered smoke target' smoke all
expect_dispatch_rejection 'scenario cannot occupy the target axis' smoke flux-ready
expect_dispatch_rejection 'self-test cannot occupy the target axis' smoke diagnostics-self-test
expect_dispatch_rejection 'unknown smoke scenario is rejected' smoke cluster unknown-scenario
expect_dispatch_rejection 'media target requires a scenario' smoke media
expect_dispatch_rejection 'unknown media smoke scenario is rejected' smoke media unknown-scenario
expect_dispatch_rejection 'diagnostics rejects a scenario argument' diagnostics cluster flux-ready
expect_dispatch_rejection 'smoke requires an explicit target' smoke
