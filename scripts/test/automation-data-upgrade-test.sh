#!/usr/bin/env bash
# Offline contract and disposable PostgreSQL tests for the fixed NocoDB platform upgrade.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

upgrade_command='scripts/upgrade/automation-data.sh'
upgrade_sql='kubernetes/apps/automation-data/postgresql/app/scripts/upgrade-nocodb.sql'
extension_sql='kubernetes/apps/automation-data/postgresql/app/scripts/nocodb-extension.sql'
control_sql='kubernetes/apps/automation-data/postgresql/app/scripts/platform-control.sql'
init_script='kubernetes/apps/automation-data/postgresql/app/scripts/init-platform.sh'
kustomization='kubernetes/apps/automation-data/postgresql/app/kustomization.yaml'

fail() {
	echo "automation-data upgrade test failed: $*" >&2
	exit 1
}

for source in "$upgrade_command" "$upgrade_sql" "$extension_sql" "$control_sql" \
	"$init_script" "$kustomization"; do
	[[ -f "$source" ]] || fail "missing $source"
done
[[ -x "$upgrade_command" ]] || fail 'upgrade command is not executable'

recipe="$(mise exec -- just --dry-run kube automation-data-upgrade 2>&1)" ||
	fail 'missing kube automation-data-upgrade recipe'
rg -Fq -- "scripts/upgrade/automation-data.sh '.kube/config'" <<<"$recipe" ||
	fail 'upgrade recipe does not pass only the scoped kubeconfig'

[[ "$(yq -r '
  select(.kind == "Kustomization") |
  [.configMapGenerator[] | select(.name == "automation-data-postgresql-upgrade") |
    (.files | sort | join(","))] | join("")
' "$kustomization")" == 'nocodb-extension.sql=scripts/nocodb-extension.sql,upgrade-nocodb.sql=scripts/upgrade-nocodb.sql' ]] ||
	fail 'upgrade ConfigMap does not contain the two fixed reviewed SQL sources'

rg -Fq '\ir nocodb-extension.sql' "$control_sql" ||
	fail 'fresh initialization does not load the shared NocoDB definitions'
rg -Fq '\ir nocodb-extension.sql' "$upgrade_sql" ||
	fail 'the upgrade does not load the shared NocoDB definitions'
! rg -n -- '--set=(revision|database|role|sql)=|--command=' "$upgrade_command" >/dev/null ||
	fail 'upgrade command exposes mutable SQL, revision, database, or role input'
! rg -n 'get secret|secrets[[:space:]]|jsonpath=.*data\.' "$upgrade_command" >/dev/null ||
	fail 'upgrade command retrieves Secret data'

# The behavioral command fixture names the production breaks it catches: stale source,
# wrong workload identity, missing backup evidence, and overlap must all stop before Job
# creation. A valid run must read back the fixed revision and delete only its own Job.
fixture="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-upgrade-command.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
stub_bin="$fixture/bin"
case_root="$fixture/case"
mkdir -p "$stub_bin"
remote_main='0123456789012345678901234567890123456789'
export UPGRADE_TEST_LOG="$fixture/events.log"
export UPGRADE_TEST_REMOTE_MAIN="$remote_main"

cat >"$stub_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git\t%s\n' "$*" >>"$UPGRADE_TEST_LOG"
case "$*" in
  'remote get-url origin') printf '%s\n' 'https://github.com/supermorphic/homelab-talos.git' ;;
  'status --porcelain') ;;
  'ls-remote --exit-code origin refs/heads/main')
    printf '%s\trefs/heads/main\n' "$UPGRADE_TEST_REMOTE_MAIN"
    ;;
  "cat-file -e ${UPGRADE_TEST_REMOTE_MAIN}^{commit}") ;;
  "diff --quiet ${UPGRADE_TEST_REMOTE_MAIN} --"*)
    [[ "${UPGRADE_TEST_CASE:-}" != stale-source ]] || exit 1
    ;;
  *) echo "unexpected git invocation: $*" >&2; exit 64 ;;
esac
EOF

