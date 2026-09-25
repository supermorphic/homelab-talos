#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 && -f "$1" ]] || {
  printf '%s\n' '{"status":"inaccessible","classification":"invalid-source"}'
  exit 2
}

if ! kubectl --kubeconfig "$1" config get-contexts homelab-diagnostic --no-headers >/dev/null 2>&1 ||
  ! kubectl --kubeconfig "$1" --context homelab-diagnostic get namespace openbao >/dev/null 2>&1; then
  printf '%s\n' '{"status":"inaccessible","classification":"diagnostic-context"}'
  exit 1
fi

exec python3 -m scripts.openbao.verify "$1"
