#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/test/lib/n8n-restore-command.sh
source scripts/test/lib/n8n-restore-command.sh

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/n8n-restore-command-test.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT
mkdir -p "$temp_dir/backups"
real_sha256sum="$(command -v sha256sum)"

fail() {
  echo "n8n restore command test failed: $*" >&2
  exit 1
}

restore_command="$(n8n_restore_job_command)"
fixture_command="${restore_command//\/backups/$temp_dir/backups}"
restore_status=0
restore_output="$(RESTORE_DATABASE=n8n_restore_fixture \
  /bin/sh -ceu "$fixture_command" 2>&1)" || restore_status="$?"
[[ "$restore_status" -eq 1 ]] || {
  echo "Restore command returned status $restore_status instead of 1." >&2
  exit 1
}
[[ "$restore_output" == $'restore_stage=artifact-selection\nrestore_failure=artifact-selection' ]] || {
  echo 'Restore command did not report the exact artifact-selection failure.' >&2
  exit 1
}

new_case() {
  local name="$1" root
  root="$temp_dir/$name"
  mkdir -p "$root/bin" "$root/backups"
  cat >"$root/bin/pg_restore" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'pg_restore' >>"$RESTORE_LOG"
printf '\t%s' "$@" >>"$RESTORE_LOG"
printf '\n' >>"$RESTORE_LOG"
if [[ "${1:-}" == '--list' ]]; then
  grep -Fxq 'valid synthetic n8n dump' "$2"
fi
EOF
  cat >"$root/bin/psql" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *'--command=SELECT 1'* ]]; then
  exit 1
fi
printf 'true\n'
EOF
  cat >"$root/bin/createdb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'createdb\t%s\n' "$*" >>"$RESTORE_LOG"
EOF
  cat >"$root/bin/dropdb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'dropdb\t%s\n' "$*" >>"$RESTORE_LOG"
EOF
  chmod +x "$root/bin/pg_restore" "$root/bin/psql" "$root/bin/createdb" \
    "$root/bin/dropdb"
  : >"$root/commands.log"
  printf '%s\n' "$root"
}

create_dump() {
  local root="$1" timestamp="$2" dump
  dump="$root/n8n-postgresql-$timestamp.dump"
  printf 'valid synthetic n8n dump\n' >"$dump"
  (
    cd "$root"
    "$real_sha256sum" "$(basename "$dump")" >"$(basename "$dump").sha256"
  )
}

run_n8n_restore() {
  local root="$1" output status=0 command
  command="$(n8n_restore_job_command)"
  command="${command//\/backups/$root/backups}"
  output="$(
    env PATH="$root/bin:$PATH" \
      RESTORE_DATABASE=n8n_restore_fixture \
      N8N_RESTORE_DUMP="${N8N_RESTORE_DUMP_OVERRIDE:-}" \
      RESTORE_LOG="$root/commands.log" \
      /bin/sh -ceu "$command" 2>&1
  )" || status="$?"
  printf '%s\n' "$status" >"$root/status"
  printf '%s\n' "$output" >"$root/output"
}

newest_valid="$(new_case newest-valid)"
create_dump "$newest_valid/backups" 20260825T003000Z
create_dump "$newest_valid/backups" 20260826T003000Z
create_dump "$newest_valid/backups" 20260827T003000Z
printf 'corrupt\n' >>"$newest_valid/backups/n8n-postgresql-20260827T003000Z.dump"
run_n8n_restore "$newest_valid"
[[ "$(<"$newest_valid/status")" == '0' ]] || fail 'newest-valid default restore failed'
rg -Fq 'selected_dump=n8n-postgresql-20260826T003000Z.dump' "$newest_valid/output" ||
  fail 'the newest checksum-valid dump was not selected by default'

exact_dump="$(new_case exact-dump)"
create_dump "$exact_dump/backups" 20260825T003000Z
create_dump "$exact_dump/backups" 20260826T003000Z
N8N_RESTORE_DUMP_OVERRIDE='n8n-postgresql-20260825T003000Z.dump' \
  run_n8n_restore "$exact_dump"
[[ "$(<"$exact_dump/status")" == '0' ]] || fail 'exact dump restore failed'
rg -Fq 'selected_dump=n8n-postgresql-20260825T003000Z.dump' "$exact_dump/output" ||
  fail 'the exact requested dump was not selected'