cat >"$stub_bin/just" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'just\t%s\n' "$*" >>"$UPGRADE_TEST_LOG"
case "$*" in
  'kube automation-data-validate') ;;
  'kube automation-data-verify')
    [[ "${UPGRADE_TEST_CASE:-}" != missing-backup ]] || exit 70
    ;;
  *) echo "unexpected just invocation: $*" >&2; exit 64 ;;
esac
EOF

cat >"$stub_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl\t%s\n' "$*" >>"$UPGRADE_TEST_LOG"
case "$*" in
  *'--namespace flux-system get gitrepository flux-system --output jsonpath={.status.artifact.revision}')
    printf 'main@sha1:%s' "$UPGRADE_TEST_REMOTE_MAIN"
    ;;
  *'--namespace automation-data get statefulset automation-data-postgresql --output json')
    if [[ "${UPGRADE_TEST_CASE:-}" == wrong-target ]]; then
      printf '%s\n' '{"metadata":{"name":"automation-data-postgresql"},"spec":{"serviceName":"other","replicas":1,"template":{"spec":{"containers":[{"name":"postgresql","image":"postgres:17.11-alpine3.24"}]}}},"status":{"observedGeneration":1,"currentRevision":"a","updateRevision":"a","readyReplicas":1},"metadata":{"name":"automation-data-postgresql","generation":1}}'
    else
      printf '%s\n' '{"metadata":{"name":"automation-data-postgresql","generation":1},"spec":{"serviceName":"automation-data-postgresql","replicas":1,"template":{"spec":{"containers":[{"name":"postgresql","image":"postgres:17.11-alpine3.24"}]}}},"status":{"observedGeneration":1,"currentRevision":"a","updateRevision":"a","readyReplicas":1}}'
    fi
    ;;
  *'--namespace automation-data get job automation-data-nocodb-upgrade --output json')
    if [[ "${UPGRADE_TEST_CASE:-}" == overlap ]]; then
      printf '%s\n' '{"metadata":{"name":"automation-data-nocodb-upgrade"}}'
    else
      exit 1
    fi
    ;;
  *'--namespace automation-data get configmaps --output json')
    printf '%s\n' '{"items":[{"metadata":{"name":"automation-data-postgresql-upgrade-abc123"},"data":{"nocodb-extension.sql":"fixed","upgrade-nocodb.sql":"fixed"}}]}'
    ;;
  *'--namespace automation-data create --filename -')
    cat >"$UPGRADE_TEST_CASE_ROOT/job.yaml"
    printf 'create-job\n' >>"$UPGRADE_TEST_LOG"
    ;;
  *'--namespace automation-data wait --for=condition=Complete job/automation-data-nocodb-upgrade --timeout=5m')
    case "${UPGRADE_TEST_CASE:-}" in
      sql-unknown | sql-partial | sql-overlap) exit 72 ;;
    esac
    ;;
  *'--namespace automation-data logs job/automation-data-nocodb-upgrade --container=upgrade')
    printf '%s\n' 'installed_revision=026-nocodb-v1' 'extension_contract_valid=true'
    ;;
  *'--namespace automation-data delete job automation-data-nocodb-upgrade --wait=true --timeout=2m')
    printf 'delete-job\n' >>"$UPGRADE_TEST_LOG"
    ;;
  *) echo "unexpected kubectl invocation: $*" >&2; exit 64 ;;
esac
EOF
chmod 700 "$stub_bin/git" "$stub_bin/just" "$stub_bin/kubectl"

run_case() {
	local name="$1" confirmation="${2:-upgrade:automation-data:nocodb-v1}" output status
	rm -rf -- "$case_root"
	mkdir -p "$case_root"
	: >"$case_root/kubeconfig"
	: >"$UPGRADE_TEST_LOG"
	set +e
	output="$(cd "$repo_root" && env PATH="$stub_bin:$PATH" \
		UPGRADE_TEST_CASE="$name" UPGRADE_TEST_CASE_ROOT="$case_root" \
		AUTOMATION_DATA_UPGRADE_CONFIRM="$confirmation" \
		"$upgrade_command" "$case_root/kubeconfig" 2>&1)"
	status=$?
	set -e
	printf '%s\n' "$output" >"$case_root/output"
	return "$status"
}

for rejected in stale-source wrong-target missing-backup overlap; do
	if run_case "$rejected"; then
		fail "$rejected was accepted"
	fi
	! rg -Fxq create-job "$UPGRADE_TEST_LOG" ||
		fail "$rejected created a Job"
