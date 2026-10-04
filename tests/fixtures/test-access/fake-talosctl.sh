#!/usr/bin/env bash
set -euo pipefail
[[ "$#" == 6 && "$1 $2 $3" == 'config info --talosconfig' &&
  "$4" == "${TEST_FIXTURE_TALOS_ROOT:-${CAMPAIGN_TEST_REPO_ROOT:-}}/.talos/config" &&
  "$5 $6" == '--output json' ]] || exit 2
printf '{"roles":["%s"]}\n' "${TEST_FIXTURE_TALOS_ROLE:-os:reader}"
