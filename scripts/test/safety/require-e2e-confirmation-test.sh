#!/usr/bin/env bash
set -euo pipefail

guard='scripts/test/safety/require-e2e-confirmation.sh'
target='qbit-manage-policy'

if env -u CLUSTER_E2E_CONFIRM "$guard" "$target" >/dev/null 2>&1; then
  echo 'E2E guard accepted a missing confirmation.' >&2
  exit 1
fi

if CLUSTER_E2E_CONFIRM='e2e:wrong-target' "$guard" "$target" >/dev/null 2>&1; then
  echo 'E2E guard accepted a confirmation for another target.' >&2
  exit 1
fi

if CLUSTER_E2E_CONFIRM='chaos:qbit-manage-policy' "$guard" "$target" >/dev/null 2>&1; then
  echo 'E2E guard accepted the wrong confirmation type.' >&2
  exit 1
fi

CLUSTER_E2E_CONFIRM="e2e:${target}" "$guard" "$target" >/dev/null
