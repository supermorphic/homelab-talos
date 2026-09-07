#!/usr/bin/env bash
# Disposable local NocoDB integration against the repository's pinned containers.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

postgres_image_expected='postgres:17.11-alpine3.24'
n8n_image_expected='docker.n8n.io/n8nio/n8n:2.36.7'
nocodb_image_expected='docker.io/nocodb/nocodb@sha256:4b760f0d25471fb49707d515f161d9d36b49c88e7ecbe25eded774af385be5a9'

postgres_image="${NOCODB_LOCAL_POSTGRES_IMAGE:-$postgres_image_expected}"
n8n_image="${NOCODB_LOCAL_N8N_IMAGE:-$n8n_image_expected}"
nocodb_image="${NOCODB_LOCAL_NOCODB_IMAGE:-$nocodb_image_expected}"
nocodb_url="${NOCODB_LOCAL_NOCODB_URL:-http://127.0.0.1:18080}"
n8n_url="${NOCODB_LOCAL_N8N_URL:-http://127.0.0.1:15678}"
podman_bin="${NOCODB_LOCAL_PODMAN:-podman}"
run_id="${NOCODB_LOCAL_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM}"
run_marker="nocodb-local-$run_id"

fail() {
	echo "NocoDB local integration refused: $*" >&2
	exit 1
}

usage() {
	echo 'Usage: nocodb-local-integration.sh [--preflight|--cleanup-test]' >&2
	exit 2
}

case "$#" in
	0) preflight_only=false; cleanup_test=false ;;
	1)
		case "$1" in
			--preflight) preflight_only=true; cleanup_test=false ;;
			--cleanup-test) preflight_only=false; cleanup_test=true ;;
			*) usage ;;
		esac
		;;
	*) usage ;;
esac

[[ "$run_id" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,47}$ ]] ||
	fail 'NOCODB_LOCAL_RUN_ID must contain 1-48 safe identifier characters.'

[[ "$postgres_image" == "$postgres_image_expected" ]] ||
	fail "PostgreSQL image must be exactly $postgres_image_expected."
[[ "$n8n_image" == "$n8n_image_expected" ]] ||
	fail "n8n image must be exactly $n8n_image_expected."
[[ "$nocodb_image" == "$nocodb_image_expected" ]] ||
	fail "NocoDB image must be exactly $nocodb_image_expected."

require_loopback_url() {
	local label="$1" value="$2"
	[[ "$value" =~ ^http://(127\.0\.0\.1|localhost|\[::1\]):[0-9]{1,5}$ ]] ||
		fail "$label must be an HTTP loopback URL with an explicit port."
}
require_loopback_url NOCODB_LOCAL_NOCODB_URL "$nocodb_url"
require_loopback_url NOCODB_LOCAL_N8N_URL "$n8n_url"

command -v "$podman_bin" >/dev/null 2>&1 || fail 'Podman is required for this local integration test.'
"$podman_bin" info >/dev/null 2>&1 || fail 'Podman is installed but its engine is unavailable.'
for image in "$postgres_image" "$n8n_image" "$nocodb_image"; do
	"$podman_bin" image exists "$image" >/dev/null 2>&1 ||
		fail "required pinned image is not available locally: $image"
done

network="$run_marker-network"
containers=("$run_marker-postgres" "$run_marker-nocodb" "$run_marker-n8n" \
	"$run_marker-restore-postgres" "$run_marker-restore-nocodb")
volumes=("$run_marker-postgres-data" "$run_marker-n8n-data" "$run_marker-restore-postgres-data")

require_absent_or_owned() { # <kind> <name>
	local kind="$1" name="$2" status owner
	set +e
	case "$kind" in
		container) "$podman_bin" container exists "$name" >/dev/null 2>&1 ;;
		network) "$podman_bin" network exists "$name" >/dev/null 2>&1 ;;
		volume) "$podman_bin" volume exists "$name" >/dev/null 2>&1 ;;
	esac
	status=$?
	set -e
	[[ "$status" == 1 ]] && return 0
	[[ "$status" == 0 ]] || fail "could not determine whether $kind $name exists."
	case "$kind" in
		container) owner="$("$podman_bin" inspect --format '{{ index .Config.Labels "homelab-talos.test-run" }}' "$name" 2>/dev/null)" ;;
		network) owner="$("$podman_bin" network inspect --format '{{ index .Labels "homelab-talos.test-run" }}' "$name" 2>/dev/null)" ;;
		volume) owner="$("$podman_bin" volume inspect --format '{{ index .Labels "homelab-talos.test-run" }}' "$name" 2>/dev/null)" ;;
	esac
	[[ "$owner" == "$run_marker" ]] || fail "$kind $name exists but is not owned by this run."
	fail "$kind $name already exists for this run; choose a new run ID."
}

require_absent_or_owned network "$network"
for resource in "${containers[@]}"; do require_absent_or_owned container "$resource"; done
for resource in "${volumes[@]}"; do require_absent_or_owned volume "$resource"; done

[[ "$preflight_only" == false ]] || {
	echo 'NocoDB local integration preflight passed.'
	exit 0
}

integration_root="$(mktemp -d "$repo_root/.tmp/nocodb-local-integration.XXXXXX")"
chmod 700 "$integration_root"
umask 077
created_containers=()
created_volumes=()
network_created=false
phase='resource-creation'

resource_owner() { # <kind> <name>
	case "$1" in
		container) "$podman_bin" inspect --format '{{ index .Config.Labels "homelab-talos.test-run" }}' "$2" 2>/dev/null ;;
		network) "$podman_bin" network inspect --format '{{ index .Labels "homelab-talos.test-run" }}' "$2" 2>/dev/null ;;
		volume) "$podman_bin" volume inspect --format '{{ index .Labels "homelab-talos.test-run" }}' "$2" 2>/dev/null ;;
	esac
}

resource_exists() { # <kind> <name>
	case "$1" in
		container) "$podman_bin" container exists "$2" >/dev/null 2>&1 ;;
		network) "$podman_bin" network exists "$2" >/dev/null 2>&1 ;;
		volume) "$podman_bin" volume exists "$2" >/dev/null 2>&1 ;;
	esac
}

remove_owned_resource() { # <kind> <name>
	local kind="$1" name="$2" exists_status owner
	set +e
	resource_exists "$kind" "$name"
	exists_status=$?
	set -e
	[[ "$exists_status" == 1 ]] && return 0
	[[ "$exists_status" == 0 ]] || return 1
	owner="$(resource_owner "$kind" "$name")" || return 1
	[[ "$owner" == "$run_marker" ]] || return 1
	case "$kind" in
		container) "$podman_bin" rm --force "$name" >/dev/null 2>&1 ;;
		network) "$podman_bin" network rm "$name" >/dev/null 2>&1 ;;
		volume) "$podman_bin" volume rm "$name" >/dev/null 2>&1 ;;
	esac || return 1
	set +e
	resource_exists "$kind" "$name"
	exists_status=$?
	set -e
	[[ "$exists_status" == 1 ]]
}

