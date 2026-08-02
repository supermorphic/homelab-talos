#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *' config view '* ]]; then
  printf 'fixture-cluster\n'
  exit 0
fi
printf '%s\n' "$*" >>"${FORBIDDEN_KUBECTL_CALLS:?}"
echo 'Scoped campaign invoked forbidden Lease kubectl.' >&2
exit 97
