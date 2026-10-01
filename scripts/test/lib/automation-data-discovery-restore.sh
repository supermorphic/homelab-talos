#!/usr/bin/env bash
# Sourced only by the registered run-owned disposable NocoDB integration.
# shellcheck disable=SC2034,SC2154 # The caller supplies owned resources and reads phase for diagnostics.

discovery_restore_owned() {
	[[ "$("$podman_bin" inspect --format '{{ index .Config.Labels "homelab-talos.test-run" }}' "$restore_postgres_name")" == "$run_marker" ]] ||
		fail 'Discovery restore fixture ownership changed.'
}

prove_discovery_restored_projections() {
	phase='credential-discovery-isolated-projection-restore'
	discovery_owned_database
	"$podman_bin" exec "$postgres_name" pg_dump --username postgres --dbname n8n --format custom \
		--no-owner --no-privileges --exclude-schema=platform_discovery >"$integration_root/discovery-n8n.dump" || fail 'Synthetic n8n application dump failed.'
	"$podman_bin" cp "$integration_root/discovery-n8n.dump" "$restore_postgres_name:/tmp/discovery-n8n.dump"
	discovery_restore_owned
	# This fixture shares one PostgreSQL server, so its platform bundle already
	# contains n8n. Replace only that isolated restored database to exercise the
	# production n8n dump format, which excludes the derived discovery schema.
	[[ "$("$podman_bin" exec "$restore_postgres_name" psql -X --username postgres --dbname postgres -At \
		--command "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='n8n';")" == n8n ]] ||
		fail 'Isolated synthetic n8n database ownership is unexpected.'
	discovery_restore_owned
	"$podman_bin" exec --interactive "$restore_postgres_name" psql -X --set=ON_ERROR_STOP=1 --username postgres --dbname postgres \
		>"$integration_root/discovery-restore-create.log" 2>&1 <<'SQL' || fail 'Isolated n8n database replacement failed.'
DROP DATABASE n8n;
CREATE DATABASE n8n OWNER n8n;
REVOKE CONNECT ON DATABASE n8n FROM PUBLIC;
GRANT CONNECT ON DATABASE n8n TO n8n;
SQL
	"$podman_bin" exec "$restore_postgres_name" pg_restore --username postgres --dbname n8n \
		--role n8n --exit-on-error --no-owner --no-privileges /tmp/discovery-n8n.dump >"$integration_root/discovery-restore.log" 2>&1 || fail 'Isolated n8n application restore failed.'
	[[ "$("$podman_bin" exec "$restore_postgres_name" psql -X --username postgres --dbname n8n -At \
		--command "SELECT EXISTS(SELECT FROM pg_namespace WHERE nspname='platform_discovery');")" == f ]] ||
		fail 'Derived n8n discovery schema was unexpectedly restored from its application dump.'
	discovery_restore_owned
	"$podman_bin" exec --interactive "$restore_postgres_name" psql -X --set=ON_ERROR_STOP=1 --username postgres --dbname n8n \
		<kubernetes/apps/automation/n8n-postgresql/app/scripts/credential-discovery.sql \
		>"$integration_root/discovery-restored-projection.log" 2>&1 || fail 'Reviewed n8n projection reconstruction failed.'
	local database reader candidate source query
	for source in platform nocodb n8n; do
		case "$source" in
		platform)
			database=automation_data_control
			reader=automation_data_inventory
			candidate="$platform_inventory_password"
			;;
		nocodb)
			database=nocodb
			reader=nocodb_inventory
			candidate="$nocodb_inventory_password"
			;;
		n8n)
			database=n8n
			reader=n8n_inventory
			candidate="$n8n_inventory_password"
			;;
		esac
		printf 'PGPASSWORD=%s\n' "$candidate" >"$integration_root/discovery-restored-reader.env"
		"$podman_bin" run --rm --name "$auth_probe_name" --label "homelab-talos.test-run=$run_marker" \
			--network "$network" --env-file "$integration_root/discovery-restored-reader.env" "$postgres_image" \
			psql -X --no-password --set=ON_ERROR_STOP=1 --host restore-postgresql --username "$reader" --dbname "$database" -At \
			--command 'SELECT platform_discovery.read_snapshot();' >"$integration_root/discovery-restored-$source.json" \
			2>"$integration_root/discovery-restored-reader.log" || fail 'Retained restricted reader did not authenticate after restore.'
		# Real base-table denial under the same authenticated restored identity.
		case "$source" in
		platform) query='SELECT * FROM platform_operations.managed_domains;' ;;
		nocodb) query='SELECT config FROM public.nc_integrations_v2;' ;;
		n8n) query='SELECT data FROM public.credentials_entity;' ;;
		esac
		if "$podman_bin" run --rm --name "$auth_probe_name" --label "homelab-talos.test-run=$run_marker" \
			--network "$network" --env-file "$integration_root/discovery-restored-reader.env" "$postgres_image" \
			psql -X --no-password --set=ON_ERROR_STOP=1 --host restore-postgresql --username "$reader" --dbname "$database" \
			--command "$query" >"$integration_root/discovery-restored-denial.log" 2>&1; then
			fail 'Restored metadata reader acquired base-table access.'
		fi
	done
	jq -s '{schemaVersion:1,sources:.}' "$integration_root/discovery-restored-platform.json" \
		"$integration_root/discovery-restored-nocodb.json" "$integration_root/discovery-restored-n8n.json" >"$integration_root/discovery-restored.json"
	assert_discovery complete "$integration_root/discovery-restored.json" 2
}
