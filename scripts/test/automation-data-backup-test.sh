#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
backup_script="$repo_root/kubernetes/apps/automation-data/postgresql/app/scripts/backup.sh"
status_sql="$repo_root/kubernetes/apps/automation-data/postgresql/app/scripts/update-backup-status.sql"
cronjob="$repo_root/kubernetes/apps/automation-data/postgresql/app/cronjob.yaml"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-backup-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

[[ -x "$backup_script" ]] || {
  echo "Missing executable automation-data backup script: $backup_script" >&2
  exit 1
}
[[ -f "$status_sql" && -f "$cronjob" ]] || {
  echo 'Missing automation-data backup SQL or CronJob.' >&2
  exit 1
}

real_sha256sum="$(command -v sha256sum)"
backup_test_shell="$(command -v dash || command -v sh)"
default_databases=$'automation_data_control\ndomain_one\npostgres\n../unregistered db'

fail() {
  echo "automation-data backup test failed: $*" >&2
  exit 1
}

assert_count() {
  local directory="$1" pattern="$2" expected="$3" actual
  actual="$(find "$directory" -maxdepth 1 -name "$pattern" -print | wc -l | tr -d ' ')"
  [[ "$actual" == "$expected" ]] ||
    fail "expected $expected $pattern entries in $directory, found $actual"
}

new_case() {
  local case_name="$1" case_root
  case_root="$test_root/$case_name"
  mkdir -p "$case_root/bin" "$case_root/backups"
  cat >"$case_root/bin/fake-postgresql-tool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

tool="$(basename -- "$0")"
case "$tool" in
  psql)
    command_text=''
    is_status=false
    for argument in "$@"; do
      case "$argument" in
        --command=*) command_text="${argument#--command=}" ;;
        --file=/scripts/update-backup-status.sql | /scripts/update-backup-status.sql)
          is_status=true
          ;;
      esac
    done
    if $is_status; then
      printf 'status-attempt\t%s\n' "$*" >>"$FAKE_LOG"
      [[ "${FAIL_STAGE:-}" != status ]] || exit 41
      printf 'freshness-advanced\n' >>"$FAKE_LOG"
    elif [[ "$command_text" == *capture_backup_state* ]]; then
      count=0
      [[ ! -f "$FAKE_STATE_COUNT" ]] || count="$(<"$FAKE_STATE_COUNT")"
      count=$((count + 1))
      printf '%s\n' "$count" >"$FAKE_STATE_COUNT"
      generation=7
      if [[ "${UNSTABLE_ONCE:-}" == generation && "$count" == 2 ]]; then
        generation=8
      fi
      registry="$(
        printf 'domain\tdatabase_name\towner_role\tmigrator_role\truntime_role\tstate\thas_reached_ready\tgeneration\tmigrator_credential_id\truntime_credential_id\tmigrator_credential_updated_at\truntime_credential_updated_at\toperation_started_at\tupdated_at\terror_code\n'
        printf 'domain_one\tdomain_one\tdomain_one_owner\tdomain_one_migrator\tdomain_one_runtime\tready\ttrue\t6\tmigrator-id\truntime-id\t2026-08-27T00:00:00Z\t2026-08-27T00:00:00Z\t2026-08-27T00:00:00Z\t2026-08-27T00:00:00Z\t\n'
        printf 'stuck\tstuck\tstuck_owner\tstuck_migrator\tstuck_runtime\terror\tfalse\t7\t\t\t\t\t2026-08-26T00:00:00Z\t2026-08-26T00:00:00Z\tworkflow_operation_failed'
      )"
      encoded_registry="$(printf '%s' "$registry" | base64 | tr -d '\n')"
      printf '%s|%s\n' "$generation" "$encoded_registry"
      printf 'capture-state\t%s\n' "$generation" >>"$FAKE_LOG"
    elif [[ "$command_text" == *pg_database* ]]; then
      count=0
      [[ ! -f "$FAKE_DATABASE_COUNT" ]] || count="$(<"$FAKE_DATABASE_COUNT")"
      count=$((count + 1))
      printf '%s\n' "$count" >"$FAKE_DATABASE_COUNT"
      printf '%s\n' "$DATABASES" | while IFS= read -r database; do
        printf '%s' "$database" | base64 | tr -d '\n'
        printf '\n'
      done
      if [[ "${UNSTABLE_ONCE:-}" == database && "$count" == 2 ]]; then
        printf '%s' 'concurrent_database' | base64 | tr -d '\n'
        printf '\n'
      fi
      printf 'capture-databases\t%s\n' "$count" >>"$FAKE_LOG"
    else
      exit 42
    fi
    ;;
  pg_dumpall)
    printf 'pg_dumpall\t%s\n' "$*" >>"$FAKE_LOG"
    [[ "${FAIL_STAGE:-}" != globals ]] || exit 51
    output=''
    for argument in "$@"; do
      case "$argument" in --file=*) output="${argument#--file=}" ;; esac
    done
    [[ -n "$output" ]] || exit 52
    printf '%s\n' "CREATE ROLE synthetic_runtime PASSWORD 'SCRAM-SHA-256\$synthetic-verifier';" >"$output"
    ;;
  pg_dump)
    printf 'pg_dump\t%s\n' "$*" >>"$FAKE_LOG"
    [[ "${FAIL_STAGE:-}" != dump ]] || exit 61
    output=''
    database=''
    while (($#)); do
      case "$1" in
        --file) output="$2"; shift 2 ;;
        --file=*) output="${1#--file=}"; shift ;;
        --dbname) database="$2"; shift 2 ;;
        --dbname=*) database="${1#--dbname=}"; shift ;;
        *) shift ;;
      esac
    done
    [[ -n "$output" && -n "$database" ]] || exit 62
    printf 'synthetic custom archive for %s\n' "$database" >"$output"
    ;;
  pg_restore)
    printf 'pg_restore\t%s\n' "$*" >>"$FAKE_LOG"
    [[ "${FAIL_STAGE:-}" != restore ]] || exit 71
    ;;
  *) exit 90 ;;
