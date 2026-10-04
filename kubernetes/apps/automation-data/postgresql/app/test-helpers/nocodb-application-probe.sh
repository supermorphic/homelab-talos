#!/bin/sh
set -eu
set +x
printf '%s\n' "$PGHOST" | grep -Eq '^(nc-restore-[0-9a-f]{12}-db|restore-postgresql)$' || exit 1
printf '%s\n' "$RUN_ID" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' || exit 1
identity_hex="$(printf '%s' "$RUN_ID" | md5sum | cut -c1-15)"
identity=$((0x$identity_hex))
value="acceptance:$RUN_ID"
umask 077
IFS=: read -r _retained_host _retained_port retained_database retained_role retained_password < /credentials/pgpass
[ "$retained_database" = 'automation_data_acceptance' ] && [ "$retained_role" = 'app_615fdb4405179d440872ca3edc72e3df_integration' ]
printf '%s:5432:%s:%s:%s\n' "$PGHOST" 'automation_data_acceptance' 'app_615fdb4405179d440872ca3edc72e3df_integration' "$retained_password" > /tmp/application.pgpass
chmod 600 /tmp/application.pgpass
unset retained_password
client() {
  env -i PATH="$PATH" PGHOST="$PGHOST" PGPORT=5432 PGDATABASE='automation_data_acceptance' PGUSER='app_615fdb4405179d440872ca3edc72e3df_integration' \
    PGPASSFILE=/tmp/application.pgpass PGCONNECT_TIMEOUT=5 PGOPTIONS='-c statement_timeout=5000' \
    psql --no-psqlrc --no-password --tuples-only --no-align --set=ON_ERROR_STOP=1 "$@"
}
if env -i PATH="$PATH" PGHOST="$PGHOST" PGPORT=5432 PGDATABASE='automation_data_acceptance' PGUSER='app_615fdb4405179d440872ca3edc72e3df_integration' \
  PGPASSWORD=acceptance-wrong-password PGCONNECT_TIMEOUT=5 \
  psql --no-psqlrc --no-password --command 'SELECT current_user' >/dev/null 2>&1; then
  exit 1
fi
[ "$(client --command 'SELECT current_database() || chr(58) || session_user || chr(58) || current_user' 2>/dev/null)" = 'automation_data_acceptance:app_615fdb4405179d440872ca3edc72e3df_integration:app_615fdb4405179d440872ca3edc72e3df_integration' ]
client --command "SELECT app.record_integration_fact(${identity},'${value}')" >/dev/null 2>&1
[ "$(client --command "SELECT fact FROM app.integration_facts WHERE id=${identity}" 2>/dev/null)" = "${value}" ]
denied() {
  if client --set=VERBOSITY=sqlstate --command "$1" >/tmp/denial.out 2>/tmp/denial.err; then exit 1; fi
  # A missing table/function or connection failure cannot satisfy this oracle.
  test "$(sed -n 's/^ERROR: *//p' /tmp/denial.err)" = 42501
}
denied 'SELECT * FROM app.withheld_bookkeeping'
denied 'SELECT app.withheld_admin()'
denied "INSERT INTO app.integration_facts VALUES (-491,'denied')"
denied 'SELECT * FROM extra_read.visible_facts'
denied 'SET ROLE automation_data_acceptance_owner'
rm -f /tmp/application.pgpass /tmp/denial.out /tmp/denial.err
printf '%s\n' 'application_acceptance=passed'
