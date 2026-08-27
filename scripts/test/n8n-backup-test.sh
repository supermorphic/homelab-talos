#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
backup_script="$repo_root/kubernetes/apps/automation/n8n-postgresql/app/scripts/backup.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/n8n-backup-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

[[ -x "$backup_script" ]] || {
  echo "Missing executable n8n backup script: $backup_script" >&2
  exit 1
}

real_sha256sum="$(command -v sha256sum)"

fail() {
  echo "n8n backup test failed: $*" >&2
  exit 1
}

assert_file_count() {
  local directory="$1" pattern="$2" expected="$3" actual
  actual="$(find "$directory" -maxdepth 1 -type f -name "$pattern" -print | wc -l | tr -d ' ')"
  [[ "$actual" == "$expected" ]] ||
    fail "expected $expected $pattern files in $directory, found $actual"
}

new_case() {
  local case_name="$1" case_root
  case_root="$test_root/$case_name"
  mkdir -p "$case_root/bin" "$case_root/backups"
  cat >"$case_root/bin/fake-postgresql-tool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

tool="$(basename -- "$0")"
printf '%s' "$tool" >>"$FAKE_LOG"
printf '\t%s' "$@" >>"$FAKE_LOG"
printf '\n' >>"$FAKE_LOG"

case "$tool" in
  pg_dump)
    [[ "${FAIL_STAGE:-}" != pg_dump ]] || exit 21
    output=''
    while (($#)); do
      case "$1" in
        --file)
          output="$2"
          shift 2
          ;;
        --file=*)
          output="${1#--file=}"
          shift
          ;;
        *) shift ;;
      esac
    done
    [[ -n "$output" ]] || exit 22
    printf 'synthetic custom-format archive\n' >"$output"
    ;;
  pg_restore)
    [[ "${FAIL_STAGE:-}" != pg_restore ]] || exit 31
    ;;
  psql)
    [[ "${FAIL_STAGE:-}" != psql ]] || exit 41
    ;;
  *) exit 90 ;;
esac
EOF
  cat >"$case_root/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == --check ]]; then
  printf 'final-check\t%s\n' "$2" >>"$FAKE_LOG"
  [[ "${FAIL_STAGE:-}" != final_check ]] || exit 51
else
  printf 'checksum\t%s\n' "$1" >>"$FAKE_LOG"
  [[ "${FAIL_STAGE:-}" != checksum ]] || exit 52
fi
exec "$REAL_SHA256SUM" "$@"
EOF
  cat >"$case_root/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'mv' >>"$FAKE_LOG"
printf '\t%s' "$@" >>"$FAKE_LOG"
printf '\n' >>"$FAKE_LOG"
count=0
[[ ! -f "$FAKE_MV_COUNT" ]] || count="$(<"$FAKE_MV_COUNT")"
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_MV_COUNT"
[[ "${FAIL_STAGE:-}" != rename || "$count" -ne 1 ]] || exit 61
exec /bin/mv "$@"
EOF
  cat >"$case_root/bin/date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${*: -1}" in
  +%Y%m%dT%H%M%SZ) printf '%s\n' '20260827T010000Z' ;;
  +%Y-%m-%dT%H:%M:%SZ) printf '%s\n' '2026-08-27T01:00:00Z' ;;
  *) exit 71 ;;
esac
EOF
  chmod +x "$case_root/bin/fake-postgresql-tool" "$case_root/bin/sha256sum" \
    "$case_root/bin/mv" "$case_root/bin/date"
  ln -s fake-postgresql-tool "$case_root/bin/pg_dump"
  ln -s fake-postgresql-tool "$case_root/bin/pg_restore"
  ln -s fake-postgresql-tool "$case_root/bin/psql"
  : >"$case_root/commands.log"
  printf '%s\n' "$case_root"
}

run_backup() {
  local case_root="$1" fail_stage="${2:-}"
  env \
    PATH="$case_root/bin:$PATH" \
    BACKUP_DIR="$case_root/backups" \
    PGDATABASE=n8n \
    PGHOST=n8n-postgresql \
    PGPORT=5432 \
    PGUSER=n8n_backup \
    PGPASSWORD='synthetic-password-that-must-not-be-an-argument' \
    FAKE_LOG="$case_root/commands.log" \
    FAKE_MV_COUNT="$case_root/mv-count" \
    FAIL_STAGE="$fail_stage" \
    REAL_SHA256SUM="$real_sha256sum" \
    "$backup_script"
}

success_case="$(new_case success)"
run_backup "$success_case"
assert_file_count "$success_case/backups" '*.dump' 1
assert_file_count "$success_case/backups" '*.sha256' 1
assert_file_count "$success_case/backups" '*.tmp' 0
final_dump="$(find "$success_case/backups" -maxdepth 1 -type f -name '*.dump' -print)"
final_checksum="$(find "$success_case/backups" -maxdepth 1 -type f -name '*.sha256' -print)"
dump_basename="$(basename -- "$final_dump")"
expected_checksum="$($real_sha256sum "$final_dump" | awk '{print $1}')"
[[ "$(<"$final_checksum")" == "$expected_checksum  $dump_basename" ]] ||
  fail 'checksum sidecar must contain the final dump basename and checksum'
