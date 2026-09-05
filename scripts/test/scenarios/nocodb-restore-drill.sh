#!/usr/bin/env bash
# Attended, catalog-coordinated NocoDB metadata and attachment restore drill.
set -euo pipefail
set +x

# shellcheck source=scripts/lib/common.sh
source scripts/lib/common.sh
# shellcheck source=scripts/lib/lease.sh
source scripts/lib/lease.sh
# shellcheck source=scripts/test/lib/job.sh
source scripts/test/lib/job.sh
# shellcheck source=scripts/test/lib/automation-data-restore-command.sh
source scripts/test/lib/automation-data-restore-command.sh
# shellcheck source=scripts/test/lib/nocodb-restore-command.sh
source scripts/test/lib/nocodb-restore-command.sh
require_bash

[[ "$#" -eq 1 ]] || {
	echo 'Usage: nocodb-restore-drill.sh <kubeconfig>' >&2
	exit 2
}

# Refuse before kubeconfig inspection or any Kubernetes request.
expected_confirmation='restore:nocodb:metadata'
[[ "${NOCODB_RESTORE_CONFIRM:-}" == "$expected_confirmation" ]] || {
	echo "Refusing NocoDB restore drill: set NOCODB_RESTORE_CONFIRM=$expected_confirmation after reviewing its isolated storage and cleanup scope." >&2
	exit 1
}

kubeconfig="$1"
run_dir="${HOMELAB_TEST_RUN_DIR:-}"
[[ -f "$kubeconfig" ]] || {
	echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
	exit 1
}
[[ -n "$run_dir" && -d "$run_dir" ]] || {
	echo 'Refusing NocoDB restore drill outside the catalog run coordinator.' >&2
	exit 1
}

run_id="$(basename "$run_dir")"
[[ "$run_id" =~ ^[A-Za-z0-9_.:-]+$ ]] || {
	echo 'The catalog coordinator supplied an unsafe run ID.' >&2
	exit 1
}
run_hash="$(printf '%s' "$run_id" | shasum -a 256 | cut -c1-12)"
lease_holder="${TEST_CAMPAIGN_LEASE_HOLDER:-$run_id}"
prefix="nc-restore-$run_hash"
namespace='automation-data'
longhorn_namespace='longhorn-system'
database="$prefix-db"
database_service="$prefix-db"
database_pvc="$prefix-db-data"
restore_job="$prefix-load"
preflight_job="$prefix-preflight"
attachment_volume="$prefix-attachments"
attachment_pv="$prefix-attachments-pv"
attachment_pvc="$prefix-attachments"
app="$prefix-nocodb"
app_service="$prefix-nocodb"
request_job="$prefix-request"
policy="$prefix-policy"
backup_configmap=''
kc=(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace")
kl=(kubectl --kubeconfig "$kubeconfig" --namespace "$longhorn_namespace")
kcluster=(kubectl --kubeconfig "$kubeconfig")

umask 077
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-nocodb-restore.XXXXXX")"
chmod 700 "$temp_dir"

write_phase() {
	local phase="$1" status="$2" reason="$3"
	PHASE_STATUS="$status" PHASE_REASON="$reason" \
		yq --null-input --output-format json '{
      "status": strenv(PHASE_STATUS),
      "reason": strenv(PHASE_REASON)
    }' >"$run_dir/$phase.json"
}

write_phase assertion not-classified 'isolated metadata and attachment assertions have not completed'
write_phase cleanup not-classified 'run-owned restore resources have not been removed'
write_phase recovery not-required 'production NocoDB, PostgreSQL, and claims are not modified'

verify_lease() {
	verify_test_lease_holder "$kubeconfig" "$lease_holder" || {
		echo 'The shared state-changing test Lease is absent, expired, or owned by another run.' >&2
		return 1
	}
}

# A multi-document create would hide several API mutations behind one Lease check.
create_owned_manifests() { # <namespace-or-dash> <manifest>
	local target_namespace="$1" manifest="$2" object
	yq ea -o=json -I=0 '.' "$manifest" >"$temp_dir/create-objects.jsonl"
	while IFS= read -r object; do
		printf '%s\n' "$object" >"$temp_dir/create-object.json"
		nocodb_restore_resource_is_owned "$run_hash" "$temp_dir/create-object.json" || return 1
		verify_lease || return 1
		if [[ "$target_namespace" == - ]]; then
			"${kcluster[@]}" create --filename "$temp_dir/create-object.json" >/dev/null || return 1
		else
			kubectl --kubeconfig "$kubeconfig" --namespace "$target_namespace" \
				create --filename "$temp_dir/create-object.json" >/dev/null || return 1
		fi
	done <"$temp_dir/create-objects.jsonl"
}

