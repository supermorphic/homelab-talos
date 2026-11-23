#!/bin/sh
set -eu
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/session-revocation.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT HUP INT TERM

# Run one phase of workstation session revocation and print its result line:
# "suspend" suspends ready capabilities; "finish" revokes every registered login and
# resumes the listed capabilities. On failure, print only a fixed marker.
case "${1:-}" in
  suspend) file=/scripts/suspend-access-capabilities.sql ;;
  finish)
    file=/scripts/revoke-all-session-logins.sql
    if [ -z "${REVOCATION_CAPABILITIES+set}" ] || [ -z "${REVOCATION_RESUME:-}" ]; then
      file=
    fi
    ;;
  *) file= ;;
esac
if [ -n "$file" ] &&
  psql --no-psqlrc --set=ON_ERROR_STOP=1 --tuples-only --no-align \
    --file="$file" >"$temp_dir/revocation.out" 2>"$temp_dir/revocation.err"; then
  tail -n 1 "$temp_dir/revocation.out"
else
  echo 'session_revocation=failed'
  exit 1
fi