[[ "$(<"$final_checksum")" != *tmp* ]] ||
  fail 'checksum sidecar must not name a temporary artifact'
restore_line="$(rg -n '^pg_restore\t' "$success_case/commands.log" | cut -d: -f1)"
first_rename_line="$(rg -n '^mv\t' "$success_case/commands.log" | head -n 1 | cut -d: -f1)"
[[ "$restore_line" -lt "$first_rename_line" ]] ||
  fail 'pg_restore archive expansion must happen before final publication'
psql_line="$(rg '^psql\t' "$success_case/commands.log")"
[[ "$psql_line" == *$'\t--set=completed_at=2026-08-27T01:00:00Z'* ]] ||
  fail 'status update must receive the completion timestamp'
[[ "$psql_line" == *$'\t--set=filename='"$dump_basename"* ]] ||
  fail 'status update must receive the final dump basename'
[[ "$psql_line" == *$'\t--set=checksum='"$expected_checksum"* ]] ||
  fail 'status update must receive the final checksum'
[[ "$psql_line" == *$'\t--file\t/scripts/update-backup-status.sql'* ]] ||
  fail 'status update must use the mounted SQL file'
[[ "$psql_line" != *synthetic-password* && "$psql_line" != *PGPASSWORD* ]] ||
  fail 'status update command arguments must not contain the database password'

for failure_stage in pg_dump pg_restore checksum rename final_check; do
  failure_case="$(new_case "failure-$failure_stage")"
  if run_backup "$failure_case" "$failure_stage" >/dev/null 2>&1; then
    fail "$failure_stage failure must fail the backup"
  fi
  ! rg -q '^psql\t' "$failure_case/commands.log" ||
    fail "$failure_stage failure must prevent the status update"
done

cleanup_gate_case="$(new_case cleanup-gate)"
printf 'unpaired archive\n' >"$cleanup_gate_case/backups/n8n-postgresql-20260801T010000Z.dump"
printf 'temporary artifact\n' >"$cleanup_gate_case/backups/orphan.tmp"
if run_backup "$cleanup_gate_case" psql >/dev/null 2>&1; then
  fail 'status update failure must fail the backup'
fi
[[ -f "$cleanup_gate_case/backups/n8n-postgresql-20260801T010000Z.dump" &&
  -f "$cleanup_gate_case/backups/orphan.tmp" ]] ||
  fail 'cleanup must not run before a successful status update'

retention_case="$(new_case retention)"
for day in 19 20 21 22 23 24 25 26; do
  prior_dump="$retention_case/backups/n8n-postgresql-202608${day}T010000Z.dump"
  printf 'valid prior archive %s\n' "$day" >"$prior_dump"
  prior_checksum="$($real_sha256sum "$prior_dump" | awk '{print $1}')"
  printf '%s  %s\n' "$prior_checksum" "$(basename -- "$prior_dump")" >"$prior_dump.sha256"
done
printf 'unpaired archive\n' >"$retention_case/backups/n8n-postgresql-20260828T010000Z.dump"
printf 'unpaired checksum\n' >"$retention_case/backups/n8n-postgresql-20260817T010000Z.dump.sha256"
printf 'temporary dump\n' >"$retention_case/backups/.n8n-postgresql-incomplete.dump.tmp"
printf 'temporary checksum\n' >"$retention_case/backups/.n8n-postgresql-incomplete.dump.sha256.tmp"
run_backup "$retention_case"
assert_file_count "$retention_case/backups" '*.dump' 7
assert_file_count "$retention_case/backups" '*.sha256' 7
assert_file_count "$retention_case/backups" '*.tmp' 0
[[ ! -e "$retention_case/backups/n8n-postgresql-20260819T010000Z.dump" &&
  ! -e "$retention_case/backups/n8n-postgresql-20260820T010000Z.dump" ]] ||
  fail 'retention must remove pairs older than the newest seven successful artifacts'
[[ -f "$retention_case/backups/n8n-postgresql-20260826T010000Z.dump" &&
  -f "$retention_case/backups/n8n-postgresql-20260826T010000Z.dump.sha256" ]] ||
  fail 'cleanup must preserve a valid retained archive pair'
[[ ! -e "$retention_case/backups/n8n-postgresql-20260828T010000Z.dump" &&
  ! -e "$retention_case/backups/n8n-postgresql-20260817T010000Z.dump.sha256" ]] ||
  fail 'cleanup must remove unpaired final artifacts'

echo 'n8n logical backup behavior passed.'