resource_json() { # <namespace-or-dash> <target> <output>
	local target_namespace="$1" target="$2" output="$3"
	if [[ "$target_namespace" == - ]]; then
		"${kcluster[@]}" get "$target" --ignore-not-found --output json >"$output"
	else
		kubectl --kubeconfig "$kubeconfig" --namespace "$target_namespace" \
			get "$target" --ignore-not-found --output json >"$output"
	fi
}

resource_absent() { # <namespace-or-dash> <target>
	local target_namespace="$1" target="$2" output
	output="$(mktemp "$temp_dir/absent.XXXXXX")"
	resource_json "$target_namespace" "$target" "$output" || return 1
	[[ ! -s "$output" || "$(jq -r '.kind // ""' "$output")" == '' ]]
}

delete_owned() { # <namespace-or-dash> <target>
	local target_namespace="$1" target="$2" object
	object="$temp_dir/delete-${target//\//-}.json"
	resource_json "$target_namespace" "$target" "$object" || return 1
	[[ -s "$object" && "$(jq -r '.kind // ""' "$object")" != '' ]] || return 0
	nocodb_restore_resource_is_owned "$run_hash" "$object" || {
		echo "Refusing cleanup of $target_namespace/$target because both run ownership labels do not match." >&2
		return 1
	}
	verify_lease || return 1
	if [[ "$target_namespace" == - ]]; then
		"${kcluster[@]}" delete "$target" --wait=true --timeout=5m >/dev/null
	else
		kubectl --kubeconfig "$kubeconfig" --namespace "$target_namespace" \
			delete "$target" --wait=true --timeout=5m >/dev/null
	fi
}

