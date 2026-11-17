#!/bin/sh
set -eu
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/session-sweep.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT HUP INT TERM

# Revoke registered temporary logins past expiry. A Job succeeds only when every
# revocation succeeded, so the CronJob's last success is the sweep heartbeat.
if psql --no-psqlrc --set=ON_ERROR_STOP=1 --tuples-only --no-align --field-separator=' ' \
    --command="SELECT result->>'revoked', result->>'failed'
      FROM platform_operations.sweep_session_logins() AS result" \
    >"$temp_dir/sweep.out" 2>"$temp_dir/sweep.err"; then
  read -r revoked failed <"$temp_dir/sweep.out"
  echo "session_sweep revoked=$revoked failed=$failed"
  [ "$failed" = 0 ]
else
  echo 'session_sweep=failed'
  exit 1
fi
