#!/usr/bin/env bash
# Real restricted-reader permission and projection checks against disposable PostgreSQL.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
scratch="$(mktemp -d "$PWD/.tmp/discovery-sql.XXXXXX")"
chmod 700 "$scratch"
marker="discovery-sql-$$-$RANDOM"
container="$marker"
cleanup() {
	if podman container exists "$container" >/dev/null 2>&1 &&
		[[ "$(podman inspect --format '{{ index .Config.Labels "homelab-talos.test-run" }}' "$container")" == "$marker" ]]; then
		podman rm --force "$container" >/dev/null
	fi
	rm -r -- "$scratch"
}
trap cleanup EXIT
for file in kubernetes/apps/automation-data/postgresql/app/scripts/credential-discovery.sql \
	kubernetes/apps/automation-data/postgresql/app/scripts/nocodb-discovery.sql \
	kubernetes/apps/automation/n8n-postgresql/app/scripts/credential-discovery.sql; do
	[[ -f "$file" ]] || {
		echo 'Metadata SQL projection implementation missing.' >&2
		exit 1
	}
done
cat >"$scratch/postgres.env" <<EOF
POSTGRES_DB=automation_data_control
POSTGRES_USER=postgres
POSTGRES_PASSWORD=$(openssl rand -hex 24)
PROVISIONER_PASSWORD=$(openssl rand -hex 24)
BACKUP_PASSWORD=$(openssl rand -hex 24)
EXPORTER_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 "$scratch/postgres.env"
podman run --detach --name "$container" --label "homelab-talos.test-run=$marker" \
	--env-file "$scratch/postgres.env" \
	--volume "$PWD/kubernetes/apps/automation-data/postgresql/app/scripts:/scripts:ro" \
	--volume "$PWD/kubernetes/apps/automation-data/postgresql/app/scripts/init-platform.sh:/docker-entrypoint-initdb.d/init.sh:ro" \
	postgres:17.11-alpine3.24 >/dev/null
for _ in {1..60}; do
	if podman exec "$container" sh -c 'test "$(cat /proc/1/comm)" = postgres' &&
		podman exec "$container" psql -X -U postgres -d automation_data_control -Atc 'SELECT 1' >/dev/null 2>&1; then break; fi
	sleep 1
