#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/test/lib/automation-data-restore-command.sh
source scripts/test/lib/automation-data-restore-command.sh

test_root="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-restore-command-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT
real_sha256sum="$(command -v sha256sum)"

fail() {
  echo "automation-data restore command test failed: $*" >&2
  exit 1
}

registry_body=$'domain\tdatabase_name\towner_role\tmigrator_role\truntime_role\tstate\thas_reached_ready\tgeneration\tmigrator_credential_id\truntime_credential_id\tmigrator_credential_updated_at\truntime_credential_updated_at\toperation_started_at\tupdated_at\terror_code\ndomain_one\tdomain_one\tdomain_one_owner\tdomain_one_migrator\tdomain_one_runtime\tready\ttrue\t2\tmigrator-id\truntime-id\t2026-08-27 00:00:00+00\t2026-08-27 00:00:00+00\t2026-08-27 00:00:00+00\t2026-08-27 00:00:00+00\t\nissue317_backup_error\tissue317_backup_error\tissue317_backup_error_owner\tissue317_backup_error_migrator\tissue317_backup_error_runtime\terror\tfalse\t3\t\t\t\t\t2026-08-27 00:00:00+00\t2026-08-27 00:00:00+00\tacceptance_backup_error'
database_names=$'automation_data_control\ndomain_one\npostgres'