for requested in \
  n8n-postgresql-20260827T003000Z.dump \
  ../n8n-postgresql-20260826T003000Z.dump; do
  case_name="exact-invalid-$(printf '%s' "$requested" | tr -c 'A-Za-z0-9' '-')"
  case_root="$(new_case "$case_name")"
  create_dump "$case_root/backups" 20260826T003000Z
  N8N_RESTORE_DUMP_OVERRIDE="$requested" run_n8n_restore "$case_root"
  [[ "$(<"$case_root/status")" != '0' ]] || fail "invalid exact dump $requested was accepted"
  rg -Fq 'restore_failure=artifact-selection' "$case_root/output" ||
    fail "invalid exact dump $requested did not fail artifact selection"
  [[ ! -s "$case_root/commands.log" ]] ||
    fail "invalid exact dump $requested fell back to another dump"
done

exact_corrupt="$(new_case exact-corrupt)"
create_dump "$exact_corrupt/backups" 20260825T003000Z
create_dump "$exact_corrupt/backups" 20260826T003000Z
printf 'corrupt\n' >>"$exact_corrupt/backups/n8n-postgresql-20260826T003000Z.dump"
N8N_RESTORE_DUMP_OVERRIDE='n8n-postgresql-20260826T003000Z.dump' \
  run_n8n_restore "$exact_corrupt"
[[ "$(<"$exact_corrupt/status")" != '0' ]] || fail 'corrupt exact dump was accepted'
rg -Fq 'restore_failure=artifact-selection' "$exact_corrupt/output" ||
  fail 'corrupt exact dump did not fail artifact selection'
! rg -Fq $'createdb\t' "$exact_corrupt/commands.log" ||
  fail 'corrupt exact dump fell back to an older valid dump'

exact_symlink="$(new_case exact-symlink)"
mkdir -p "$exact_symlink/outside"
create_dump "$exact_symlink/outside" 20260826T003000Z
ln -s "$exact_symlink/outside/n8n-postgresql-20260826T003000Z.dump" \
  "$exact_symlink/backups/n8n-postgresql-20260826T003000Z.dump"
ln -s "$exact_symlink/outside/n8n-postgresql-20260826T003000Z.dump.sha256" \
  "$exact_symlink/backups/n8n-postgresql-20260826T003000Z.dump.sha256"
N8N_RESTORE_DUMP_OVERRIDE='n8n-postgresql-20260826T003000Z.dump' \
  run_n8n_restore "$exact_symlink"
[[ "$(<"$exact_symlink/status")" != '0' ]] || fail 'symlinked exact dump was accepted'
rg -Fq 'restore_failure=artifact-selection' "$exact_symlink/output" ||
  fail 'symlinked exact dump did not fail artifact selection'

exact_sidecar_symlink="$(new_case exact-sidecar-symlink)"
mkdir -p "$exact_sidecar_symlink/outside"
create_dump "$exact_sidecar_symlink/outside" 20260826T003000Z
cp "$exact_sidecar_symlink/outside/n8n-postgresql-20260826T003000Z.dump" \
  "$exact_sidecar_symlink/backups/n8n-postgresql-20260826T003000Z.dump"
ln -s "$exact_sidecar_symlink/outside/n8n-postgresql-20260826T003000Z.dump.sha256" \
  "$exact_sidecar_symlink/backups/n8n-postgresql-20260826T003000Z.dump.sha256"
N8N_RESTORE_DUMP_OVERRIDE='n8n-postgresql-20260826T003000Z.dump' \
  run_n8n_restore "$exact_sidecar_symlink"
[[ "$(<"$exact_sidecar_symlink/status")" != '0' ]] ||
  fail 'symlinked exact dump checksum sidecar was accepted'
rg -Fq 'restore_failure=artifact-selection' "$exact_sidecar_symlink/output" ||
  fail 'symlinked exact dump checksum sidecar did not fail artifact selection'

for stage in artifact-selection database-absence database-create dump-restore \
  schema-contract workflow-contract credential-contract credential-binding complete; do
  rg -Fq "restore_stage=$stage" <<<"$restore_command" || {
    echo "Restore command is missing stage marker: $stage" >&2
    exit 1
  }
done

echo 'n8n restore command stage diagnostics passed.'
