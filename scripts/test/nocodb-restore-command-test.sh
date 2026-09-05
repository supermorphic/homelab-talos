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

backups="$fixture/backups.json"
jq -n '{items: [
  {metadata:{name:"backup-before"},spec:{backupTargetName:"default"},status:{state:"Completed",volumeName:"pvc-nocodb-volume",backupCreatedAt:"2026-09-04T02:20:00Z",url:"s3://off-cluster/backup-before",volumeSize:"10737418240"}},
  {metadata:{name:"backup-closest"},spec:{backupTargetName:"default"},status:{state:"Completed",volumeName:"pvc-nocodb-volume",backupCreatedAt:"2026-09-04T02:31:00Z",url:"s3://off-cluster/backup-closest",volumeSize:"10737418240"}},
  {metadata:{name:"backup-failed"},spec:{backupTargetName:"default"},status:{state:"Error",volumeName:"pvc-nocodb-volume",backupCreatedAt:"2026-09-04T02:30:00Z",url:"s3://off-cluster/backup-failed",volumeSize:"10737418240"}},
  {metadata:{name:"backup-wrong-volume"},spec:{backupTargetName:"default"},status:{state:"Completed",volumeName:"different-volume",backupCreatedAt:"2026-09-04T02:30:00Z",url:"s3://off-cluster/backup-wrong-volume",volumeSize:"10737418240"}}
]}' >"$backups"
selected_backup="$(nocodb_restore_select_attachment_backup \
	automation-data-20260904T023000Z pvc-nocodb-volume default "$backups")" ||
	fail 'closest completed attachment backup selection failed'
[[ "$(jq -cS . <<<"$selected_backup")" == '{"name":"backup-closest","url":"s3://off-cluster/backup-closest","volumeSize":"10737418240"}' ]] ||
	fail 'the closest completed backup for the bound volume was not selected'
selected_backup_url="$(jq -r '.url' <<<"$selected_backup")"
selected_backup_size="$(jq -r '.volumeSize' <<<"$selected_backup")"

jq -n '{items:[]}' >"$fixture/backups-empty.json"
if nocodb_restore_select_attachment_backup automation-data-20260904T023000Z \
	pvc-nocodb-volume default "$fixture/backups-empty.json" >/dev/null 2>&1; then
	fail 'a missing Longhorn backup was accepted'
fi
jq '.items |= map(select(.status.volumeName != "pvc-nocodb-volume"))' \
	"$backups" >"$fixture/backups-mismatch.json"
if nocodb_restore_select_attachment_backup automation-data-20260904T023000Z \
	pvc-nocodb-volume default "$fixture/backups-mismatch.json" >/dev/null 2>&1; then
	fail 'a backup for a different Longhorn volume was selected'
fi
jq '.items |= map(select(.status.state != "Completed"))' \
	"$backups" >"$fixture/backups-incomplete.json"
if nocodb_restore_select_attachment_backup automation-data-20260904T023000Z \
	pvc-nocodb-volume default "$fixture/backups-incomplete.json" >/dev/null 2>&1; then
	fail 'a non-completed Longhorn backup was selected'
fi

if nocodb_restore_require_inputs "$selected_bundle" '' '' >/dev/null 2>&1; then
	fail 'a metadata-only restore was accepted'
fi
if nocodb_restore_require_inputs '' "$selected_backup_url" "$selected_backup_size" >/dev/null 2>&1; then
	fail 'an attachment-only restore was accepted'
fi
if nocodb_restore_require_inputs "$selected_bundle" "$selected_backup_url" '' >/dev/null 2>&1; then
	fail 'an attachment restore without the exact backup size was accepted'
fi
nocodb_restore_require_inputs "$selected_bundle" "$selected_backup_url" "$selected_backup_size" ||
	fail 'the complete metadata and attachment recovery unit was rejected'

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
volume_manifest="$fixture/volume.yaml"
binding_manifest="$fixture/binding.yaml"
app_manifest="$fixture/app.yaml"
policy_manifest="$fixture/policy.yaml"

nocodb_restore_longhorn_volume_manifest "$prefix-attachments" "$selected_backup_url" \
	"$selected_backup_size" "$run_hash" >"$volume_manifest"
yq -e '
  .kind == "Volume" and .apiVersion == "longhorn.io/v1beta2" and
  .metadata.namespace == "longhorn-system" and
  .metadata.name == "nc-restore-0123456789ab-attachments" and
  .metadata.labels."homelab-talos/test" == "nocodb-restore-drill" and
  .metadata.labels."homelab-talos/run-id" == "0123456789ab" and
  .spec.fromBackup == "s3://off-cluster/backup-closest" and
  .spec.size == "10737418240" and
  .spec.numberOfReplicas == 2
' "$volume_manifest" >/dev/null || fail 'Longhorn restore Volume render is unsafe'

nocodb_restore_static_binding_manifests "$prefix-attachments-pv" \
	"$prefix-attachments" "$prefix-attachments" "$run_hash" >"$binding_manifest"
yq ea -e '
  select(.kind == "PersistentVolume") |
  .metadata.name == "nc-restore-0123456789ab-attachments-pv" and
  .spec.capacity.storage == "10Gi" and
  (.spec.accessModes | join(",")) == "ReadWriteOnce" and
  .spec.csi.driver == "driver.longhorn.io" and
  .spec.csi.volumeHandle == "nc-restore-0123456789ab-attachments" and
  .spec.claimRef.namespace == "automation-data" and
  .spec.claimRef.name == "nc-restore-0123456789ab-attachments"
