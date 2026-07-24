#!/usr/bin/env bash

# Fail unless running under Bash >= 4. macOS /bin/bash 3.2 does not honor
# `set -e` for failed bare [[ ]] or (( )) assertions in the same way.
require_bash() {
  [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] || {
    echo 'This repository requires bash >= 4 (for example: brew install bash).' >&2
    echo 'macOS /bin/bash 3.2 skips set -e for [[ ]] tests, so validation would not gate.' >&2
    return 1
  }
}
