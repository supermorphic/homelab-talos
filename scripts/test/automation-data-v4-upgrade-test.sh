#!/usr/bin/env bash
# Real PostgreSQL v3-to-v4 upgrade: retirement arrives without changing existing logins.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-v4-upgrade.XXXXXX")"
chmod 700 "$scratch"
marker="automation-data-v4-upgrade-$$-$RANDOM"
container="${marker:0:63}"
stage=historical-init
trap 'echo "v4 upgrade fixture failed during $stage" >&2' ERR
cleanup() {
  if podman container exists "$container" >/dev/null 2>&1 &&
      [[ "$(podman inspect --format '{{ index .Config.Labels "homelab-talos.test-run" }}' "$container")" == "$marker" ]]; then
    podman rm --force "$container" >/dev/null || true
  fi
  rm -rf -- "$scratch"
}
trap cleanup EXIT
# The deployed v3 platform predates the retired state.
historical_ref=12f672efce8d4da88395cb1d71c879ca443ff000
scripts_path=kubernetes/apps/automation-data/postgresql/app/scripts
mkdir -m 700 "$scratch/historical"
for name in init-platform.sh platform-control.sql nocodb-extension.sql nocodb-metadata.sql \
    domain-validation.sql application-login.sql; do
  git show "$historical_ref:$scripts_path/$name" >"$scratch/historical/$name"
done
chmod +x "$scratch/historical/init-platform.sh"
cat >"$scratch/postgresql.env" <<EOF
POSTGRES_USER=postgres
POSTGRES_DB=automation_data_control
POSTGRES_PASSWORD=$(openssl rand -hex 24)
PROVISIONER_PASSWORD=$(openssl rand -hex 24)
BACKUP_PASSWORD=$(openssl rand -hex 24)
EXPORTER_PASSWORD=$(openssl rand -hex 24)
FIXTURE_MIGRATOR_PASSWORD=$(openssl rand -hex 24)
FIXTURE_RUNTIME_PASSWORD=$(openssl rand -hex 24)
APPLICATION_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 "$scratch/postgresql.env"
podman run --detach --name "$container" --label "homelab-talos.test-run=$marker" \
  --env-file "$scratch/postgresql.env" \
  --volume "$scratch/historical:/scripts:ro" \
  --volume "$scratch/historical/init-platform.sh:/docker-entrypoint-initdb.d/00-init-platform.sh:ro" \
  --volume "$(pwd)/$scripts_path:/candidate:ro" \
  postgres:17.11-alpine3.24 >"$scratch/container-id"
query() {
  podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
    --tuples-only --no-align --username postgres --dbname automation_data_control \
    --command="$1"
}
upgrade() {
  podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
    --tuples-only --no-align --username postgres --dbname automation_data_control \
    --file /candidate/upgrade-nocodb.sql
}
for _attempt in {1..60}; do
  if podman exec "$container" sh -eu -c 'grep -qx postgres /proc/1/comm' >/dev/null 2>&1 &&
      query 'SELECT platform_operations.read_platform_revision()' 2>/dev/null \
      | rg -qx '026-nocodb-v3'; then break; fi
  sleep 1
done
[[ "$(query 'SELECT platform_operations.read_platform_revision()')" == 026-nocodb-v3 ]]

stage=v3-fixture
cat >"$scratch/setup.sql" <<'SQL'
\getenv migrator_password FIXTURE_MIGRATOR_PASSWORD
\getenv runtime_password FIXTURE_RUNTIME_PASSWORD
\getenv application_password APPLICATION_PASSWORD
SELECT platform_operations.provision_domain('v4_fixture', :'migrator_password', :'runtime_password');
SELECT platform_operations.record_domain_credentials('v4_fixture', 'synthetic-migrator',
  'synthetic-runtime', '2026-09-01T00:00:00Z'::timestamptz,
  '2026-09-01T00:00:00Z'::timestamptz);
SELECT platform_operations.register_application_login('v4_fixture', 'interview', 'interview_api');
-- Stand in for a completed activation; the upgrade must not touch this login.
UPDATE platform_operations.managed_application_logins
  SET state = 'ready', credential_generation = 1
  WHERE domain = 'v4_fixture' AND application = 'interview';
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L',
  'app_' || md5('v4_fixture:interview') || '_integration', :'application_password') \gexec
SQL
podman cp "$scratch/setup.sql" "$container:/tmp/v4-setup.sql"
podman exec --env-file "$scratch/postgresql.env" "$container" psql --no-psqlrc \
  --set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control \
  --file /tmp/v4-setup.sql >"$scratch/setup.out"
login_row="SELECT to_jsonb(login)::text FROM platform_operations.managed_application_logins AS login
  WHERE domain = 'v4_fixture' AND application = 'interview'"
role="app_$(printf 'v4_fixture:interview' | md5sum | cut -d' ' -f1)_integration"
query "$login_row" >"$scratch/login-before.json"
query "SELECT rolpassword FROM pg_authid WHERE rolname = '$role'" >"$scratch/verifier-before"
chmod 600 "$scratch/verifier-before"
if query "BEGIN; UPDATE platform_operations.managed_application_logins SET state = 'retired'
    WHERE domain = 'v4_fixture'; ROLLBACK" >"$scratch/old-check.out" 2>"$scratch/old-check.err"; then
  echo 'The historical v3 state list already accepted retired.' >&2; exit 1
fi
rg -q 'managed_application_logins_state_check' "$scratch/old-check.err"

stage=upgrade
upgrade >"$scratch/upgrade.out"
rg -Fxq 'installed_revision=026-nocodb-v4' "$scratch/upgrade.out"
[[ "$(query 'SELECT platform_operations.read_platform_revision()')" == 026-nocodb-v4 ]]
query "$login_row" >"$scratch/login-after.json"
cmp -s "$scratch/login-before.json" "$scratch/login-after.json"
query "SELECT rolpassword FROM pg_authid WHERE rolname = '$role'" >"$scratch/verifier-after"
cmp -s "$scratch/verifier-before" "$scratch/verifier-after"
query "BEGIN; UPDATE platform_operations.managed_application_logins SET state = 'retired'
  WHERE domain = 'v4_fixture'; ROLLBACK" >/dev/null
[[ "$(query "SELECT has_function_privilege('automation_data_provisioner',
  'platform_operations.retire_application_login(text,text)', 'EXECUTE')")" == t ]]
[[ "$(query "SELECT has_function_privilege('public',
  'platform_operations.retire_application_login(text,text)', 'EXECUTE')")" == f ]]
[[ "$(query "SELECT platform_operations.capture_backup_state()->>'platformRevision'")" == 026-nocodb-v4 ]]

stage=rerun
generation_before="$(query 'SELECT generation FROM platform_operations.platform_generation')"
upgrade >"$scratch/rerun.out"
rg -Fxq 'installed_revision=026-nocodb-v4' "$scratch/rerun.out"
[[ "$(query 'SELECT generation FROM platform_operations.platform_generation')" == "$generation_before" ]]
query "$login_row" >"$scratch/login-rerun.json"
cmp -s "$scratch/login-before.json" "$scratch/login-rerun.json"
echo 'automation-data v3-to-v4 upgrade preserved logins and added retirement.'
