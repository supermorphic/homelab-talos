#!/usr/bin/env bash
set -euo pipefail

[[ -z "${TEST_RUN_ID_FILE+x}" ]] || {
  echo 'CI child command inherited the aggregate TEST_RUN_ID_FILE channel.' >&2
  exit 98
}

printf '%s\n' "$*" >>"${FAKE_JUST_CALLS:?}"
case "$1" in
  fixture-pass)
    sleep 0.02
    printf '%s\n' \
      '<testsuites tests="1" failures="0" errors="0" skipped="0">' \
      '<testsuite name="fixture-pass" tests="1" failures="0" errors="0" skipped="0">' \
      '<testcase classname="fixture-pass" name="native"/>' \
      '</testsuite>' \
      '</testsuites>' >"${TEST_RESULT_FRAGMENT_DIR:?}/native.xml"
    exit 0
    ;;
  fixture-fail)
    sleep 0.02
    exit 9
    ;;
  fixture-skipped)
    echo 'Fail-fast fixture executed a suite that should have been skipped.' >&2
    exit 99
    ;;
  *) exit 2 ;;
esac
