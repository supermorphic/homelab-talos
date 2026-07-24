#!/usr/bin/env bash
set -euo pipefail

guard='scripts/test/safety/require-chaos-confirmation.sh'
target='guard-self-test'

if env -u CLUSTER_CHAOS_CONFIRM "$guard" "$target" >/dev/null 2>&1; then
  echo 'Chaos guard accepted a missing confirmation.' >&2
  exit 1
fi

if CLUSTER_CHAOS_CONFIRM='chaos:wrong-target' "$guard" "$target" >/dev/null 2>&1; then
  echo 'Chaos guard accepted a confirmation for another target.' >&2
  exit 1
fi

CLUSTER_CHAOS_CONFIRM="chaos:${target}" "$guard" "$target" >/dev/null
