#!/usr/bin/env bash
# Disposable local NocoDB integration against the repository's pinned containers.
set -euo pipefail

if [[ "${NOCODB_LOCAL_OUTPUT_CAPTURED:-false}" != true ]]; then
	output_capture_root="$(mktemp -d "${TMPDIR:-/tmp}/nocodb-local-output.XXXXXX")"
	chmod 700 "$output_capture_root"
	trap 'rm -r -- "$output_capture_root"' EXIT
	set +e
	NOCODB_LOCAL_OUTPUT_CAPTURED=true \
		NOCODB_LOCAL_SECRET_MANIFEST="$output_capture_root/secrets" \
		"$0" "$@" >"$output_capture_root/stdout" 2>"$output_capture_root/stderr"
	captured_status=$?
	set -e
	credential_output_detected=false
	if [[ -s "$output_capture_root/secrets" ]]; then
		while IFS= read -r captured_secret; do
			[[ -n "$captured_secret" ]] || continue
			if rg -Fq -- "$captured_secret" "$output_capture_root/stdout" "$output_capture_root/stderr"; then
				credential_output_detected=true
				break
			fi
		done <"$output_capture_root/secrets"
	fi
	if [[ "$credential_output_detected" == true ]]; then
		echo 'NocoDB local integration credential output safety check failed.' >&2
		exit 1
	fi
	cat "$output_capture_root/stdout"
	cat "$output_capture_root/stderr" >&2
	exit "$captured_status"
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
source scripts/test/lib/nocodb-restore-command.sh
source scripts/test/lib/automation-data-discovery-restore.sh

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
	echo 'Usage: nocodb-local-integration.sh [--preflight|--cleanup-test|--output-safety-test]' >&2
	exit 2
}

case "$#" in
0)
	preflight_only=false
	cleanup_test=false
	output_safety_test=false
	;;
1)
	case "$1" in
	--preflight)
		preflight_only=true
		cleanup_test=false
		output_safety_test=false
		;;
	--cleanup-test)
		preflight_only=false
		cleanup_test=true
		output_safety_test=false
		;;
	--output-safety-test)
		preflight_only=false
		cleanup_test=false
		output_safety_test=true
		;;
	*) usage ;;
	esac
	;;
*) usage ;;
esac

secret_manifest="${NOCODB_LOCAL_SECRET_MANIFEST:?internal secret manifest is required}"
: >"$secret_manifest"
chmod 600 "$secret_manifest"
record_secret() {
	printf '%s\n' "$1" >>"$secret_manifest"
}

if [[ "$output_safety_test" == true ]]; then
	output_test_sentinel="${NOCODB_LOCAL_OUTPUT_TEST_SENTINEL:?output test sentinel is required}"
	record_secret "$output_test_sentinel"
	case "${NOCODB_LOCAL_OUTPUT_TEST_LEAK_STREAM:-safe}" in
	safe) ;;
	stdout) printf '%s\n' "$output_test_sentinel" ;;
	stderr) printf '%s\n' "$output_test_sentinel" >&2 ;;
	*) fail 'output safety test stream is invalid.' ;;
	esac
	echo 'NocoDB local integration output safety self-test completed.'
	exit 0
fi

[[ "$run_id" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,47}$ ]] ||
	fail 'NOCODB_LOCAL_RUN_ID must contain 1-48 safe identifier characters.'

[[ "$postgres_image" == "$postgres_image_expected" ]] ||
	fail "PostgreSQL image must be exactly $postgres_image_expected."
[[ "$n8n_image" == "$n8n_image_expected" ]] ||
	fail "n8n image must be exactly $n8n_image_expected."
[[ "$nocodb_image" == "$nocodb_image_expected" ]] ||
	fail "NocoDB image must be exactly $nocodb_image_expected."

