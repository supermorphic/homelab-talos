#!/usr/bin/env bash
set -euo pipefail

[[ "$*" == *'get nodes --output json'* ]] || {
  echo "Unexpected cluster verifier kubectl invocation: $*" >&2
  exit 2
}
cat "${CLUSTER_TEST_NODES:?}"