esac
EOF
  cat >"$case_root/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'sha256sum\t%s\t%s\n' "$PWD" "$*" >>"$FAKE_LOG"
if [[ "${FAIL_STAGE:-}" == checksum && "${1:-}" != -c ]]; then
  exit 81
fi
if [[ "${FAIL_STAGE:-}" == final_validation && "${1:-}" == -c && "$PWD" != *'.tmp' ]]; then
  exit 82
fi
exec "$REAL_SHA256SUM" "$@"
EOF
  cat >"$case_root/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'mv\t%s\t%s\n' "$1" "$2" >>"$FAKE_LOG"
[[ "${FAIL_STAGE:-}" != rename ]] || exit 91
exec /bin/mv "$@"
EOF
  cat >"$case_root/bin/date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${*: -1}" in
  +%Y%m%dT%H%M%SZ) printf '%s\n' '20260827T003000Z' ;;
  +%Y-%m-%dT%H:%M:%SZ) printf '%s\n' '2026-08-27T00:30:00Z' ;;
  *) exit 101 ;;
esac
EOF
  chmod +x "$case_root/bin/fake-postgresql-tool" "$case_root/bin/sha256sum" \
    "$case_root/bin/mv" "$case_root/bin/date"
  ln -s fake-postgresql-tool "$case_root/bin/psql"
  ln -s fake-postgresql-tool "$case_root/bin/pg_dumpall"
  ln -s fake-postgresql-tool "$case_root/bin/pg_dump"
  ln -s fake-postgresql-tool "$case_root/bin/pg_restore"
  : >"$case_root/commands.log"
  printf '%s\n' "$case_root"
}