cleanup() {
	local original_exit="$?" cleanup_failed=false index
	trap - EXIT INT TERM
	if [[ "$original_exit" -ne 0 ]]; then
		printf 'NocoDB local integration stopped during phase=%s.\n' "$phase" >&2
	fi
	set +e
	for ((index = ${#created_containers[@]} - 1; index >= 0; index -= 1)); do
		remove_owned_resource container "${created_containers[$index]}" || cleanup_failed=true
	done
	for ((index = ${#created_volumes[@]} - 1; index >= 0; index -= 1)); do
		remove_owned_resource volume "${created_volumes[$index]}" || cleanup_failed=true
	done
	if [[ "$network_created" == true ]]; then
		remove_owned_resource network "$network" || cleanup_failed=true
	fi
	rm -r -- "$integration_root" || cleanup_failed=true
	set -e
	if [[ "$cleanup_failed" == true ]]; then
		echo 'NocoDB local integration cleanup failed or could not prove exact resource absence.' >&2
		exit 1
	fi
	exit "$original_exit"
}
trap cleanup EXIT INT TERM

random_secret() { openssl rand -hex 24; }
postgres_password="$(random_secret)"
provisioner_password="$(random_secret)"
backup_password="$(random_secret)"
exporter_password="$(random_secret)"
metadata_password="$(random_secret)"
n8n_password="$(random_secret)"
n8n_encryption_key="$(random_secret)"
n8n_owner_password="Local!$(openssl rand -hex 20)Aa1"
nocodb_admin_password="$(random_secret)"
nocodb_jwt_secret="$(random_secret)"
nocodb_connection_key="$(random_secret)"
provision_webhook_secret="$(random_secret)"
source_webhook_secret="$(random_secret)"
acceptance_webhook_secret="$(random_secret)"

postgres_name="${containers[0]}"
nocodb_name="${containers[1]}"
n8n_name="${containers[2]}"
restore_postgres_name="${containers[3]}"
restore_nocodb_name="${containers[4]}"
postgres_volume="${volumes[0]}"
n8n_volume="${volumes[1]}"
restore_postgres_volume="${volumes[2]}"

"$podman_bin" network create --label "homelab-talos.test-run=$run_marker" "$network" >/dev/null
network_created=true
[[ "$cleanup_test" == false ]] || {
	phase='cleanup-test'
	exit 79
}
for resource in "${volumes[@]}"; do
	"$podman_bin" volume create --label "homelab-talos.test-run=$run_marker" "$resource" >/dev/null
	created_volumes+=("$resource")
done

{
	printf 'POSTGRES_DB=automation_data_control\nPOSTGRES_USER=postgres\n'
	printf 'POSTGRES_PASSWORD=%s\nPROVISIONER_PASSWORD=%s\nBACKUP_PASSWORD=%s\nEXPORTER_PASSWORD=%s\n' \
		"$postgres_password" "$provisioner_password" "$backup_password" "$exporter_password"
} >"$integration_root/postgres.env"

"$podman_bin" run --detach --name "$postgres_name" \
	--label "homelab-talos.test-run=$run_marker" \
	--network "$network" \
	--network-alias automation-data-postgresql.automation-data.svc.cluster.local \
	--env-file "$integration_root/postgres.env" \
	--volume "$postgres_volume:/var/lib/postgresql/data" \
	--volume "$repo_root/kubernetes/apps/automation-data/postgresql/app/scripts:/scripts:ro" \
	--volume "$repo_root/kubernetes/apps/automation-data/postgresql/app/scripts/init-platform.sh:/docker-entrypoint-initdb.d/10-init-platform.sh:ro" \
	"$postgres_image" >/dev/null
created_containers+=("$postgres_name")

wait_postgres() { # [container] [database]
	local container="${1:-$postgres_name}" database="${2:-automation_data_control}"
	for _attempt in $(seq 1 90); do
		if "$podman_bin" exec "$container" sh -eu -c \
			'grep -qx postgres /proc/1/comm' >/dev/null 2>&1 &&
			"$podman_bin" exec "$container" psql --no-psqlrc --tuples-only --no-align \
				--username postgres --dbname "$database" --command 'SELECT 1;' \
				>/dev/null 2>&1; then
			return 0
		fi
		sleep 1
	done
	fail 'disposable PostgreSQL did not become ready.'
}
wait_postgres

phase='database-bootstrap'
{
	printf "SELECT platform_operations.provision_nocodb_metadata('%s');\n" "$metadata_password"
	printf "CREATE ROLE n8n LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD '%s';\n" "$n8n_password"
	printf 'CREATE DATABASE n8n OWNER n8n;\n'
	printf 'REVOKE CONNECT ON DATABASE n8n FROM PUBLIC; GRANT CONNECT ON DATABASE n8n TO n8n;\n'
} >"$integration_root/bootstrap.sql"
"$podman_bin" exec --interactive "$postgres_name" psql --no-psqlrc \
	--set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control \
	<"$integration_root/bootstrap.sql" >/dev/null

{
	printf 'DB_TYPE=postgresdb\nDB_POSTGRESDB_HOST=automation-data-postgresql.automation-data.svc.cluster.local\n'
	printf 'DB_POSTGRESDB_PORT=5432\nDB_POSTGRESDB_DATABASE=n8n\nDB_POSTGRESDB_USER=n8n\n'
	printf 'DB_POSTGRESDB_PASSWORD=%s\nN8N_ENCRYPTION_KEY=%s\n' "$n8n_password" "$n8n_encryption_key"
	printf 'N8N_HOST=127.0.0.1\nN8N_PORT=5678\nN8N_PROTOCOL=http\nN8N_SECURE_COOKIE=false\n'
	printf 'N8N_DIAGNOSTICS_ENABLED=false\nN8N_PERSONALIZATION_ENABLED=false\nN8N_VERSION_NOTIFICATIONS_ENABLED=false\n'
	printf 'EXECUTIONS_DATA_SAVE_ON_ERROR=none\nEXECUTIONS_DATA_SAVE_ON_SUCCESS=none\nEXECUTIONS_DATA_SAVE_ON_PROGRESS=false\n'
} >"$integration_root/n8n.env"

{
	printf 'DATABASE_URL=postgres://nocodb_metadata:%s@automation-data-postgresql.automation-data.svc.cluster.local:5432/nocodb?sslmode=disable\n' "$metadata_password"
	printf 'NC_AUTH_JWT_SECRET=%s\nNC_CONNECTION_ENCRYPT_KEY=%s\n' "$nocodb_jwt_secret" "$nocodb_connection_key"
	printf 'NC_ADMIN_EMAIL=local-admin@example.invalid\nNC_ADMIN_PASSWORD=%s\n' "$nocodb_admin_password"
	printf 'NC_ALLOW_LOCAL_EXTERNAL_DBS=true\nNC_DISABLE_TELE=true\nNC_DISABLE_SUPPORT_CHAT=true\n'
	printf 'NC_SITE_URL=%s\n' "$nocodb_url"
} >"$integration_root/nocodb.env"

"$podman_bin" run --detach --name "$n8n_name" \
	--label "homelab-talos.test-run=$run_marker" --network "$network" \
	--env-file "$integration_root/n8n.env" \
	--publish "127.0.0.1:${n8n_url##*:}:5678" \
	--volume "$n8n_volume:/home/node/.n8n" "$n8n_image" >/dev/null
created_containers+=("$n8n_name")

start_nocodb_container() { # <name> <env-file> <network-alias> <loopback-port> [fixed-database-ip]
	local name="$1" env_file="$2" network_alias="$3" loopback_port="$4" database_ip="${5:-}"
	local host_args=()
	if [[ -n "$database_ip" ]]; then
		host_args+=(--add-host "automation-data-postgresql.automation-data.svc.cluster.local:$database_ip")
	fi
	"$podman_bin" run --detach --name "$name" \
		--label "homelab-talos.test-run=$run_marker" --network "$network" \
		--network-alias "$network_alias" --env-file "$env_file" \
		"${host_args[@]}" \
		--publish "127.0.0.1:$loopback_port:8080" \
		--tmpfs /usr/app/data --tmpfs /tmp "$nocodb_image" >/dev/null
}
start_nocodb_container "$nocodb_name" "$integration_root/nocodb.env" \
	nocodb.automation-data.svc.cluster.local "${nocodb_url##*:}"
created_containers+=("$nocodb_name")

phase='application-readiness'
wait_http() { # <url> <label> [json jq]
	local url="$1" label="$2" filter="${3:-}" code
	for _attempt in $(seq 1 180); do
		code="$(curl --silent --output "$integration_root/wait-response" \
			--write-out '%{http_code}' --connect-timeout 2 --max-time 5 "$url" || true)"
		if [[ "$code" == 200 ]] && { [[ -z "$filter" ]] || jq -e "$filter" "$integration_root/wait-response" >/dev/null 2>&1; }; then
			return 0
		fi
		sleep 1
	done
	fail "$label did not become ready."
}
wait_http "$n8n_url/healthz/readiness" 'disposable n8n'
wait_http "$nocodb_url/api/v1/health" 'disposable NocoDB' '.message == "OK"'

http_request() { # <method> <url> <auth-mode> <body-file|-> <output-file>
	local method="$1" url="$2" auth="$3" body="$4" output="$5"
	local config="$integration_root/request-$RANDOM.curl"
	{
		printf '%s\n' silent show-error fail-with-body \
			'connect-timeout = 5' 'max-time = 120' 'max-filesize = 1048576'
		printf 'request = "%s"\nurl = "%s"\noutput = "%s"\n' "$method" "$url" "$output"
		case "$auth" in
			none) ;;
			n8n-cookie) printf 'cookie = "%s"\n' "$integration_root/n8n.cookies" ;;
			n8n-key) printf 'header = "X-N8N-API-KEY: %s"\n' "$n8n_api_key" ;;
			nocodb-jwt) printf 'header = "xc-auth: %s"\n' "$nocodb_session" ;;
			nocodb-token) printf 'header = "xc-token: %s"\n' "$nocodb_token" ;;
			provision-webhook) printf 'header = "X-Automation-Data-Provisioning: %s"\n' "$provision_webhook_secret" ;;
			source-webhook) printf 'header = "Authorization: Bearer %s"\n' "$source_webhook_secret" ;;
			acceptance-webhook) printf 'header = "Authorization: Bearer %s"\n' "$acceptance_webhook_secret" ;;
			*) return 64 ;;
		esac
		if [[ "$body" != - ]]; then
			printf 'header = "Content-Type: application/json"\ndata-binary = "@%s"\n' "$body"
		fi
	} >"$config"
	chmod 600 "$config"
	curl --config "$config"
}

http_status_request() { # <url> <auth-mode> <output-file>
	local url="$1" auth="$2" output="$3"
	local config="$integration_root/status-request-$RANDOM.curl"
	{
		printf '%s\n' silent show-error location 'max-redirs = 3' \
			'connect-timeout = 5' 'max-time = 60' 'max-filesize = 1048576'
		printf 'request = "GET"\nurl = "%s"\noutput = "%s"\nwrite-out = "%%{http_code}"\n' \
			"$url" "$output"
		case "$auth" in
			none) ;;
			nocodb-jwt) printf 'header = "xc-auth: %s"\n' "$nocodb_session" ;;
			nocodb-token) printf 'header = "xc-token: %s"\n' "$nocodb_token" ;;
			*) return 64 ;;
		esac
	} >"$config"
	chmod 600 "$config"
	curl --config "$config" || true
}