create_bundle() {
  local root="$1" timestamp="$2" mutation="${3:-none}" bundle
  bundle="$root/automation-data-$timestamp"
  mkdir -p "$bundle/databases"
  cat >"$bundle/globals.sql" <<'EOF'
CREATE ROLE postgres;
ALTER ROLE postgres WITH SUPERUSER LOGIN;
CREATE ROLE domain_one_owner;
EOF
  printf '%s\n' "$registry_body" >"$bundle/registry.tsv"
  {
    printf 'bundle_version\t1\n'
    printf 'captured_at\t2026-08-27T00:30:00Z\n'
    printf 'platform_generation\t3\n'
    printf 'database_set_hash\t%064d\n' 7
    printf 'record_type\tdatabase_name_base64\tdump_path\n'
    while IFS= read -r database; do
      encoded="$(printf '%s' "$database" | base64 | tr -d '\n')"
      filename="$(printf '%s' "$encoded" | tr '+/' '-_' | tr -d '=')"
      printf 'synthetic archive for %s\n' "$database" >"$bundle/databases/db-$filename.dump"
      printf 'database\t%s\tdatabases/db-%s.dump\n' "$encoded" "$filename"
    done <<<"$database_names"
  } >"$bundle/manifest.tsv"
  (
    cd "$bundle"
    "$real_sha256sum" globals.sql registry.tsv manifest.tsv databases/*.dump >SHA256SUMS
    "$real_sha256sum" SHA256SUMS | awk '{print $1 "  SHA256SUMS"}' >COMPLETE
  )
  case "$mutation" in
    none) ;;
    corrupt) printf 'corrupt\n' >>"$bundle/registry.tsv" ;;
    extra) printf 'untracked\n' >"$bundle/extra.txt" ;;
    missing) rm -f -- "$(find "$bundle/databases" -type f | head -n 1)" ;;
    *) return 2 ;;
  esac
}

refresh_bundle_checksums() {
  local bundle="$1"
  (
    cd "$bundle"
    "$real_sha256sum" globals.sql registry.tsv manifest.tsv databases/*.dump >SHA256SUMS
    "$real_sha256sum" SHA256SUMS | awk '{print $1 "  SHA256SUMS"}' >COMPLETE
  )
}

new_case() {
  local name="$1" root
  root="$test_root/$name"
  mkdir -p "$root/bin" "$root/backups" "$root/post-recovery"
  cat >"$root/bin/psql" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'psql' >>"$RESTORE_LOG"
printf '\t%s' "$@" >>"$RESTORE_LOG"
printf '\n' >>"$RESTORE_LOG"
command_text=''
file_input=''
for argument in "$@"; do
  case "$argument" in
    --command=*) command_text="${argument#--command=}" ;;
    --file=*) file_input="${argument#--file=}" ;;
  esac
done
if [[ -n "$file_input" ]]; then
  if grep -Fxq 'CREATE ROLE postgres;' "$file_input"; then
    printf 'bootstrap role already exists\n' >&2
    exit 29
  fi
  grep -Fxq 'ALTER ROLE postgres WITH SUPERUSER LOGIN;' "$file_input"
  grep -Fxq 'CREATE ROLE domain_one_owner;' "$file_input"
fi
if [[ "$command_text" == *"datname <> 'postgres'"* ]]; then
  printf '0\n'
elif [[ "$command_text" == *'FROM pg_database'* ]]; then
  printf '%s\n' "$RESTORED_DATABASES" | while IFS= read -r database; do
    printf '%s' "$database" | base64 | tr -d '\n'
    printf '\n'
  done
elif [[ "$command_text" == *'managed_domains'* && "$command_text" == *'validate_domain'* ]]; then
  printf '%s\n' "${VALIDATION_RESULT:-true}"
elif [[ "$command_text" == *'managed_domains'* ]]; then
  printf '%s\n' "$RESTORED_REGISTRY_BASE64"
fi
EOF
  cat >"$root/bin/pg_restore" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'pg_restore' >>"$RESTORE_LOG"
printf '\t%s' "$@" >>"$RESTORE_LOG"
printf '\n' >>"$RESTORE_LOG"
EOF
  cat >"$root/bin/backup" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
bundle="$BACKUP_DIR/automation-data-20260828T003000Z"
mkdir -p "$bundle/databases"
printf 'post recovery globals\n' >"$bundle/globals.sql"
printf 'post recovery registry\n' >"$bundle/registry.tsv"
printf 'post recovery manifest\n' >"$bundle/manifest.tsv"
printf 'post recovery dump\n' >"$bundle/databases/db-cG9zdGdyZXM.dump"
(
  cd "$bundle"
  "$REAL_SHA256SUM" globals.sql registry.tsv manifest.tsv databases/*.dump >SHA256SUMS
  "$REAL_SHA256SUM" SHA256SUMS | awk '{print $1 "  SHA256SUMS"}' >COMPLETE
)
printf 'backup\n' >>"$RESTORE_LOG"
EOF
  chmod +x "$root/bin/psql" "$root/bin/pg_restore" "$root/bin/backup"
  : >"$root/commands.log"
  printf '%s\n' "$root"
}

run_restore() {
  local root="$1" validation_result="${2:-true}" output status=0 command
  command="$(automation_data_restore_job_command)"
  output="$(
    env \
      PATH="$root/bin:$PATH" \
      BACKUP_DIR="$root/backups" \
      POST_RECOVERY_BACKUP_DIR="$root/post-recovery" \
      AUTOMATION_DATA_BACKUP_SCRIPT="$root/bin/backup" \
      AUTOMATION_DATA_UPDATE_BACKUP_STATUS_SQL="$root/update-status.sql" \
      AUTOMATION_DATA_BACKUP_PASSWORD='synthetic-backup-password-never-print' \
      PGPASSWORD='synthetic-superuser-password-never-print' \
      RESTORE_LOG="$root/commands.log" \
      RESTORED_DATABASES="$database_names" \
      RESTORED_REGISTRY_BASE64="$(printf '%s\n' "$registry_body" | base64 | tr -d '\n')" \
      VALIDATION_RESULT="$validation_result" \
      REAL_SHA256SUM="$real_sha256sum" \
      /bin/sh -ceu "$command" 2>&1
  )" || status="$?"
  printf '%s\n' "$status" >"$root/status"
  printf '%s\n' "$output" >"$root/output"
}

success="$(new_case success)"
create_bundle "$success/backups" 20260825T003000Z
create_bundle "$success/backups" 20260826T003000Z
create_bundle "$success/backups" 20260827T003000Z corrupt
run_restore "$success"
[[ "$(<"$success/status")" == '0' ]] || fail 'valid restore command failed'
rg -Fq 'selected_bundle=automation-data-20260826T003000Z' "$success/output" ||
  fail 'newest complete checksum-valid bundle was not selected'
for stage in artifact-selection globals-restore database-restore catalog-validation \
  permission-validation post-recovery-backup complete; do
  rg -Fq "restore_stage=$stage" "$success/output" || fail "missing stage $stage"
done
! rg -qi 'synthetic globals|synthetic-.*password|credential.*data' "$success/output" ||
  fail 'restore output exposed globals or credential data'
globals_line="$(rg -n $'^psql\t.*--file=' "$success/commands.log" | head -n 1 | cut -d: -f1)"
first_database_line="$(rg -n $'^pg_restore\t--exit-on-error' \
  "$success/commands.log" | head -n 1 | cut -d: -f1)"
[[ "$globals_line" -lt "$first_database_line" ]] || fail 'globals were not restored first'
[[ "$(rg -c '^pg_restore' "$success/commands.log")" == '6' ]] ||
  fail 'every database archive was not inspected and restored'
rg -Fq 'backup' "$success/commands.log" || fail 'fresh post-recovery backup was not invoked'
rg -Fq 'post_recovery_bundle=automation-data-20260828T003000Z' "$success/output" ||
  fail 'fresh post-recovery bundle was not validated'

for mutation in corrupt extra missing; do
  case_root="$(new_case "$mutation")"
  create_bundle "$case_root/backups" 20260827T003000Z "$mutation"
  run_restore "$case_root"
  [[ "$(<"$case_root/status")" != '0' ]] || fail "$mutation bundle was accepted"
  ! rg -q '^backup$' "$case_root/commands.log" || fail "$mutation bundle reached fresh backup"
done

for mutation in globals-bootstrap-missing globals-bootstrap-duplicate; do
  case_root="$(new_case "$mutation")"
  create_bundle "$case_root/backups" 20260827T003000Z
  bundle="$case_root/backups/automation-data-20260827T003000Z"
  if [[ "$mutation" == globals-bootstrap-missing ]]; then
    awk '$0 != "CREATE ROLE postgres;"' "$bundle/globals.sql" >"$bundle/globals.updated"
    mv "$bundle/globals.updated" "$bundle/globals.sql"
  else
    printf 'CREATE ROLE postgres;\n' >>"$bundle/globals.sql"
  fi
  refresh_bundle_checksums "$bundle"
  run_restore "$case_root"
  [[ "$(<"$case_root/status")" != '0' ]] || fail "$mutation globals were accepted"
  rg -Fq 'restore_failure=globals-bootstrap-declaration' "$case_root/output" ||
    fail "$mutation did not fail at the exact bootstrap-role guard"
  ! rg -q '^backup$' "$case_root/commands.log" || fail "$mutation reached fresh backup"
done

registry_mismatch="$(new_case registry-mismatch)"
create_bundle "$registry_mismatch/backups" 20260827T003000Z
RESTORED_REGISTRY_OVERRIDE='different' run_restore "$registry_mismatch" false
[[ "$(<"$registry_mismatch/status")" != '0' ]] ||
  fail 'registry/catalog disagreement was accepted'
! rg -q '^backup$' "$registry_mismatch/commands.log" ||
  fail 'registry/catalog disagreement reached fresh backup'

echo 'automation-data restore command behavior passed.'
