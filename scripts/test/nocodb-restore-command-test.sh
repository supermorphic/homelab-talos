#!/usr/bin/env bash
# Pure command, selection, render, and ownership tests for the NocoDB restore drill.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

library='scripts/test/lib/nocodb-restore-command.sh'
scenario='scripts/test/scenarios/nocodb-restore-drill.sh'
[[ -f "$library" ]] || {
	echo "Missing NocoDB restore library: $library" >&2
	exit 1
}
# shellcheck source=scripts/test/lib/nocodb-restore-command.sh
source "$library"
# shellcheck source=scripts/test/lib/automation-data-restore-command.sh
source scripts/test/lib/automation-data-restore-command.sh
[[ -x "$scenario" ]] || {
	echo "Missing executable NocoDB restore scenario: $scenario" >&2
	exit 1
}

fixture="$(mktemp -d "${TMPDIR:-/tmp}/homelab-nocodb-restore-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

fail() {
	echo "NocoDB restore command test failed: $*" >&2
	exit 1
}

postgresql_render="$fixture/postgresql.yaml"
kustomize build kubernetes/apps/automation-data/postgresql/app >"$postgresql_render"
rendered_backup_configmap="$(yq ea -r '
  select(.kind == "CronJob" and .metadata.name == "automation-data-postgresql-backup") |
  [.spec.jobTemplate.spec.template.spec.volumes[] |
    select(.name == "backup-script") | .configMap.name] |
  select(length == 1) | .[0]
' "$postgresql_render")"
[[ "$rendered_backup_configmap" =~ ^automation-data-postgresql-backup-[a-z0-9]+$ ]] ||
	fail 'PostgreSQL render did not produce one hashed backup ConfigMap reference'
rendered_backup_source="$(CONFIGMAP_NAME="$rendered_backup_configmap" yq ea -o=json -I=0 '
  select(.kind == "ConfigMap" and .metadata.name == strenv(CONFIGMAP_NAME))
' "$postgresql_render")"
jq -e '.data | has("backup.sh") and has("update-backup-status.sql")' \
	<<<"$rendered_backup_source" >/dev/null || fail 'rendered backup ConfigMap is missing a required script key'

