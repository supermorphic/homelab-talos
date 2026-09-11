#!/usr/bin/env bash
set -euo pipefail

STATUS=failed REASON='fixture dependency unavailable' \
  yq --null-input --output-format json '{
    "status": strenv(STATUS),
    "reason": strenv(REASON)
  }' >"${HOMELAB_TEST_RUN_DIR:?}/external-dependency.json"