route_targets_service() {
	local service_name="$1" routes="$2"
	SERVICE_NAME="$service_name" NAMESPACE="$namespace" jq -e '
    any(.items[]?; . as $route |
      any(.spec.rules[]?.backendRefs[]?;
        (.kind // "Service") == "Service" and
        (.group // "") == "" and
        (.namespace // $route.metadata.namespace) == env.NAMESPACE and
        .name == env.SERVICE_NAME
      )
    )
  ' "$routes" >/dev/null
}

resolve_rendered_backup_configmap() { # <rendered-package-json>
	jq -er '
    [.[] | select(.kind == "CronJob" and
      .metadata.name == "automation-data-postgresql-backup")] as $jobs |
    (if ($jobs | length) != 1 then
      error("expected one rendered backup CronJob")
    else $jobs[0] end) as $job |
    [$job.spec.jobTemplate.spec.template.spec.volumes[]? |
      select(.name == "backup-script") | .configMap.name |
      select(type == "string" and
        test("^automation-data-postgresql-backup-[a-z0-9]+$"))] as $references |
    (if ($references | length) != 1 then
      error("expected one rendered backup-script volume reference")
    else $references[0] end) as $name |
    [.[] | select(.kind == "ConfigMap" and .metadata.name == $name and
      (.data | type == "object") and
      (.data | has("backup.sh") and has("update-backup-status.sql")))] as $sources |
    if ($sources | length) == 1 then $name
    else error("expected one rendered backup ConfigMap with both script keys") end
  ' "$1"
}

resolve_deployed_backup_configmap() { # <deployed-cronjob-json>
	jq -er '
    select(.kind == "CronJob" and
      .metadata.name == "automation-data-postgresql-backup") |
    [.spec.jobTemplate.spec.template.spec.volumes[]? |
      select(.name == "backup-script") | .configMap.name |
      select(type == "string" and
        test("^automation-data-postgresql-backup-[a-z0-9]+$"))] |
    if length == 1 then .[0]
    else error("expected one deployed backup-script volume reference") end
  ' "$1"
}

database_manifests() {
	# shellcheck disable=SC2016 # yq evaluates its own variables.
	DATABASE="$database" DATABASE_SERVICE="$database_service" DATABASE_PVC="$database_pvc" \
		RUN_HASH="$run_hash" yq --null-input --output-format yaml '
      {"homelab-talos/test":"nocodb-restore-drill","homelab-talos/run-id":strenv(RUN_HASH)} as $run |
      [
        {
          "apiVersion":"v1","kind":"PersistentVolumeClaim",
          "metadata":{"name":strenv(DATABASE_PVC),"namespace":"automation-data","labels":($run * {"homelab-talos/role":"database-data"})},
          "spec":{"accessModes":["ReadWriteOnce"],"storageClassName":"longhorn","resources":{"requests":{"storage":"20Gi"}}}
        },
        {
          "apiVersion":"v1","kind":"Service",
          "metadata":{"name":strenv(DATABASE_SERVICE),"namespace":"automation-data","labels":($run * {"homelab-talos/role":"database"})},
          "spec":{"type":"ClusterIP","selector":($run * {"homelab-talos/role":"database"}),"ports":[{"name":"postgresql","port":5432,"targetPort":"postgresql"}]}
        },
        {
          "apiVersion":"apps/v1","kind":"StatefulSet",
          "metadata":{"name":strenv(DATABASE),"namespace":"automation-data","labels":($run * {"homelab-talos/role":"database"})},
          "spec":{
            "replicas":1,"serviceName":strenv(DATABASE_SERVICE),
            "selector":{"matchLabels":($run * {"homelab-talos/role":"database"})},
            "template":{"metadata":{"labels":($run * {"homelab-talos/role":"database"})},"spec":{
              "automountServiceAccountToken":false,
              "securityContext":{"fsGroup":70,"fsGroupChangePolicy":"OnRootMismatch","seccompProfile":{"type":"RuntimeDefault"}},
              "containers":[{
                "name":"postgresql","image":"postgres:17.11-alpine3.24","imagePullPolicy":"IfNotPresent",
                "env":[
                  {"name":"PGDATA","value":"/var/lib/postgresql/data/pgdata"},
                  {"name":"POSTGRES_DB","value":"postgres"},
                  {"name":"POSTGRES_PASSWORD","valueFrom":{"secretKeyRef":{"name":"postgresql-credentials","key":"postgres-superuser-password"}}}
                ],
                "ports":[{"name":"postgresql","containerPort":5432}],
                "readinessProbe":{"exec":{"command":["pg_isready","--username=postgres","--dbname=postgres"]},"periodSeconds":5,"failureThreshold":120},
                "resources":{"requests":{"cpu":"50m","memory":"128Mi"},"limits":{"memory":"1Gi"}},
                "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true,"runAsNonRoot":true,"runAsUser":70,"runAsGroup":70},
                "volumeMounts":[
                  {"name":"data","mountPath":"/var/lib/postgresql/data"},
                  {"name":"run","mountPath":"/var/run/postgresql"},
                  {"name":"tmp","mountPath":"/tmp"}
                ]
              }],
              "volumes":[
                {"name":"data","persistentVolumeClaim":{"claimName":strenv(DATABASE_PVC)}},
                {"name":"run","emptyDir":{}},{"name":"tmp","emptyDir":{}}
              ]
            }}
          }
        }
      ] | .[] | split_doc
    '
}

restore_job_manifest() {
	local command
	command="$(automation_data_restore_job_command)"
	command+="$(
		cat <<'EOF'

printf '%s\n' 'restore_stage=nocodb-source-registry'
source_registry="$(psql --dbname=automation_data_control --tuples-only --no-align --command="
SELECT jsonb_build_object(
  'items', COALESCE(jsonb_agg(jsonb_build_object(
    'domain', source.domain,
    'accessKind', source.access_kind,
    'state', source.state,
    'baseId', source.base_id,
    'sourceId', source.source_id,
    'integrationId', source.integration_id,
    'valid', (platform_operations.validate_nocodb_access(source.domain, source.access_kind)->>'valid')::boolean
  ) ORDER BY source.access_kind), '[]'::jsonb)
)
FROM platform_operations.managed_nocodb_sources AS source
WHERE source.domain = 'issue334_acceptance';
")" || restore_fail nocodb-source-registry-query
# Validate decoded JSON in the caller; the pinned PostgreSQL image has no jq.
test -n "$source_registry" || restore_fail nocodb-source-registry-shape
printf 'source_registry_base64=%s\n' "$(printf '%s' "$source_registry" | base64 | tr -d '\n')"
EOF
	)"
	JOB_NAME="$restore_job" JOB_COMMAND="$command" DATABASE_SERVICE="$database_service" \
		RUN_HASH="$run_hash" SELECTED_BUNDLE="$selected_bundle" \
		BACKUP_CONFIGMAP="$backup_configmap" yq --null-input --output-format yaml '
      {
        "apiVersion":"batch/v1","kind":"Job",
        "metadata":{"name":strenv(JOB_NAME),"namespace":"automation-data","labels":{
          "homelab-talos/test":"nocodb-restore-drill","homelab-talos/run-id":strenv(RUN_HASH),"homelab-talos/role":"restore"
        }},
        "spec":{"activeDeadlineSeconds":1800,"backoffLimit":0,"template":{
          "metadata":{"labels":{"homelab-talos/test":"nocodb-restore-drill","homelab-talos/run-id":strenv(RUN_HASH),"homelab-talos/role":"restore"}},
          "spec":{"automountServiceAccountToken":false,"restartPolicy":"Never",
            "securityContext":{"fsGroup":70,"fsGroupChangePolicy":"OnRootMismatch","runAsNonRoot":true,"runAsUser":70,"runAsGroup":70,"seccompProfile":{"type":"RuntimeDefault"}},
            "containers":[{
              "name":"restore","image":"postgres:17.11-alpine3.24","imagePullPolicy":"IfNotPresent",
              "command":["/bin/sh","-ceu"],"args":[strenv(JOB_COMMAND)],
              "env":[
                {"name":"PGHOST","value":strenv(DATABASE_SERVICE)},{"name":"PGPORT","value":"5432"},{"name":"PGUSER","value":"postgres"},
                {"name":"PGPASSWORD","valueFrom":{"secretKeyRef":{"name":"postgresql-credentials","key":"postgres-superuser-password"}}},
                {"name":"BACKUP_DIR","value":"/backups"},{"name":"POST_RECOVERY_BACKUP_DIR","value":"/post-recovery"},
                {"name":"AUTOMATION_DATA_BACKUP_PASSWORD","valueFrom":{"secretKeyRef":{"name":"postgresql-credentials","key":"backup-password"}}}
              ],
              "resources":{"requests":{"cpu":"50m","memory":"64Mi"},"limits":{"memory":"512Mi"}},
              "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true},
              "volumeMounts":[
                {"name":"backups","mountPath":("/backups/" + strenv(SELECTED_BUNDLE)),"subPath":strenv(SELECTED_BUNDLE),"readOnly":true},
                {"name":"post-recovery","mountPath":"/post-recovery"},
                {"name":"scripts","mountPath":"/scripts/backup.sh","subPath":"backup.sh","readOnly":true},
                {"name":"scripts","mountPath":"/scripts/update-backup-status.sql","subPath":"update-backup-status.sql","readOnly":true},
                {"name":"tmp","mountPath":"/tmp"}
              ]
            }],
            "volumes":[
              {"name":"backups","persistentVolumeClaim":{"claimName":"automation-data-postgresql-backups","readOnly":true}},
              {"name":"post-recovery","emptyDir":{}},
              {"name":"scripts","configMap":{"name":strenv(BACKUP_CONFIGMAP),"defaultMode":365}},
              {"name":"tmp","emptyDir":{}}
            ]
          }
        }}
      }
    '
}

request_job_manifest() {
	local request_script
	request_script="$(nocodb_restore_request_script)"
	JOB_NAME="$request_job" APP_SERVICE="$app_service" REQUEST_SCRIPT="$request_script" \
		RUN_HASH="$run_hash" SOURCE_REGISTRY="$(jq -c . "$temp_dir/source-registry.json")" yq --null-input --output-format yaml '
      {
        "apiVersion":"batch/v1","kind":"Job",
        "metadata":{"name":strenv(JOB_NAME),"namespace":"automation-data","labels":{
          "homelab-talos/test":"nocodb-restore-drill","homelab-talos/run-id":strenv(RUN_HASH),"homelab-talos/role":"request"
        }},
        "spec":{"activeDeadlineSeconds":600,"backoffLimit":0,"template":{
          "metadata":{"labels":{"homelab-talos/test":"nocodb-restore-drill","homelab-talos/run-id":strenv(RUN_HASH),"homelab-talos/role":"request"}},
          "spec":{"automountServiceAccountToken":false,"restartPolicy":"Never",
            "securityContext":{"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}},
            "containers":[{
              "name":"request","image":"docker.io/nocodb/nocodb@sha256:4b760f0d25471fb49707d515f161d9d36b49c88e7ecbe25eded774af385be5a9","imagePullPolicy":"IfNotPresent",
              "command":["node","--input-type=module","--eval"],"args":[strenv(REQUEST_SCRIPT)],
              "env":[
                {"name":"APP_SERVICE","value":strenv(APP_SERVICE)},{"name":"RUN_HASH","value":strenv(RUN_HASH)},
                {"name":"SOURCE_REGISTRY","value":strenv(SOURCE_REGISTRY)},
                {"name":"ADMIN_EMAIL","valueFrom":{"secretKeyRef":{"name":"nocodb-credentials","key":"NC_ADMIN_EMAIL"}}},
                {"name":"ADMIN_PASSWORD","valueFrom":{"secretKeyRef":{"name":"nocodb-credentials","key":"NC_ADMIN_PASSWORD"}}},
                {"name":"HOME","value":"/tmp"}
              ],
              "resources":{"requests":{"cpu":"10m","memory":"64Mi"},"limits":{"memory":"256Mi"}},
              "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true,"runAsNonRoot":true,"runAsUser":1000,"runAsGroup":1000},
              "volumeMounts":[{"name":"tmp","mountPath":"/tmp"}]
            }],"volumes":[{"name":"tmp","emptyDir":{}}]
          }
        }}
      }
    '
}

cleanup() {
	local original_exit="$?"
	local cleanup_ok=true final_exit="$original_exit"
	trap - EXIT INT TERM
	set +e
	verify_lease || cleanup_ok=false
	if [[ "$cleanup_ok" == true ]]; then
		for target in "job/$request_job" "deployment/$app" "service/$app_service" \
			"job/$restore_job" "job/$preflight_job" "statefulset/$database" "service/$database_service" \
			"pvc/$database_pvc" "pvc/$attachment_pvc" "ciliumnetworkpolicy/$policy"; do
			delete_owned "$namespace" "$target" || cleanup_ok=false
		done
		delete_owned - "persistentvolume/$attachment_pv" || cleanup_ok=false
		delete_owned "$longhorn_namespace" "volumes.longhorn.io/$attachment_volume" || cleanup_ok=false
	fi
	for target in "job/$request_job" "deployment/$app" "service/$app_service" \
		"job/$restore_job" "job/$preflight_job" "statefulset/$database" "service/$database_service" \
		"pvc/$database_pvc" "pvc/$attachment_pvc" "ciliumnetworkpolicy/$policy"; do
		resource_absent "$namespace" "$target" || cleanup_ok=false
	done
	resource_absent - "persistentvolume/$attachment_pv" || cleanup_ok=false
	resource_absent "$longhorn_namespace" "volumes.longhorn.io/$attachment_volume" || cleanup_ok=false
	rm -rf -- "$temp_dir" || cleanup_ok=false
	[[ ! -e "$temp_dir" ]] || cleanup_ok=false
	if [[ "$cleanup_ok" == true ]]; then
		write_phase cleanup passed 'all and only run-owned workloads, policy, Services, PV, PVCs, and Longhorn Volume are absent'
	else
		write_phase cleanup failed 'one or more run-owned resources remain or failed the ownership guard'
		[[ "$final_exit" -ne 0 ]] || final_exit=1
	fi
	if [[ "$original_exit" -ne 0 && "$(yq -r '.status' "$run_dir/assertion.json" 2>/dev/null)" == not-classified ]]; then
		write_phase assertion failed 'isolated metadata or attachment recovery did not satisfy the fixed contract'
	fi
	exit "$final_exit"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

verify_lease
routes="$temp_dir/routes.json"
"${kcluster[@]}" get httproutes.gateway.networking.k8s.io --all-namespaces --output json >"$routes"
route_targets_service "$app_service" "$routes" && {
	echo 'Refusing restore drill because an HTTPRoute targets its temporary Service name.' >&2
	exit 1
}

for target in "job/$request_job" "deployment/$app" "service/$app_service" \
	"job/$restore_job" "job/$preflight_job" "statefulset/$database" "service/$database_service" \
	"pvc/$database_pvc" "pvc/$attachment_pvc" "ciliumnetworkpolicy/$policy"; do
	resource_absent "$namespace" "$target" || {
		echo "Refusing to adopt existing $namespace/$target." >&2
		exit 1
	}
done
resource_absent - "persistentvolume/$attachment_pv" || {
	echo "Refusing to adopt existing persistentvolume/$attachment_pv." >&2
	exit 1
}
resource_absent "$longhorn_namespace" "volumes.longhorn.io/$attachment_volume" || {
	echo "Refusing to adopt existing Longhorn Volume $attachment_volume." >&2
	exit 1
}

# Bind the restore Job to the exact generated script source selected by both the local
# package and the current deployed backup CronJob. A stale ConfigMap with matching keys
# is not an acceptable substitute.
postgresql_package_yaml="$temp_dir/postgresql-package.yaml"
postgresql_package_json="$temp_dir/postgresql-package.json"
kustomize build kubernetes/apps/automation-data/postgresql/app >"$postgresql_package_yaml"
# shellcheck disable=SC2016 # yq evaluates its own variables.
yq ea -o=json -I=0 '. as $item ireduce ([]; . + [$item])' \
	"$postgresql_package_yaml" >"$postgresql_package_json"
rendered_backup_configmap="$(resolve_rendered_backup_configmap "$postgresql_package_json")" || {
	echo 'The rendered PostgreSQL package has no unambiguous backup script ConfigMap.' >&2
	exit 1
}
deployed_backup_cronjob="$temp_dir/deployed-backup-cronjob.json"
"${kc[@]}" get cronjob automation-data-postgresql-backup --output json \
	>"$deployed_backup_cronjob" || {
	echo 'The deployed automation-data backup CronJob is absent.' >&2
	exit 1
}
deployed_backup_configmap="$(resolve_deployed_backup_configmap "$deployed_backup_cronjob")" || {
	echo 'The deployed automation-data backup CronJob has no unambiguous generated script reference.' >&2
	exit 1
}
[[ "$deployed_backup_configmap" == "$rendered_backup_configmap" ]] || {
	echo 'The deployed backup CronJob script reference differs from the rendered PostgreSQL package.' >&2
	exit 1
}
deployed_backup_source="$temp_dir/deployed-backup-configmap.json"
"${kc[@]}" get configmap "$deployed_backup_configmap" --output json \
	>"$deployed_backup_source" || {
	echo 'The exact backup ConfigMap selected by the deployed CronJob is absent.' >&2
	exit 1
}
CONFIGMAP_NAME="$deployed_backup_configmap" jq -e '
  .kind == "ConfigMap" and .metadata.name == env.CONFIGMAP_NAME and
  (.data | type == "object") and
  (.data | has("backup.sh") and has("update-backup-status.sql"))
' "$deployed_backup_source" >/dev/null || {
	echo 'The deployed backup ConfigMap is missing a required script key.' >&2
	exit 1
}
backup_configmap="$deployed_backup_configmap"

production_pvc="$temp_dir/production-pvc.json"
production_pv="$temp_dir/production-pv.json"
"${kc[@]}" get persistentvolumeclaim nocodb-data --output json >"$production_pvc"
production_pv_name="$(jq -er '
  select(.status.phase == "Bound") |
  select(.spec.resources.requests.storage == "10Gi" and .spec.storageClassName == "longhorn") |
  select(.spec.accessModes == ["ReadWriteOnce"]) |
  select(.metadata.uid | type == "string" and length > 0) |
  .spec.volumeName | select(type == "string" and length > 0)
' "$production_pvc")" || {
	echo 'The production NocoDB attachment claim is not Bound to one PV.' >&2
	exit 1
}
"${kcluster[@]}" get persistentvolume "$production_pv_name" --output json >"$production_pv"
production_volume="$(PVC_UID="$(jq -r '.metadata.uid' "$production_pvc")" jq -er '
  select(.spec.claimRef.namespace == "automation-data" and .spec.claimRef.name == "nocodb-data") |
  select(.spec.claimRef.uid == env.PVC_UID) |
  select(.spec.capacity.storage == "10Gi" and .spec.accessModes == ["ReadWriteOnce"]) |
  select(.spec.csi.driver == "driver.longhorn.io") |
  .spec.csi.volumeHandle | select(type == "string" and length > 0)
' "$production_pv")" || {
	echo 'The production NocoDB claim does not have an exact Longhorn volume binding.' >&2
	exit 1
}

backup_target="$temp_dir/backup-target.json"
backups="$temp_dir/backups.json"
"${kl[@]}" get backuptargets.longhorn.io default --output json >"$backup_target"
jq -e '
  .metadata.name == "default" and .status.available == true and
  (.spec.backupTargetURL | type == "string" and length > 0)
' "$backup_target" >/dev/null || {
	echo 'The default off-cluster Longhorn BackupTarget is not available.' >&2
	exit 1
}
"${kl[@]}" get backups.longhorn.io --output json >"$backups"

