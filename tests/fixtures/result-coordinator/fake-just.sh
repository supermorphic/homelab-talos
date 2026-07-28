#!/usr/bin/env bash
set -euo pipefail

[[ -z "${TEST_RUN_ID_FILE+x}" ]] || {
  echo 'CI child command inherited the aggregate TEST_RUN_ID_FILE channel.' >&2
  exit 98
}

printf '%s\n' "$*" >>"${FAKE_JUST_CALLS:?}"
case "$1" in
  fixture-pass) exit 0 ;;
  fixture-fail) exit 9 ;;
  fixture-skipped)
    echo 'Fail-fast fixture executed a suite that should have been skipped.' >&2
    exit 99
    ;;
  *) exit 2 ;;
esac
