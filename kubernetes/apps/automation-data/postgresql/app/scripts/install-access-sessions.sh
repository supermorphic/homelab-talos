#!/bin/sh
set -eu
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/access-sessions.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT HUP INT TERM

# SQL errors can include catalog detail. Expose only a fixed marker to Job logs.
if psql --no-psqlrc --set=ON_ERROR_STOP=1 --tuples-only --no-align \
    --file=/scripts/access-sessions.sql >"$temp_dir/install.log" 2>&1 &&
  grep -qx 'access_sessions_contract_valid=true' "$temp_dir/install.log"; then
  echo 'access_sessions_installation=applied'
else
  echo 'access_sessions_installation=failed'
  exit 1
fi