require_loopback_url() {
	local label="$1" value="$2" port
	[[ "$value" =~ ^http://(127\.0\.0\.1|localhost|\[::1\]):([0-9]{1,5})$ ]] ||
		fail "$label must be an HTTP loopback URL with an explicit port."
	port="${BASH_REMATCH[2]}"
	((10#$port >= 1 && 10#$port <= 65535)) ||
		fail "$label must use a port from 1 through 65535."
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
containers=("$run_marker-postgres" "$run_marker-nocodb" "$run_marker-n8n"
	"$run_marker-restore-postgres" "$run_marker-restore-nocodb" "$run_marker-auth-probe")
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

mkdir -p "$repo_root/.tmp"
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
inventory_webhook_secret="$(random_secret)"
platform_inventory_password="$(random_secret)"
nocodb_inventory_password="$(random_secret)"
n8n_inventory_password="$(random_secret)"
for generated_secret in \
	"$postgres_password" "$provisioner_password" "$backup_password" "$exporter_password" \
	"$metadata_password" "$n8n_password" "$n8n_encryption_key" "$n8n_owner_password" \
	"$nocodb_admin_password" "$nocodb_jwt_secret" "$nocodb_connection_key" \
	"$provision_webhook_secret" "$source_webhook_secret" "$acceptance_webhook_secret" \
	"$inventory_webhook_secret" "$platform_inventory_password" "$nocodb_inventory_password" "$n8n_inventory_password"; do
	record_secret "$generated_secret"
done

postgres_name="${containers[0]}"
nocodb_name="${containers[1]}"
n8n_name="${containers[2]}"
restore_postgres_name="${containers[3]}"
restore_nocodb_name="${containers[4]}"
auth_probe_name="${containers[5]}"
postgres_volume="${volumes[0]}"
n8n_volume="${volumes[1]}"
restore_postgres_volume="${volumes[2]}"

"$podman_bin" network create --label "homelab-talos.test-run=$run_marker" "$network" >/dev/null
network_created=true
created_containers+=("$auth_probe_name")
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
	--network-alias n8n-postgresql.automation.svc.cluster.local \
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
		inventory-webhook) printf 'header = "X-Automation-Data-Inventory: %s"\n' "$inventory_webhook_secret" ;;
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
record_secret "$nocodb_session"
jq -n '{description:"NocoDB Task 5 disposable integration"}' >"$integration_root/nocodb-token.json"
http_request POST "$nocodb_url/api/v1/tokens" nocodb-jwt "$integration_root/nocodb-token.json" \
	"$integration_root/nocodb-token-response.json"
nocodb_token="$(jq -er '.token | select(type == "string" and length > 0)' "$integration_root/nocodb-token-response.json")"
record_secret "$nocodb_token"

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
record_secret "$n8n_api_key"

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

phase='discovery-projection-installation'
install_discovery_projection() { # <database> <reader> <candidate> <reviewed-sql>
	local database="$1" reader="$2" candidate="$3" reviewed_sql="$4"
	"$podman_bin" exec --interactive "$postgres_name" psql -X --set=ON_ERROR_STOP=1 \
		--username postgres --dbname "$database" <"$reviewed_sql" \
		>"$integration_root/discovery-install-$database.log" 2>&1 || fail 'Reviewed discovery projection failed.'
	printf "SET log_statement='none'; SET log_min_error_statement='panic'; ALTER ROLE %s LOGIN PASSWORD '%s';\n" "$reader" "$candidate" |
		"$podman_bin" exec --interactive "$postgres_name" psql -X --set=ON_ERROR_STOP=1 --username postgres --dbname "$database" \
			>"$integration_root/discovery-login-$database.log" 2>&1 || fail 'Synthetic discovery reader activation failed.'
}
install_discovery_projection automation_data_control automation_data_inventory "$platform_inventory_password" \
	kubernetes/apps/automation-data/postgresql/app/scripts/credential-discovery.sql
install_discovery_projection nocodb nocodb_inventory "$nocodb_inventory_password" \
	kubernetes/apps/automation-data/postgresql/app/scripts/nocodb-discovery.sql
install_discovery_projection n8n n8n_inventory "$n8n_inventory_password" \
	kubernetes/apps/automation/n8n-postgresql/app/scripts/credential-discovery.sql
# Exercise the production CLI enrollment against the real pinned application.
# New synthetic credentials enter only through stdin; existing values are not exported.
platform_inventory_id="$(openssl rand -hex 16)"
nocodb_inventory_id="$(openssl rand -hex 16)"
n8n_inventory_id="$(openssl rand -hex 16)"
inventory_header_id="$(openssl rand -hex 16)"
inventory_workflow_id="$(openssl rand -hex 16)"
native_project="$("$podman_bin" exec "$postgres_name" psql -X -U postgres -d n8n -Atc 'SELECT id FROM project;')"
[[ "$native_project" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || fail 'Disposable n8n project is ambiguous.'
PLATFORM_PASSWORD="$platform_inventory_password" NOCODB_PASSWORD="$nocodb_inventory_password" \
	N8N_PASSWORD="$n8n_inventory_password" HEADER="$inventory_webhook_secret" \
	uv run --locked python - "$native_project" "$platform_inventory_id" "$nocodb_inventory_id" "$n8n_inventory_id" "$inventory_header_id" "$inventory_workflow_id" \
	>"$integration_root/native-input.json" <<'PYTHON'
import json,os,sys,uuid
from pathlib import Path
sys.path.insert(0,'scripts/lib')
from automation_data_enrollment import SOURCES, WORKFLOW
project,*identities=sys.argv[1:]
ids=dict(zip(SOURCES,identities[:4],strict=True))
credentials=[]
for source,env in zip(SOURCES,['PLATFORM_PASSWORD','NOCODB_PASSWORD','N8N_PASSWORD','HEADER'],strict=True):
    ns,host,database,user,name=SOURCES[source]
    data=({'name':'X-Automation-Data-Inventory','value':os.environ[env]} if source=='header' else
          {'host':f'{host}.{ns}.svc.cluster.local','port':5432,'database':database,'user':user,'password':os.environ[env],'ssl':'disable'})
    credentials.append({'id':ids[source],'name':name,'type':'httpHeaderAuth' if source=='header' else 'postgres','data':data})
workflow=json.loads(WORKFLOW.read_text())
workflow={key:workflow[key] for key in ('name','nodes','connections','settings')}
workflow.update(id=identities[4],active=False)
for node in workflow['nodes']:
    if node['type']=='n8n-nodes-base.webhook':
        node['webhookId']=str(uuid.UUID(hex=identities[4]))
    for binding in node.get('credentials',{}).values():
        binding['id']=ids[next(s for s,entry in SOURCES.items() if entry[4]==binding['name'])]
print(json.dumps({'projectId':project,'verifyOnly':False,'credentials':credentials,'workflow':workflow}))
PYTHON
native_enroll_name="${run_marker}-native-enroll"
created_containers+=("$native_enroll_name")
native_enroll() {
	"$podman_bin" run --rm --interactive --name "$native_enroll_name" --label "homelab-talos.test-run=$run_marker" \
		--network "$network" --env-file "$integration_root/n8n.env" --env N8N_USER_FOLDER=/tmp/n8n \
		--read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
		--volume "$repo_root/scripts/lib/automation-data-discovery-enroll.cjs:/enroll.cjs:ro" \
		--entrypoint node "$n8n_image" /enroll.cjs /dev/stdin "${2:-import}" <"$1"
}
native_enroll "$integration_root/native-input.json" preflight >"$integration_root/native-preflight.log"
rg -Fxq 'discovery_native_preflight=verified' "$integration_root/native-preflight.log" || fail 'Native preflight failed.'
jq '.projectId="synthetic-missing-project"' "$integration_root/native-input.json" >"$integration_root/native-missing-project.json"
if native_enroll "$integration_root/native-missing-project.json" preflight >"$integration_root/native-missing-project.log" 2>&1; then
	fail 'Native preflight accepted a missing project.'
fi
[[ "$("$podman_bin" exec "$postgres_name" psql -X -U postgres -d n8n -Atc 'SELECT (SELECT count(*) FROM credentials_entity)+(SELECT count(*) FROM workflow_entity);')" == 0 ]] || fail 'Native preflight created credentials or workflows.'
native_enroll "$integration_root/native-input.json" >"$integration_root/native-import.log"
rg -Fxq 'discovery_native_enrollment=verified' "$integration_root/native-import.log" || fail 'Native enrollment failed.'
# The CLI normally upserts. The wrapper must refuse even an identical second creation.
if native_enroll "$integration_root/native-input.json" >"$integration_root/native-collision.log" 2>&1; then
	fail 'Native enrollment overwrote existing credentials.'
fi
jq '.verifyOnly=true' "$integration_root/native-input.json" >"$integration_root/native-verify.json"
native_enroll "$integration_root/native-verify.json" >"$integration_root/native-verify.log"
rg -Fxq 'discovery_native_enrollment=verified' "$integration_root/native-verify.log" || fail 'Retained native enrollment verification failed.'

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
	local migrator_nodes='["Create Acceptance Structure","Grant Acceptance Access","Clear Reader Negative Residue","Cleanup Unexpected Reader Insert","Clear Feedback Residue","Cleanup Feedback Fact","Grant Extended Acceptance Access","Cleanup Extended Acceptance"]'
	jq --arg pg_id "$pg_id" --arg pg_name "$pg_name" --arg http_id "$http_id" --arg http_name "$http_name" \
		--arg webhook_id "$webhook_id" --arg webhook_name "$webhook_name" \
		--arg runtime_id "$runtime_id" --arg runtime_name "$runtime_name" \
		--arg inventory_header_id "$inventory_header_id" \
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
			elif .name == "Observe Mutation Inventory" then .credentials = {httpHeaderAuth:{id:$inventory_header_id,name:"Automation Data Inventory Header"}}
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
http_request POST "$n8n_url/api/v1/workflows/$inventory_workflow_id/publish" n8n-key - "$integration_root/native-publish.json"
jq -e '.active == true' "$integration_root/native-publish.json" >/dev/null || fail 'Native inventory publication failed.'
printf '{"action":"list"}\n' >"$integration_root/native-probe.json"
http_request POST "$n8n_url/webhook/automation-data-credential-inventory" inventory-webhook "$integration_root/native-probe.json" "$integration_root/native-probe-response.json"
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
	local operation="$1" access_kind="$2" response="$3" domain="${4:-automation_data_acceptance}"
	local confirmation_name confirmation_value validator_status
	local -a command=(scripts/nocodb/source-operation.sh "$operation" "$domain")
	case "$operation" in
	sync)
		confirmation_name='NOCODB_SOURCE_SYNC_CONFIRM'
		confirmation_value="sync:nocodb:$domain"
		;;
	rotate)
		confirmation_name='NOCODB_SOURCE_ROTATE_CONFIRM'
		confirmation_value="rotate:nocodb:$domain:$access_kind"
		command+=("$access_kind")
		;;
	esac
	set +e
	env PATH="$integration_root/validator-bin:$PATH" \
		NOCODB_SOURCE_OPERATION_ACTUAL_RESPONSE="$response" \
		NOCODB_SOURCE_PROVISIONING_HEADER="$source_webhook_secret" \
		"$confirmation_name=$confirmation_value" \
		"${command[@]}" >/dev/null
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
	local operation="$1" access_kind="$2" output="$3" domain="${4:-automation_data_acceptance}" body registry_state
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

pair_call() { # <register|prepare|sync|rotate|retry> <output> [access-kind]
	local operation="$1" output="$2" access_kind="${3:-}" recovery_id="${4:-}" body status
	local domain='automation_data_acceptance' pair='extra'
	local action="pair-$operation" confirmation_name confirmation_value
	local -a command=(scripts/nocodb/source-operation.sh "$action" "$domain" "$pair")
	case "$operation" in
	register)
		body="$(jq -cn --arg domain "$domain" --arg pair "$pair" \
			'{domain:$domain,pair:$pair,operation:"register",readerSchema:"extra_read",operatorSchema:"extra_edit"}')"
		command+=(extra_read extra_edit)
		confirmation_name=NOCODB_PAIR_REGISTER_CONFIRM
		confirmation_value="register:nocodb:$domain:$pair:extra_read:extra_edit"
		;;
	prepare | sync)
		body="$(jq -cn --arg domain "$domain" --arg pair "$pair" --arg operation "$operation" \
			'{domain:$domain,pair:$pair,operation:$operation}')"
		confirmation_name="NOCODB_PAIR_${operation^^}_CONFIRM"
		confirmation_value="$operation:nocodb:$domain:$pair"
		;;
	rotate | retry)
		[[ "$access_kind" == reader || "$access_kind" == operator ]] || fail 'invalid pair rotation target.'
		body="$(jq -cn --arg domain "$domain" --arg pair "$pair" --arg access_kind "$access_kind" \
			--arg operation "$operation" \
			'{domain:$domain,pair:$pair,operation:$operation,accessKind:$access_kind}')"
		command+=("$access_kind")
		confirmation_name="NOCODB_PAIR_${operation^^}_CONFIRM"
		confirmation_value="$operation:nocodb:$domain:$pair:$access_kind"
		if [[ "$operation" == retry ]]; then
			# This fixture called SQL directly; no workflow or external request
			# was started for the retained claim, so quiescence is established.
			command+=("$recovery_id")
			confirmation_value+=":$recovery_id:quiesced"
			body="$(jq --arg id "$recovery_id" '. + {quiescedOperationId:$id}' <<<"$body")"
		fi
		;;
	*) fail 'invalid pair operation.' ;;
	esac
	webhook_call automation-data-nocodb-source source-webhook "$body" "$output"
	if ! jq -e '.ok == true' "$output" >/dev/null; then
		jq '{ok,domain,pair,operation,state,errorCode,reader:(.reader|if type=="object" then {state,credentialGeneration} else . end),operator:(.operator|if type=="object" then {state,credentialGeneration} else . end)}' "$output" >&2 || true
		fail "named pair $operation failed."
	fi
	set +e
	env PATH="$integration_root/validator-bin:$PATH" \
		NOCODB_SOURCE_OPERATION_ACTUAL_RESPONSE="$output" \
		NOCODB_SOURCE_PROVISIONING_HEADER="$source_webhook_secret" \
		"$confirmation_name=$confirmation_value" \
		"${command[@]}" >/dev/null
	status=$?
	set -e
	[[ "$status" == 0 ]] || fail "named pair $operation failed operator command validation."
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
	'{"domain":"automation_data_acceptance","operation":"provision"}' "$integration_root/provision-response.json"
jq -e '.ok == true and .state == "ready" and .domain == "automation_data_acceptance"' \
	"$integration_root/provision-response.json" >/dev/null || fail 'actual provisioning workflow failed.'
migrator_credential_id="$(jq -er '.migratorCredentialId' "$integration_root/provision-response.json")"
runtime_credential_id="$(jq -er '.runtimeCredentialId' "$integration_root/provision-response.json")"
[[ "$migrator_credential_id" =~ ^[A-Za-z0-9_-]+$ && "$runtime_credential_id" =~ ^[A-Za-z0-9_-]+$ &&
	"$migrator_credential_id" != "$runtime_credential_id" ]] || fail 'provisioning did not return distinct credential identities.'

phase='acceptance-binding'
bind_workflow kubernetes/apps/automation/n8n/app/workflows/nocodb-acceptance-domain.json \
	"$integration_root/nocodb-acceptance-domain.json" "$migrator_credential_id" \
	'automation-data/automation_data_acceptance/migrator' "$nocodb_header_id" 'NocoDB Operator API' \
	"$acceptance_header_id" 'NocoDB Acceptance Header' "$runtime_credential_id" \
	'automation-data/automation_data_acceptance/runtime'
acceptance_workflow_id="$(import_and_publish "$integration_root/nocodb-acceptance-domain.json" 'NocoDB Acceptance Domain')"
http_request GET "$n8n_url/api/v1/workflows/$acceptance_workflow_id" n8n-key - \
	"$integration_root/imported-acceptance-workflow.json"
jq -e --arg migrator "$migrator_credential_id" --arg runtime "$runtime_credential_id" '
	(if type == "array" and length == 1 then .[0] else . end) as $workflow |
	([$workflow.nodes[] | select(.type == "n8n-nodes-base.postgres" and .credentials.postgres.id == $migrator)] | length) == 8 and
	([$workflow.nodes[] | select(.type == "n8n-nodes-base.postgres" and .credentials.postgres.id == $runtime)] | length) == 4 and
	([$workflow.nodes[] | select(.type == "n8n-nodes-base.postgres" and
		(.credentials.postgres.id != $migrator and .credentials.postgres.id != $runtime))] | length) == 0
' "$integration_root/imported-acceptance-workflow.json" >/dev/null ||
	fail 'n8n did not retain the exact eight-migrator/four-runtime acceptance credential binding.'

prove_aged_jobs_rotation_and_restart() { # <ready source response>
	local ready_response="$1" reader_job_id operator_job_id completed_count absent_count base_id
	reader_job_id="$(jq -er '.reader.sourceCreateJobId' "$ready_response")"
	operator_job_id="$(jq -er '.operator.sourceCreateJobId' "$ready_response")"
	base_id="$(jq -er '.baseId' "$ready_response")"
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
	jq -n '{}' >"$integration_root/aged-job-api-request.json"
	http_request POST "$nocodb_url/api/v2/jobs/$base_id" nocodb-jwt \
		"$integration_root/aged-job-api-request.json" "$integration_root/aged-job-api-response.json"
	jq -e --arg reader "$reader_job_id" --arg operator "$operator_job_id" '
		type == "array" and
		([.[] | select(.id == $reader or .id == $operator)] | length) == 0
	' "$integration_root/aged-job-api-response.json" >/dev/null ||
		fail 'complete aged-job API readback still exposed a deleted source job.'

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

	phase='reader-rotation-with-aged-job'
	source_call rotate reader "$integration_root/source-reader-rotation.json"
	jq -e --slurpfile before "$integration_root/source-restarted-sync.json" '
		.reader.sourceCreateJobState == null and .operator.sourceCreateJobState == null and
		.reader.sourceId == $before[0].reader.sourceId and
		.reader.integrationId == $before[0].reader.integrationId and
		.reader.sourceCreateJobId == $before[0].reader.sourceCreateJobId and
		.reader.generation > $before[0].reader.generation and
		.reader.credentialGeneration == ($before[0].reader.credentialGeneration + 1) and
		.operator.sourceId == $before[0].operator.sourceId and
		.operator.integrationId == $before[0].operator.integrationId and
		.operator.sourceCreateJobId == $before[0].operator.sourceCreateJobId and
		.operator.generation == $before[0].operator.generation and
		.operator.credentialGeneration == $before[0].operator.credentialGeneration
	' "$integration_root/source-reader-rotation.json" >/dev/null ||
		fail 'reader-only rotation changed identity or the wrong credential generation.'

	phase='operator-rotation-with-aged-job'
	source_call rotate operator "$integration_root/source-operator-rotation.json"
	jq -e --slurpfile before "$integration_root/source-reader-rotation.json" '
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
	jq -n '{invite_only_signup:true,restrict_workspace_creation:true}' \
		>"$integration_root/replacement-settings-update.json"
	http_request POST "$nocodb_url/api/v1/app-settings" nocodb-jwt \
		"$integration_root/replacement-settings-update.json" \
		"$integration_root/replacement-settings-update-response.json"
	http_request GET "$nocodb_url/api/v1/app-settings" nocodb-jwt - \
		"$integration_root/replacement-settings-before.json"
	jq -e '.invite_only_signup == true and .restrict_workspace_creation == true' \
		"$integration_root/replacement-settings-before.json" >/dev/null ||
		fail 'safe app settings were not established before scratch replacement.'
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
	record_secret "$nocodb_session"
	http_request GET "$nocodb_url/api/v1/app-settings" nocodb-jwt - \
		"$integration_root/replacement-settings-after.json"
	jq -e --slurpfile before "$integration_root/replacement-settings-before.json" '
		.invite_only_signup == $before[0].invite_only_signup and
		.restrict_workspace_creation == $before[0].restrict_workspace_creation
	' "$integration_root/replacement-settings-after.json" >/dev/null ||
		fail 'safe app settings changed across container and scratch replacement.'
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
	printf '%s\n' 'BEGIN; SET LOCAL ROLE automation_data_acceptance_owner; ALTER TABLE operator.acceptance_decision ADD COLUMN IF NOT EXISTS refresh_note text; COMMIT;' |
		"$podman_bin" exec --interactive "$postgres_name" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
			--username postgres --dbname automation_data_acceptance >/dev/null
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
	pair_call sync "$integration_root/refresh-extra-sync.json"
	jq -e --slurpfile before "$integration_root/extra-ready.json" '
		.baseId == $before[0].baseId and
		.reader.sourceId == $before[0].reader.sourceId and
		.reader.integrationId == $before[0].reader.integrationId and
		.reader.credentialGeneration == $before[0].reader.credentialGeneration and
		.operator.sourceId == $before[0].operator.sourceId and
		.operator.integrationId == $before[0].operator.integrationId and
		.operator.credentialGeneration == $before[0].operator.credentialGeneration
	' "$integration_root/refresh-extra-sync.json" >/dev/null ||
		fail 'default pair metadata refresh changed the named pair.'
}

prove_logical_restore() { # <ready-source-response> <probe-response>
	local ready_before="$1" probe_before="$2" bundle_name bundle_host globals_filtered fresh_bundle
	local record encoded dump_path database_name restore_ip restore_url='http://127.0.0.1:18081'
	local original_session restored_session reader_status operator_status source_registry request_script
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
		"SELECT platform_operations.read_platform_revision();")" == 026-nocodb-v3 ]] ||
		fail 'restored platform revision was not exact.'
	prove_discovery_restored_projections
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
		restore-nocodb.automation-data.svc.cluster.local 18081 "$restore_ip"
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
	record_secret "$restored_session"
	nocodb_session="$restored_session"
	local named_base named_reader_table named_operator_table retained_password
	named_base="$(jq -er '.baseId' "$integration_root/extra-ready.json")"
	named_reader_table="$(jq -er --arg source "$(jq -er '.reader.sourceId' "$integration_root/extra-ready.json")" \
		'(.list // .data // [])[] | select(.title == "visible_facts" and .source_id == $source) | .id' \
		"$integration_root/extra-tables.json")"
	named_operator_table="$(jq -er --arg source "$(jq -er '.operator.sourceId' "$integration_root/extra-ready.json")" \
		'(.list // .data // [])[] | select(.title == "decisions" and .source_id == $source) | .id' \
		"$integration_root/extra-tables.json")"
	http_request GET "$restore_url/api/v2/meta/bases/$named_base/sources" nocodb-token - \
		"$integration_root/restore-extra-sources.json"
	jq -e --slurpfile before "$integration_root/extra-ready.json" '
		(if type == "array" then . else (.list // .data // []) end) as $sources |
		([$sources[] | select(.id == $before[0].reader.sourceId and
			.fk_integration_id == $before[0].reader.integrationId and
			.is_schema_readonly == true and .is_data_readonly == true)] | length) == 1 and
		([$sources[] | select(.id == $before[0].operator.sourceId and
			.fk_integration_id == $before[0].operator.integrationId and
			.is_schema_readonly == true and .is_data_readonly == false)] | length) == 1
	' "$integration_root/restore-extra-sources.json" >/dev/null ||
		fail 'restored named pair lost source identities or privilege flags.'
	http_request GET "$restore_url/api/v2/meta/bases/$named_base/tables" nocodb-token - \
		"$integration_root/restore-extra-tables.json"
	jq -e --slurpfile before "$integration_root/extra-tables.json" '
		[(.list // .data // [])[] | {id,title,source_id}] | sort_by(.id) ==
		([$before[0] | (.list // .data // [])[] | {id,title,source_id}] | sort_by(.id))
	' "$integration_root/restore-extra-tables.json" >/dev/null ||
		fail 'restored named pair changed reflected table identities.'
	for named_table in "$named_reader_table" "$named_operator_table"; do
		http_request GET "$restore_url/api/v2/meta/tables/$named_table/views" nocodb-token - \
			"$integration_root/restore-extra-views-$named_table.json"
		local original_views="$integration_root/extra-reader-views.json"
		[[ "$named_table" == "$named_operator_table" ]] &&
			original_views="$integration_root/extra-operator-views.json"
		jq -e --slurpfile before "$original_views" '
			[(.list // .data // [])[] | {id,title,fk_model_id}] | sort_by(.id) ==
			([$before[0] | (.list // .data // [])[] | {id,title,fk_model_id}] | sort_by(.id))
		' "$integration_root/restore-extra-views-$named_table.json" >/dev/null ||
			fail 'restored named pair changed a saved-view identity.'
	done
	IFS=: read -r retained_host retained_port retained_database retained_role retained_password \
		<"$application_credential_file"
	[[ "$retained_host" == 127.0.0.1 && "$retained_port" == 5432 &&
		"$retained_database" == automation_data_acceptance &&
		"$retained_role" == "$application_role" &&
		"$retained_password" == "$application_password" ]] ||
		fail 'protected application credential binding changed.'
	application_authenticates "$restore_postgres_name" "$retained_password" ||
		fail 'retained application credential did not authenticate to isolated restore.'
	"$podman_bin" exec "$restore_postgres_name" psql --no-psqlrc --tuples-only --no-align \
		--set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control --command \
		"SELECT (platform_operations.validate_application_login('automation_data_acceptance','interview')->>'valid')::boolean;" |
		rg -qx t || fail 'restored application privilege validation failed.'
	phase='restored-retained-application-contract'
	uv run --locked python scripts/test/lib/automation-data-application-acceptance.py \
		disposable-command "$run_id" "$integration_root/restored-app-probe.sh"
	"$podman_bin" run --rm --name "$auth_probe_name" \
		--label "homelab-talos.test-run=$run_marker" --network "$network" \
		--volume "$application_credential_file:/credentials/pgpass:ro" \
		--volume "$integration_root/restored-app-probe.sh:/probe.sh:ro" \
		"$postgres_image" /bin/sh /probe.sh >"$integration_root/restored-app-probe.log" 2>/dev/null ||
		fail 'retained application restore write/read and real privilege denials failed.'
	[[ "$(cat "$integration_root/restored-app-probe.log")" == application_acceptance=passed ]] ||
		fail 'retained application restore probe omitted bounded evidence.'
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
			"SELECT (platform_operations.validate_nocodb_access('automation_data_acceptance','$access_kind')->>'valid')::boolean;" |
			rg -qx t || fail "restored PostgreSQL $access_kind authority validation failed."
	done
	source_registry="$("$podman_bin" exec "$restore_postgres_name" psql --no-psqlrc --tuples-only --no-align \
		--set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control --command "
SELECT jsonb_build_object(
  'items', COALESCE(jsonb_agg(jsonb_build_object(
    'domain', source.domain,
    'pair', source.pair,
    'accessKind', source.access_kind,
    'state', source.state,
    'baseId', source.base_id,
    'sourceId', source.source_id,
    'integrationId', source.integration_id,
    'schema', CASE source.access_kind WHEN 'reader' THEN
      COALESCE(mapping.reader_schema, 'read_model') ELSE
      COALESCE(mapping.operator_schema, 'operator') END,
    'valid', (platform_operations.validate_nocodb_access(source.domain, source.pair, source.access_kind)->>'valid')::boolean
  ) ORDER BY source.pair, source.access_kind), '[]'::jsonb)
)
FROM platform_operations.managed_nocodb_sources AS source
LEFT JOIN platform_operations.managed_nocodb_schema_mappings AS mapping
  ON mapping.domain = source.domain AND mapping.pair = source.pair
WHERE source.domain = 'automation_data_acceptance';")" ||
		fail 'could not capture the restored source registry for the production request helper.'
	nocodb_restore_validate_source_registry <(printf '%s\n' "$source_registry") ||
		fail 'restored source registry did not satisfy the production request contract.'
	jq -e '(.items | length) == 4 and ([.items[].pair] | unique) == ["default","extra"]' \
		<<<"$source_registry" >/dev/null || fail 'restored source registry lost a pair.'
	{
		printf 'APP_SERVICE=restore-nocodb\n'
		printf 'RUN_HASH=%s\n' "$run_id"
		printf 'SOURCE_REGISTRY=%s\n' "$(jq -c . <<<"$source_registry")"
		printf 'ADMIN_EMAIL=local-admin@example.invalid\n'
		printf 'ADMIN_PASSWORD=%s\n' "$nocodb_admin_password"
	} >"$integration_root/restore-request.env"
	chmod 600 "$integration_root/restore-request.env"
	request_script="$(nocodb_restore_request_script)"
	printf '%s\n' "$request_script" | "$podman_bin" exec --interactive \
		--env-file "$integration_root/restore-request.env" "$restore_nocodb_name" \
		node --input-type=module - >"$integration_root/restore-request-output"
	rg -Fxq 'nocodb_restore_assertions=passed' "$integration_root/restore-request-output" ||
		fail 'production restore request helper did not pass against the actual restored NocoDB.'
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

prove_named_pair() {
	local reader_role operator_role
	phase='named-pair-registration'
	pair_call register "$integration_root/extra-registration.json"
	jq -e '.pair == "extra" and .state == "registered" and
		.readerSchema == "extra_read" and .operatorSchema == "extra_edit" and
		(.readerRole | test("^nocodb_[a-f0-9]{32}_reader$")) and
		(.operatorRole | test("^nocodb_[a-f0-9]{32}_operator$"))' \
		"$integration_root/extra-registration.json" >/dev/null || fail 'named pair registration was incomplete.'
	reader_role="$(jq -er '.readerRole' "$integration_root/extra-registration.json")"
	operator_role="$(jq -er '.operatorRole' "$integration_root/extra-registration.json")"
	[[ "$reader_role" =~ ^nocodb_[a-f0-9]{32}_reader$ &&
		"$operator_role" =~ ^nocodb_[a-f0-9]{32}_operator$ ]] || fail 'named pair roles were malformed.'
	pair_call prepare "$integration_root/extra-before-grants.json"
	jq -e '.readerEligible == false and .operatorEligible == false' \
		"$integration_root/extra-before-grants.json" >/dev/null ||
		fail 'named pair was eligible before its consumer-reviewed grants.'

	phase='named-pair-migrator-grants'
	local body
	body="$(jq -cn '{domain:"automation_data_acceptance",operation:"login-register",application:"interview",schema:"app"}')"
	webhook_call automation-data-provision provision-webhook "$body" "$integration_root/application-registration.json"
	application_role="$(jq -er '.role' "$integration_root/application-registration.json")"
	acceptance_call extensions "$run_id" "$integration_root/extensions-grants.json"
	jq -e '.ok == true and .extensionsReady == true' "$integration_root/extensions-grants.json" >/dev/null ||
		fail 'fixed extended acceptance grants failed.'
	pair_call prepare "$integration_root/extra-prepared.json"
	jq -e '.readerEligible == true and .operatorEligible == true and
		.operatorRequested == true' "$integration_root/extra-prepared.json" >/dev/null ||
		fail 'named pair did not become eligible after reviewed grants.'

	phase='named-pair-first-sync'
	pair_call sync "$integration_root/extra-ready.json"
	jq -e '.pair == "extra" and .reader.state == "ready" and .operator.state == "ready" and
		.reader.dataEditAllowed == false and .operator.dataEditAllowed == true and
		.reader.schemaEditAllowed == false and .operator.schemaEditAllowed == false and
		.reader.sourceId != .operator.sourceId' "$integration_root/extra-ready.json" >/dev/null ||
		fail 'named pair source privilege or identity was wrong.'
	pair_call sync "$integration_root/extra-repeat.json"
	jq -e --slurpfile before "$integration_root/extra-ready.json" '
		.baseId == $before[0].baseId and
		.reader.sourceId == $before[0].reader.sourceId and
		.reader.integrationId == $before[0].reader.integrationId and
		.reader.credentialGeneration == $before[0].reader.credentialGeneration and
		.operator.sourceId == $before[0].operator.sourceId and
		.operator.integrationId == $before[0].operator.integrationId and
		.operator.credentialGeneration == $before[0].operator.credentialGeneration
	' "$integration_root/extra-repeat.json" >/dev/null ||
		fail 'repeated named pair sync changed source or credential identity.'
	local base_id reader_source operator_source
	base_id="$(jq -er '.baseId' "$integration_root/extra-ready.json")"
	reader_source="$(jq -er '.reader.sourceId' "$integration_root/extra-ready.json")"
	operator_source="$(jq -er '.operator.sourceId' "$integration_root/extra-ready.json")"
	http_request GET "$nocodb_url/api/v2/meta/bases/$base_id/tables" nocodb-token - \
		"$integration_root/extra-tables.json"
	jq -e --arg reader "$reader_source" --arg operator "$operator_source" '
		(.list // .data // []) as $tables |
		([$tables[] | select(.title == "visible_facts" and .source_id == $reader)] | length) == 1 and
		([$tables[] | select(.title == "decisions" and .source_id == $operator)] | length) == 1 and
		([$tables[] | select(.title == "withheld_bookkeeping")] | length) == 0
	' "$integration_root/extra-tables.json" >/dev/null ||
		fail 'named pair reflected a withheld or missing table.'
	local reader_table operator_table
	reader_table="$(jq -er --arg source "$reader_source" \
		'(.list // .data // [])[] | select(.title == "visible_facts" and .source_id == $source) | .id' \
		"$integration_root/extra-tables.json")"
	operator_table="$(jq -er --arg source "$operator_source" \
		'(.list // .data // [])[] | select(.title == "decisions" and .source_id == $source) | .id' \
		"$integration_root/extra-tables.json")"
	local group_table link_field
	group_table="$(jq -er --arg source "$operator_source" \
		'(.list // .data // [])[] | select(.title == "decision_groups" and .source_id == $source) | .id' \
		"$integration_root/extra-tables.json")"
	http_request GET "$nocodb_url/api/v2/meta/tables/$operator_table" nocodb-token - \
		"$integration_root/extra-operator-meta.json"
	link_field="$(jq -er --arg parent "$group_table" '
		[.columns[] | select((.uidt == "Links" or .uidt == "LinkToAnotherRecord") and
		  .colOptions.type == "bt" and .colOptions.fk_related_model_id == $parent)] |
		if length == 1 then .[0].id else error("missing reflected foreign-key link") end
	' "$integration_root/extra-operator-meta.json")"
	# Exercise the same native relation API used by Community Edition controls.
	for parent_id in 2 1; do
		jq -n --argjson id "$parent_id" '[{id:$id}]' >"$integration_root/extra-link-body.json"
		http_request POST "$nocodb_url/api/v2/tables/$operator_table/links/$link_field/records/491" \
			nocodb-token "$integration_root/extra-link-body.json" "$integration_root/extra-link-write.json"
		http_request GET "$nocodb_url/api/v2/tables/$operator_table/links/$link_field/records/491" \
			nocodb-token - "$integration_root/extra-link-read.json"
		# A belongs-to link returns the single parent object, not a paginated list.
		jq -e --arg id "$parent_id" '(.id | tostring) == $id' \
			"$integration_root/extra-link-read.json" >/dev/null || fail 'native linked-record edit was not retained.'
	done
	http_request GET "$nocodb_url/api/v2/meta/tables/$reader_table/views" nocodb-token - \
		"$integration_root/extra-reader-views.json"
	http_request GET "$nocodb_url/api/v2/meta/tables/$operator_table/views" nocodb-token - \
		"$integration_root/extra-operator-views.json"
	jq -e '(.list // .data // []) | length > 0 and all(.[]; .id | type == "string")' \
		"$integration_root/extra-reader-views.json" >/dev/null ||
		fail 'named reader did not retain a saved view.'
	jq -e '(.list // .data // []) | length > 0 and all(.[]; .id | type == "string")' \
		"$integration_root/extra-operator-views.json" >/dev/null ||
		fail 'named operator did not retain a saved view.'
	source_call sync - "$integration_root/default-after-extra.json"
	jq -e --slurpfile before "$integration_root/source-ready.json" '
		.baseId == $before[0].baseId and
		.reader.sourceId == $before[0].reader.sourceId and
		.reader.credentialGeneration == $before[0].reader.credentialGeneration and
		.operator.sourceId == $before[0].operator.sourceId and
		.operator.credentialGeneration == $before[0].operator.credentialGeneration
	' "$integration_root/default-after-extra.json" >/dev/null ||
		fail 'named pair creation changed the default pair.'
}

prove_concurrent_pair_sync() {
	local first_pid second_pid first_status second_status
	phase='concurrent-named-pair-webhooks'
	printf '%s\n' '{"domain":"automation_data_acceptance","pair":"extra","operation":"sync"}' \
		>"$integration_root/concurrent-pair-body.json"
	http_request POST "$n8n_url/webhook/automation-data-nocodb-source" source-webhook \
		"$integration_root/concurrent-pair-body.json" \
		"$integration_root/concurrent-pair-first.json" &
	first_pid=$!
	http_request POST "$n8n_url/webhook/automation-data-nocodb-source" source-webhook \
		"$integration_root/concurrent-pair-body.json" \
		"$integration_root/concurrent-pair-second.json" &
	second_pid=$!
	set +e
	wait "$first_pid"
	first_status=$?
	wait "$second_pid"
	second_status=$?
	set -e
	[[ "$first_status" == 0 && "$second_status" == 0 ]] ||
		fail 'concurrent source webhook transport failed.'
	for response in "$integration_root/concurrent-pair-first.json" \
		"$integration_root/concurrent-pair-second.json"; do
		jq -e --slurpfile before "$integration_root/extra-ready.json" '
			.pair == "extra" and .operation == "sync" and
			((.ok == true and .reader.state == "ready" and .operator.state == "ready" and
				.reader.sourceId == $before[0].reader.sourceId and
				.reader.credentialGeneration == $before[0].reader.credentialGeneration and
				.operator.sourceId == $before[0].operator.sourceId and
				.operator.credentialGeneration == $before[0].operator.credentialGeneration) or
			 (.ok == false and .errorCode == "operation_in_progress" and
				.activeOperation == "sync"))
		' "$response" >/dev/null || fail 'concurrent webhook returned an unsafe outcome.'
	done
	jq -s -e 'any(.[]; .ok == true)' "$integration_root/concurrent-pair-first.json" \
		"$integration_root/concurrent-pair-second.json" >/dev/null ||
		fail 'neither concurrent source webhook completed.'
	pair_call sync "$integration_root/concurrent-pair-after.json"
	jq -e --slurpfile before "$integration_root/extra-ready.json" '
		.reader.sourceId == $before[0].reader.sourceId and
		.reader.credentialGeneration == $before[0].reader.credentialGeneration and
		.operator.sourceId == $before[0].operator.sourceId and
		.operator.credentialGeneration == $before[0].operator.credentialGeneration
	' "$integration_root/concurrent-pair-after.json" >/dev/null ||
		fail 'concurrent named pair sync changed a source credential.'
}

application_authenticates() { # <postgres-container> <password>
	local container="$1" password="$2" observed host
	if [[ "$container" == "$postgres_name" ]]; then
		host='automation-data-postgresql.automation-data.svc.cluster.local'
	elif [[ "$container" == "$restore_postgres_name" ]]; then
		host='restore-postgresql'
	else
		fail 'application authentication selected an unknown PostgreSQL container.'
	fi
	observed="$("$podman_bin" run --rm --name "$auth_probe_name" \
		--label "homelab-talos.test-run=$run_marker" --network "$network" \
		--env "PGPASSWORD=$password" "$postgres_image" \
		psql --no-psqlrc --no-password --tuples-only --no-align --set=ON_ERROR_STOP=1 \
		--host="$host" --username="$application_role" \
		--dbname=automation_data_acceptance --command 'SELECT current_user;' 2>/dev/null)" || return 1
	[[ "$observed" == "$application_role" ]]
}

prove_application_login() {
	local domain='automation_data_acceptance' application='interview' body
	phase='application-login-registration'
	body="$(jq -cn --arg domain "$domain" --arg application "$application" \
		'{domain:$domain,operation:"login-register",application:$application,schema:"app"}')"
	webhook_call automation-data-provision provision-webhook "$body" \
		"$integration_root/application-registration.json"
	jq -e '.ok == true and .state == "awaiting_grants" and
		.schema == "app" and (.role | test("^app_[a-f0-9]{32}_integration$"))' \
		"$integration_root/application-registration.json" >/dev/null ||
		fail 'application login registration failed.'
	application_role="$(jq -er '.role' "$integration_root/application-registration.json")"
	[[ "$application_role" =~ ^app_[a-f0-9]{32}_integration$ ]] ||
		fail 'application login role was malformed.'
	body="$(jq -cn --arg domain "$domain" --arg application "$application" \
		'{domain:$domain,operation:"login-validate",application:$application}')"
	webhook_call automation-data-provision provision-webhook "$body" \
		"$integration_root/application-eligible.json"
	jq -e '.ok == true and .state == "awaiting_grants" and .valid == true' \
		"$integration_root/application-eligible.json" >/dev/null ||
		fail 'application login grants were not eligible.'
	phase='application-login-activation'
	application_password="$(random_secret)"
	record_secret "$application_password"
	application_credential_file="$integration_root/application-credential.pgpass"
	printf '127.0.0.1:5432:%s:%s:%s\n' "$domain" "$application_role" \
		"$application_password" >"$application_credential_file"
	chmod 600 "$application_credential_file"
	body="$(jq -cn --arg domain "$domain" --arg application "$application" \
		--arg password "$application_password" \
		'{domain:$domain,operation:"login-activate",application:$application,
		operationId:"00000000-0000-4000-8000-000000000491",expectedGeneration:0,password:$password}')"
	webhook_call automation-data-provision provision-webhook "$body" \
		"$integration_root/application-activated.json"
	jq -e '.ok == true and .state == "activating" and .credentialGeneration == 1 and
		.operationId == "00000000-0000-4000-8000-000000000491"' \
		"$integration_root/application-activated.json" >/dev/null ||
		fail 'application credential activation failed.'
	application_authenticates "$postgres_name" "$application_password" ||
		fail 'activated application credential did not authenticate.'
	if application_authenticates "$postgres_name" "$(random_secret)"; then
		fail 'application password probe accepted an unrelated password.'
	fi
	body="$(jq -cn --arg domain "$domain" --arg application "$application" \
		'{domain:$domain,operation:"login-complete",application:$application,
		operationId:"00000000-0000-4000-8000-000000000491",credentialGeneration:1}')"
	webhook_call automation-data-provision provision-webhook "$body" \
		"$integration_root/application-ready.json"
	jq -e '.ok == true and .state == "ready" and .credentialGeneration == 1' \
		"$integration_root/application-ready.json" >/dev/null ||
		fail 'application login completion failed.'
	[[ "$("$podman_bin" exec --env "PGPASSWORD=$application_password" "$postgres_name" \
		psql --no-psqlrc --no-password --tuples-only --no-align --set=ON_ERROR_STOP=1 \
		--host=127.0.0.1 --username="$application_role" --dbname="$domain" \
		--command "SELECT app.record_integration_fact(2,'created'); SELECT fact FROM app.integration_facts WHERE id=2;" 2>/dev/null | tail -1)" == created ]] ||
		fail 'application fixed write/read functions failed.'
	if "$podman_bin" exec --env "PGPASSWORD=$application_password" "$postgres_name" \
		psql --no-psqlrc --no-password --tuples-only --no-align --set=ON_ERROR_STOP=1 \
		--host=127.0.0.1 --username="$application_role" --dbname="$domain" \
		--command 'SELECT * FROM app.withheld_bookkeeping;' >/dev/null 2>&1; then
		fail 'application login read the withheld bookkeeping table.'
	fi
	if "$podman_bin" exec --env "PGPASSWORD=$application_password" "$postgres_name" \
		psql --no-psqlrc --no-password --tuples-only --no-align --set=ON_ERROR_STOP=1 \
		--host=127.0.0.1 --username="$application_role" --dbname="$domain" \
		--command 'SELECT app.withheld_admin();' >/dev/null 2>&1; then
		fail 'application login executed the withheld privileged routine.'
	fi
	phase='extended-fixture-current-run-cleanup'
	"$podman_bin" exec "$postgres_name" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
		--username postgres --dbname automation_data_acceptance --command \
		"SELECT app.record_integration_fact(('x'||substr(md5('$run_id'),1,15))::bit(60)::bigint, 'acceptance:$run_id');" >/dev/null
	acceptance_call extensions-cleanup "$run_id" "$integration_root/extensions-cleanup.json"
	jq -e '.ok == true and .extensionsReady == true' "$integration_root/extensions-cleanup.json" >/dev/null ||
		fail 'fixed current-run application cleanup failed.'
	"$podman_bin" exec "$postgres_name" psql --no-psqlrc --tuples-only --no-align \
		--set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_acceptance --command \
		"SELECT NOT EXISTS (SELECT FROM app.integration_facts WHERE id = ('x'||substr(md5('$run_id'),1,15))::bit(60)::bigint) AND EXISTS (SELECT FROM app.integration_facts WHERE id=2 AND fact='created');" |
		rg -qx t || fail 'application cleanup removed another fixture or retained the current run.'

}

prove_targeted_rotations() {
	local domain='automation_data_acceptance' application='interview'
	local old_password="$application_password" body before_registry after_registry
	phase='named-pair-reader-rotation'
	pair_call rotate "$integration_root/extra-reader-rotated.json" reader
	jq -e --slurpfile before "$integration_root/extra-ready.json" '
		.baseId == $before[0].baseId and
		.reader.sourceId == $before[0].reader.sourceId and
		.reader.integrationId == $before[0].reader.integrationId and
		.reader.credentialGeneration == ($before[0].reader.credentialGeneration + 1) and
		.operator.sourceId == $before[0].operator.sourceId and
		.operator.integrationId == $before[0].operator.integrationId and
		.operator.credentialGeneration == $before[0].operator.credentialGeneration
	' "$integration_root/extra-reader-rotated.json" >/dev/null ||
		fail 'named reader rotation changed its sibling identity or credential.'
	pair_call sync "$integration_root/extra-after-rotation.json"
	jq -e --slurpfile before "$integration_root/extra-reader-rotated.json" '
		.reader.sourceId == $before[0].reader.sourceId and
		.reader.credentialGeneration == $before[0].reader.credentialGeneration and
		.operator.sourceId == $before[0].operator.sourceId and
		.operator.credentialGeneration == $before[0].operator.credentialGeneration
	' "$integration_root/extra-after-rotation.json" >/dev/null ||
		fail 'named pair sync changed a freshly rotated credential.'
	cp "$integration_root/extra-after-rotation.json" "$integration_root/extra-ready.json"
	source_call sync - "$integration_root/default-after-extra-rotation.json"
	jq -e --slurpfile before "$integration_root/default-after-extra.json" '
		.reader.sourceId == $before[0].reader.sourceId and
		.reader.credentialGeneration == $before[0].reader.credentialGeneration and
		.operator.sourceId == $before[0].operator.sourceId and
		.operator.credentialGeneration == $before[0].operator.credentialGeneration
	' "$integration_root/default-after-extra-rotation.json" >/dev/null ||
		fail 'named pair rotation changed the default pair.'

	phase='application-credential-rotation'
	before_registry="$("$podman_bin" exec "$postgres_name" psql --no-psqlrc --tuples-only --no-align \
		--set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control --command \
		"SELECT jsonb_agg(jsonb_build_object('pair',pair,'accessKind',access_kind,'credentialGeneration',credential_generation,'sourceId',source_id,'integrationId',integration_id) ORDER BY pair,access_kind) FROM platform_operations.managed_nocodb_sources WHERE domain = '$domain';")"
	application_password="$(random_secret)"
	record_secret "$application_password"
	body="$(jq -cn --arg domain "$domain" --arg application "$application" \
		--arg password "$application_password" \
		'{domain:$domain,operation:"login-rotate",application:$application,
		operationId:"00000000-0000-4000-8000-000000000492",expectedGeneration:1,password:$password}')"
	webhook_call automation-data-provision provision-webhook "$body" \
		"$integration_root/application-rotated.json"
	jq -e '.ok == true and .state == "rotating" and .credentialGeneration == 2 and
		.operationId == "00000000-0000-4000-8000-000000000492"' \
		"$integration_root/application-rotated.json" >/dev/null ||
		fail 'application credential rotation did not advance once.'
	application_authenticates "$postgres_name" "$application_password" ||
		fail 'new application credential did not authenticate.'
	if application_authenticates "$postgres_name" "$old_password"; then
		fail 'old application credential still authenticated after rotation.'
	fi
	body="$(jq -cn --arg domain "$domain" --arg application "$application" \
		'{domain:$domain,operation:"login-complete",application:$application,
		operationId:"00000000-0000-4000-8000-000000000492",credentialGeneration:2}')"
	webhook_call automation-data-provision provision-webhook "$body" \
		"$integration_root/application-rotation-ready.json"
	jq -e '.ok == true and .state == "ready" and .credentialGeneration == 2' \
		"$integration_root/application-rotation-ready.json" >/dev/null ||
		fail 'application rotation did not complete.'
	printf '127.0.0.1:5432:%s:%s:%s\n' "$domain" "$application_role" \
		"$application_password" >"$application_credential_file"
	chmod 600 "$application_credential_file"
	after_registry="$("$podman_bin" exec "$postgres_name" psql --no-psqlrc --tuples-only --no-align \
		--set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control --command \
		"SELECT jsonb_agg(jsonb_build_object('pair',pair,'accessKind',access_kind,'credentialGeneration',credential_generation,'sourceId',source_id,'integrationId',integration_id) ORDER BY pair,access_kind) FROM platform_operations.managed_nocodb_sources WHERE domain = '$domain';")"
	[[ "$before_registry" == "$after_registry" ]] ||
		fail 'application rotation changed a NocoDB source registry entry.'
}

prove_partial_rotation_retry() {
	local domain='automation_data_acceptance' pair='extra' access_kind='operator'
	local claim_id='00000000-0000-4000-8000-000000000493' claim generation
	local intermediate_password rotation_state body
	phase='partial-operator-rotation'
	claim="$("$podman_bin" exec "$postgres_name" psql --no-psqlrc --tuples-only --no-align \
		--set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control --command \
		"SELECT platform_operations.claim_nocodb_operation('$domain','$pair','rotate','$access_kind','$claim_id');")"
	jq -e '.canExecute == true and .phase == "active" and .operation == "rotate" and
		.accessKind == "operator"' <<<"$claim" >/dev/null ||
		fail 'partial rotation could not acquire its exact source claim.'
	generation="$(jq -er '.generation' <<<"$claim")"
	[[ "$generation" =~ ^[0-9]+$ ]] || fail 'partial rotation claim generation was invalid.'
	intermediate_password="$(random_secret)"
	record_secret "$intermediate_password"
	rotation_state="$("$podman_bin" exec "$postgres_name" psql --no-psqlrc --tuples-only --no-align \
		--set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control --command \
		"SELECT platform_operations.rotate_nocodb_source_credential('$domain','$pair','$access_kind','$intermediate_password','$claim_id',$generation);")"
	jq -e --slurpfile before "$integration_root/extra-ready.json" '
		.state == "rotating" and .sourceId == $before[0].operator.sourceId and
		.credentialGeneration == ($before[0].operator.credentialGeneration + 1)
	' <<<"$rotation_state" >/dev/null || fail 'partial rotation did not retain its source identity.'
	"$podman_bin" exec "$postgres_name" psql --no-psqlrc --tuples-only --no-align \
		--set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control --command \
		"SELECT platform_operations.mark_nocodb_operation_uncertain('$domain','$pair','$claim_id',$generation,'external_response_unknown');" \
		>/dev/null
	body="$(jq -cn --arg domain "$domain" --arg pair "$pair" \
		'{domain:$domain,pair:$pair,operation:"sync"}')"
	webhook_call automation-data-nocodb-source source-webhook "$body" \
		"$integration_root/partial-ordinary-sync.json"
	jq -e '.ok == false and .pair == "extra" and .activeOperation == "rotate" and
		.errorCode == "operation_in_progress"' \
		"$integration_root/partial-ordinary-sync.json" >/dev/null ||
		fail 'ordinary sync tried to repair an uncertain partial rotation.'
	phase='close-stale-integration-sessions'
	"$podman_bin" restart --time 1 "$nocodb_name" >/dev/null
	wait_http "$nocodb_url/api/v1/health" 'NocoDB before partial rotation retry' '.message == "OK"'
	webhook_call automation-data-nocodb-source source-webhook \
		'{"domain":"automation_data_acceptance","pair":"extra","operation":"status"}' \
		"$integration_root/partial-operation-status.json"
	jq -e --arg id "$claim_id" '.ok == true and .claim.operationId == $id and .claim.phase == "uncertain" and .claim.operation == "rotate" and .claim.accessKind == "operator"' \
		"$integration_root/partial-operation-status.json" >/dev/null ||
		fail 'supported status did not expose the exact uncertain rotation ID.'
	phase='explicit-partial-rotation-retry'
	pair_call retry "$integration_root/extra-retry-ready.json" operator "$claim_id"
	jq -e --slurpfile before "$integration_root/extra-ready.json" '
		.pair == "extra" and .reader.state == "ready" and .operator.state == "ready" and
		.reader.sourceId == $before[0].reader.sourceId and
		.reader.credentialGeneration == $before[0].reader.credentialGeneration and
		.operator.sourceId == $before[0].operator.sourceId and
		.operator.integrationId == $before[0].operator.integrationId and
		.operator.credentialGeneration == ($before[0].operator.credentialGeneration + 2)
	' "$integration_root/extra-retry-ready.json" >/dev/null ||
		fail 'explicit partial rotation retry changed sibling or source identity.'
	cp "$integration_root/extra-retry-ready.json" "$integration_root/extra-ready.json"
}

prove_foreign_base_title_collision() {
	local domain='automation_data_acceptance' pair='blocked' reader_role foreign_base
	phase='foreign-named-base-collision'
	"$podman_bin" start "$postgres_name" >/dev/null
	wait_postgres "$postgres_name" automation_data_control
	wait_http "$nocodb_url/api/v1/health" 'original NocoDB after isolated restore' '.message == "OK"'
	wait_http "$n8n_url/healthz/readiness" 'original n8n after isolated restore'
	phase='foreign-base-creation'
	jq -n --arg title "$domain--$pair" '{title:$title}' \
		>"$integration_root/foreign-base-request.json"
	http_request POST "$nocodb_url/api/v2/meta/bases" nocodb-token \
		"$integration_root/foreign-base-request.json" \
		"$integration_root/foreign-base-response.json"
	foreign_base="$(jq -er --arg title "$domain--$pair" \
		'select(.title == $title) | .id | select(type == "string" and length > 0)' \
		"$integration_root/foreign-base-response.json")"
	for _attempt in $(seq 1 30); do
		http_request GET "$nocodb_url/api/v2/meta/bases" nocodb-token - \
			"$integration_root/foreign-base-visible.json"
		if jq -e --arg title "$domain--$pair" --arg id "$foreign_base" '
			(if type == "array" then . else (.list // .data // []) end) as $bases |
			([$bases[] | select(.id == $id and .title == $title)] | length) == 1
		' "$integration_root/foreign-base-visible.json" >/dev/null; then
			break
		fi
		sleep 0.2
	done
	jq -e --arg title "$domain--$pair" --arg id "$foreign_base" '
		(if type == "array" then . else (.list // .data // []) end) as $bases |
		([$bases[] | select(.id == $id and .title == $title)] | length) == 1
	' "$integration_root/foreign-base-visible.json" >/dev/null ||
		fail 'foreign base did not become visible before the collision probe.'
	phase='foreign-base-pair-registration'
	webhook_call automation-data-nocodb-source source-webhook \
		"$(jq -cn --arg domain "$domain" --arg pair "$pair" \
			'{domain:$domain,pair:$pair,operation:"register",readerSchema:"blocked_read",operatorSchema:null}')" \
		"$integration_root/blocked-registration.json"
	jq -e '.ok == true and .pair == "blocked" and .operatorRole == null and
		(.readerRole | test("^nocodb_[a-f0-9]{32}_reader$"))' \
		"$integration_root/blocked-registration.json" >/dev/null ||
		fail 'collision fixture pair registration failed.'
	reader_role="$(jq -er '.readerRole' "$integration_root/blocked-registration.json")"
	[[ "$reader_role" =~ ^nocodb_[a-f0-9]{32}_reader$ ]] ||
		fail 'collision fixture role was malformed.'
	phase='foreign-base-grants'
	cat >"$integration_root/blocked-grants.sql" <<SQL
SET SESSION AUTHORIZATION automation_data_acceptance_migrator;
SET ROLE automation_data_acceptance_owner;
CREATE SCHEMA blocked_read AUTHORIZATION automation_data_acceptance_owner;
CREATE TABLE blocked_read.visible (id bigint PRIMARY KEY, fact text NOT NULL);
INSERT INTO blocked_read.visible VALUES (1,'visible');
GRANT CONNECT ON DATABASE automation_data_acceptance TO "$reader_role";
GRANT USAGE ON SCHEMA blocked_read TO "$reader_role";
GRANT SELECT ON blocked_read.visible TO "$reader_role";
SQL
	"$podman_bin" exec --interactive "$postgres_name" psql --no-psqlrc \
		--set=ON_ERROR_STOP=1 --username postgres --dbname "$domain" \
		<"$integration_root/blocked-grants.sql" >/dev/null ||
		fail 'collision fixture reviewed grants failed.'
	phase='foreign-base-prepare'
	webhook_call automation-data-nocodb-source source-webhook \
		"$(jq -cn --arg domain "$domain" --arg pair "$pair" \
			'{domain:$domain,pair:$pair,operation:"prepare"}')" \
		"$integration_root/blocked-prepared.json"
	jq -e '.ok == true and .readerEligible == true and .operatorRequested == false' \
		"$integration_root/blocked-prepared.json" >/dev/null ||
		fail 'collision fixture was not eligible before sync.'
	phase='foreign-base-sync'
	webhook_call automation-data-nocodb-source source-webhook \
		"$(jq -cn --arg domain "$domain" --arg pair "$pair" \
			'{domain:$domain,pair:$pair,operation:"sync"}')" \
		"$integration_root/blocked-sync.json"
	if ! jq -e '.ok == false and .domain == "automation_data_acceptance" and
		.pair == "blocked" and .operation == "sync"' \
		"$integration_root/blocked-sync.json" >/dev/null; then
		jq '{ok,domain,pair,operation,state,errorCode,baseId,
			reader:(.reader | if type == "object" then {state,sourceId,credentialGeneration} else . end)}' \
			"$integration_root/blocked-sync.json" >&2 || true
		fail 'source collision response did not retain the rejected request identity.'
	fi
	http_request GET "$nocodb_url/api/v2/meta/bases" nocodb-token - \
		"$integration_root/blocked-bases.json"
	jq -e --arg title "$domain--$pair" --arg id "$foreign_base" '
		(if type == "array" then . else (.list // .data // []) end) as $bases |
		([$bases[] | select(.title == $title)] | length) == 1 and
		([$bases[] | select(.id == $id and .title == $title)] | length) == 1
	' "$integration_root/blocked-bases.json" >/dev/null ||
		fail 'collision handling changed the foreign base identity.'
	http_request GET "$nocodb_url/api/v2/meta/bases/$foreign_base/sources" nocodb-token - \
		"$integration_root/blocked-sources.json"
	jq -e '(if type == "array" then . else (.list // .data // []) end) |
		[.[] | select(.alias == "Read Model" or .alias == "Operator")] | length == 0' \
		"$integration_root/blocked-sources.json" >/dev/null ||
		fail 'collision handling added a managed source to the foreign base.'
}

prove_lost_source_create_response() {
	local domain='issue491_response_loss' workflow_id base_id integration_id registry before after request_pid
	phase='lost-source-response-proxy'
	# Forward one supported API create, then discard its completed response. The
	# proxy retains only a count, never request bodies, headers, or credentials.
	cat >"$integration_root/source-loss-proxy.cjs" <<'JS'
const http = require('node:http');
const fs = require('node:fs');
let accepted = 0;
http.createServer((incoming, outgoing) => {
  const upstream = http.request({hostname: process.env.LOSS_TARGET_HOST, port: 8080,
    path: incoming.url, method: incoming.method, headers: incoming.headers}, response => {
    response.resume();
    response.on('end', () => {
      if (response.statusCode >= 200 && response.statusCode < 300) accepted++;
      fs.writeFileSync('/tmp/source-loss-count', String(accepted));
      const release = setInterval(() => {
        if (fs.existsSync('/tmp/source-loss-release')) {
          clearInterval(release);
          outgoing.destroy();
        }
      }, 50);
      setTimeout(() => { clearInterval(release); outgoing.destroy(); }, 60000).unref();
    });
  });
  upstream.on('error', () => outgoing.destroy());
  incoming.pipe(upstream);
}).listen(18081, '127.0.0.1', () => fs.writeFileSync('/tmp/source-loss-ready', 'ready'));
JS
	"$podman_bin" cp "$integration_root/source-loss-proxy.cjs" "$n8n_name:/tmp/source-loss-proxy.cjs"
	"$podman_bin" exec --detach --env "LOSS_TARGET_HOST=$nocodb_name" "$n8n_name" \
		node /tmp/source-loss-proxy.cjs >/dev/null
	for _attempt in $(seq 1 30); do
		if "$podman_bin" exec "$n8n_name" test -f /tmp/source-loss-ready; then break; fi
		sleep 0.1
	done
	"$podman_bin" exec "$n8n_name" test -f /tmp/source-loss-ready || fail 'response-loss proxy did not start.'
	jq '
		.name = "Synthetic Source Response Loss" |
		.nodes |= map(if .type == "n8n-nodes-base.webhook" then .parameters.path = "issue491-source-loss"
			elif .name == "Create Reader Source" then .parameters.url |=
				sub("http://nocodb.automation-data.svc.cluster.local:8080"; "http://127.0.0.1:18081")
			else . end)
	' "$integration_root/nocodb-source-provisioner.json" >"$integration_root/source-loss-workflow.json"
	workflow_id="$(import_and_publish "$integration_root/source-loss-workflow.json" 'Synthetic Source Response Loss')"
	[[ -n "$workflow_id" ]] || fail 'response-loss workflow was not published.'
	phase='lost-source-response-domain'
	webhook_call automation-data-provision provision-webhook \
		'{"domain":"issue491_response_loss","operation":"provision"}' \
		"$integration_root/loss-provision.json"
	jq -e '.ok == true and .state == "ready"' "$integration_root/loss-provision.json" >/dev/null ||
		fail 'response-loss synthetic domain was not provisioned.'
	printf '%s\n' 'BEGIN; SET LOCAL ROLE issue491_response_loss_owner; CREATE SCHEMA read_model AUTHORIZATION issue491_response_loss_owner; CREATE TABLE app.loss_fact (id bigint PRIMARY KEY, fact text NOT NULL); CREATE VIEW read_model.loss_facts AS SELECT id, fact FROM app.loss_fact; COMMIT;' |
		"$podman_bin" exec --interactive "$postgres_name" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
			--username postgres --dbname "$domain" >/dev/null
	phase='lose-accepted-create-response'
	webhook_call issue491-source-loss source-webhook \
		'{"domain":"issue491_response_loss","operation":"sync"}' "$integration_root/loss-response.json" &
	request_pid=$!
	for _attempt in $(seq 1 100); do
		if [[ "$("$podman_bin" exec "$n8n_name" cat /tmp/source-loss-count 2>/dev/null || true)" == 1 ]]; then break; fi
		sleep 0.05
	done
	[[ "$("$podman_bin" exec "$n8n_name" cat /tmp/source-loss-count)" == 1 ]] || fail 'external create did not reach the held-response boundary.'
	[[ "$("$podman_bin" exec "$postgres_name" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
		--username postgres --dbname automation_data_control --tuples-only --no-align --command \
		"SELECT phase FROM platform_operations.nocodb_source_operations WHERE domain='$domain' AND pair='default';")" == active ]] ||
		fail 'first creation claim was not active at the concurrency boundary.'
	phase='concurrent-create-with-response-in-flight'
	webhook_call automation-data-nocodb-source source-webhook \
		'{"domain":"issue491_response_loss","operation":"sync"}' "$integration_root/loss-concurrent.json"
	jq -e '.ok == false and .domain == "issue491_response_loss" and (.errorCode == "operation_in_progress" or .errorCode == "source_operation_failed")' \
		"$integration_root/loss-concurrent.json" >/dev/null || fail 'concurrent create did not observe the retained claim.'
	"$podman_bin" exec "$n8n_name" touch /tmp/source-loss-release
	wait "$request_pid" || fail 'response-loss workflow did not return its bounded error.'
	jq -e '.ok == false and .domain == "issue491_response_loss" and .operation == "sync"' \
		"$integration_root/loss-response.json" >/dev/null || fail 'lost response did not fail with its target retained.'
	[[ "$("$podman_bin" exec "$n8n_name" cat /tmp/source-loss-count)" == 1 ]] ||
		fail 'response-loss test did not accept exactly one external create.'
	registry="$("$podman_bin" exec "$postgres_name" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
		--username postgres --dbname automation_data_control --tuples-only --no-align --command \
		"SELECT jsonb_build_object('baseId',base_id,'integrationId',integration_id,'generation',credential_generation,'jobId',source_create_job_id) FROM platform_operations.managed_nocodb_sources WHERE domain='$domain' AND pair='default' AND access_kind='reader';")"
	jq -e '.jobId == null and (.baseId|type=="string") and (.integrationId|type=="string")' \
		<<<"$registry" >/dev/null || fail 'lost create response did not retain pre-create identities.'
	base_id="$(jq -er '.baseId' <<<"$registry")"
	integration_id="$(jq -er '.integrationId' <<<"$registry")"
	# Wait for the accepted asynchronous operation to appear through the supported
	# API. This wait is evidence of its identity, not permission to create again.
	for _attempt in $(seq 1 60); do
		http_request GET "$nocodb_url/api/v2/meta/bases/$base_id/sources" nocodb-token - "$integration_root/loss-sources.json"
		if jq -e --arg integration "$integration_id" '
			(if type == "array" then . else (.list // .data // []) end) |
			[.[] | select(.fk_integration_id == $integration)] | length == 1
		' "$integration_root/loss-sources.json" >/dev/null; then break; fi
		sleep 0.2
	done
	before="$(jq -cS --arg integration "$integration_id" '
		(if type == "array" then . else (.list // .data // []) end) |
		[.[] | select(.fk_integration_id == $integration) | {id,fk_integration_id}] | sort_by(.id)
	' "$integration_root/loss-sources.json")"
	[[ "$(jq length <<<"$before")" == 1 ]] || fail 'accepted source did not appear after response loss.'
	phase='observe-lost-source-response'
	for _attempt in 1 2; do
		webhook_call automation-data-nocodb-source source-webhook \
			'{"domain":"issue491_response_loss","operation":"sync"}' "$integration_root/loss-observed.json"
		jq -e '.ok == false and .domain == "issue491_response_loss"' "$integration_root/loss-observed.json" >/dev/null ||
			fail 'unknown job outcome was silently marked ready.'
	done
	http_request GET "$nocodb_url/api/v2/meta/bases/$base_id/sources" nocodb-token - "$integration_root/loss-after.json"
	after="$(jq -cS --arg integration "$integration_id" '
		(if type == "array" then . else (.list // .data // []) end) |
		[.[] | select(.fk_integration_id == $integration) | {id,fk_integration_id}] | sort_by(.id)
	' "$integration_root/loss-after.json")"
	[[ "$after" == "$before" ]] || fail 'observing a lost create response changed or duplicated the source.'
	[[ "$("$podman_bin" exec "$n8n_name" cat /tmp/source-loss-count)" == 1 ]] || fail 'observation dispatched another external create.'
	[[ "$("$podman_bin" exec "$postgres_name" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
		--username postgres --dbname automation_data_control --tuples-only --no-align --command \
		"SELECT credential_generation FROM platform_operations.managed_nocodb_sources WHERE domain='$domain' AND pair='default' AND access_kind='reader';")" == "$(jq -r '.generation' <<<"$registry")" ]] ||
		fail 'observing a lost response changed the source password.'
}

observe_discovery() { # <output-file>
	webhook_call automation-data-credential-inventory inventory-webhook '{"action":"list"}' "$1"
	jq -e --arg id "$inventory_workflow_id" --arg header "$inventory_header_id" \
		--arg platform "$platform_inventory_id" --arg nocodb "$nocodb_inventory_id" --arg n8n "$n8n_inventory_id" '
        (.sources[] | select(.source == "n8n")) as $source |
        if $source.complete then
          any($source.objects[]; .kind == "workflow" and .id == $id and .published == true) and
          ([ $source.objects[] | select(.kind == "binding" and .workflowId == $id) | .credentialId ] | unique | sort) ==
          ([$header,$platform,$nocodb,$n8n] | sort)
        else true end' "$1" >/dev/null || fail 'Actual published inventory workflow bindings were not observed.'
}
assert_discovery() { # <mode> <snapshot> [fixture-expectations]
	uv run --locked python scripts/test/lib/automation-data-discovery-acceptance.py "$@" || fail 'Independent credential inventory assertion failed.'
}
discovery_owned_database() {
	[[ "$("$podman_bin" inspect --format '{{ index .Config.Labels "homelab-talos.test-run" }}' "$postgres_name")" == "$run_marker" ]] || fail 'Discovery fixture database ownership changed.'
}
prove_discovery_current() { # <expected-application-generation> <application-response>
	phase='credential-discovery-current-inventory'
	observe_discovery "$integration_root/discovery-current.json"
	assert_discovery complete "$integration_root/discovery-current.json" "$1"
	assert_discovery lifecycle "$integration_root/discovery-current.json" "$2"
	assert_discovery lifecycle "$integration_root/discovery-current.json" "$integration_root/extra-ready.json"
}
prove_discovery_timeout_and_recovery() {
	phase='credential-discovery-reader-cancellation'
	discovery_owned_database
	"$podman_bin" exec --interactive "$postgres_name" psql -X --set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control \
		>"$integration_root/discovery-delay.log" 2>&1 <<'SQL'
ALTER FUNCTION platform_discovery.read_snapshot() RENAME TO fast_snapshot;
CREATE FUNCTION platform_discovery.read_snapshot() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog AS $$ BEGIN PERFORM pg_sleep(3); RETURN platform_discovery.fast_snapshot(); END $$;
ALTER FUNCTION platform_discovery.read_snapshot() OWNER TO automation_data_inventory_projection;
REVOKE ALL ON FUNCTION platform_discovery.read_snapshot() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION platform_discovery.read_snapshot() TO automation_data_inventory;
SQL
	observe_discovery "$integration_root/discovery-cancelled.json"
	assert_discovery incomplete "$integration_root/discovery-cancelled.json"
	discovery_owned_database
	"$podman_bin" exec --interactive "$postgres_name" psql -X --set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control \
		<kubernetes/apps/automation-data/postgresql/app/scripts/credential-discovery.sql \
		>"$integration_root/discovery-rebuild.log" 2>&1
	"$podman_bin" exec "$postgres_name" psql -X --set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control \
		--command 'DROP FUNCTION platform_discovery.fast_snapshot();' >/dev/null
	observe_discovery "$integration_root/discovery-after-cancellation.json"
	assert_discovery complete "$integration_root/discovery-after-cancellation.json" 2
}
prove_discovery_attended_removal() {
	phase='credential-discovery-reviewed-synthetic-removal'
	local credential_id removed_runtime
	credential_id="$(create_n8n_credential 'Synthetic discovery removal' httpHeaderAuth '{"name":"X-Synthetic","value":"SYNTHETIC_REMOVAL_ONLY"}')"
	[[ "$credential_id" =~ ^[A-Za-z0-9_-]+$ ]] || fail 'Synthetic removal credential identity is invalid.'
	discovery_owned_database
	"$podman_bin" exec "$postgres_name" psql -X --set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control \
		--command 'CREATE ROLE issue506_unregistered NOLOGIN;' >/dev/null
	observe_discovery "$integration_root/discovery-before-removal.json"
	jq -e --arg id "$credential_id" '
        all(.sources[]; .complete == true) and
        any(.sources[] | select(.source == "n8n") | .objects[]; .kind == "credential" and .id == $id) and
        any(.sources[] | select(.source == "platform") | .objects[]; .kind == "role" and .id == "issue506_unregistered")
        ' "$integration_root/discovery-before-removal.json" >/dev/null || fail 'Removal targets were not independently enumerated.'
	http_request DELETE "$n8n_url/api/v1/credentials/$credential_id" n8n-key - "$integration_root/discovery-delete-response.json"
	discovery_owned_database
	"$podman_bin" exec "$postgres_name" psql -X --set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control \
		--command 'DROP ROLE issue506_unregistered;' >/dev/null
	observe_discovery "$integration_root/discovery-after-removal.json"
	jq -n --arg id "$credential_id" '{schemaVersion:1,steps:["enumerated","removed","enumerated"],
        removed:[["n8n","credential",$id],["platform","role","issue506_unregistered"]]}' >"$integration_root/discovery-removal-receipt.json"
	assert_discovery absent "$integration_root/discovery-after-removal.json" "$integration_root/discovery-removal-receipt.json"
    jq --slurpfile cancelled "$integration_root/discovery-cancelled.json" '
      .sources |= map(if .source == "platform" then
        ($cancelled[0].sources[] | select(.source == "platform")) else . end)
      ' "$integration_root/discovery-after-removal.json" >"$integration_root/discovery-removal-incomplete.json"
    if uv run --locked python scripts/test/lib/automation-data-discovery-acceptance.py absent \
        "$integration_root/discovery-removal-incomplete.json" "$integration_root/discovery-removal-receipt.json" >/dev/null 2>&1; then
        fail 'A removal receipt established absence despite failed independent enumeration.'
    fi
	assert_discovery complete "$integration_root/discovery-after-removal.json" 2
	application_authenticates "$postgres_name" "$application_password" || fail 'Synthetic removal affected the surviving application.'
	acceptance_call probe "$run_id" "$integration_root/discovery-surviving-consumers.json"
	jq -e '.ok == true' "$integration_root/discovery-surviving-consumers.json" >/dev/null || fail 'Surviving consumers failed after attended synthetic removal.'
	# Remove only one unused synthetic domain's observed credential, then its registry
	# row. Each side remains observable independently; no production delete API is added.
	webhook_call automation-data-provision provision-webhook '{"domain":"issue506_inventory_removal","operation":"provision"}' "$integration_root/discovery-removal-domain.json"
	removed_runtime="$(jq -er '.runtimeCredentialId' "$integration_root/discovery-removal-domain.json")"
	[[ "$removed_runtime" =~ ^[A-Za-z0-9_-]+$ ]] || fail 'Synthetic domain credential identity is invalid.'
	http_request DELETE "$n8n_url/api/v1/credentials/$removed_runtime" n8n-key - "$integration_root/discovery-domain-delete.json"
	observe_discovery "$integration_root/discovery-registry-only.json"
	assert_discovery registry-only "$integration_root/discovery-registry-only.json"
	discovery_owned_database
	"$podman_bin" exec "$postgres_name" psql -X --set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control \
		--command "DELETE FROM platform_operations.managed_domains WHERE domain='issue506_inventory_removal';" >/dev/null
	observe_discovery "$integration_root/discovery-observed-only.json"
	assert_discovery observed-only "$integration_root/discovery-observed-only.json"
}

slice_run first true
prove_named_pair
prove_concurrent_pair_sync
prove_application_login
prove_discovery_current 1 "$integration_root/application-ready.json"
prove_targeted_rotations
prove_discovery_current 2 "$integration_root/application-rotation-ready.json"
prove_discovery_timeout_and_recovery
prove_discovery_attended_removal
prove_partial_rotation_retry
prove_aged_jobs_rotation_and_restart "$integration_root/source-ready.json"
slice_run second false
prove_additive_metadata_refresh "$integration_root/source-ready.json" "$integration_root/acceptance-probe.json"
replace_nocodb_scratch "$integration_root/source-ready.json" "$integration_root/acceptance-probe.json"
prove_interrupted_initial_creation
prove_logical_restore "$integration_root/source-ready.json" "$integration_root/acceptance-probe.json"
prove_foreign_base_title_collision
prove_lost_source_create_response
phase='credential-discovery-sql-permission-and-installer-boundaries'
scripts/test/automation-data-discovery-sql-test.sh
