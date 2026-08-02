#!/usr/bin/env bash
set -euo pipefail
printf 'called\n' >>"${FORBIDDEN_SOURCE_CALLS:?}"
echo 'Scoped campaign invoked the operator Flux/source check.' >&2
exit 98