done

for sql_rejection in sql-unknown sql-partial sql-overlap; do
	if run_case "$sql_rejection"; then
		fail "$sql_rejection was accepted"
	fi
	rg -Fxq create-job "$UPGRADE_TEST_LOG" ||
		fail "$sql_rejection did not reach its bounded SQL Job"
	rg -Fxq delete-job "$UPGRADE_TEST_LOG" ||
		fail "$sql_rejection did not remove its bounded SQL Job"
done

run_case valid || fail 'valid fixed upgrade was rejected'
rg -Fxq create-job "$UPGRADE_TEST_LOG" || fail 'valid upgrade did not create its Job'
rg -Fxq delete-job "$UPGRADE_TEST_LOG" || fail 'valid upgrade did not delete its Job'
[[ "$(yq -r '[.kind, .metadata.name, .spec.template.spec.containers[0].name,
  .spec.template.spec.containers[0].env[] | select(.name == "PGPASSWORD") |
  .valueFrom.secretKeyRef.name + "/" + .valueFrom.secretKeyRef.key] | join("|")' \
	"$case_root/job.yaml")" == 'Job|automation-data-nocodb-upgrade|upgrade|postgresql-credentials/backup-password' ]] ||
	fail 'upgrade Job identity or Secret reference is wrong'
rg -Fxq 'installed_revision=026-nocodb-v1' "$case_root/output" ||
	fail 'valid upgrade did not read back the fixed installed revision'
! rg -n 'password|SCRAM-SHA-256' "$case_root/output" >/dev/null ||
	fail 'valid upgrade output exposed credential material'

echo 'automation-data fixed upgrade command contract passed.'

# Real database proof. The old initialization sources come from committed Git objects;
# no file from another checkout or worktree participates in this fixture.
command -v podman >/dev/null || fail 'Podman is required for the upgrade integration test'
podman info >/dev/null 2>&1 || fail 'Podman engine is unavailable'

integration_root="$(mktemp -d "$repo_root/.tmp/automation-data-upgrade-pg.XXXXXX")"
chmod 700 "$integration_root"
containers=()
cleanup_integration() {
	local container
	set +e
	for container in "${containers[@]}"; do
		podman rm --force "$container" >/dev/null 2>&1 || true
	done
	rm -rf -- "$integration_root"
}
trap 'cleanup_integration; rm -rf -- "$fixture"' EXIT

baseline='508a1b8f4562'
image='postgres:17.11-alpine3.24'
baseline_scripts="$integration_root/baseline-scripts"
candidate_scripts="$repo_root/kubernetes/apps/automation-data/postgresql/app/scripts"
mkdir -p "$baseline_scripts" "$integration_root/backups/old" \
	"$integration_root/backups/new" "$integration_root/private"
chmod 700 "$integration_root/private"
for source_name in init-platform.sh platform-control.sql update-backup-status.sql; do
	git show "$baseline:kubernetes/apps/automation-data/postgresql/app/scripts/$source_name" \
		>"$baseline_scripts/$source_name"
done
chmod 700 "$baseline_scripts/init-platform.sh"

credential_env="$integration_root/private/postgresql.env"
{
	printf 'POSTGRES_USER=postgres\n'
	printf 'POSTGRES_DB=automation_data_control\n'
	printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 24)"
	printf 'PROVISIONER_PASSWORD=%s\n' "$(openssl rand -hex 24)"
	printf 'BACKUP_PASSWORD=%s\n' "$(openssl rand -hex 24)"
	printf 'EXPORTER_PASSWORD=%s\n' "$(openssl rand -hex 24)"
	printf 'FIXTURE_MIGRATOR_PASSWORD=%s\n' "$(openssl rand -hex 24)"
	printf 'FIXTURE_RUNTIME_PASSWORD=%s\n' "$(openssl rand -hex 24)"
} >"$credential_env"
chmod 600 "$credential_env"

