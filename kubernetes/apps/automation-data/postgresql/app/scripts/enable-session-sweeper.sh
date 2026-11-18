#!/bin/sh
set -eu
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/session-sweeper.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT HUP INT TERM

# psql echoes failing statements, which here contain the password. Expose only a
# fixed marker to Job logs.
password="${SWEEPER_PASSWORD:-}"
if [ "${#password}" -ge 32 ] &&
  psql --no-psqlrc --set=ON_ERROR_STOP=1 --tuples-only --no-align \
    --file=/scripts/enable-session-sweeper.sql >"$temp_dir/enable.log" 2>&1 &&
  grep -qx 'session_sweeper_login=enabled' "$temp_dir/enable.log"; then
  echo 'session_sweeper_login=enabled'
else
  echo 'session_sweeper_login=failed'
  exit 1
fi