run_backup() {
  local case_root="$1" fail_stage="${2:-}" unstable_once="${3:-}"
  env \
    PATH="$case_root/bin:$PATH" \
    BACKUP_DIR="$case_root/backups" \
    PGDATABASE=automation_data_control \
    PGHOST=automation-data-postgresql \
    PGPORT=5432 \
    PGUSER=automation_data_backup \
    PGPASSWORD='synthetic-backup-password-not-for-command-arguments' \
    DATABASES="$default_databases" \
    FAKE_LOG="$case_root/commands.log" \
    FAKE_STATE_COUNT="$case_root/state-count" \
    FAKE_DATABASE_COUNT="$case_root/database-count" \
    FAIL_STAGE="$fail_stage" \
    UNSTABLE_ONCE="$unstable_once" \
    REAL_SHA256SUM="$real_sha256sum" \
    "$backup_test_shell" "$backup_script"
}

success_case="$(new_case success)"
run_backup "$success_case"
final_bundle="$success_case/backups/automation-data-20260827T003000Z"
[[ -d "$final_bundle" && -f "$final_bundle/COMPLETE" ]] ||
  fail 'successful backup did not publish one complete final bundle'
for artifact in globals.sql registry.tsv manifest.tsv SHA256SUMS COMPLETE; do
  [[ -s "$final_bundle/$artifact" ]] || fail "complete bundle is missing $artifact"
done
assert_count "$final_bundle/databases" '*.dump' 4
(cd "$final_bundle" && "$real_sha256sum" -c SHA256SUMS >/dev/null &&
  "$real_sha256sum" -c COMPLETE >/dev/null) || fail 'published checksums do not validate'
rg -Fq $'stuck\tstuck\tstuck_owner\tstuck_migrator\tstuck_runtime\terror' \
  "$final_bundle/registry.tsv" || fail 'stable error registry state was not preserved'
rg -Fq 'Li4vdW5yZWdpc3RlcmVkIGRi' "$final_bundle/manifest.tsv" ||
  fail 'manifest does not preserve the encoded unregistered database name'
[[ ! -e "$success_case/unregistered db" ]] || fail 'database filename encoding escaped the bundle'
globals_command="$(rg '^pg_dumpall\t' "$success_case/commands.log")"
[[ "$globals_command" == *'--globals-only'* && "$globals_command" != *'--no-role-passwords'* ]] ||
  fail 'globals dump must preserve role password verifiers'
[[ "$globals_command" != *synthetic-backup-password* && "$globals_command" != *PGPASSWORD* ]] ||
  fail 'backup password appeared in command arguments'
dump_count="$(rg -c '^pg_dump\t' "$success_case/commands.log")"
restore_count="$(rg -c '^pg_restore\t' "$success_case/commands.log")"
[[ "$dump_count" == 4 && "$restore_count" == 4 ]] ||
  fail 'every captured database must have one inspected custom-format dump'
rename_line="$(rg -n '^mv\t' "$success_case/commands.log" | cut -d: -f1)"
status_line="$(rg -n '^status-attempt\t' "$success_case/commands.log" | cut -d: -f1)"
[[ "$rename_line" -lt "$status_line" ]] || fail 'freshness update ran before atomic publication'
rename_record="$(rg '^mv\t' "$success_case/commands.log")"
rename_source="$(cut -f2 <<<"$rename_record")"
rename_target="$(cut -f3 <<<"$rename_record")"
[[ "$(dirname -- "$rename_source")" == "$(dirname -- "$rename_target")" ]] ||
  fail 'bundle publication must rename within one filesystem'
rg -q '^freshness-advanced$' "$success_case/commands.log" ||
  fail 'successful final validation did not advance freshness'

for failure_stage in globals dump restore checksum rename final_validation status; do
  failure_case="$(new_case "failure-$failure_stage")"
  if run_backup "$failure_case" "$failure_stage" >/dev/null 2>&1; then
    fail "$failure_stage failure must fail the backup"
  fi
  ! find "$failure_case/backups" -type f -name COMPLETE -print -quit | rg -q . ||
    fail "$failure_stage failure left a complete bundle"
  ! rg -q '^freshness-advanced$' "$failure_case/commands.log" ||
    fail "$failure_stage failure advanced freshness"