populate_sql="$integration_root/private/populate.sql"
cat >"$populate_sql" <<'EOSQL'
\getenv migrator_password FIXTURE_MIGRATOR_PASSWORD
\getenv runtime_password FIXTURE_RUNTIME_PASSWORD
SELECT platform_operations.provision_domain(
  'upgrade_fixture', :'migrator_password', :'runtime_password'
);
SELECT platform_operations.record_domain_credentials(
  'upgrade_fixture', 'migrator-fixture-id', 'runtime-fixture-id',
  '2026-09-05T00:00:00Z'::timestamptz, '2026-09-05T00:00:00Z'::timestamptz
);
EOSQL
cat >"$integration_root/private/domain-data.sql" <<'EOSQL'
SET ROLE upgrade_fixture_owner;
CREATE TABLE app.records (id bigint PRIMARY KEY, value text NOT NULL);
INSERT INTO app.records VALUES (1, 'preserved-value'), (2, 'second-value');
RESET ROLE;
EOSQL
chmod 600 "$populate_sql" "$integration_root/private/domain-data.sql"

new_container_name() {
	printf 'automation-data-upgrade-%s-%s' "$1" "$$"
}

start_database() { # <name> <baseline|candidate|empty>
	local name="$1" mode="$2" log
	log="$integration_root/$name-start.log"
	local -a volumes=() environment_overrides=()
	case "$mode" in
	baseline)
		volumes+=(
			--volume "$baseline_scripts:/scripts:ro"
			--volume "$baseline_scripts/init-platform.sh:/docker-entrypoint-initdb.d/00-init-platform.sh:ro"
			--volume "$candidate_scripts:/candidate:ro"
		)
		;;
	candidate)
		volumes+=(
			--volume "$candidate_scripts:/scripts:ro"
			--volume "$candidate_scripts/init-platform.sh:/docker-entrypoint-initdb.d/00-init-platform.sh:ro"
		)
		;;
	empty) environment_overrides+=(--env POSTGRES_DB=postgres) ;;
	*) return 2 ;;
	esac
	podman run --detach --name "$name" --env-file "$credential_env" \
		"${environment_overrides[@]}" "${volumes[@]}" "$image" >"$log" 2>&1 ||
		fail "could not start $mode PostgreSQL fixture"
	containers+=("$name")
	for _attempt in {1..60}; do
		if podman exec "$name" pg_isready --username postgres >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
	done
	tail -n 60 "$log" >&2
	podman logs --tail 60 "$name" >&2 || true
	fail "$mode PostgreSQL fixture did not become ready"
}

psql_file() { # <container> <database> <file>
	podman exec --env-file "$credential_env" "$1" psql --no-psqlrc \
		--set=ON_ERROR_STOP=1 --tuples-only --no-align \
		--username postgres --dbname "$2" --file "$3"
}

psql_query() { # <container> <database> <query>
	podman exec "$1" psql --no-psqlrc --set=ON_ERROR_STOP=1 --tuples-only \
		--no-align --username postgres --dbname "$2" --command "$3"
}

old_container="$(new_container_name old)"
start_database "$old_container" baseline
podman cp "$populate_sql" "$old_container:/tmp/populate.sql"
podman cp "$integration_root/private/domain-data.sql" "$old_container:/tmp/domain-data.sql"
psql_file "$old_container" automation_data_control /tmp/populate.sql >/dev/null
psql_file "$old_container" upgrade_fixture /tmp/domain-data.sql >/dev/null