create_bundle() { # <timestamp> <complete|incomplete>
	local timestamp="$1" state="$2" bundle database_name encoded dump_path
	bundle="$fixture/bundles/automation-data-$timestamp"
	mkdir -p "$bundle/databases"
	printf 'CREATE ROLE postgres;\n' >"$bundle/globals.sql"
	printf 'registry\n' >"$bundle/registry.tsv"
	printf 'bundle_version\t1\ncaptured_at\tfixture\nplatform_generation\t1\ndatabase_set_hash\tfixture\nrecord_type\tdatabase_name_base64\tdump_path\n' >"$bundle/manifest.tsv"
	for database_name in nocodb automation_data_control issue334_acceptance; do
		encoded="$(printf '%s' "$database_name" | base64 | tr -d '\n')"
		dump_path="databases/db-$(printf '%s' "$encoded" | tr -d '=').dump"
		printf 'database\t%s\t%s\n' "$encoded" "$dump_path" >>"$bundle/manifest.tsv"
		printf 'fixture archive\n' >"$bundle/$dump_path"
	done
	(
		cd "$bundle"
		sha256sum globals.sql registry.tsv manifest.tsv databases/*.dump >SHA256SUMS
		sha256sum SHA256SUMS | awk '{print $1 "  SHA256SUMS"}' >COMPLETE
	)
	[[ "$state" == complete ]] || rm -f -- "$bundle/COMPLETE"
}

mkdir -p "$fixture/bundles"
create_bundle 20260904T003000Z complete
create_bundle 20260904T013000Z incomplete
create_bundle 20260904T023000Z complete
selected_bundle="$(nocodb_restore_select_complete_bundle "$fixture/bundles")" ||
	fail 'complete bundle selection failed'
[[ "$(basename "$selected_bundle")" == automation-data-20260904T023000Z ]] ||
	fail 'the newest complete bundle was not selected'

mkdir -p "$fixture/no-complete"
create_bundle 20260904T033000Z incomplete
mv "$fixture/bundles/automation-data-20260904T033000Z" "$fixture/no-complete/"
if nocodb_restore_select_complete_bundle "$fixture/no-complete" >/dev/null 2>&1; then
	fail 'a non-complete bundle was selected'
fi

source_registry="$fixture/source-registry.json"
jq -n '{items: [
  {domain:"issue334_acceptance",accessKind:"reader",state:"ready",baseId:"base-canary",sourceId:"source-reader",integrationId:"integration-reader",valid:true},
  {domain:"issue334_acceptance",accessKind:"operator",state:"ready",baseId:"base-canary",sourceId:"source-operator",integrationId:"integration-operator",valid:true}
]}' >"$source_registry"
nocodb_restore_validate_source_registry "$source_registry" ||
	fail 'the complete reader/operator source registry was rejected'
jq '.items[1].baseId = "different-base"' "$source_registry" >"$fixture/source-registry-mismatch.json"
if nocodb_restore_validate_source_registry "$fixture/source-registry-mismatch.json"; then
	fail 'mismatched reader/operator base identity was accepted'
fi
jq '.items[0].state = "error"' "$source_registry" >"$fixture/source-registry-error.json"
if nocodb_restore_validate_source_registry "$fixture/source-registry-error.json"; then
	fail 'a non-ready retained source was accepted'
fi

run_hash='0123456789ab'
prefix="nc-restore-$run_hash"
preflight_manifest="$fixture/preflight.yaml"
nocodb_restore_preflight_manifest "$prefix-preflight" "$run_hash" >"$preflight_manifest"
yq -e '
  .kind == "Job" and .spec.activeDeadlineSeconds == 300 and .spec.backoffLimit == 0 and
  .spec.template.spec.automountServiceAccountToken == false and
  .spec.template.spec.containers[0].image == "postgres:17.11-alpine3.24" and
  .spec.template.spec.containers[0].volumeMounts[0].readOnly == true and
  .spec.template.spec.volumes[0].persistentVolumeClaim.claimName == "automation-data-postgresql-backups" and
  .spec.template.spec.volumes[0].persistentVolumeClaim.readOnly == true and
  (.spec.template.spec.containers[0].env | length) == 1 and
  .spec.template.spec.containers[0].env[0].name == "BACKUP_DIR"
' "$preflight_manifest" >/dev/null || fail 'logical preflight has writable input or credential access'
mkdir -p "$fixture/bin" "$fixture/preflight-run"
printf '#!/bin/sh\nexit 0\n' >"$fixture/bin/pg_restore"
printf '#!/bin/sh\necho unexpected-database-connection >&2\nexit 1\n' >"$fixture/bin/psql"
chmod +x "$fixture/bin/pg_restore" "$fixture/bin/psql"
preflight_command="$(yq -r '.spec.template.spec.containers[0].args[0]' "$preflight_manifest")"
preflight_command="${preflight_command//\/tmp\/restore/$fixture\/preflight-run\/restore}"
preflight_output="$(PATH="$fixture/bin:$PATH" BACKUP_DIR="$fixture/bundles" sh -ceu "$preflight_command")" ||
	fail 'read-only preflight rejected the complete required database set'
[[ "$preflight_output" == selected_bundle=automation-data-20260904T023000Z ]] || fail 'preflight output was not bounded to selected bundle'
if PATH="$fixture/bin:$PATH" BACKUP_DIR="$fixture/no-complete" sh -ceu "$preflight_command" >/dev/null 2>&1; then
	fail 'logical preflight accepted an incomplete bundle'
fi
mkdir -p "$fixture/corrupt-only" "$fixture/missing-required"
cp -R "$selected_bundle" "$fixture/corrupt-only/"
printf 'changed\n' >>"$fixture/corrupt-only/$(basename "$selected_bundle")/globals.sql"
if PATH="$fixture/bin:$PATH" BACKUP_DIR="$fixture/corrupt-only" sh -ceu "$preflight_command" >/dev/null 2>&1; then
	fail 'logical preflight accepted a checksum mismatch'
fi
cp -R "$selected_bundle" "$fixture/missing-required/"
missing_required="$fixture/missing-required/$(basename "$selected_bundle")"
awk -F '\t' '$2 != "bm9jb2Ri"' "$missing_required/manifest.tsv" >"$fixture/without-nocodb.tsv"
mv "$fixture/without-nocodb.tsv" "$missing_required/manifest.tsv"
rm -f -- "$missing_required/databases/db-bm9jb2Ri.dump"
(
	cd "$missing_required"
	sha256sum globals.sql registry.tsv manifest.tsv databases/*.dump >SHA256SUMS
	sha256sum SHA256SUMS >COMPLETE
)
if PATH="$fixture/bin:$PATH" BACKUP_DIR="$fixture/missing-required" sh -ceu "$preflight_command" >/dev/null 2>&1; then
	fail 'logical preflight accepted a complete bundle without NocoDB metadata'
fi
app_manifest="$fixture/app.yaml"
policy_manifest="$fixture/policy.yaml"

isolated_ip='192.0.2.45'
nocodb_restore_application_manifests "$prefix-nocodb" "$prefix-nocodb" \
	"$isolated_ip" "$run_hash" >"$app_manifest"
yq ea -e '
  select(.kind == "Deployment") |
  .spec.replicas == 1 and .spec.strategy.type == "Recreate" and
  (.spec.template.spec.hostAliases | length) == 1 and
  .spec.template.spec.hostAliases[0].ip == "192.0.2.45" and
  (.spec.template.spec.hostAliases[0].hostnames | length) == 2 and
  .spec.template.spec.hostAliases[0].hostnames[0] == "automation-data-postgresql" and
  .spec.template.spec.hostAliases[0].hostnames[1] == "automation-data-postgresql.automation-data.svc.cluster.local" and
  (.spec.template.spec.containers | length) == 1 and
  .spec.template.spec.containers[0].image == "docker.io/nocodb/nocodb@sha256:4b760f0d25471fb49707d515f161d9d36b49c88e7ecbe25eded774af385be5a9" and
  ([.spec.template.spec.volumes[] | select(has("persistentVolumeClaim"))] | length) == 0 and
  ([.spec.template.spec.volumes[] | select(.name == "data" and has("emptyDir"))] | length) == 1 and
  ([.spec.template.spec.containers[0].volumeMounts[] | select(.name == "data" and .mountPath == "/usr/app/data")] | length) == 1 and
  ([.spec.template.spec.containers[0].env[] | select(.name == "NC_SECURE_ATTACHMENTS")] | length) == 0
' "$app_manifest" >/dev/null || fail 'restored NocoDB application render is unsafe'

nocodb_restore_policy_manifest "$prefix-policy" "$prefix-db" "$prefix-nocodb" \
	"$prefix-request" "$run_hash" >"$policy_manifest"
nocodb_restore_validate_isolation "$app_manifest" "$policy_manifest" \
	"$isolated_ip" "$run_hash" || fail 'valid host redirection and exact policy were rejected'

yq 'select(.kind == "Deployment") |
  .spec.template.spec.volumes[0] = {"name":"data","persistentVolumeClaim":{"claimName":"nocodb-data"}}' \
  "$app_manifest" >"$fixture/app-claim.yaml"
if nocodb_restore_validate_isolation "$fixture/app-claim.yaml" "$policy_manifest" \
	"$isolated_ip" "$run_hash" >/dev/null 2>&1; then
	fail 'isolated recovery accepted a NocoDB claim mount'
fi
yq 'select(.kind == "Deployment") |
  .spec.template.spec.containers[0].env += [{"name":"NC_SECURE_ATTACHMENTS","value":"false"}]' \
  "$app_manifest" >"$fixture/app-attachment-env.yaml"
if nocodb_restore_validate_isolation "$fixture/app-attachment-env.yaml" "$policy_manifest" \
	"$isolated_ip" "$run_hash" >/dev/null 2>&1; then
	fail 'isolated recovery accepted a native-attachment override'
fi
yq 'select(.kind == "Deployment") |
  (.spec.template.spec.containers[0].env[] | select(.name == "NC_CONNECTION_ENCRYPT_KEY") |
    .valueFrom.secretKeyRef.key) = "replacement-key"' \
  "$app_manifest" >"$fixture/app-wrong-key-reference.yaml"
if nocodb_restore_validate_isolation "$fixture/app-wrong-key-reference.yaml" "$policy_manifest" \
	"$isolated_ip" "$run_hash" >/dev/null 2>&1; then
	fail 'isolated recovery accepted a different connection-key reference'
fi

yq '.specs[2].egress[1].toEndpoints[0].matchLabels."homelab-talos/run-id" = "another-run"' \
	"$policy_manifest" >"$fixture/policy-wrong-database.yaml"
if nocodb_restore_validate_isolation "$app_manifest" "$fixture/policy-wrong-database.yaml" \
	"$isolated_ip" "$run_hash" >/dev/null 2>&1; then
	fail 'policy accepted a database endpoint from another run'
fi

yq 'select(.kind == "Deployment") | .spec.template.spec.hostAliases[0].hostnames = ["automation-data-postgresql"]' \
	"$app_manifest" >"$fixture/app-missing-fqdn.yaml"
if nocodb_restore_validate_isolation "$fixture/app-missing-fqdn.yaml" "$policy_manifest" \
	"$isolated_ip" "$run_hash" >/dev/null 2>&1; then
	fail 'missing fully qualified source host redirection was accepted'
fi
yq 'select(.kind == "Deployment") | .spec.template.spec.hostAliases[0].ip = "192.0.2.99"' \
	"$app_manifest" >"$fixture/app-wrong-ip.yaml"
if nocodb_restore_validate_isolation "$fixture/app-wrong-ip.yaml" "$policy_manifest" \
	"$isolated_ip" "$run_hash" >/dev/null 2>&1; then
	fail 'source host redirection to a different Service IP was accepted'
fi

owned_resource="$fixture/owned.json"
jq -n --arg run_hash "$run_hash" '{metadata:{labels:{
  "homelab-talos/test":"nocodb-restore-drill","homelab-talos/run-id":$run_hash
}}}' >"$owned_resource"
nocodb_restore_resource_is_owned "$run_hash" "$owned_resource" ||
	fail 'a run-owned cleanup target was rejected'
jq '.metadata.labels."homelab-talos/run-id" = "different-run"' "$owned_resource" \
	>"$fixture/foreign-run.json"
if nocodb_restore_resource_is_owned "$run_hash" "$fixture/foreign-run.json"; then
	fail 'cleanup accepted a resource owned by another run'
fi
jq 'del(.metadata.labels."homelab-talos/test")' "$owned_resource" \
	>"$fixture/unlabeled.json"
if nocodb_restore_resource_is_owned "$run_hash" "$fixture/unlabeled.json"; then
	fail 'cleanup accepted a resource without the test label'
fi

dry_run="$(mise exec -- just --dry-run kube nocodb-restore-drill 2>&1)"
rg -Fq 'run-catalog-suite.sh test.nocodb-restore-drill -- scripts/test/scenarios/nocodb-restore-drill.sh' \
	<<<"$dry_run" || fail 'Just does not dispatch the restore drill through the catalog coordinator'

# shellcheck source=scripts/test/lib/catalog.sh
source scripts/test/lib/catalog.sh
entry_json="$(catalog_entry_by_id tests/catalog.yaml test.nocodb-restore-drill)"
jq -e '
  .metadata.id == "test.nocodb-restore-drill" and
  .metadata.source == "test" and .metadata.framework == "bash" and
  .metadata.suite == "platform" and .metadata.tier == "integration" and
  .metadata.target == "nocodb" and .metadata.scenario == "metadata-record-restore" and
  .metadata.scope == "system" and .metadata.intent == "resilience" and
  .metadata.mutates_cluster == true and .metadata.execution_owner == "human" and
  .confirmation.type == "exact" and
  .confirmation.variable == "NOCODB_RESTORE_CONFIRM" and
  .confirmation.expected == "restore:nocodb:metadata" and
  .runner.command == "NOCODB_RESTORE_CONFIRM=restore:nocodb:metadata mise exec -- just kube nocodb-restore-drill" and
  .runner.implementation == "scripts/test/scenarios/nocodb-restore-drill.sh" and
  .native_results.strategy == "wrapper-junit" and
  .dispatch.mode == "direct" and .dispatch.runtime == "bash" and
  .dispatch.path == "scripts/test/scenarios/nocodb-restore-drill.sh" and
  .dispatch.args == [".kube/config"] and .dispatch.selector == null
' <<<"$entry_json" >/dev/null || fail 'catalog metadata does not preserve the attended resilience contract'

echo 'NocoDB restore command tests passed.'