http_status_json_request() { # <method> <url> <auth-mode> <body-file> <output-file>
	local method="$1" url="$2" auth="$3" body="$4" output="$5"
	local config="$integration_root/status-json-request-$RANDOM.curl"
	{
		printf '%s\n' silent show-error 'connect-timeout = 5' 'max-time = 60' 'max-filesize = 1048576'
		printf 'request = "%s"\nurl = "%s"\noutput = "%s"\nwrite-out = "%%{http_code}"\n' \
			"$method" "$url" "$output"
		case "$auth" in
			nocodb-jwt) printf 'header = "xc-auth: %s"\n' "$nocodb_session" ;;
			nocodb-token) printf 'header = "xc-token: %s"\n' "$nocodb_token" ;;
			acceptance-webhook) printf 'header = "Authorization: Bearer %s"\n' "$acceptance_webhook_secret" ;;
			*) return 64 ;;
		esac
		printf 'header = "Content-Type: application/json"\ndata-binary = "@%s"\n' "$body"
	} >"$config"
	chmod 600 "$config"
	curl --config "$config" || true
}

wait_nocodb_job() { # <base-id> <job-id> <output-file>
	local base_id="$1" job_id="$2" output="$3" list_status match_count job_status
	jq -n '{}' >"$integration_root/job-list-request.json"
	for _attempt in $(seq 1 120); do
		list_status="$(http_status_json_request POST "$nocodb_url/api/v2/jobs/$base_id" nocodb-jwt \
			"$integration_root/job-list-request.json" "$integration_root/job-list-response.json")"
		[[ "$list_status" =~ ^20[01]$ ]] || fail "NocoDB job list returned HTTP $list_status."
		match_count="$(jq -r --arg id "$job_id" '[.[]? | select(.id == $id)] | length' \
			"$integration_root/job-list-response.json")"
		[[ "$match_count" -le 1 ]] || fail 'NocoDB job list returned a duplicate exact job identity.'
		if [[ "$match_count" == 1 ]]; then
			jq --arg id "$job_id" '.[] | select(.id == $id)' \
				"$integration_root/job-list-response.json" >"$output"
			job_status="$(jq -er '.status' "$output")"
			case "$job_status" in
				completed) return 0 ;;
				failed)
					jq '{job,status,resultType:(.result|type)}' "$output" >&2 || true
					fail 'NocoDB metadata job failed.'
					;;
				waiting | active | delayed) ;;
				*) fail 'NocoDB metadata job returned an unknown state.' ;;
			esac
		fi
		sleep 1
	done
	fail 'NocoDB metadata job did not reach a terminal state.'
}

phase='nocodb-authentication'
NOCODB_ADMIN_PASSWORD="$nocodb_admin_password" jq -n \
	'{email:"local-admin@example.invalid",password:env.NOCODB_ADMIN_PASSWORD}' \
	>"$integration_root/nocodb-signin.json"
http_request POST "$nocodb_url/api/v1/auth/user/signin" none \
	"$integration_root/nocodb-signin.json" "$integration_root/nocodb-signin-response.json"
nocodb_session="$(jq -er '.token | select(type == "string" and length > 0)' "$integration_root/nocodb-signin-response.json")"
jq -n '{description:"NocoDB Task 5 disposable integration"}' >"$integration_root/nocodb-token.json"
http_request POST "$nocodb_url/api/v1/tokens" nocodb-jwt "$integration_root/nocodb-token.json" \
	"$integration_root/nocodb-token-response.json"
nocodb_token="$(jq -er '.token | select(type == "string" and length > 0)' "$integration_root/nocodb-token-response.json")"

phase='n8n-owner-setup'
N8N_OWNER_PASSWORD="$n8n_owner_password" jq -n \
	'{email:"owner@example.invalid",firstName:"Local",lastName:"Operator",password:env.N8N_OWNER_PASSWORD}' \
	>"$integration_root/n8n-owner.json"
{
	printf '%s\n' silent show-error fail-with-body 'connect-timeout = 5' 'max-time = 60'
	printf 'request = "POST"\nurl = "%s/rest/owner/setup"\n' "$n8n_url"
	printf 'header = "Content-Type: application/json"\ndata-binary = "@%s"\n' "$integration_root/n8n-owner.json"
	printf 'cookie-jar = "%s"\noutput = "%s"\n' "$integration_root/n8n.cookies" "$integration_root/n8n-owner-response.json"
} >"$integration_root/n8n-owner.curl"
chmod 600 "$integration_root/n8n-owner.curl"
curl --config "$integration_root/n8n-owner.curl"
http_request GET "$n8n_url/rest/api-keys/scopes" n8n-cookie - "$integration_root/n8n-scopes.json"
jq '{label:"NocoDB Task 5 disposable integration",scopes:.data,expiresAt:null}' "$integration_root/n8n-scopes.json" \
	>"$integration_root/n8n-key.json"
http_request POST "$n8n_url/rest/api-keys" n8n-cookie "$integration_root/n8n-key.json" \
	"$integration_root/n8n-key-response.json"
n8n_api_key="$(jq -er '.data.rawApiKey | select(type == "string" and length > 0)' "$integration_root/n8n-key-response.json")"

phase='n8n-credential-import'
create_n8n_credential() { # <name> <type> <data-json>
	local name="$1" type="$2" data="$3" slug response
	slug="$(printf '%s' "$name" | tr -cs 'A-Za-z0-9' '-')"
	NAME="$name" TYPE="$type" DATA="$data" jq -n \
		'{name:env.NAME,type:env.TYPE,data:(env.DATA|fromjson)}' >"$integration_root/credential-$slug.json"
	http_request POST "$n8n_url/api/v1/credentials" n8n-key "$integration_root/credential-$slug.json" \
		"$integration_root/credential-$slug-response.json"
	response="$integration_root/credential-$slug-response.json"
	jq -er --arg name "$name" --arg type "$type" \
		'select(.name == $name and .type == $type) | .id | select(type == "string" and length > 0)' "$response"
}

provisioner_pg_data="$(jq -cn --arg password "$provisioner_password" '{host:"automation-data-postgresql.automation-data.svc.cluster.local",port:5432,database:"automation_data_control",user:"automation_data_provisioner",password:$password,ssl:"disable"}')"
provisioner_pg_id="$(create_n8n_credential 'Automation Data Provisioner' postgres "$provisioner_pg_data")"
n8n_header_id="$(create_n8n_credential 'Local n8n API' httpHeaderAuth "$(jq -cn --arg value "$n8n_api_key" '{name:"X-N8N-API-KEY",value:$value}')")"
nocodb_header_id="$(create_n8n_credential 'NocoDB Operator API' httpHeaderAuth "$(jq -cn --arg value "$nocodb_token" '{name:"xc-token",value:$value}')")"
provision_header_id="$(create_n8n_credential 'Automation Data Provisioning Header' httpHeaderAuth "$(jq -cn --arg value "$provision_webhook_secret" '{name:"X-Automation-Data-Provisioning",value:$value}')")"
source_header_id="$(create_n8n_credential 'NocoDB Source Provisioning Header' httpHeaderAuth "$(jq -cn --arg value "$source_webhook_secret" '{name:"Authorization",value:("Bearer "+$value)}')")"
acceptance_header_id="$(create_n8n_credential 'NocoDB Acceptance Header' httpHeaderAuth "$(jq -cn --arg value "$acceptance_webhook_secret" '{name:"Authorization",value:("Bearer "+$value)}')")"

bind_workflow() { # <source> <output> <postgres-id> <postgres-name> <http-id> <http-name> <webhook-id> <webhook-name> [runtime-id runtime-name]
	local source="$1" output="$2" pg_id="$3" pg_name="$4" http_id="$5" http_name="$6" webhook_id="$7" webhook_name="$8"
	local runtime_id="${9:-}" runtime_name="${10:-}"
	local runtime_nodes='["Publish Initial Feedback Fact","Consume Feedback Before Refresh","Refresh Feedback Fact","Consume Feedback After Refresh"]'
	local migrator_nodes='["Create Acceptance Structure","Grant Acceptance Access","Clear Reader Negative Residue","Cleanup Unexpected Reader Insert","Clear Feedback Residue","Cleanup Feedback Fact"]'
	jq --arg pg_id "$pg_id" --arg pg_name "$pg_name" --arg http_id "$http_id" --arg http_name "$http_name" \
		--arg webhook_id "$webhook_id" --arg webhook_name "$webhook_name" \
		--arg runtime_id "$runtime_id" --arg runtime_name "$runtime_name" \
		--argjson runtime_nodes "$runtime_nodes" --argjson migrator_nodes "$migrator_nodes" '
		.nodes |= map(
			. as $node |
			if .type == "n8n-nodes-base.postgres" and $runtime_id != "" and ($runtime_nodes | index($node.name)) != null
			then .credentials = {postgres:{id:$runtime_id,name:$runtime_name}}
			elif .type == "n8n-nodes-base.postgres" and $runtime_id != "" and ($migrator_nodes | index($node.name)) != null
			then .credentials = {postgres:{id:$pg_id,name:$pg_name}}
			elif .type == "n8n-nodes-base.postgres" and $runtime_id != ""
			then error("unknown acceptance PostgreSQL node")
			elif .type == "n8n-nodes-base.postgres" then .credentials = {postgres:{id:$pg_id,name:$pg_name}}
			elif .type == "n8n-nodes-base.httpRequest" then .credentials = {httpHeaderAuth:{id:$http_id,name:$http_name}}
			elif .type == "n8n-nodes-base.webhook" then .credentials = {httpHeaderAuth:{id:$webhook_id,name:$webhook_name}}
			else . end
		)' "$source" >"$output"
}

