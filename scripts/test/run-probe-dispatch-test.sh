#!/usr/bin/env bash
# Offline unit test for the run-probe.sh allowlist: unknown/missing targets must be
# rejected with exit 2 before any cluster access.
set -euo pipefail

runner='scripts/test/run-probe.sh'

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

expect_dispatch_rejection 'unknown probe target is rejected' bogus
expect_dispatch_rejection 'path traversal is not a target' ../../../scripts/foo
expect_dispatch_rejection 'probe requires an explicit target'
expect_dispatch_rejection 'probe rejects extra arguments' qbittorrent extra

echo 'run-probe dispatch tests passed.'