capture_preservation_state() { # <suffix>
	local suffix="$1"
	psql_query "$old_container" automation_data_control "
SELECT row_to_json(managed)::text
FROM platform_operations.managed_domains AS managed
ORDER BY domain;
" >"$integration_root/domain-registry-$suffix"
	psql_query "$old_container" automation_data_control \
		'SELECT generation::text FROM platform_operations.platform_generation WHERE singleton;' \
		>"$integration_root/platform-generation-$suffix"
	psql_query "$old_container" automation_data_control \
		'SELECT platform_operations.capture_backup_state()::text;' \
		>"$integration_root/backup-state-$suffix"
	psql_query "$old_container" automation_data_control "
SELECT rolname || '|' || oid::text
FROM pg_roles
WHERE rolname IN (
  'automation_data_provisioner', 'automation_data_backup', 'automation_data_exporter',
  'upgrade_fixture_owner', 'upgrade_fixture_migrator', 'upgrade_fixture_runtime'
)
ORDER BY rolname;
" >"$integration_root/role-oids-$suffix"
	psql_query "$old_container" automation_data_control "
SELECT rolname || '|' || COALESCE(rolpassword, '')
FROM pg_authid
WHERE rolname IN (
  'automation_data_provisioner', 'automation_data_backup', 'automation_data_exporter',
  'upgrade_fixture_migrator', 'upgrade_fixture_runtime'
)
ORDER BY rolname;
" >"$integration_root/private/verifiers-$suffix"
	psql_query "$old_container" upgrade_fixture "
SELECT grantee || '|' || table_schema || '|' || table_name || '|' || privilege_type
FROM information_schema.role_table_grants
WHERE table_schema = 'app'
ORDER BY grantee, table_name, privilege_type;
" >"$integration_root/grants-$suffix"
	psql_query "$old_container" upgrade_fixture \
		'SELECT id::text || '\''|'\'' || value FROM app.records ORDER BY id;' \
		>"$integration_root/data-$suffix"
	chmod 600 "$integration_root/private/verifiers-$suffix"
}
capture_preservation_state before

run_backup_in_container() { # <container> <host-output-directory>
	local container="$1" output="$2" container_output
	container_output="/tmp/$(basename "$output")"
	podman exec "$container" mkdir -p "$container_output"
	podman cp "$candidate_scripts/backup.sh" "$container:/tmp/candidate-backup.sh"
	podman exec --env BACKUP_DIR="$container_output" --env PGDATABASE=automation_data_control \
		--env PGUSER=postgres "$container" /bin/sh /tmp/candidate-backup.sh >/dev/null
	podman cp "$container:$container_output/." "$output"
}
run_backup_in_container "$old_container" "$integration_root/backups/old"
old_bundle="$(find "$integration_root/backups/old" -mindepth 1 -maxdepth 1 \
	-type d -name 'automation-data-*' -print -quit)"
[[ -n "$old_bundle" && -s "$old_bundle/COMPLETE" ]] ||
	fail 'candidate backup did not publish a bundle for the old schema'

# Partial extension artifacts, an unknown recorded revision, and a held advisory lock
# must each fail before persistent upgrade mutation.
psql_query "$old_container" automation_data_control \
	'CREATE TABLE platform_operations.managed_nocodb_sources (partial boolean);' >/dev/null
if psql_file "$old_container" automation_data_control /candidate/upgrade-nocodb.sql \
	>"$integration_root/partial-output" 2>&1; then
	fail 'partial extension schema was accepted'
fi
[[ "$(psql_query "$old_container" automation_data_control \
	"SELECT to_regclass('platform_operations.platform_schema_revision') IS NULL;")" == t ]] ||
	fail 'partial extension failure persisted migration metadata'
psql_query "$old_container" automation_data_control \
	'DROP TABLE platform_operations.managed_nocodb_sources;' >/dev/null