# Reject missing or malformed attachment recovery candidates before creating anything.
jq -e --arg volume "$production_volume" '
  [.items[] | select(.status.state == "Completed" and
    .status.volumeName == $volume and .spec.backupTargetName == "default")] as $matching |
  ($matching | length) > 0 and all($matching[];
    .status.volumeSize == "10737418240" and
    (.status.url | type == "string" and test("^[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]]+$")) and
    (.status.backupCreatedAt | fromdateiso8601 | type == "number"))
' "$backups" >/dev/null || {
	echo 'No complete attachment recovery candidates with the required URL and size.' >&2
	exit 1
}

# This observational Job is the only resource allowed before both recovery inputs pass.
preflight_manifest="$temp_dir/preflight.yaml"
nocodb_restore_preflight_manifest "$preflight_job" "$run_hash" >"$preflight_manifest"
create_owned_manifests "$namespace" "$preflight_manifest"
wait_for_job_terminal "$preflight_job" 300 5 "${kc[@]}"
"${kc[@]}" logs "job/$preflight_job" --tail=2 >"$temp_dir/preflight.log"
selected_bundle="$(sed -n 's/^selected_bundle=//p' "$temp_dir/preflight.log")"
[[ "$selected_bundle" =~ ^automation-data-[0-9]{8}T[0-9]{6}Z$ ]] || {
	echo 'The logical preflight omitted exact complete-bundle evidence.' >&2
	exit 1
}
selected_backup="$(nocodb_restore_select_attachment_backup "$selected_bundle" \
	"$production_volume" default "$backups")" || {
	echo 'No completed off-cluster attachment backup matches the bound NocoDB volume.' >&2
	exit 1
}
selected_backup_url="$(jq -er '.url' <<<"$selected_backup")"
selected_backup_size="$(jq -er '.volumeSize' <<<"$selected_backup")"
nocodb_restore_require_inputs "/backups/$selected_bundle" "$selected_backup_url" "$selected_backup_size" || {
	echo 'Both metadata and attachment recovery inputs are required.' >&2
	exit 1
}