phase='workflow-binding'
bind_workflow kubernetes/apps/automation/n8n/app/workflows/automation-data-provisioner.json \
	"$integration_root/automation-data-provisioner.json" "$provisioner_pg_id" 'Automation Data Provisioner' \
	"$n8n_header_id" 'Local n8n API' "$provision_header_id" 'Automation Data Provisioning Header'
bind_workflow kubernetes/apps/automation/n8n/app/workflows/nocodb-source-provisioner.json \
	"$integration_root/nocodb-source-provisioner.json" "$provisioner_pg_id" 'Automation Data Provisioner' \
	"$nocodb_header_id" 'NocoDB Operator API' "$source_header_id" 'NocoDB Source Provisioning Header'

import_and_publish() { # <local-file> <workflow-name>
	local local_file="$1" workflow_name="$2"
	local slug payload response publish_response id
	slug="$(printf '%s' "$workflow_name" | tr -cs 'A-Za-z0-9' '-')"
	payload="$integration_root/workflow-$slug.json"
	response="$integration_root/workflow-$slug-response.json"
	publish_response="$integration_root/workflow-$slug-publish-response.json"
	jq '{name,nodes,connections,settings}' "$local_file" >"$payload"
	http_request POST "$n8n_url/api/v1/workflows" n8n-key \
		"$payload" "$response"
	id="$(jq -er --arg name "$workflow_name" \
		'select(.name == $name) | .id | select(type == "string" and length > 0)' "$response")"
	http_request POST "$n8n_url/api/v1/workflows/$id/publish" n8n-key - "$publish_response"
	jq -e --arg id "$id" --arg name "$workflow_name" \
		'.id == $id and .name == $name and .active == true' "$publish_response" >/dev/null ||
		fail "n8n did not publish imported workflow $workflow_name."
	printf '%s\n' "$id"
}

phase='workflow-import'
import_and_publish "$integration_root/automation-data-provisioner.json" 'Automation Data Provisioner' >/dev/null
import_and_publish "$integration_root/nocodb-source-provisioner.json" 'NocoDB Source Provisioner' >/dev/null

webhook_call() { # <path> <auth> <json-body> <output>
	local path="$1" auth="$2" body="$3" output="$4"
	printf '%s\n' "$body" >"$integration_root/webhook-body.json"
	http_request POST "$n8n_url/webhook/$path" "$auth" "$integration_root/webhook-body.json" "$output"
}

mkdir -p "$integration_root/validator-bin"
cat >"$integration_root/validator-bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
	status) exit 0 ;;
	ls-remote) printf '%s\trefs/heads/main\n' 'd3d5bed8b8aa980302b26b7f9227c5e3969d170f' ;;
	cat-file | diff) exit 0 ;;
	*) exit 64 ;;
esac
EOF
cat >"$integration_root/validator-bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec /bin/cat "${NOCODB_SOURCE_OPERATION_ACTUAL_RESPONSE:?}"
EOF
chmod 700 "$integration_root/validator-bin/git" "$integration_root/validator-bin/curl"

validate_source_response() { # <operation> <access-kind|-> <actual-response> [domain]
	local operation="$1" access_kind="$2" response="$3" domain="${4:-issue334_acceptance}"
	local confirmation_name confirmation_value validator_status
	case "$operation" in
		sync)
			confirmation_name='NOCODB_SOURCE_SYNC_CONFIRM'
			confirmation_value="sync:nocodb:$domain"
			;;
		rotate)
			confirmation_name='NOCODB_SOURCE_ROTATE_CONFIRM'
			confirmation_value="rotate:nocodb:$domain:$access_kind"
			;;
	esac
	set +e
	env PATH="$integration_root/validator-bin:$PATH" \
		NOCODB_SOURCE_OPERATION_ACTUAL_RESPONSE="$response" \
		NOCODB_SOURCE_PROVISIONING_HEADER="$source_webhook_secret" \
		"$confirmation_name=$confirmation_value" \
		scripts/nocodb/source-operation.sh "$operation" "$domain" \
		"${access_kind/#-/}" >/dev/null
	validator_status=$?
	set -e
	if [[ "$validator_status" -ne 0 ]]; then
		jq '{keys:(keys|sort),ok,domain,operation,errorCode,
			reader:(.reader | if type == "object" then {keys:(keys|sort),accessKind,state,sourceDiscovered,sourceReadBack,dataEditAllowed,schemaEditAllowed,postgresqlValidation} else . end),
			operator:(.operator | if type == "object" then {keys:(keys|sort),accessKind,state,sourceDiscovered,sourceReadBack,dataEditAllowed,schemaEditAllowed,postgresqlValidation} else . end)}' \
			"$response" >&2 || true
		fail 'actual source response failed the operator command validator.'
	fi
}

source_call() { # <operation> <access-kind|-> <output> [domain]
	local operation="$1" access_kind="$2" output="$3" domain="${4:-issue334_acceptance}" body registry_state
	if [[ "$operation" == sync ]]; then
		body="$(jq -cn --arg domain "$domain" '{domain:$domain,operation:"sync"}')"
	else
		body="$(jq -cn --arg domain "$domain" --arg access_kind "$access_kind" \
			'{domain:$domain,operation:"rotate",accessKind:$access_kind}')"
	fi
	webhook_call automation-data-nocodb-source source-webhook "$body" "$output"
	if ! jq -e '.ok == true' "$output" >/dev/null; then
		jq '{keys:(keys|sort),ok,domain,operation,errorCode,
			reader:(.reader | if type == "object" then {accessKind,state,generation,credentialGeneration} else . end),
			operator:(.operator | if type == "object" then {accessKind,state,generation,credentialGeneration} else . end)}' \
			"$output" >&2 || true
		if [[ "$operation" == rotate && "$access_kind" =~ ^(reader|operator)$ ]]; then
			registry_state="$("$podman_bin" exec "$postgres_name" psql --no-psqlrc --tuples-only --no-align \
				--set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control --command \
				"SELECT jsonb_build_object('state', state, 'operation', operation, 'generation', generation, 'credentialGeneration', credential_generation, 'errorCode', error_code) FROM platform_operations.managed_nocodb_sources WHERE domain = '$domain' AND access_kind = '$access_kind';")"
			printf '%s\n' "$registry_state" >&2
		fi
	fi
	validate_source_response "$operation" "$access_kind" "$output" "$domain"
}

acceptance_call() { # <operation> <run-id> <output>
	local operation="$1" acceptance_run_id="$2" output="$3" body status
	body="$(jq -cn --arg operation "$operation" --arg run_id "$acceptance_run_id" \
		'{operation:$operation,runId:$run_id}')"
	printf '%s\n' "$body" >"$integration_root/acceptance-webhook-body.json"
	status="$(http_status_json_request POST "$n8n_url/webhook/nocodb-acceptance-domain" \
		acceptance-webhook "$integration_root/acceptance-webhook-body.json" "$output")"
	[[ "$status" == 200 ]] || fail "acceptance webhook returned HTTP $status."
}

phase='domain-provisioning'
webhook_call automation-data-provision provision-webhook \
	'{"domain":"issue334_acceptance","operation":"provision"}' "$integration_root/provision-response.json"
jq -e '.ok == true and .state == "ready" and .domain == "issue334_acceptance"' \
	"$integration_root/provision-response.json" >/dev/null || fail 'actual provisioning workflow failed.'
migrator_credential_id="$(jq -er '.migratorCredentialId' "$integration_root/provision-response.json")"
runtime_credential_id="$(jq -er '.runtimeCredentialId' "$integration_root/provision-response.json")"
[[ "$migrator_credential_id" =~ ^[A-Za-z0-9_-]+$ && "$runtime_credential_id" =~ ^[A-Za-z0-9_-]+$ &&
	"$migrator_credential_id" != "$runtime_credential_id" ]] || fail 'provisioning did not return distinct credential identities.'