done
query() { podman exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U "$2" -d "$1" -At; }
query automation_data_control postgres >"$scratch/bootstrap.out" <<'SQL'
CREATE DATABASE n8n;
CREATE DATABASE nocodb;
SELECT platform_operations.provision_domain('sample', repeat('synthetic-migrator-', 3), repeat('synthetic-runtime-', 3));
SELECT platform_operations.record_domain_credentials('sample', 'fixture-migrator', 'fixture-runtime', now(), now());
CREATE ROLE unregistered_fixture LOGIN;
CREATE TABLE public.business_records(payload text);
INSERT INTO public.business_records VALUES ('SENTINEL_SECRET_PAYLOAD');
SQL
python - "$scratch" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1]);contract=json.loads(Path('tests/fixtures/automation-data-discovery/schema-contract.json').read_text())
for database in ('n8n','nocodb'):
    lines=[]
    for table,columns in contract[database]['tables'].items():
        types={'character varying':'varchar','timestamp with time zone':'timestamptz'}
        definition=','.join('"'+c+'" '+types.get(t,t) for c,t in columns.items())
        lines.append(f'CREATE TABLE public."{table}" ({definition});')
    if database=='n8n':
        lines += ["ALTER TABLE credentials_entity ADD COLUMN data text;",
                  "ALTER TABLE workflow_entity ADD COLUMN nodes json;",
                  '''INSERT INTO credentials_entity(id,name,type,"updatedAt",data) VALUES ('fixture-runtime','automation-data/sample/runtime','postgres',now(),'SENTINEL_SECRET_PAYLOAD');''',
                  '''INSERT INTO workflow_entity(id,active,"activeVersionId","isArchived",nodes) VALUES ('fixture-workflow',true,'published-version',false,'[{"parameters":{"password":"SENTINEL_SECRET_PAYLOAD"},"credentials":{"postgres":{"id":"draft-only"}}}]');''',
                  '''INSERT INTO workflow_history("versionId","workflowId",nodes) VALUES ('published-version','fixture-workflow','[{"name":"Unsafe raw name","parameters":{"password":"SENTINEL_SECRET_PAYLOAD"},"credentials":{"postgres":{"id":"fixture-runtime"}}}]');''',
                  '''INSERT INTO workflow_published_version("workflowId","publishedVersionId") VALUES ('fixture-workflow','published-version');''']
    else:
        lines += ["ALTER TABLE nc_integrations_v2 ADD COLUMN config text;",
                  "ALTER TABLE nc_users_v2 ADD COLUMN password text;",
                  "ALTER TABLE nc_api_tokens ADD COLUMN token text;",
                  "INSERT INTO workspace(id,deleted) VALUES('workspace-fixture',false);",
                  "INSERT INTO nc_bases_v2(id,fk_workspace_id,deleted) VALUES('base-fixture','workspace-fixture',false);",
                  "INSERT INTO nc_integrations_v2(id,fk_workspace_id,type,sub_type,deleted,updated_at,config) VALUES('integration-only','workspace-fixture','database','pg',false,now(),'SENTINEL_SECRET_PAYLOAD');",
                  "INSERT INTO nc_sources_v2(id,base_id,fk_workspace_id,fk_integration_id,is_data_readonly,is_schema_readonly,enabled,deleted,is_local,updated_at) VALUES('intrinsic-fixture','base-fixture','workspace-fixture',NULL,false,false,true,false,true,now());",
                  "INSERT INTO nc_users_v2(id,is_deleted,password) VALUES('account-fixture',false,'SENTINEL_SECRET_PAYLOAD');",
                  "INSERT INTO nc_api_tokens(id,expiry,enabled,updated_at,token) VALUES(1,'unlimited',true,now(),'SENTINEL_SECRET_PAYLOAD');"]
    (root/f'{database}.sql').write_text('\n'.join(lines)+'\n')
PY
query n8n postgres <"$scratch/n8n.sql" >"$scratch/n8n-setup.out"
query nocodb postgres <"$scratch/nocodb.sql" >"$scratch/nocodb-setup.out"
query automation_data_control postgres <kubernetes/apps/automation-data/postgresql/app/scripts/credential-discovery.sql >"$scratch/platform-install.out"
query nocodb postgres <kubernetes/apps/automation-data/postgresql/app/scripts/nocodb-discovery.sql >"$scratch/nocodb-install.out"
query n8n postgres <kubernetes/apps/automation/n8n-postgresql/app/scripts/credential-discovery.sql >"$scratch/n8n-install.out"
query automation_data_control postgres >/dev/null <<'SQL'
ALTER ROLE automation_data_inventory LOGIN;
ALTER ROLE nocodb_inventory LOGIN;
ALTER ROLE n8n_inventory LOGIN;
SQL
for target in automation_data_control:automation_data_inventory nocodb:nocodb_inventory n8n:n8n_inventory; do
	database="${target%:*}"
	reader="${target#*:}"
	printf '%s\n' "SET search_path=public; SELECT platform_discovery.read_snapshot();" |
		query "$database" "$reader" >"$scratch/$database-observation.json"
	for denied in 'SELECT rolpassword FROM pg_authid' 'CREATE ROLE illicit_role' \
		'CREATE TABLE public.illicit_table(id int)' 'SELECT * FROM platform_discovery.objects' \
		'CREATE FUNCTION platform_discovery.illicit() RETURNS integer LANGUAGE sql AS $$ SELECT 1 $$'; do
		if printf '%s\n' "$denied" | query "$database" "$reader" >"$scratch/denial.out" 2>&1; then
			echo "Restricted metadata reader unexpectedly received prohibited authority: $database." >&2
			exit 1
		fi
	done
	if printf '%s\n' 'SELECT platform_discovery.read_snapshot();' | query "$database" automation_data_provisioner >"$scratch/public-denial.out" 2>&1; then
		echo 'Projection execution leaked to another login.' >&2
		exit 1
	fi