delete_owned "$namespace" "job/$preflight_job"
resource_absent "$namespace" "job/$preflight_job"

policy_manifest="$temp_dir/policy.yaml"
nocodb_restore_policy_manifest "$policy" "$database" "$app" "$request_job" \
	"$run_hash" >"$policy_manifest"
verify_lease
create_owned_manifests "$namespace" "$policy_manifest"
database_manifests >"$temp_dir/database.yaml"
create_owned_manifests "$namespace" "$temp_dir/database.yaml"
"${kc[@]}" rollout status "statefulset/$database" --timeout=10m >/dev/null

verify_lease
restore_job_manifest >"$temp_dir/restore-job.yaml"
create_owned_manifests "$namespace" "$temp_dir/restore-job.yaml"
wait_for_job_terminal "$restore_job" 1800 5 "${kc[@]}"
restore_output="$temp_dir/restore-output.log"
"${kc[@]}" logs "job/$restore_job" --tail=30 >"$restore_output"
restored_bundle="$(sed -n 's/^selected_bundle=//p' "$restore_output" | tail -n 1)"
post_recovery_bundle="$(sed -n 's/^post_recovery_bundle=//p' "$restore_output" | tail -n 1)"
source_registry_base64="$(sed -n 's/^source_registry_base64=//p' "$restore_output" | tail -n 1)"
[[ "$restored_bundle" == "$selected_bundle" &&
	"$post_recovery_bundle" =~ ^automation-data-[0-9]{8}T[0-9]{6}Z$ &&
	"$source_registry_base64" =~ ^[A-Za-z0-9+/=]+$ ]] || {
	echo 'The restore Job omitted bounded bundle or source-registry evidence.' >&2
	exit 1
}
printf '%s' "$source_registry_base64" | base64 --decode >"$temp_dir/source-registry.json"
nocodb_restore_validate_source_registry "$temp_dir/source-registry.json" || {
	echo 'The restored issue334 source registry is incomplete or invalid.' >&2
	exit 1
}