phase='acceptance-binding'
bind_workflow kubernetes/apps/automation/n8n/app/workflows/nocodb-acceptance-domain.json \
	"$integration_root/nocodb-acceptance-domain.json" "$migrator_credential_id" \
	'automation-data/issue334_acceptance/migrator' "$nocodb_header_id" 'NocoDB Operator API' \
	"$acceptance_header_id" 'NocoDB Acceptance Header' "$runtime_credential_id" \
	'automation-data/issue334_acceptance/runtime'
acceptance_workflow_id="$(import_and_publish "$integration_root/nocodb-acceptance-domain.json" 'NocoDB Acceptance Domain')"
http_request GET "$n8n_url/api/v1/workflows/$acceptance_workflow_id" n8n-key - \
	"$integration_root/imported-acceptance-workflow.json"
jq -e --arg migrator "$migrator_credential_id" --arg runtime "$runtime_credential_id" '
	(if type == "array" and length == 1 then .[0] else . end) as $workflow |
	([$workflow.nodes[] | select(.type == "n8n-nodes-base.postgres" and .credentials.postgres.id == $migrator)] | length) == 6 and
	([$workflow.nodes[] | select(.type == "n8n-nodes-base.postgres" and .credentials.postgres.id == $runtime)] | length) == 4 and
	([$workflow.nodes[] | select(.type == "n8n-nodes-base.postgres" and
		(.credentials.postgres.id != $migrator and .credentials.postgres.id != $runtime))] | length) == 0
' "$integration_root/imported-acceptance-workflow.json" >/dev/null ||
	fail 'n8n did not retain the exact six-migrator/four-runtime acceptance credential binding.'

prove_aged_jobs_rotation_and_restart() { # <ready source response>
	local ready_response="$1" reader_job_id operator_job_id completed_count absent_count
	reader_job_id="$(jq -er '.reader.sourceCreateJobId' "$ready_response")"
	operator_job_id="$(jq -er '.operator.sourceCreateJobId' "$ready_response")"
	[[ "$reader_job_id" =~ ^[A-Za-z0-9_-]+$ && "$operator_job_id" =~ ^[A-Za-z0-9_-]+$ &&
		"$reader_job_id" != "$operator_job_id" ]] || fail 'source job identities were not safe and distinct.'

	phase='age-completed-source-jobs'
	completed_count="$("$podman_bin" exec "$postgres_name" psql --no-psqlrc --tuples-only --no-align \
		--set=ON_ERROR_STOP=1 --username postgres --dbname nocodb --command \
		"SELECT count(*) FROM nc_jobs WHERE id IN ('$reader_job_id', '$operator_job_id') AND status = 'completed';")"
	[[ "$completed_count" == 2 ]] || fail 'initial source jobs were not both completed before age-out.'
	"$podman_bin" exec "$postgres_name" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
		--username postgres --dbname nocodb --command \
		"UPDATE nc_jobs SET updated_at = clock_timestamp() - interval '31 days' WHERE id IN ('$reader_job_id', '$operator_job_id') AND status = 'completed'; DELETE FROM nc_jobs WHERE id IN ('$reader_job_id', '$operator_job_id') AND status = 'completed' AND updated_at < clock_timestamp() - interval '30 days';" \
		>/dev/null
	absent_count="$("$podman_bin" exec "$postgres_name" psql --no-psqlrc --tuples-only --no-align \
		--set=ON_ERROR_STOP=1 --username postgres --dbname nocodb --command \
		"SELECT count(*) FROM nc_jobs WHERE id IN ('$reader_job_id', '$operator_job_id');")"
	[[ "$absent_count" == 0 ]] || fail 'aged source jobs were not exactly removed from disposable metadata.'

	phase='sync-with-aged-jobs'
	source_call sync - "$integration_root/source-aged-sync.json"
	jq -e --slurpfile before "$ready_response" '
		.reader.sourceCreateJobState == null and .operator.sourceCreateJobState == null and
		.reader.sourceId == $before[0].reader.sourceId and
		.reader.integrationId == $before[0].reader.integrationId and
		.reader.sourceCreateJobId == $before[0].reader.sourceCreateJobId and
		.reader.generation == $before[0].reader.generation and
		.reader.credentialGeneration == $before[0].reader.credentialGeneration and
		.operator.sourceId == $before[0].operator.sourceId and
		.operator.integrationId == $before[0].operator.integrationId and
		.operator.sourceCreateJobId == $before[0].operator.sourceCreateJobId and
		.operator.generation == $before[0].operator.generation and
		.operator.credentialGeneration == $before[0].operator.credentialGeneration
	' "$integration_root/source-aged-sync.json" >/dev/null ||
		fail 'ready sync queried or changed aged source-job identity.'

	phase='application-restart'
	"$podman_bin" restart "$nocodb_name" "$n8n_name" >/dev/null
	wait_http "$n8n_url/healthz/readiness" 'restarted disposable n8n'
	wait_http "$nocodb_url/api/v1/health" 'restarted disposable NocoDB' '.message == "OK"'
	source_call sync - "$integration_root/source-restarted-sync.json"
	jq -e --slurpfile before "$integration_root/source-aged-sync.json" '
		.reader.sourceCreateJobState == null and .operator.sourceCreateJobState == null and
		.reader.sourceId == $before[0].reader.sourceId and
		.reader.integrationId == $before[0].reader.integrationId and
		.reader.sourceCreateJobId == $before[0].reader.sourceCreateJobId and
		.reader.generation == $before[0].reader.generation and
		.reader.credentialGeneration == $before[0].reader.credentialGeneration and
		.operator.sourceId == $before[0].operator.sourceId and
		.operator.integrationId == $before[0].operator.integrationId and
		.operator.sourceCreateJobId == $before[0].operator.sourceCreateJobId and
		.operator.generation == $before[0].operator.generation and
		.operator.credentialGeneration == $before[0].operator.credentialGeneration
	' "$integration_root/source-restarted-sync.json" >/dev/null ||
		fail 'restart changed ready source identity or historical-job behavior.'

	phase='operator-rotation-with-aged-job'
	source_call rotate operator "$integration_root/source-operator-rotation.json"
	jq -e --slurpfile before "$integration_root/source-restarted-sync.json" '
		.reader.sourceCreateJobState == null and .operator.sourceCreateJobState == null and
		.reader.sourceId == $before[0].reader.sourceId and
		.reader.integrationId == $before[0].reader.integrationId and
		.reader.sourceCreateJobId == $before[0].reader.sourceCreateJobId and
		.reader.generation == $before[0].reader.generation and
		.reader.credentialGeneration == $before[0].reader.credentialGeneration and
		.operator.sourceId == $before[0].operator.sourceId and
		.operator.integrationId == $before[0].operator.integrationId and
		.operator.sourceCreateJobId == $before[0].operator.sourceCreateJobId and
		.operator.generation > $before[0].operator.generation and
		.operator.credentialGeneration == ($before[0].operator.credentialGeneration + 1)
	' "$integration_root/source-operator-rotation.json" >/dev/null ||
		fail 'operator-only rotation changed identity or the wrong credential generation.'
}

