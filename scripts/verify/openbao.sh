#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 && -f "$1" ]] || {
  printf '%s\n' '{"status":"inaccessible","classification":"invalid-source"}'
  exit 2
}

if ! kubectl --kubeconfig "$1" get namespace openbao >/dev/null 2>&1; then
  printf '%s\n' '{"status":"inaccessible","classification":"read-denied"}'
  exit 1
fi

exec uv run --locked python -m scripts.openbao.verify "$1"