volume_manifest="$temp_dir/attachment-volume.yaml"
binding_manifest="$temp_dir/attachment-binding.yaml"
nocodb_restore_longhorn_volume_manifest "$attachment_volume" "$selected_backup_url" \
	"$selected_backup_size" "$run_hash" >"$volume_manifest"
verify_lease
create_owned_manifests "$longhorn_namespace" "$volume_manifest"
volume_healthy=false
for _ in {1..180}; do
	"${kl[@]}" get "volumes.longhorn.io/$attachment_volume" --output json \
		>"$temp_dir/attachment-volume.json"
	if nocodb_restore_validate_volume_pre_bind "$attachment_volume" "$selected_backup_url" \
		"$selected_backup_size" "$temp_dir/attachment-volume.json"; then
		volume_healthy=true
		break
	fi
	sleep 5
done
[[ "$volume_healthy" == true ]] || {
	echo 'The restored attachment Volume did not complete the detached restore phase.' >&2
	exit 1
}

nocodb_restore_static_binding_manifests "$attachment_pv" "$attachment_pvc" \
	"$attachment_volume" "$run_hash" >"$binding_manifest"
verify_lease
create_owned_manifests - "$binding_manifest"
"${kc[@]}" wait --for=jsonpath='{.status.phase}'=Bound \
	"persistentvolumeclaim/$attachment_pvc" --timeout=10m >/dev/null

