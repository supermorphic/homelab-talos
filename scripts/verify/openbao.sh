#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 && -f "$1" ]] || {
  printf '%s\n' '{"status":"inaccessible","classification":"invalid-source"}'
  exit 2
}

exec python3 -m scripts.openbao.verify "$1"