' "$binding_manifest" >/dev/null || fail 'static attachment PV render is unsafe'
yq ea -e '
  select(.kind == "PersistentVolumeClaim") |
  .metadata.namespace == "automation-data" and
  .metadata.name == "nc-restore-0123456789ab-attachments" and
  .spec.volumeName == "nc-restore-0123456789ab-attachments-pv" and
  .spec.resources.requests.storage == "10Gi" and
  (.spec.accessModes | join(",")) == "ReadWriteOnce"
' "$binding_manifest" >/dev/null || fail 'static attachment PVC render is unsafe'

isolated_ip='192.0.2.45'
nocodb_restore_application_manifests "$prefix-nocodb" "$prefix-nocodb" \
	"$prefix-attachments" "$isolated_ip" "$run_hash" >"$app_manifest"
yq ea -e '
  select(.kind == "Deployment") |
  .spec.replicas == 1 and .spec.strategy.type == "Recreate" and
  (.spec.template.spec.hostAliases | length) == 1 and
  .spec.template.spec.hostAliases[0].ip == "192.0.2.45" and
  (.spec.template.spec.hostAliases[0].hostnames | length) == 2 and
  .spec.template.spec.hostAliases[0].hostnames[0] == "automation-data-postgresql" and
  .spec.template.spec.hostAliases[0].hostnames[1] == "automation-data-postgresql.automation-data.svc.cluster.local" and
  (.spec.template.spec.containers | length) == 1 and
  .spec.template.spec.containers[0].image == "docker.io/nocodb/nocodb@sha256:4b760f0d25471fb49707d515f161d9d36b49c88e7ecbe25eded774af385be5a9"
' "$app_manifest" >/dev/null || fail 'restored NocoDB application render is unsafe'

# The pinned producer and restore consumer use the canonical /download/* contract.
# Require one literal string value; a duplicate, boolean, or absent setting is unsafe.
yq ea -o=json 'select(.kind == "Deployment")' "$app_manifest" | jq -e '
  [.spec.template.spec.containers[0].env[] | select(.name == "NC_SECURE_ATTACHMENTS")] |
  length == 1 and .[0].value == "false" and (.[0] | has("valueFrom") | not)
' >/dev/null || fail 'restored NocoDB must set NC_SECURE_ATTACHMENTS exactly once to string false'

nocodb_restore_policy_manifest "$prefix-policy" "$prefix-db" "$prefix-nocodb" \
	"$prefix-request" "$run_hash" >"$policy_manifest"
nocodb_restore_validate_isolation "$app_manifest" "$policy_manifest" \
	"$isolated_ip" "$run_hash" || fail 'valid host redirection and exact policy were rejected'

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

pre_bind_volume="$fixture/pre-bind-volume.json"
jq -n --arg name "$prefix-attachments" --arg url "$selected_backup_url" \
	--arg size "$selected_backup_size" '{
  metadata:{name:$name},spec:{numberOfReplicas:2,fromBackup:$url,size:$size},
  status:{state:"detached",robustness:"unknown",restoreRequired:false,replicaModeMap:{}}
}' >"$pre_bind_volume"
nocodb_restore_validate_volume_pre_bind "$prefix-attachments" "$selected_backup_url" \
	"$selected_backup_size" "$pre_bind_volume" ||
	fail 'a completed detached Longhorn 1.12 restore was rejected before binding'
for mutation in attached restore-required wrong-backup wrong-size nonempty-replicas; do
	case "$mutation" in
	attached) expression='.status.state = "attached" | .status.robustness = "healthy" | .status.replicaModeMap = {"replica-a":"RW","replica-b":"RW"}' ;;
	restore-required) expression='.status.restoreRequired = true' ;;
	wrong-backup) expression='.spec.fromBackup = "s3://off-cluster/different-backup"' ;;
	wrong-size) expression='.spec.size = "5368709120"' ;;
	nonempty-replicas) expression='.status.replicaModeMap = {"replica-a":"RW"}' ;;
	esac
	jq "$expression" "$pre_bind_volume" >"$fixture/pre-bind-$mutation.json"
	if nocodb_restore_validate_volume_pre_bind "$prefix-attachments" "$selected_backup_url" \
		"$selected_backup_size" "$fixture/pre-bind-$mutation.json"; then
		fail "the pre-bind gate accepted $mutation state"
	fi
done

attached_volume="$fixture/attached-volume.json"
jq '.status.state = "attached" | .status.robustness = "healthy" |
  .status.replicaModeMap = {"replica-a":"RW","replica-b":"RW"}' \
	"$pre_bind_volume" >"$attached_volume"
nocodb_restore_validate_volume_attached "$prefix-attachments" "$selected_backup_url" \
	"$selected_backup_size" "$attached_volume" ||
	fail 'a mounted healthy two-replica restored volume was rejected'
for mutation in detached failed-rebuild wrong-backup wrong-size; do
	case "$mutation" in
	detached) expression='.status.state = "detached" | .status.robustness = "unknown" | .status.replicaModeMap = {}' ;;
	failed-rebuild) expression='.status.replicaModeMap["replica-b"] = "ERR"' ;;
	wrong-backup) expression='.spec.fromBackup = "s3://off-cluster/different-backup"' ;;
	wrong-size) expression='.spec.size = "5368709120"' ;;
	esac
	jq "$expression" "$attached_volume" >"$fixture/attached-$mutation.json"
	if nocodb_restore_validate_volume_attached "$prefix-attachments" "$selected_backup_url" \
		"$selected_backup_size" "$fixture/attached-$mutation.json"; then
		fail "the post-mount gate accepted $mutation state"
	fi
done

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
  .metadata.target == "nocodb" and .metadata.scenario == "metadata-attachment-restore" and
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