database_ip="$("${kc[@]}" get service "$database_service" --output jsonpath='{.spec.clusterIP}')"
[[ "$database_ip" =~ ^[0-9A-Fa-f:.]+$ && "$database_ip" != None ]] || {
	echo 'The isolated PostgreSQL Service has no usable ClusterIP.' >&2
	exit 1
}
app_manifest="$temp_dir/application.yaml"
live_policy="$temp_dir/live-policy.json"
nocodb_restore_application_manifests "$app" "$app_service" "$attachment_pvc" \
	"$database_ip" "$run_hash" >"$app_manifest"
"${kc[@]}" get "ciliumnetworkpolicy/$policy" --output json >"$live_policy"
nocodb_restore_validate_isolation "$app_manifest" "$live_policy" \
	"$database_ip" "$run_hash" || {
	echo 'Refusing to start restored NocoDB: hostAliases or exact run policy failed independent validation.' >&2
	exit 1
}

verify_lease
create_owned_manifests "$namespace" "$app_manifest"
"${kc[@]}" rollout status "deployment/$app" --timeout=20m >/dev/null

volume_healthy=false
for _ in {1..180}; do
	"${kl[@]}" get "volumes.longhorn.io/$attachment_volume" --output json >"$temp_dir/attachment-volume.json"
	if nocodb_restore_validate_volume_attached "$attachment_volume" "$selected_backup_url" \
		"$selected_backup_size" "$temp_dir/attachment-volume.json"; then
		volume_healthy=true
		break
	fi
	sleep 5
