#!/bin/sh
set -eu
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/openbao-issuer.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT HUP INT TERM

# psql echoes failing statements, which here contain the password. Expose only a
# fixed marker to Job logs.
password="${ISSUER_PASSWORD:-}"
if [ "${#password}" -ge 32 ] &&
  psql --no-psqlrc --set=ON_ERROR_STOP=1 --tuples-only --no-align \
    --file=/scripts/enable-openbao-issuer.sql >"$temp_dir/enable.log" 2>&1 &&
  grep -qx 'openbao_issuer_login=enabled' "$temp_dir/enable.log"; then
  echo 'openbao_issuer_login=enabled'
else
  echo 'openbao_issuer_login=failed'
  exit 1
fi
