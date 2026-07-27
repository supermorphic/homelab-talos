#!/usr/bin/env bash
set -euo pipefail

case "$1" in
  run|delete)
    exit 0
    ;;
  retrieve)
    destination="$2/sonobuoy-results.tar.gz"
    cp "${FAKE_SONOBUOY_ARCHIVE:?}" "$destination"
    printf '%s\n' "$destination"
    ;;
  results)
    printf '%s\n' 'Plugin: e2e' 'Status: complete' 'Failed: 0'
    ;;
  *) exit 2 ;;
esac
