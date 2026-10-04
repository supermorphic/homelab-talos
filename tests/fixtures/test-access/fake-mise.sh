#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'exec -- just talos readerconfig' ]] || exit 2
printf '%s\n' 'talos-reader-bootstrap' >>"${TEST_FIXTURE_ACCESS_TRACE:?}"