done
[[ "$volume_healthy" == true ]] || {
	echo 'The mounted attachment Volume did not become healthy with exactly two RW replicas.' >&2
	exit 1
}

# This drill creates no HTTPRoute. Recheck after Service creation before any request Job.
"${kcluster[@]}" get httproutes.gateway.networking.k8s.io --all-namespaces --output json >"$routes"
route_targets_service "$app_service" "$routes" && {
	echo 'The restored NocoDB Service gained an HTTPRoute after creation.' >&2
	exit 1
}

verify_lease
request_job_manifest >"$temp_dir/request-job.yaml"
create_owned_manifests "$namespace" "$temp_dir/request-job.yaml"
wait_for_job_terminal "$request_job" 600 5 "${kc[@]}"
[[ "$("${kc[@]}" logs "job/$request_job" --tail=1)" == nocodb_restore_assertions=passed ]] || {
	echo 'The restored NocoDB request Job omitted bounded recovery evidence.' >&2
	exit 1
}

RUN_HASH="$run_hash" SELECTED_BUNDLE="$selected_bundle" \
	POST_RECOVERY_BUNDLE="$post_recovery_bundle" \
	yq --null-input --output-format json '{
    "runHash":strenv(RUN_HASH),
    "selectedAutomationDataBundle":strenv(SELECTED_BUNDLE),
    "completedAttachmentBackupSelected":true,
    "restoredAttachmentVolumeHealthy":true,
    "hostAliasesIndependentlyValidated":true,
    "networkPolicyIndependentlyValidated":true,
    "workspaceBaseViewSourcesAndAttachmentValidated":true,
    "postRecoveryBundle":strenv(POST_RECOVERY_BUNDLE),
    "productionMutation":false
  }' >"$run_dir/nocodb-restore-evidence.json"
write_phase assertion passed 'isolated NocoDB metadata, encrypted sources, privilege denials, saved view, attachment checksum, and fresh backup passed'
echo "NocoDB metadata and attachment restore drill passed with $selected_bundle; cleanup will remove all run-owned resources."