done

for unstable_kind in database generation; do
  retry_case="$(new_case "retry-$unstable_kind")"
  run_backup "$retry_case" '' "$unstable_kind"
  [[ "$(rg -c '^pg_dumpall\t' "$retry_case/commands.log")" == 2 ]] ||
    fail "$unstable_kind drift did not reject and retry the first temporary bundle"
  assert_count "$retry_case/backups" 'automation-data-*' 1
  [[ -f "$retry_case/backups/automation-data-20260827T003000Z/COMPLETE" ]] ||
    fail "$unstable_kind retry did not publish the stable second attempt"
done

create_prior_bundle() {
  local root="$1" day="$2" bundle
  bundle="$root/automation-data-202608${day}T003000Z"
  mkdir -p "$bundle/databases"
  printf 'globals %s\n' "$day" >"$bundle/globals.sql"
  printf 'registry %s\n' "$day" >"$bundle/registry.tsv"
  printf 'manifest %s\n' "$day" >"$bundle/manifest.tsv"
  printf 'dump %s\n' "$day" >"$bundle/databases/db-cG9zdGdyZXM.dump"
  (
    cd "$bundle"
    "$real_sha256sum" globals.sql registry.tsv manifest.tsv \
      databases/db-cG9zdGdyZXM.dump >SHA256SUMS
    complete_checksum="$($real_sha256sum SHA256SUMS | awk '{print $1}')"
    printf '%s  SHA256SUMS\n' "$complete_checksum" >COMPLETE
  )
}

retention_case="$(new_case retention)"
for day in 19 20 21 22 23 24 25 26; do
  create_prior_bundle "$retention_case/backups" "$day"
done
mkdir -p "$retention_case/backups/.automation-data-abandoned.tmp"
printf 'partial\n' >"$retention_case/backups/.automation-data-abandoned.tmp/globals.sql"
mkdir -p "$retention_case/backups/automation-data-20260818T003000Z"
printf 'invalid\n' >"$retention_case/backups/automation-data-20260818T003000Z/COMPLETE"
run_backup "$retention_case"
assert_count "$retention_case/backups" 'automation-data-*' 7
assert_count "$retention_case/backups" '.automation-data-*.tmp' 0
[[ ! -e "$retention_case/backups/automation-data-20260818T003000Z" &&
  ! -e "$retention_case/backups/automation-data-20260819T003000Z" &&
  ! -e "$retention_case/backups/automation-data-20260820T003000Z" ]] ||
  fail 'retention did not remove invalid and oldest complete bundles as units'
[[ -d "$retention_case/backups/automation-data-20260821T003000Z" &&
  -d "$retention_case/backups/automation-data-20260827T003000Z" ]] ||
  fail 'retention removed a newest valid complete bundle'

cron_contract="$(yq -r '
  [
    .spec.schedule,
    .spec.timeZone,
    .spec.concurrencyPolicy,
    .spec.jobTemplate.spec.activeDeadlineSeconds,
    .spec.jobTemplate.spec.template.spec.automountServiceAccountToken,
    (.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "backup") | .image),
    (.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "backup") |
      [.env[].name] | sort | join(","))
  ] | join("|")
' "$cronjob")"
[[ "$cron_contract" == \
  '30 0 * * *|Etc/UTC|Forbid|1800|false|postgres:17.11-alpine3.24|BACKUP_DIR,PGDATABASE,PGHOST,PGPASSWORD,PGPORT,PGUSER' ]] ||
  fail 'backup CronJob schedule, isolation, image, or dynamic-discovery environment drifted'

rg -Fq "platform_operations.publish_backup(:'bundle', :'checksum', :'database_set_hash')" \
  "$status_sql" || fail 'status SQL does not call the fixed publication function'

echo 'automation-data dynamic logical backup behavior passed.'
