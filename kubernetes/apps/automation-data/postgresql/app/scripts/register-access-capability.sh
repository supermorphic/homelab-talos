#!/bin/sh
set -eu
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/access-capability.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT HUP INT TERM

# Print the validated capability as one JSON line. On failure, print only a known
# error code, never SQL text.
if [ -n "${CAPABILITY_DOMAIN:-}" ] && [ -n "${CAPABILITY_NAME:-}" ] &&
  [ -n "${CAPABILITY_SCHEMAS:-}" ] && [ -n "${CAPABILITY_MAX_TTL:-}" ] &&
  psql --no-psqlrc --set=ON_ERROR_STOP=1 --tuples-only --no-align \
    --file=/scripts/register-access-capability.sql >"$temp_dir/register.out" \
    2>"$temp_dir/register.err"; then
  tail -n 1 "$temp_dir/register.out"
else
  reason="$(grep -oE '(invalid_access_capability[a-z_]*|access_capability_[a-z_]+|unknown_access_capability)' \
    "$temp_dir/register.err" 2>/dev/null | head -n 1 || true)"
  echo "access_capability_registration=failed reason=${reason:-unknown}"
  exit 1
fi
