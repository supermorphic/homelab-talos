#!/usr/bin/env bash

# Fail unless running under Bash >= 5. macOS /bin/bash 3.2 does not honor
# `set -e` for failed bare [[ ]] or (( )) assertions in the same way.
require_bash() {
  [[ "${BASH_VERSINFO[0]:-0}" -ge 5 ]] || {
    echo 'This repository requires bash >= 5 (for example: brew install bash).' >&2
    echo 'macOS /bin/bash 3.2 skips set -e for [[ ]] tests, so validation would not gate.' >&2
    return 1
  }
}

# Assert that a command used as an absence predicate finds no match. A status of 1
# means "not found"; status >= 2 is an execution error and must still fail the gate.
assert_command_finds_nothing() {
  local message="$1"
  shift

  if "$@"; then
    echo "$message" >&2
    return 1
  else
    local status="$?"
    if [[ "$status" -eq 1 ]]; then
      return 0
    fi
    echo "Absence check failed to execute (status $status): $message" >&2
    return "$status"
  fi
}

assert_empty() {
  local value="$1"
  local message="$2"
  [[ -z "$value" ]] || {
    echo "$message" >&2
    return 1
  }
}
