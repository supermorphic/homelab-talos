#!/usr/bin/env bash

n8n_restore_job_command() {
  cat <<'EOF'
restore_fail() {
  printf 'restore_failure=%s\n' "$1" >&2
  exit 1
}

printf '%s\n' 'restore_stage=artifact-selection'
backup_directory=/backups
selected=''
for dump in $(find "$backup_directory" -maxdepth 1 -type f -name 'n8n-postgresql-*.dump' | LC_ALL=C sort -r); do
  sidecar="$dump.sha256"
  test -f "$sidecar" || continue
  target=$(awk 'NF == 2 { print $2; exit }' "$sidecar")
  test "$target" = "$(basename "$dump")" || continue
  (cd "$backup_directory" && sha256sum -c "$(basename "$sidecar")") >/dev/null 2>&1 || continue
  pg_restore --list "$dump" >/dev/null 2>&1 || continue
  selected="$dump"
  break
done
test -n "$selected" || restore_fail artifact-selection

printf '%s\n' 'restore_stage=database-absence'
if psql --dbname="$RESTORE_DATABASE" --command='SELECT 1' >/dev/null 2>&1; then
  restore_fail database-already-exists
fi

printf '%s\n' 'restore_stage=database-create'
createdb --owner=n8n "$RESTORE_DATABASE" || restore_fail database-create
restore_ok=false
cleanup_partial() {
  test "$restore_ok" = true || dropdb --if-exists --force "$RESTORE_DATABASE" >/dev/null 2>&1 || true
}
trap cleanup_partial EXIT

printf '%s\n' 'restore_stage=dump-restore'
pg_restore --dbname="$RESTORE_DATABASE" --no-owner --no-privileges --role=n8n "$selected" ||
  restore_fail dump-restore

printf '%s\n' 'restore_stage=schema-contract'
schema_contract="$(psql --dbname="$RESTORE_DATABASE" --tuples-only --no-align --command="SELECT (to_regclass(\$\$public.workflow_entity\$\$) IS NOT NULL AND to_regclass(\$\$public.credentials_entity\$\$) IS NOT NULL AND to_regclass(\$\$public.webhook_entity\$\$) IS NOT NULL AND to_regclass(\$\$public.execution_entity\$\$) IS NOT NULL)::text")" ||
  restore_fail schema-query
test "$schema_contract" = true || restore_fail schema-contract

printf '%s\n' 'restore_stage=workflow-contract'
workflow_contract="$(psql --dbname="$RESTORE_DATABASE" --tuples-only --no-align --command="SELECT (count(*) = 1)::text FROM workflow_entity WHERE name = \$\$Platform Canary\$\$ AND active IS TRUE")" ||
  restore_fail workflow-query
test "$workflow_contract" = true || restore_fail workflow-contract

printf '%s\n' 'restore_stage=credential-contract'
credential_contract="$(psql --dbname="$RESTORE_DATABASE" --tuples-only --no-align --command="SELECT (count(*) = 1)::text FROM credentials_entity WHERE name = \$\$Platform Canary Header\$\$ AND type = \$\$httpHeaderAuth\$\$")" ||
  restore_fail credential-query
test "$credential_contract" = true || restore_fail credential-contract

printf '%s\n' 'restore_stage=credential-binding'
binding_contract="$(psql --dbname="$RESTORE_DATABASE" --tuples-only --no-align --command="SELECT (count(*) = 1)::text FROM workflow_entity AS workflow JOIN credentials_entity AS credential ON credential.name = \$\$Platform Canary Header\$\$ AND credential.type = \$\$httpHeaderAuth\$\$ WHERE workflow.name = \$\$Platform Canary\$\$ AND workflow.active IS TRUE AND EXISTS (SELECT 1 FROM jsonb_array_elements(workflow.nodes::jsonb) AS node WHERE node->>\$\$name\$\$ = \$\$Webhook\$\$ AND node->\$\$credentials\$\$->\$\$httpHeaderAuth\$\$->>\$\$id\$\$ = credential.id::text AND node->\$\$credentials\$\$->\$\$httpHeaderAuth\$\$->>\$\$name\$\$ = \$\$Platform Canary Header\$\$)")" ||
  restore_fail credential-binding-query
test "$binding_contract" = true || restore_fail credential-binding

restore_ok=true
printf '%s\n' 'restore_stage=complete'
printf 'selected_dump=%s\n' "$(basename "$selected")"
EOF
}

n8n_drop_restore_database_job_command() {
  cat <<'EOF'
dropdb --if-exists --force "$RESTORE_DATABASE"
database_count="$(PGOPTIONS="-c restore.database=$RESTORE_DATABASE" psql --dbname=postgres --tuples-only --no-align --command="SELECT count(*) FROM pg_database WHERE datname = current_setting('restore.database')")"
test "$database_count" = 0
EOF
}
