#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
migration_lib="$repo_root/scripts/lib/automation-data-bootstrap.sh"
init_script="$repo_root/kubernetes/apps/automation-data/postgresql/app/scripts/init-platform.sh"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-exporter-grant.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

fail() {
  echo "automation-data exporter grant test failed: $*" >&2
  exit 1
}

[[ -f "$migration_lib" ]] || fail "missing $migration_lib"
# shellcheck source=scripts/lib/automation-data-bootstrap.sh
source "$migration_lib"

automation_data_exporter_grant_job_manifest \
  automation-data-exporter-grant-123456789abc 123456789abc >"$temp_dir/job.yaml"
kubeconform -strict -summary -ignore-missing-schemas "$temp_dir/job.yaml" >/dev/null

job_contract="$(yq -o=json -I=0 '
  {
    "name": .metadata.name,
    "app": .metadata.labels."app.kubernetes.io/name",
    "role": .metadata.labels."homelab-talos/role",
    "run": .metadata.labels."homelab-talos/run-id",
    "deadline": .spec.activeDeadlineSeconds,
    "backoff": .spec.backoffLimit,
    "serviceAccountToken": .spec.template.spec.automountServiceAccountToken,
    "restartPolicy": .spec.template.spec.restartPolicy,
    "podUser": .spec.template.spec.securityContext.runAsUser,
    "podGroup": .spec.template.spec.securityContext.runAsGroup,
    "seccomp": .spec.template.spec.securityContext.seccompProfile.type,
    "container": (.spec.template.spec.containers[0] | {
      "name": .name,
      "image": .image,
      "command": .command,
      "args": .args,
      "env": [.env[] | [
        .name,
        (.value // .valueFrom.secretKeyRef.name // ""),
        (.valueFrom.secretKeyRef.key // "")
      ] | join("|")],
      "allowPrivilegeEscalation": .securityContext.allowPrivilegeEscalation,
      "readOnlyRootFilesystem": .securityContext.readOnlyRootFilesystem,
      "capabilities": .securityContext.capabilities.drop
    })
  }
' "$temp_dir/job.yaml")"
expected_job_contract='{"name":"automation-data-exporter-grant-123456789abc","app":"automation-data-postgresql-backup","role":"exporter-monitor-grant","run":"123456789abc","deadline":300,"backoff":0,"serviceAccountToken":false,"restartPolicy":"Never","podUser":70,"podGroup":70,"seccomp":"RuntimeDefault","container":{"name":"grant-exporter-monitor","image":"postgres:17.11-alpine3.24","command":["psql"],"args":["--no-psqlrc","--set=ON_ERROR_STOP=1","--command=ALTER ROLE automation_data_exporter INHERIT; GRANT pg_monitor TO automation_data_exporter;"],"env":["PGDATABASE|automation_data_control|","PGHOST|automation-data-postgresql|","PGPORT|5432|","PGUSER|automation_data_backup|","PGPASSWORD|postgresql-credentials|backup-password"],"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":["ALL"]}}'
[[ "$job_contract" == "$expected_job_contract" ]] || fail 'migration Job contract is not exact'

mkdir "$temp_dir/bin"
cat >"$temp_dir/bin/psql" <<'EOF'
#!/bin/sh
for argument in "$@"; do
  case "$argument" in
    --file | --file=*) exit 0 ;;
  esac
done
cat >>"$PSQL_STDIN_CAPTURE"
EOF
chmod +x "$temp_dir/bin/psql"
PSQL_STDIN_CAPTURE="$temp_dir/init.sql" \
  PATH="$temp_dir/bin:$PATH" \
  POSTGRES_USER=postgres \
  POSTGRES_DB=automation_data_control \
  PROVISIONER_PASSWORD=synthetic-provisioner \
  BACKUP_PASSWORD=synthetic-backup \
  EXPORTER_PASSWORD=synthetic-exporter \
  /bin/sh "$init_script"
rg -Uq 'CREATE ROLE automation_data_exporter\n  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT\n  PASSWORD' \
  "$temp_dir/init.sql" ||
  fail 'fresh initialization does not enable exporter role inheritance'
rg -Fxq 'GRANT pg_monitor TO automation_data_exporter;' "$temp_dir/init.sql" ||
  fail 'fresh initialization does not grant pg_monitor to the exporter'

bootstrap_source="$(just --show bootstrap automation-data)"
for marker in \
  'source scripts/lib/automation-data-bootstrap.sh' \
  'automation_data_exporter_grant_job_manifest' \
  'wait_for_exporter_grant_job' \
  'deleting run-owned exporter grant Job'; do
  rg -Fq "$marker" <<<"$bootstrap_source" ||
    fail "bootstrap omits required migration behavior: $marker"
done

grant_create_line="$(rg -n -m 1 -F 'automation_data_exporter_grant_job_manifest' \
  <<<"$bootstrap_source" | cut -d: -f1)"
grant_wait_line="$(rg -n -F 'wait_for_exporter_grant_job' \
  <<<"$bootstrap_source" | tail -n 1 | cut -d: -f1)"
grant_delete_line="$(rg -n -m 1 -F 'deleting run-owned exporter grant Job' \
  <<<"$bootstrap_source" | cut -d: -f1)"
backup_create_line="$(rg -n -m 1 -F 'Creating the first validated automation-data logical backup' \
  <<<"$bootstrap_source" | cut -d: -f1)"
[[ -n "$grant_create_line" && -n "$grant_wait_line" && -n "$grant_delete_line" && \
  -n "$backup_create_line" && "$grant_create_line" -lt "$grant_wait_line" && \
  "$grant_wait_line" -lt "$grant_delete_line" && \
  "$grant_delete_line" -lt "$backup_create_line" ]] ||
  fail 'bootstrap does not complete and remove the exporter grant Job before backup'

echo 'automation-data exporter grant behavior passed.'