prove_interrupted_initial_creation() {
	local domain='issue334_interrupt' request_pid request_status registry='' job_id base_id
	phase='interrupted-initial-domain-provisioning'
	webhook_call automation-data-provision provision-webhook \
		'{"domain":"issue334_interrupt","operation":"provision"}' \
		"$integration_root/interrupt-provision-response.json"
	jq -e '.ok == true and .state == "ready" and .domain == "issue334_interrupt"' \
		"$integration_root/interrupt-provision-response.json" >/dev/null ||
		fail 'interrupted-creation domain provisioning failed.'
	printf '%s\n' 'BEGIN; SET LOCAL ROLE issue334_interrupt_owner; CREATE SCHEMA IF NOT EXISTS read_model AUTHORIZATION issue334_interrupt_owner; CREATE TABLE IF NOT EXISTS app.interrupt_fact (id bigint PRIMARY KEY, fact text NOT NULL); CREATE OR REPLACE VIEW read_model.interrupt_facts AS SELECT id, fact FROM app.interrupt_fact; COMMIT;' |
		"$podman_bin" exec --interactive "$postgres_name" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
			--username postgres --dbname "$domain" >/dev/null
	phase='interrupt-initial-source-wait'
	printf '%s\n' '{"domain":"issue334_interrupt","operation":"sync"}' >"$integration_root/interrupt-source-body.json"
	http_request POST "$n8n_url/webhook/automation-data-nocodb-source" source-webhook \
		"$integration_root/interrupt-source-body.json" "$integration_root/interrupt-source-response.json" \
		2>"$integration_root/interrupt-source.stderr" &
	request_pid=$!
	for _attempt in $(seq 1 200); do
		registry="$("$podman_bin" exec "$postgres_name" psql --no-psqlrc --tuples-only --no-align \
			--set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control --command \
			"SELECT jsonb_build_object('state',state,'baseId',base_id,'integrationId',integration_id,'jobId',source_create_job_id,'sourceId',source_id,'generation',generation,'credentialGeneration',credential_generation) FROM platform_operations.managed_nocodb_sources WHERE domain = '$domain' AND access_kind = 'reader';" 2>/dev/null || true)"
		if jq -e '.state == "waiting_for_source" and (.baseId|type=="string") and
			(.integrationId|type=="string") and (.jobId|type=="string") and .sourceId == null' \
			<<<"$registry" >/dev/null 2>&1; then
			break
		fi
		sleep 0.1
	done
	jq -e '.state == "waiting_for_source"' <<<"$registry" >/dev/null ||
		fail 'initial source creation did not reach the controlled waiting boundary.'
	"$podman_bin" stop --time 1 "$n8n_name" >/dev/null
	set +e
	wait "$request_pid"
	request_status=$?
	set -e
	[[ "$request_status" -ne 0 ]] || fail 'stopping n8n did not interrupt the in-flight initial source request.'
	job_id="$(jq -er '.jobId' <<<"$registry")"
	base_id="$(jq -er '.baseId' <<<"$registry")"
	wait_nocodb_job "$base_id" "$job_id" "$integration_root/interrupt-completed-job.json"
	"$podman_bin" start "$n8n_name" >/dev/null
	wait_http "$n8n_url/healthz/readiness" 'restarted n8n after controlled initial-source interruption'
	phase='resume-interrupted-initial-source'
	source_call sync - "$integration_root/interrupt-resumed-source.json" "$domain"
	jq -e --argjson before "$registry" '
		.ok == true and .domain == "issue334_interrupt" and .reader.state == "ready" and .operator == null and
		.reader.integrationId == $before.integrationId and .reader.sourceCreateJobId == $before.jobId and
		.reader.credentialGeneration == $before.credentialGeneration and
		.reader.generation > $before.generation and .reader.sourceCreateJobState == "completed"
	' "$integration_root/interrupt-resumed-source.json" >/dev/null ||
		fail 'interrupted initial creation did not resume the stored job without implicit credential rotation.'
	http_request GET "$nocodb_url/api/v2/meta/bases/$base_id/sources" nocodb-token - \
		"$integration_root/interrupt-sources.json"
	jq -e --arg integration "$(jq -er '.reader.integrationId' "$integration_root/interrupt-resumed-source.json")" '
		(if type == "array" then . else (.list // .data // []) end) |
		[.[] | select(.alias == "Read Model" and .fk_integration_id == $integration)] | length == 1
	' "$integration_root/interrupt-sources.json" >/dev/null ||
		fail 'interrupted initial creation produced a missing or duplicate reader source.'
}

replace_nocodb_scratch() { # <ready-source-response> <probe-response>
	local ready_before="$1" probe_before="$2" old_container_id new_container_id
	phase='nocodb-container-and-scratch-replacement'
	old_container_id="$("$podman_bin" inspect --format '{{.Id}}' "$nocodb_name")"
	[[ -n "$old_container_id" ]] || fail 'could not capture the original NocoDB container identity.'
	remove_owned_resource container "$nocodb_name" || fail 'could not remove the exact run-owned NocoDB container.'
	start_nocodb_container "$nocodb_name" "$integration_root/nocodb.env" \
		nocodb.automation-data.svc.cluster.local "${nocodb_url##*:}"
	new_container_id="$("$podman_bin" inspect --format '{{.Id}}' "$nocodb_name")"
	[[ -n "$new_container_id" && "$new_container_id" != "$old_container_id" ]] ||
		fail 'NocoDB replacement reused the old container identity.'
	wait_http "$nocodb_url/api/v1/health" 'replacement disposable NocoDB' '.message == "OK"'
	http_request POST "$nocodb_url/api/v1/auth/user/signin" none \
		"$integration_root/nocodb-signin.json" "$integration_root/replacement-signin-response.json"
	nocodb_session="$(jq -er '.token | select(type == "string" and length > 0)' \
		"$integration_root/replacement-signin-response.json")"
	http_request GET "$nocodb_url/api/v2/meta/bases" nocodb-token - \
		"$integration_root/replacement-bases.json"
	jq -e 'if type == "array" then length >= 1 else (.list // .data // [] | length >= 1) end' \
		"$integration_root/replacement-bases.json" >/dev/null ||
		fail 'retained NocoDB API token did not read restored base settings.'
	source_call sync - "$integration_root/replacement-source.json"
	jq -e --slurpfile before "$ready_before" '
		.baseId == $before[0].baseId and
		.reader.sourceId == $before[0].reader.sourceId and .reader.integrationId == $before[0].reader.integrationId and
		.reader.credentialGeneration == $before[0].reader.credentialGeneration and
		.operator.sourceId == $before[0].operator.sourceId and .operator.integrationId == $before[0].operator.integrationId and
		.operator.credentialGeneration == $before[0].operator.credentialGeneration and
		.reader.state == "ready" and .operator.state == "ready"
	' "$integration_root/replacement-source.json" >/dev/null ||
		fail 'container replacement changed source or credential identity.'
	acceptance_call probe "$run_id-replacement" "$integration_root/replacement-probe.json"
	jq -e --slurpfile before "$probe_before" '
		.ok == true and .recoveryCanary.version == 2 and
		.recoveryCanary.baseId == $before[0].recoveryCanary.baseId and
		.recoveryCanary.readerSourceId == $before[0].recoveryCanary.readerSourceId and
		.recoveryCanary.operatorSourceId == $before[0].recoveryCanary.operatorSourceId and
		.recoveryCanary.factTableId == $before[0].recoveryCanary.factTableId and
		.recoveryCanary.decisionTableId == $before[0].recoveryCanary.decisionTableId and
		.recoveryCanary.viewId == $before[0].recoveryCanary.viewId and
		.recoveryCanary.factId == -334 and .recoveryCanary.artifact.id == "issue334-artifact-v1"
	' "$integration_root/replacement-probe.json" >/dev/null ||
		fail 'container replacement lost a source, saved view, record canary, or durable link.'
}

prove_additive_metadata_refresh() { # <ready-source-response> <probe-response>
	local ready_before="$1" probe_before="$2" base_id operator_source_id decision_table_id view_id
	local diff_job_id sync_job_id
	base_id="$(jq -er '.baseId' "$ready_before")"
	operator_source_id="$(jq -er '.operator.sourceId' "$ready_before")"
	decision_table_id="$(jq -er '.recoveryCanary.decisionTableId' "$probe_before")"
	view_id="$(jq -er '.recoveryCanary.viewId' "$probe_before")"
	phase='additive-metadata-refresh'
	http_request GET "$nocodb_url/api/v2/meta/bases/$base_id/sources/$operator_source_id" nocodb-token - \
		"$integration_root/refresh-source-before.json"
	jq -e '.is_schema_readonly == true and .is_data_readonly == false' \
		"$integration_root/refresh-source-before.json" >/dev/null ||
		fail 'operator source flags were not schema-read-only before refresh.'
	printf '%s\n' 'BEGIN; SET LOCAL ROLE issue334_acceptance_owner; ALTER TABLE operator.acceptance_decision ADD COLUMN IF NOT EXISTS refresh_note text; COMMIT;' |
		"$podman_bin" exec --interactive "$postgres_name" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
			--username postgres --dbname issue334_acceptance >/dev/null
	http_request GET "$nocodb_url/api/v2/meta/bases/$base_id/meta-diff/$operator_source_id" nocodb-jwt - \
		"$integration_root/meta-diff-start.json"
	diff_job_id="$(jq -er '.id | select(type == "string" and length > 0)' "$integration_root/meta-diff-start.json")"
	wait_nocodb_job "$base_id" "$diff_job_id" "$integration_root/meta-diff-job.json"
	jq -e --arg source "$operator_source_id" '
		[.result[]? | select(.source_id == $source and .table_name == "acceptance_decision") |
			.detectedChanges[]? | select(.type == "TABLE_COLUMN_ADD" and .cn == "refresh_note")] | length == 1
	' "$integration_root/meta-diff-job.json" >/dev/null ||
		fail 'metadata diff did not report the exact additive domain column.'
	jq -n '{}' >"$integration_root/meta-sync-body.json"
	http_request POST "$nocodb_url/api/v2/meta/bases/$base_id/meta-diff/$operator_source_id" nocodb-jwt \
		"$integration_root/meta-sync-body.json" "$integration_root/meta-sync-start.json"
	sync_job_id="$(jq -er '.id | select(type == "string" and length > 0)' "$integration_root/meta-sync-start.json")"
	wait_nocodb_job "$base_id" "$sync_job_id" "$integration_root/meta-sync-job.json"
	http_request GET "$nocodb_url/api/v2/meta/bases/$base_id/tables" nocodb-token - \
		"$integration_root/refresh-tables.json"
	jq -e --arg source "$operator_source_id" --arg table "$decision_table_id" '
		(if type == "array" then . else (.list // .data // []) end) |
		[.[] | select(.source_id == $source and .title == "acceptance_decision" and .id == $table)] | length == 1
	' "$integration_root/refresh-tables.json" >/dev/null ||
		fail 'metadata refresh changed the existing decision table identity.'
	http_request GET "$nocodb_url/api/v2/meta/tables/$decision_table_id" nocodb-token - \
		"$integration_root/refresh-table.json"
	jq -e '[.columns[]? | select(.column_name == "refresh_note")] | length == 1' \
		"$integration_root/refresh-table.json" >/dev/null ||
		fail 'metadata refresh did not expose the additive column.'
	http_request GET "$nocodb_url/api/v2/meta/tables/$(jq -er '.recoveryCanary.factTableId' "$probe_before")/views" \
		nocodb-token - "$integration_root/refresh-views.json"
	jq -e --arg view "$view_id" '[.list[]? | select(.id == $view and .title == "acceptance_facts")] | length == 1' \
		"$integration_root/refresh-views.json" >/dev/null ||
		fail 'metadata refresh changed the saved-view identity.'
	http_request GET "$nocodb_url/api/v2/meta/bases/$base_id/sources/$operator_source_id" nocodb-token - \
		"$integration_root/refresh-source-after.json"
	jq -e '.is_schema_readonly == true and .is_data_readonly == false' \
		"$integration_root/refresh-source-after.json" >/dev/null ||
		fail 'metadata refresh changed operator source flags.'
	source_call sync - "$integration_root/refresh-source-sync.json"
	jq -e --slurpfile before "$ready_before" '
		.reader.sourceId == $before[0].reader.sourceId and .reader.integrationId == $before[0].reader.integrationId and
		.reader.credentialGeneration == $before[0].reader.credentialGeneration and
		.operator.sourceId == $before[0].operator.sourceId and .operator.integrationId == $before[0].operator.integrationId and
		.operator.credentialGeneration == $before[0].operator.credentialGeneration and
		.reader.schemaEditAllowed == false and .operator.schemaEditAllowed == false
	' "$integration_root/refresh-source-sync.json" >/dev/null ||
		fail 'metadata refresh changed source identity, credentials, or schema flags.'
}

prove_logical_restore() { # <ready-source-response> <probe-response>
	local ready_before="$1" probe_before="$2" bundle_name bundle_host globals_filtered fresh_bundle
	local record encoded dump_path database_name restore_ip restore_url='http://127.0.0.1:18081'
	local original_session restored_session reader_status operator_status
	phase='complete-logical-backup'
	"$podman_bin" exec "$postgres_name" mkdir -p /tmp/task7-backups
	"$podman_bin" exec --env BACKUP_DIR=/tmp/task7-backups --env PGDATABASE=automation_data_control \
		--env PGUSER=postgres "$postgres_name" /bin/sh /scripts/backup.sh >/dev/null
	bundle_name="$("$podman_bin" exec "$postgres_name" sh -eu -c \
		'find /tmp/task7-backups -mindepth 1 -maxdepth 1 -type d -name "automation-data-*" -exec basename {} \; | sort | tail -1')"
	[[ "$bundle_name" =~ ^automation-data-[0-9]{8}T[0-9]{6}Z$ ]] ||
		fail 'primary backup did not publish one valid complete bundle name.'
	bundle_host="$integration_root/$bundle_name"
	"$podman_bin" cp "$postgres_name:/tmp/task7-backups/$bundle_name" "$bundle_host"
	(cd "$bundle_host" && sha256sum -c SHA256SUMS >/dev/null && sha256sum -c COMPLETE >/dev/null) ||
		fail 'copied logical bundle failed checksum validation.'
	phase='separate-postgresql-restore'
	{
		printf 'POSTGRES_DB=postgres\nPOSTGRES_USER=postgres\nPOSTGRES_PASSWORD=%s\n' "$postgres_password"
	} >"$integration_root/restore-postgres.env"
	"$podman_bin" run --detach --name "$restore_postgres_name" \
		--label "homelab-talos.test-run=$run_marker" --network "$network" \
		--network-alias restore-postgresql --env-file "$integration_root/restore-postgres.env" \
		--volume "$restore_postgres_volume:/var/lib/postgresql/data" \
		--volume "$repo_root/kubernetes/apps/automation-data/postgresql/app/scripts:/scripts:ro" \
		"$postgres_image" >/dev/null
	created_containers+=("$restore_postgres_name")
	wait_postgres "$restore_postgres_name" postgres
	"$podman_bin" cp "$bundle_host" "$restore_postgres_name:/tmp/restore-bundle"
	globals_filtered="$integration_root/restore-globals.sql"
	awk '$0 != "CREATE ROLE postgres;"' "$bundle_host/globals.sql" >"$globals_filtered"
	[[ "$(rg -c -x 'CREATE ROLE postgres;' "$bundle_host/globals.sql")" == 1 ]] ||
		fail 'logical bundle did not contain one bootstrap postgres role declaration.'
	"$podman_bin" cp "$globals_filtered" "$restore_postgres_name:/tmp/restore-globals.sql"
	"$podman_bin" exec "$restore_postgres_name" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
		--username postgres --dbname postgres --file=/tmp/restore-globals.sql >/dev/null
	while IFS=$'\t' read -r record encoded dump_path; do
		[[ "$record" == database ]] || continue
		database_name="$(printf '%s' "$encoded" | base64 -d)"
		if [[ "$database_name" == postgres ]]; then
			"$podman_bin" exec "$restore_postgres_name" pg_restore --exit-on-error --username postgres \
				--dbname postgres "/tmp/restore-bundle/$dump_path" >/dev/null
		else
			"$podman_bin" exec "$restore_postgres_name" pg_restore --exit-on-error --create \
				--username postgres --dbname postgres "/tmp/restore-bundle/$dump_path" >/dev/null
		fi
	done <"$bundle_host/manifest.tsv"
	[[ "$("$podman_bin" exec "$restore_postgres_name" psql --no-psqlrc --tuples-only --no-align \
		--username postgres --dbname automation_data_control --command \
		"SELECT platform_operations.read_platform_revision();")" == 026-nocodb-v1 ]] ||
		fail 'restored platform revision was not exact.'
	restore_ip="$("$podman_bin" inspect "$restore_postgres_name" | jq -er --arg network "$network" \
		'.[0].NetworkSettings.Networks[$network].IPAddress')"
	[[ "$restore_ip" =~ ^[0-9a-fA-F:.]+$ ]] || fail 'could not resolve the isolated restored PostgreSQL address.'
	{
		printf 'DATABASE_URL=postgres://nocodb_metadata:%s@restore-postgresql:5432/nocodb?sslmode=disable\n' "$metadata_password"
		printf 'NC_AUTH_JWT_SECRET=%s\nNC_CONNECTION_ENCRYPT_KEY=%s\n' "$nocodb_jwt_secret" "$nocodb_connection_key"
		printf 'NC_ADMIN_EMAIL=local-admin@example.invalid\nNC_ADMIN_PASSWORD=%s\n' "$nocodb_admin_password"
		printf 'NC_ALLOW_LOCAL_EXTERNAL_DBS=true\nNC_DISABLE_TELE=true\nNC_DISABLE_SUPPORT_CHAT=true\n'
		printf 'NC_SITE_URL=%s\n' "$restore_url"
	} >"$integration_root/restore-nocodb.env"
	"$podman_bin" stop --time 5 "$postgres_name" >/dev/null
	[[ "$("$podman_bin" inspect --format '{{.State.Running}}' "$postgres_name")" == false ]] ||
		fail 'original PostgreSQL remained available during isolated restore validation.'
	start_nocodb_container "$restore_nocodb_name" "$integration_root/restore-nocodb.env" \
		restore-nocodb 18081 "$restore_ip"
	created_containers+=("$restore_nocodb_name")
	wait_http "$restore_url/api/v1/health" 'fresh restored NocoDB' '.message == "OK"'
	"$podman_bin" exec "$restore_nocodb_name" getent hosts \
		automation-data-postgresql.automation-data.svc.cluster.local |
		awk -v expected="$restore_ip" '$1 == expected { found = 1 } END { exit(found ? 0 : 1) }' ||
		fail 'restored NocoDB source host did not resolve to the isolated restored PostgreSQL.'
	phase='restored-nocodb-evidence'
	original_session="$nocodb_session"
	http_request POST "$restore_url/api/v1/auth/user/signin" none "$integration_root/nocodb-signin.json" \
		"$integration_root/restore-signin-response.json"
	restored_session="$(jq -er '.token | select(type == "string" and length > 0)' \
		"$integration_root/restore-signin-response.json")"
	nocodb_session="$restored_session"
	http_request GET "$restore_url/api/v2/meta/bases/$(jq -er '.baseId' "$ready_before")/sources" nocodb-token - \
		"$integration_root/restore-sources.json"
	jq -e --slurpfile before "$ready_before" '
		(if type == "array" then . else (.list // .data // []) end) as $sources |
		([$sources[] | select(.id == $before[0].reader.sourceId and .fk_integration_id == $before[0].reader.integrationId and .is_schema_readonly == true and .is_data_readonly == true)] | length) == 1 and
		([$sources[] | select(.id == $before[0].operator.sourceId and .fk_integration_id == $before[0].operator.integrationId and .is_schema_readonly == true and .is_data_readonly == false)] | length) == 1
	' "$integration_root/restore-sources.json" >/dev/null ||
		fail 'restored NocoDB lost current source identities, credentials, or flags.'
	http_request GET "$restore_url/api/v2/tables/$(jq -er '.recoveryCanary.factTableId' "$probe_before")/records?where=(id,eq,-334)&limit=2" \
		nocodb-token - "$integration_root/restore-fact.json"
	jq -e '(.list | length) == 1 and .list[0].id == -334 and .list[0].run_id == "recovery-canary-v2" and
		.list[0].artifact_id == "issue334-artifact-v1" and .list[0].artifact_uri == "https://artifacts.example.invalid/issue334/artifact-v1"' \
		"$integration_root/restore-fact.json" >/dev/null || fail 'restored record canary or artifact link metadata changed.'
	http_request GET "$restore_url/api/v2/meta/tables/$(jq -er '.recoveryCanary.factTableId' "$probe_before")/views" \
		nocodb-token - "$integration_root/restore-views.json"
	jq -e --arg view "$(jq -er '.recoveryCanary.viewId' "$probe_before")" \
		'[.list[]? | select(.id == $view and .title == "acceptance_facts")] | length == 1' \
		"$integration_root/restore-views.json" >/dev/null || fail 'restored saved-view identity changed.'
	jq -n '{id:9000000001,fact:"forbidden-restore"}' >"$integration_root/restore-reader-write.json"
	reader_status="$(http_status_json_request POST "$restore_url/api/v2/tables/$(jq -er '.recoveryCanary.factTableId' "$probe_before")/records" \
		nocodb-token "$integration_root/restore-reader-write.json" "$integration_root/restore-reader-write-response.json")"
	[[ "$reader_status" == 403 ]] || fail "restored reader source write denial returned HTTP $reader_status."
	jq -n --arg id "$(jq -er '.recoveryCanary.rowId' "$probe_before")" \
		'[{id:($id|tonumber),protected_created_at:"2000-01-01T00:00:00Z"}]' >"$integration_root/restore-operator-write.json"
	operator_status="$(http_status_json_request PATCH "$restore_url/api/v2/tables/$(jq -er '.recoveryCanary.decisionTableId' "$probe_before")/records" \
		nocodb-token "$integration_root/restore-operator-write.json" "$integration_root/restore-operator-write-response.json")"
	[[ "$operator_status" == 400 ]] || fail "restored protected-column denial returned HTTP $operator_status."
	for access_kind in reader operator; do
		"$podman_bin" exec "$restore_postgres_name" psql --no-psqlrc --tuples-only --no-align \
			--set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control --command \
			"SELECT (platform_operations.validate_nocodb_access('issue334_acceptance','$access_kind')->>'valid')::boolean;" |
			rg -qx t || fail "restored PostgreSQL $access_kind authority validation failed."
	done
	"$podman_bin" exec "$restore_postgres_name" mkdir -p /tmp/task7-fresh-backup
	"$podman_bin" exec --env BACKUP_DIR=/tmp/task7-fresh-backup --env PGDATABASE=automation_data_control \
		--env PGUSER=postgres "$restore_postgres_name" /bin/sh /scripts/backup.sh >/dev/null
	fresh_bundle="$("$podman_bin" exec "$restore_postgres_name" sh -eu -c \
		'find /tmp/task7-fresh-backup -mindepth 1 -maxdepth 1 -type d -name "automation-data-*" -exec basename {} \; | sort | tail -1')"
	[[ "$fresh_bundle" =~ ^automation-data-[0-9]{8}T[0-9]{6}Z$ ]] ||
		fail 'restored platform did not publish one fresh complete backup.'
	# $1 expands in the isolated container shell.
	# shellcheck disable=SC2016
	"$podman_bin" exec "$restore_postgres_name" sh -eu -c \
		'cd "/tmp/task7-fresh-backup/$1" && sha256sum -c SHA256SUMS >/dev/null && sha256sum -c COMPLETE >/dev/null' \
		sh "$fresh_bundle" || fail 'fresh logical bundle failed checksum validation.'
	nocodb_session="$original_session"
}

slice_run() { # <suffix> <initial-source-phase>
	local suffix="$1" initial_source_phase="$2"
	local run="${run_id}-${suffix}"
	phase="slice-$suffix-structure"
	acceptance_call structure "$run" "$integration_root/acceptance-structure.json"
	jq -e --arg run "$run" \
		'.ok == true and .operation == "structure" and .runId == $run and .structureReady == true' \
		"$integration_root/acceptance-structure.json" >/dev/null || fail 'acceptance structure failed.'

	phase="slice-$suffix-reader-sync"
	source_call sync - "$integration_root/source-reader.json"
	if [[ "$initial_source_phase" == true ]]; then
		jq -e '
			.reader.state == "ready" and .reader.accessKind == "reader" and
			.operator.state == "awaiting_grants" and .operator.accessKind == "operator"
		' "$integration_root/source-reader.json" >/dev/null ||
			fail 'initial source state was not reader-ready/operator-awaiting-grants.'
	else
		jq -e '.reader.state == "ready" and .operator.state == "ready"' \
			"$integration_root/source-reader.json" >/dev/null || fail 'rerun source sync was not ready.'
	fi

	phase="slice-$suffix-grants"
	acceptance_call grants "$run" "$integration_root/acceptance-grants.json"
	jq -e --arg run "$run" \
		'.ok == true and .operation == "grants" and .runId == $run and .grantsReady == true' \
		"$integration_root/acceptance-grants.json" >/dev/null || fail 'acceptance grants failed.'

	phase="slice-$suffix-operator-sync"
	source_call sync - "$integration_root/source-ready.json"
	jq -e '
		.reader.state == "ready" and .operator.state == "ready" and
		.reader.dataEditAllowed == false and .operator.dataEditAllowed == true and
		.reader.schemaEditAllowed == false and .operator.schemaEditAllowed == false
	' "$integration_root/source-ready.json" >/dev/null || fail 'both sources did not reach their least-privilege ready states.'
	phase="slice-$suffix-probe"
	acceptance_call probe "$run" "$integration_root/acceptance-probe.json"
	if ! jq -e '.ok == true and .operation == "probe" and
		.recoveryCanary.version == 2 and .recoveryCanary.state == "ready" and
		.recoveryCanary.factId == -334 and .recoveryCanary.artifact.id == "issue334-artifact-v1"' \
		"$integration_root/acceptance-probe.json" >/dev/null; then
		if [[ -s "$integration_root/acceptance-probe.json" ]] && ! jq 'if type == "object" then {type,keys:(keys|sort),ok,operation,errorCode,
			recoveryCanary:(.recoveryCanary | if type == "object" then
			{keys:(keys|sort),version,state,factId,artifactType:(.artifact|type)} else . end)}
			else {type,length} end' "$integration_root/acceptance-probe.json" >&2; then
			printf 'acceptanceProbeJson=false bytes=%s\n' "$(wc -c <"$integration_root/acceptance-probe.json")" >&2
		elif [[ ! -s "$integration_root/acceptance-probe.json" ]]; then
			printf 'acceptanceProbeJson=false bytes=0\n' >&2
		fi
		fail 'actual acceptance probe failed.'
	fi

	phase="slice-$suffix-feedback"
	acceptance_call feedback "$run" "$integration_root/acceptance-feedback.json"
	if ! jq -e --arg run "$run" '
		.ok == true and .operation == "feedback" and .runId == $run and
		.feedback.initialFact == "original" and
		.feedback.operatorDecision == "corrected" and
		.feedback.effectiveBeforeRefresh == "corrected" and
		.feedback.refreshedFact == "refreshed" and
		.feedback.effectiveAfterRefresh == "corrected"
	' "$integration_root/acceptance-feedback.json" >/dev/null; then
		if [[ -s "$integration_root/acceptance-feedback.json" ]]; then
			jq 'if type == "object" then {type,keys:(keys|sort),ok,operation,errorCode,
				feedback:(.feedback | if type == "object" then
				{keys:(keys|sort),initialFact,operatorDecision,effectiveBeforeRefresh,refreshedFact,effectiveAfterRefresh,
				initialFactType:(.initialFact|type),operatorDecisionType:(.operatorDecision|type),
				effectiveBeforeRefreshType:(.effectiveBeforeRefresh|type),refreshedFactType:(.refreshedFact|type),
				effectiveAfterRefreshType:(.effectiveAfterRefresh|type)} else . end)}
			else {type,length} end' "$integration_root/acceptance-feedback.json" >&2 || true
		else
			printf 'acceptanceFeedbackJson=false bytes=0\n' >&2
		fi
		fail 'actual runtime feedback loop failed.'
	fi
}

slice_run first true
prove_aged_jobs_rotation_and_restart "$integration_root/source-ready.json"
slice_run second false
prove_additive_metadata_refresh "$integration_root/source-ready.json" "$integration_root/acceptance-probe.json"
replace_nocodb_scratch "$integration_root/source-ready.json" "$integration_root/acceptance-probe.json"
prove_interrupted_initial_creation
prove_logical_restore "$integration_root/source-ready.json" "$integration_root/acceptance-probe.json"
