#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/test/lib/automation-data-restore-command.sh
source scripts/test/lib/automation-data-restore-command.sh
# shellcheck source=scripts/test/lib/n8n-restore-command.sh
source scripts/test/lib/n8n-restore-command.sh

test_root="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-restore-command-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT
real_sha256sum="$(command -v sha256sum)"
restore_scenario='scripts/test/scenarios/automation-data-restore-drill.sh'

rg -Fq '>"$run_dir/diagnostics/automation-data-restore-evidence.json"' "$restore_scenario" || {
  echo 'automation-data restore command test failed: restore evidence must stay under diagnostics' >&2
  exit 1
}
! rg -Fq '>"$run_dir/automation-data-restore-evidence.json"' "$restore_scenario" || {
  echo 'automation-data restore command test failed: restore evidence must not enter the run root' >&2
  exit 1
}

fail() {
  echo "automation-data restore command test failed: $*" >&2
  exit 1
}

sed -n '/^resolve_backup_configmap()/,/^}/p' "$restore_scenario" \
  >"$test_root/resolve-backup-configmap.sh"
# shellcheck disable=SC1091 # Extract the production resolver without running the live scenario.
source "$test_root/resolve-backup-configmap.sh"

sed -n '/^write_phase()/,/^}/p; /^validate_restore_selectors()/,/^}/p; /^validate_reported_restore_selection()/,/^}/p; /^wait_for_restore_job()/,/^}/p; /^restore_job_manifest()/,/^}/p; /^request_job_manifest()/,/^}/p' \
  "$restore_scenario" >"$test_root/restore-scenario-functions.sh"
# shellcheck disable=SC1091 # Extract production functions without running the live scenario.
source "$test_root/restore-scenario-functions.sh"
declare -F validate_restore_selectors >/dev/null ||
  fail 'the full-chain scenario has no exact-pair selector validator'
declare -F validate_reported_restore_selection >/dev/null ||
  fail 'the full-chain scenario has no reported exact-pair invariant'

validate_restore_selectors '' '' >/dev/null || fail 'default artifact selection was rejected'
validate_restore_selectors automation-data-20260825T003000Z \
  n8n-postgresql-20260825T003000Z.dump >/dev/null || fail 'canonical exact pair was rejected'
if validate_restore_selectors automation-data-20260825T003000Z '' >/dev/null 2>&1; then
  fail 'an automation-data selector without an n8n selector was accepted'
fi
if validate_restore_selectors '' n8n-postgresql-20260825T003000Z.dump >/dev/null 2>&1; then
  fail 'an n8n selector without an automation-data selector was accepted'
fi
if validate_restore_selectors '../automation-data-20260825T003000Z' \
  '../n8n-postgresql-20260825T003000Z.dump' >/dev/null 2>&1; then
  fail 'path-bearing exact selectors were accepted'
fi
validate_reported_restore_selection \
  automation-data-20260825T003000Z n8n-postgresql-20260825T003000Z.dump \
  automation-data-20260825T003000Z n8n-postgresql-20260825T003000Z.dump ||
  fail 'reported artifacts matching the exact pair were rejected'
if validate_reported_restore_selection \
  automation-data-20260825T003000Z n8n-postgresql-20260825T003000Z.dump \
  automation-data-20260826T003000Z n8n-postgresql-20260825T003000Z.dump; then
  fail 'a different canonical automation-data bundle satisfied the exact pair'
fi
if validate_reported_restore_selection \
  automation-data-20260825T003000Z n8n-postgresql-20260825T003000Z.dump \
  automation-data-20260825T003000Z n8n-postgresql-20260826T003000Z.dump; then
  fail 'a different canonical n8n dump satisfied the exact pair'
fi

