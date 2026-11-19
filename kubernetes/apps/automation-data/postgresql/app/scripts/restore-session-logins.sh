#!/bin/sh
set -eu
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/session-restore.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT HUP INT TERM

# Revoke every registered temporary login after a restore and report what remains.
# Succeeds only when nothing failed and no temporary login remains.
if psql --no-psqlrc --set=ON_ERROR_STOP=1 --tuples-only --no-align --field-separator=' ' \
    --command="SELECT result->>'revoked', result->>'failed', result->>'remaining'
      FROM platform_operations.revoke_session_logins_after_restore() AS result" \
    >"$temp_dir/restore.out" 2>"$temp_dir/restore.err"; then
  read -r revoked failed remaining <"$temp_dir/restore.out"
  echo "session_restore_cleanup revoked=$revoked failed=$failed remaining=$remaining"
  [ "$failed" = 0 ] && [ "$remaining" = 0 ]
else
  echo 'session_restore_cleanup=failed'
  exit 1
fi
