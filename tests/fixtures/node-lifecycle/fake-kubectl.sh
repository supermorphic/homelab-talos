#!/usr/bin/env bash
set -euo pipefail

[[ "$*" == *'get nodes --output json'* ]] || {
  echo "Unexpected lifecycle kubectl invocation: $*" >&2
  exit 2
}
cat "${NODE_LIFECYCLE_TEST_NODES:?}"