psql_query "$old_container" automation_data_control "
CREATE TABLE platform_operations.platform_schema_revision (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  revision text NOT NULL,
  installed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO platform_operations.platform_schema_revision(singleton, revision)
VALUES (true, '999-unknown');
" >/dev/null
if psql_file "$old_container" automation_data_control /candidate/upgrade-nocodb.sql \
	>"$integration_root/unknown-output" 2>&1; then
	fail 'unknown installed revision was accepted'
fi
[[ "$(psql_query "$old_container" automation_data_control \
	'SELECT revision FROM platform_operations.platform_schema_revision WHERE singleton;')" == 999-unknown ]] || fail 'unknown revision failure overwrote migration metadata'
psql_query "$old_container" automation_data_control \
	'DROP TABLE platform_operations.platform_schema_revision;' >/dev/null

lock_sql="$integration_root/private/hold-lock.sql"
cat >"$lock_sql" <<'EOSQL'
BEGIN;
SELECT pg_advisory_xact_lock(
  hashtextextended('automation-data:platform-upgrade:026-nocodb-v1', 0)
);
SELECT pg_sleep(4);
COMMIT;
EOSQL
chmod 600 "$lock_sql"
podman cp "$lock_sql" "$old_container:/tmp/hold-lock.sql"
podman exec "$old_container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
	--username postgres --dbname automation_data_control --file=/tmp/hold-lock.sql \
	>"$integration_root/lock-session" 2>&1 &
lock_pid=$!
sleep 1
if psql_file "$old_container" automation_data_control /candidate/upgrade-nocodb.sql \
	>"$integration_root/overlap-output" 2>&1; then
	fail 'overlapping SQL upgrade was accepted'
fi
wait "$lock_pid"
[[ "$(psql_query "$old_container" automation_data_control \
	"SELECT to_regclass('platform_operations.platform_schema_revision') IS NULL;")" == t ]] ||
	fail 'overlap refusal persisted upgrade state'

upgrade_output="$integration_root/upgrade-output"
psql_file "$old_container" automation_data_control /candidate/upgrade-nocodb.sql \
	>"$upgrade_output"
rg -Fxq 'installed_revision=026-nocodb-v1' "$upgrade_output" ||
	fail 'real upgrade did not read back its installed revision'
rg -Fxq 'extension_contract_valid=true' "$upgrade_output" ||
	fail 'real upgrade did not validate its extension contract'
capture_preservation_state after

cmp -s "$integration_root/role-oids-before" "$integration_root/role-oids-after" ||
	fail 'upgrade changed an existing role OID'
cmp -s "$integration_root/private/verifiers-before" \
	"$integration_root/private/verifiers-after" || fail 'upgrade changed a password verifier'
cmp -s "$integration_root/grants-before" "$integration_root/grants-after" ||
	fail 'upgrade changed existing domain grants'
cmp -s "$integration_root/data-before" "$integration_root/data-after" ||
	fail 'upgrade changed existing domain data'
cmp -s "$integration_root/domain-registry-before" \
	"$integration_root/domain-registry-after" || fail 'upgrade changed the managed domain registry'
cmp -s "$integration_root/platform-generation-before" \
	"$integration_root/platform-generation-after" || fail 'catalog-only upgrade changed platform generation'
cmp -s "$integration_root/backup-state-before" "$integration_root/backup-state-after" &&
	fail 'backup capture did not detect the schema revision change'
[[ "$(psql_query "$old_container" automation_data_control \
	"SELECT NOT (\$\$$(<"$integration_root/backup-state-before")\$\$::jsonb ? 'platformRevision');")" == t ]] ||
	fail 'baseline backup capture unexpectedly included a platform revision'
[[ "$(psql_query "$old_container" automation_data_control \
	"SELECT \$\$$(<"$integration_root/backup-state-after")\$\$::jsonb->>'platformRevision';")" == 026-nocodb-v1 ]] ||
	fail 'upgraded backup capture did not include the installed revision'

installed_at_before="$(psql_query "$old_container" automation_data_control \
	"SELECT installed_at::text FROM platform_operations.platform_schema_revision WHERE singleton;")"
rerun_output="$integration_root/rerun-output"
psql_file "$old_container" automation_data_control /candidate/upgrade-nocodb.sql \
	>"$rerun_output"
installed_at_after="$(psql_query "$old_container" automation_data_control \
	"SELECT installed_at::text FROM platform_operations.platform_schema_revision WHERE singleton;")"
[[ "$installed_at_before" == "$installed_at_after" ]] ||
	fail 'validated no-op rerun rewrote migration metadata'
rg -Fxq 'installed_revision=026-nocodb-v1' "$rerun_output" ||
	fail 'no-op rerun did not validate the installed revision'

run_backup_in_container "$old_container" "$integration_root/backups/new"
new_bundle="$(find "$integration_root/backups/new" -mindepth 1 -maxdepth 1 \
	-type d -name 'automation-data-*' -print -quit)"
[[ -n "$new_bundle" && -s "$new_bundle/COMPLETE" ]] ||
	fail 'candidate backup did not publish a bundle for the upgraded schema'

extension_catalog_query="
SELECT 'table|' || table_name || '|' || column_name || '|' || data_type || '|' || is_nullable
FROM information_schema.columns
WHERE table_schema = 'platform_operations'
  AND table_name IN ('platform_schema_revision', 'managed_nocodb_sources')
UNION ALL
SELECT 'function|' || namespace.nspname || '.' || procedure.proname || '|' ||
  pg_get_function_identity_arguments(procedure.oid) || '|' || owner_role.rolname
FROM pg_proc AS procedure
JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
JOIN pg_roles AS owner_role ON owner_role.oid = procedure.proowner
WHERE namespace.nspname IN ('platform_operations', 'platform_internal')
  AND (procedure.proname LIKE '%nocodb%' OR procedure.proname = 'read_platform_revision')
ORDER BY 1;
"
psql_query "$old_container" automation_data_control "$extension_catalog_query" \
	>"$integration_root/upgraded-catalog"

fresh_container="$(new_container_name fresh)"
start_database "$fresh_container" candidate
[[ "$(psql_query "$fresh_container" automation_data_control \
	'SELECT platform_operations.read_platform_revision();')" == 026-nocodb-v1 ]] ||
	fail 'fresh initialization did not install the fixed revision'
psql_query "$fresh_container" automation_data_control "$extension_catalog_query" \
	>"$integration_root/fresh-catalog"
cmp -s "$integration_root/upgraded-catalog" "$integration_root/fresh-catalog" ||
	fail 'fresh and upgraded extension catalogs differ'

restore_bundle() { # <bundle> <expected-revision>
	local bundle="$1" expected="$2" name restore_container globals_filtered
	name="restore-${expected//[^a-z0-9]/-}"
	restore_container="$(new_container_name "$name")"
	start_database "$restore_container" empty
	podman cp "$bundle" "$restore_container:/tmp/source-bundle"
	globals_filtered="$integration_root/private/globals-$name.sql"
	awk '$0 != "CREATE ROLE postgres;"' "$bundle/globals.sql" >"$globals_filtered"
	[[ "$(rg -c -x 'CREATE ROLE postgres;' "$bundle/globals.sql")" == 1 ]] ||
		fail "$expected bundle has an invalid bootstrap-role declaration"
	podman cp "$globals_filtered" "$restore_container:/tmp/globals.sql"
	podman exec "$restore_container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
		--username postgres --dbname postgres --file=/tmp/globals.sql >/dev/null
	while IFS=$'\t' read -r record encoded dump_path; do
		[[ "$record" == database ]] || continue
		database_name="$(printf '%s' "$encoded" | base64 -d)"
		if [[ "$database_name" == postgres ]]; then
			podman exec "$restore_container" pg_restore --exit-on-error --username postgres \
				--dbname postgres "/tmp/source-bundle/$dump_path" >/dev/null
		else
			podman exec "$restore_container" pg_restore --exit-on-error --create \
				--username postgres --dbname postgres "/tmp/source-bundle/$dump_path" >/dev/null
		fi
	done <"$bundle/manifest.tsv"
	if [[ "$expected" == 025-baseline ]]; then
		[[ "$(psql_query "$restore_container" automation_data_control \
			"SELECT to_regclass('platform_operations.platform_schema_revision') IS NULL AND to_regclass('platform_operations.managed_nocodb_sources') IS NULL;")" == t ]] ||
			fail 'old bundle did not restore the recognized baseline schema'
	else
		[[ "$(psql_query "$restore_container" automation_data_control \
			'SELECT platform_operations.read_platform_revision();')" == "$expected" ]] ||
			fail 'new bundle did not restore the installed revision'
	fi
	[[ "$(psql_query "$restore_container" upgrade_fixture \
		"SELECT string_agg(id::text || ':' || value, ',' ORDER BY id) FROM app.records;")" == '1:preserved-value,2:second-value' ]] || fail "$expected bundle lost domain data"
}

restore_bundle "$old_bundle" 025-baseline
restore_bundle "$new_bundle" 026-nocodb-v1

printf '%s\n' \
	'role_oids_unchanged=true' \
	'existing_grants_unchanged=true' \
	'existing_data_unchanged=true' \
	'managed_domain_registry_unchanged=true' \
	'platform_generation_unchanged=true' \
	'backup_capture_detects_revision_change=true' \
	'password_verifiers_equal=true' \
	'old_bundle_restore_valid=true' \
	'upgraded_bundle_restore_valid=true' \
	'fresh_upgrade_catalog_equal=true'
echo 'automation-data populated-platform upgrade integration passed.'