done
for target in 'n8n:n8n_inventory:SELECT data FROM credentials_entity' \
	'automation_data_control:automation_data_inventory:SELECT payload FROM public.business_records' \
	'n8n:n8n_inventory:SELECT nodes FROM workflow_history' \
	'nocodb:nocodb_inventory:SELECT config FROM nc_integrations_v2' \
	'nocodb:nocodb_inventory:SELECT password FROM nc_users_v2' \
	"automation_data_control:automation_data_inventory:SELECT platform_operations.provision_domain('illicit','x','y')"; do
	database="${target%%:*}"
	rest="${target#*:}"
	reader="${rest%%:*}"
	denied="${rest#*:}"
	if printf '%s\n' "$denied" | query "$database" "$reader" >"$scratch/denial.out" 2>&1; then
		echo 'Restricted metadata reader unexpectedly read secret data or invoked mutation.' >&2
		exit 1
	fi
done
python - "$scratch" <<'PY'
import json,sys
from pathlib import Path
sys.path.insert(0,'scripts/lib')
from automation_data_inventory import validate_observation
root=Path(sys.argv[1]);observations={}
for db,source in [('automation_data_control','platform'),('n8n','n8n'),('nocodb','nocodb')]:
    text=(root/f'{db}-observation.json').read_text().splitlines()[-1]
    assert 'SENTINEL_SECRET_PAYLOAD' not in text
    assert 'draft-only' not in text
    observations[source]=validate_observation(json.loads(text),source)
assert any(o['id']=='unregistered_fixture' for o in observations['platform'].objects)
assert any(o['id']=='integration-only' for o in observations['nocodb'].objects)
assert any(o['kind']=='binding' and o['credentialId']=='fixture-runtime' for o in observations['n8n'].objects)
assert all('Unsafe raw name' not in json.dumps(o) for o in observations['n8n'].objects)
PY
query n8n postgres >/dev/null <<'SQL'
UPDATE workflow_published_version SET "publishedVersionId"='pending-version';
SQL
printf '%s\n' 'SELECT platform_discovery.read_snapshot();' | query n8n n8n_inventory >"$scratch/pending.json"
python - "$scratch/pending.json" <<'PYTHON'
import json,sys
from pathlib import Path
observed=json.loads(Path(sys.argv[1]).read_text().splitlines()[-1])
assert not any(o['kind']=='binding' for o in observed['objects'])
assert all(o['published'] is False for o in observed['objects'] if o['kind']=='workflow')
PYTHON
query n8n postgres >/dev/null <<'SQL'
ALTER TABLE credentials_entity RENAME COLUMN type TO renamed_type;
SQL
printf '%s\n' 'SELECT platform_discovery.read_snapshot();' | query n8n n8n_inventory >"$scratch/drift.json"
python - "$scratch/drift.json" <<'PYTHON'
import json,sys
from pathlib import Path
observed=json.loads(Path(sys.argv[1]).read_text().splitlines()[-1])
assert observed.get('errorCode')=='unsupported_schema', 'schema drift was accepted as current metadata'
assert observed.get('complete') is False
PYTHON
query n8n postgres >/dev/null <<'SQL'
ALTER TABLE credentials_entity RENAME COLUMN renamed_type TO type;
INSERT INTO credentials_entity(id,name,type,"updatedAt") SELECT 'overflow-'||i,'unknown','postgres',now() FROM generate_series(1,1001) i;
SQL
printf '%s\n' 'SELECT platform_discovery.read_snapshot();' | query n8n n8n_inventory >"$scratch/overflow.json"
python - "$scratch/overflow.json" <<'PYTHON'
import json,sys
from pathlib import Path
observed=json.loads(Path(sys.argv[1]).read_text().splitlines()[-1])
assert observed.get('errorCode')=='limit_exceeded'
assert observed.get('complete') is False
assert 'objects' not in observed
PYTHON
echo 'Restricted metadata SQL projections and real permission denials passed.'