run_hash='123456789abc'
prefix="ad-restore-$run_hash"
ad_namespace='automation-data'
n8n_namespace='automation'
ad_restore_job="$prefix-ad-load"
n8n_restore_job="$prefix-n8n-load"
ad_service="$prefix-db"
n8n_service="$prefix-n8n-db"
backup_configmap='automation-data-postgresql-backup-bk2fk62b6h'
automation_data_restore_bundle='automation-data-20260825T003000Z'
n8n_restore_dump='n8n-postgresql-20260825T003000Z.dump'
export run_hash prefix ad_namespace n8n_namespace ad_restore_job n8n_restore_job \
  ad_service n8n_service backup_configmap automation_data_restore_bundle n8n_restore_dump
restore_job_manifest automation-data >"$test_root/automation-data-job.yaml"
restore_job_manifest n8n >"$test_root/n8n-job.yaml"
request_job="$prefix-request"
n8n_app="$prefix-n8n"
export request_job n8n_app
request_job_manifest >"$test_root/request-job.yaml"
request_script="$(yq -r '.spec.template.spec.containers[0].args[0]' "$test_root/request-job.yaml")"
rg -Fq '/webhook/automation-data-canary' <<<"$request_script" ||
  fail 'the restored request does not invoke the stable automation-data canary'
rg -Fq "body.database !== 'automation_data_canary'" <<<"$request_script" ||
  fail 'the restored request does not require the stable canary database identity'
rg -Fq "body.role !== 'automation_data_canary_runtime'" <<<"$request_script" ||
  fail 'the restored request does not require the stable canary runtime role'
rg -Fq "JSON.stringify(['database','executionId','role','status'])" <<<"$request_script" ||
  fail 'the restored request does not require the exact four-key canary response'
[[ "$(yq -r '.spec.template.spec.containers[0].env[] | select(.name == "AUTOMATION_DATA_RESTORE_BUNDLE") | .value' \
  "$test_root/automation-data-job.yaml")" == "$automation_data_restore_bundle" ]] ||
  fail 'the exact automation-data bundle was not passed through the Job environment'
[[ "$(yq -r '.spec.template.spec.containers[0].env[] | select(.name == "N8N_RESTORE_DUMP") | .value' \
  "$test_root/n8n-job.yaml")" == "$n8n_restore_dump" ]] ||
  fail 'the exact n8n dump was not passed through the Job environment'

classification_run="$test_root/classification-run"
mkdir -p "$classification_run"
run_dir="$classification_run"
export run_dir
wait_for_job_terminal() {
  printf 'restore_stage=%s\nrestore_failure=%s\n' "$WAIT_FAILURE_STAGE" "$WAIT_FAILURE_STAGE" >&2
  return 1
}
WAIT_FAILURE_STAGE='artifact-selection'
if wait_for_restore_job ad-load 1800 5 synthetic-kubectl >/dev/null 2>&1; then
  fail 'an artifact-selection Job failure was accepted'
fi
[[ "$(yq -r '.status' "$classification_run/external-dependency.json")" == 'failed' ]] ||
  fail 'artifact-selection failure was not classified as an external dependency'

product_failure_run="$test_root/product-failure-run"
mkdir -p "$product_failure_run"
run_dir="$product_failure_run"
export run_dir
WAIT_FAILURE_STAGE='database-restore'
if wait_for_restore_job ad-load 1800 5 synthetic-kubectl >/dev/null 2>&1; then
  fail 'a database-restore Job failure was accepted'
fi
[[ ! -e "$product_failure_run/external-dependency.json" ]] ||
  fail 'a non-artifact restore failure was classified as an external dependency'

single_configmap='{"items":[{"metadata":{"name":"unrelated"},"data":{"backup.sh":"x","update-backup-status.sql":"x"}},{"metadata":{"name":"automation-data-postgresql-backup-bk2fk62b6h"},"data":{"backup.sh":"x","update-backup-status.sql":"x"}}]}'
[[ "$(resolve_backup_configmap <<<"$single_configmap")" == \
  'automation-data-postgresql-backup-bk2fk62b6h' ]] ||
  fail 'the generated backup ConfigMap was not resolved'

no_configmap='{"items":[{"metadata":{"name":"automation-data-postgresql-backup"},"data":{"backup.sh":"x","update-backup-status.sql":"x"}}]}'
if resolve_backup_configmap <<<"$no_configmap" >/dev/null 2>&1; then
  fail 'a missing generated backup ConfigMap was accepted'
fi

multiple_configmaps='{"items":[{"metadata":{"name":"automation-data-postgresql-backup-aaaaaaaaaa"},"data":{"backup.sh":"x","update-backup-status.sql":"x"}},{"metadata":{"name":"automation-data-postgresql-backup-bbbbbbbbbb"},"data":{"backup.sh":"x","update-backup-status.sql":"x"}}]}'
if resolve_backup_configmap <<<"$multiple_configmaps" >/dev/null 2>&1; then
  fail 'multiple generated backup ConfigMaps were accepted'
fi

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
      AUTOMATION_DATA_RESTORE_BUNDLE="${AUTOMATION_DATA_RESTORE_BUNDLE_OVERRIDE:-}" \
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

exact_bundle="$(new_case exact-bundle)"
create_bundle "$exact_bundle/backups" 20260825T003000Z
create_bundle "$exact_bundle/backups" 20260826T003000Z
AUTOMATION_DATA_RESTORE_BUNDLE_OVERRIDE='automation-data-20260825T003000Z' \
  run_restore "$exact_bundle"
[[ "$(<"$exact_bundle/status")" == '0' ]] || fail 'exact bundle restore failed'
rg -Fq 'selected_bundle=automation-data-20260825T003000Z' "$exact_bundle/output" ||
  fail 'the exact requested bundle was not selected'

for requested in \
  automation-data-20260827T003000Z \
  ../automation-data-20260826T003000Z; do
  case_name="exact-invalid-$(printf '%s' "$requested" | tr -c 'A-Za-z0-9' '-')"
  case_root="$(new_case "$case_name")"
  create_bundle "$case_root/backups" 20260826T003000Z
  AUTOMATION_DATA_RESTORE_BUNDLE_OVERRIDE="$requested" run_restore "$case_root"
  [[ "$(<"$case_root/status")" != '0' ]] || fail "invalid exact bundle $requested was accepted"
  rg -Fq 'restore_failure=artifact-selection' "$case_root/output" ||
    fail "invalid exact bundle $requested did not fail artifact selection"
  [[ ! -s "$case_root/commands.log" ]] ||
    fail "invalid exact bundle $requested fell back to another bundle"
done

exact_corrupt="$(new_case exact-corrupt)"
create_bundle "$exact_corrupt/backups" 20260825T003000Z
create_bundle "$exact_corrupt/backups" 20260826T003000Z corrupt
AUTOMATION_DATA_RESTORE_BUNDLE_OVERRIDE='automation-data-20260826T003000Z' \
  run_restore "$exact_corrupt"
[[ "$(<"$exact_corrupt/status")" != '0' ]] || fail 'corrupt exact bundle was accepted'
rg -Fq 'restore_failure=artifact-selection' "$exact_corrupt/output" ||
  fail 'corrupt exact bundle did not fail artifact selection'
[[ ! -s "$exact_corrupt/commands.log" ]] ||
  fail 'corrupt exact bundle fell back to an older valid bundle'

exact_symlink="$(new_case exact-symlink)"
mkdir -p "$exact_symlink/outside"
create_bundle "$exact_symlink/outside" 20260826T003000Z
ln -s "$exact_symlink/outside/automation-data-20260826T003000Z" \
  "$exact_symlink/backups/automation-data-20260826T003000Z"
AUTOMATION_DATA_RESTORE_BUNDLE_OVERRIDE='automation-data-20260826T003000Z' \
  run_restore "$exact_symlink"
[[ "$(<"$exact_symlink/status")" != '0' ]] || fail 'symlinked exact bundle was accepted'
rg -Fq 'restore_failure=artifact-selection' "$exact_symlink/output" ||
  fail 'symlinked exact bundle did not fail artifact selection'

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
