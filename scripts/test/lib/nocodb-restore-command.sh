#!/usr/bin/env bash

nocodb_restore_preflight_manifest() { # <job-name> <run-hash>
	local job_name="$1" run_hash="$2" command
	# Reuse the full checksum, manifest, archive-list, and selection contract, stopping
	# before the first PostgreSQL connection or any restore operation.
	command="$(automation_data_restore_job_command | sed '/^initial_database_count=/,$d' |
		sed '/^printf.*restore_stage=artifact-selection/d')"
	command+=$'\n'
	command+="$(
		cat <<'EOF'
for required_database in nocodb automation_data_control issue334_acceptance; do
  encoded="$(printf '%s' "$required_database" | base64 | tr -d '\n')"
  grep -Fxq "$encoded" /tmp/restore-expected-databases-base64 || restore_fail required-database-missing
done
printf 'selected_bundle=%s\n' "$selected_name"
EOF
	)"
	JOB_NAME="$job_name" RUN_HASH="$run_hash" JOB_COMMAND="$command" \
		yq --null-input --output-format yaml '
      {
        "apiVersion":"batch/v1", "kind":"Job",
        "metadata":{"name":strenv(JOB_NAME),"namespace":"automation-data","labels":{
          "homelab-talos/test":"nocodb-restore-drill","homelab-talos/run-id":strenv(RUN_HASH),"homelab-talos/role":"preflight"
        }},
        "spec":{"activeDeadlineSeconds":300,"backoffLimit":0,"template":{
          "metadata":{"labels":{"homelab-talos/test":"nocodb-restore-drill","homelab-talos/run-id":strenv(RUN_HASH),"homelab-talos/role":"preflight"}},
          "spec":{"automountServiceAccountToken":false,"restartPolicy":"Never",
            "securityContext":{"fsGroup":70,"fsGroupChangePolicy":"OnRootMismatch","runAsNonRoot":true,"runAsUser":70,"runAsGroup":70,"seccompProfile":{"type":"RuntimeDefault"}},
            "containers":[{
              "name":"preflight","image":"postgres:17.11-alpine3.24","imagePullPolicy":"IfNotPresent",
              "command":["/bin/sh","-ceu"],"args":[strenv(JOB_COMMAND)],
              "env":[{"name":"BACKUP_DIR","value":"/backups"}],
              "resources":{"requests":{"cpu":"10m","memory":"64Mi"},"limits":{"memory":"256Mi"}},
              "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true},
              "volumeMounts":[{"name":"backups","mountPath":"/backups","readOnly":true},{"name":"tmp","mountPath":"/tmp"}]
            }],
            "volumes":[{"name":"backups","persistentVolumeClaim":{"claimName":"automation-data-postgresql-backups","readOnly":true}},{"name":"tmp","emptyDir":{}}]
          }
        }}
      }
    '
}

nocodb_restore_request_script() {
	cat <<'EOF'
import {createHash} from 'node:crypto';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

const root = mkdtempSync(join(tmpdir(), 'nocodb-restore-request-'));
const baseUrl = `http://${process.env.APP_SERVICE}.automation-data.svc.cluster.local:8080`;
const secretFile = join(root, 'signin.json');
const tokenFile = join(root, 'session.jwt');
const bounded = async (path, options = {}, allowed = [200], parseJson = true, maxBytes = 65536) => {
  const response = await fetch(`${baseUrl}${path}`, {...options, redirect:'error', signal: AbortSignal.timeout(60000)});
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.byteLength > maxBytes) throw new Error('response_exceeded_bound');
  if (!allowed.includes(response.status)) throw new Error(`unexpected_http_${response.status}`);
  return {status: response.status, bytes, json: parseJson && bytes.byteLength ? JSON.parse(new TextDecoder().decode(bytes)) : null};
};
const list = (value) => Array.isArray(value) ? value : (value?.list || value?.data || []);
let insertedId = null;
let decisionTable = null;
let jwt = '';
try {
  const health = await bounded('/api/v1/health');
  if (health.json?.message !== 'OK') throw new Error('health_contract_failed');

  writeFileSync(secretFile, JSON.stringify({email: process.env.ADMIN_EMAIL, password: process.env.ADMIN_PASSWORD}), {mode: 0o600});
  const signin = await bounded('/api/v1/auth/user/signin', {method:'POST', headers:{'Content-Type':'application/json'}, body:readFileSync(secretFile)});
  if (typeof signin.json?.token !== 'string' || !/^[A-Za-z0-9._-]+$/.test(signin.json.token)) throw new Error('signin_contract_failed');
  writeFileSync(tokenFile, signin.json.token, {mode: 0o600});
  jwt = readFileSync(tokenFile, 'utf8');
  const headers = {'xc-auth':jwt};

  const workspaces = list((await bounded('/api/v2/meta/workspaces', {headers})).json);
  const workspaceMatches = workspaces.filter((item) => item?.title === 'Automation Data');
  if (workspaceMatches.length !== 1 || !workspaceMatches[0].id) throw new Error('workspace_contract_failed');
  const bases = list((await bounded('/api/v2/meta/bases', {headers})).json);
  const baseMatches = bases.filter((item) => item?.title === 'issue334_acceptance' && (item.fk_workspace_id || item.workspace_id) === workspaceMatches[0].id);
  if (baseMatches.length !== 1 || !baseMatches[0].id) throw new Error('base_contract_failed');
  const base = baseMatches[0];
  const registry = JSON.parse(process.env.SOURCE_REGISTRY);
  const retained = registry.items.filter((item) => item.domain === 'issue334_acceptance');
  if (retained.length !== 2 || retained.some((item) => item.baseId !== base.id || item.state !== 'ready' || item.valid !== true)) throw new Error('registry_base_mismatch');
  const integrations = list((await bounded(`/api/v2/meta/workspaces/${workspaceMatches[0].id}/integrations`, {headers})).json);


  const sources = list((await bounded(`/api/v2/meta/bases/${base.id}/sources`, {headers})).json);
  if (sources.length !== 2) throw new Error('source_count_failed');
  const sourceObjects = [];
  for (const summary of sources) sourceObjects.push((await bounded(`/api/v2/meta/bases/${base.id}/sources/${summary.id}`, {headers})).json);
  const reader = sourceObjects.find((item) => item?.alias === 'Read Model');
  const operator = sourceObjects.find((item) => item?.alias === 'Operator');
  const pathOf = (source) => source?.config?.searchPath || source?.config?.search_path;
  if (!reader || JSON.stringify(pathOf(reader)) !== JSON.stringify(['read_model']) || reader.is_data_readonly !== true || reader.is_schema_readonly !== true) throw new Error('reader_source_failed');
  if (!operator || JSON.stringify(pathOf(operator)) !== JSON.stringify(['operator']) || operator.is_data_readonly !== false || operator.is_schema_readonly !== true) throw new Error('operator_source_failed');

  for (const [kind, source] of [['reader', reader], ['operator', operator]]) {
    const matches = retained.filter((item) => item.accessKind === kind);
    if (matches.length !== 1 || source.id !== matches[0].sourceId || source.fk_integration_id !== matches[0].integrationId) throw new Error('registry_source_mismatch');
    const integration = integrations.filter((item) => item.id === matches[0].integrationId);
    if (integration.length !== 1 || integration[0].title !== `automation-data/issue334_acceptance/${kind}` ||
        integration[0].type !== 'db' || integration[0].sub_type !== 'pg') throw new Error('registry_integration_mismatch');
  }

  const tables = list((await bounded(`/api/v2/meta/bases/${base.id}/tables`, {headers})).json);
  const facts = tables.find((table) => table?.title === 'acceptance_facts' && table.table_name === 'acceptance_facts' && table.schema === 'read_model' && table.source_id === reader.id);
  decisionTable = tables.find((table) => table?.title === 'acceptance_decision' && table.table_name === 'acceptance_decision' && table.schema === 'operator' && table.source_id === operator.id);
  if (tables.length !== 2 || !facts?.id || !decisionTable?.id) throw new Error('schema_separation_failed');
  await bounded(`/api/v2/tables/${facts.id}/records?limit=100`, {headers});
  await bounded(`/api/v2/tables/${decisionTable.id}/records?limit=100`, {headers});

  const exactKeys = (value, keys) => value && typeof value === 'object' && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify(keys.sort());
  const id = (value) => typeof value === 'string' && /^[A-Za-z0-9_-]+$/.test(value);
  const canaryResponse = (await bounded(`/api/v2/tables/${decisionTable.id}/records?where=(run_id,eq,recovery-canary-v1)&limit=2`, {headers})).json;
  const rows = list(canaryResponse);
  if (rows.length !== 1 || canaryResponse.pageInfo?.totalRows !== 1 || rows[0].run_id !== 'recovery-canary-v1' || typeof rows[0].decision !== 'string') throw new Error('attachment_canary_missing');
  const canary = JSON.parse(rows[0].decision);
  if (!exactKeys(canary, ['kind','version','state','baseId','sourceId','tableId','rowId','savedView','commentId','attachment']) ||
      canary.kind !== 'nocodb-attachment-recovery-canary' || canary.version !== 1 || canary.state !== 'ready' ||
      canary.baseId !== base.id || canary.sourceId !== operator.id || canary.tableId !== decisionTable.id ||
      canary.rowId !== String(rows[0].id) || !id(canary.rowId) || !id(canary.commentId)) throw new Error('canary_identity_failed');
  const view = canary.savedView;
  if (!exactKeys(view, ['id','tableId','title','type']) || !id(view.id) || view.tableId !== facts.id ||
      view.title !== 'acceptance_facts' || view.type !== 3) throw new Error('canary_view_failed');
  const views = list((await bounded(`/api/v2/meta/tables/${facts.id}/views`, {headers})).json);
  if (views.length !== 1 || views[0].id !== view.id || views[0].fk_model_id !== view.tableId ||
      views[0].title !== view.title || views[0].type !== view.type) throw new Error('saved_view_failed');
  const attachment = canary.attachment;
  if (!exactKeys(attachment, ['id','path','title','mimetype','size','sha256']) || !id(attachment.id) ||
      !/^download\/issue334_acceptance\/recovery-canary-v1\/issue334-recovery-canary-v1_[A-Za-z0-9_-]{5}\.txt$/.test(attachment.path) ||
      attachment.title !== 'issue334-recovery-canary-v1.txt' || attachment.mimetype !== 'text/plain' ||
      attachment.size !== 37 || attachment.sha256 !== '09dbca24661414e7c9bfdb82b6ee39484466ae4bc4c9775501e2789fe39786a3') throw new Error('canary_attachment_failed');
  const comments = list((await bounded(`/api/v2/meta/comments?fk_model_id=${decisionTable.id}&row_id=${canary.rowId}`, {headers})).json);
  const matches = comments.filter((item) => item.id === canary.commentId);
  if (comments.length !== 1 || matches.length !== 1) throw new Error('canary_comment_missing');
  const comment = matches[0];
  if (comment.base_id !== base.id || comment.source_id !== operator.id || comment.fk_model_id !== decisionTable.id ||
      String(comment.row_id) !== canary.rowId || comment.comment !== 'issue334-recovery-canary-v1' ||
      !Array.isArray(comment.attachments) || comment.attachments.length !== 1 ||
      ['id','path','title','mimetype','size'].some((key) => comment.attachments[0][key] !== attachment[key])) throw new Error('canary_comment_mismatch');
  const downloaded = await bounded(`/${attachment.path}`, {headers}, [200], false, 37);
  if (downloaded.bytes.byteLength !== 37 || createHash('sha256').update(downloaded.bytes).digest('hex') !== attachment.sha256) throw new Error('attachment_checksum_failed');

  const readerDenied = await bounded(`/api/v2/tables/${facts.id}/records`, {
    method:'POST', headers:{...headers,'Content-Type':'application/json'},
    body:JSON.stringify({id:2147483647,fact:`restore-denial-${process.env.RUN_HASH}`})
  }, [403]);
  if (readerDenied.status !== 403) throw new Error('reader_denial_failed');

  const inserted = await bounded(`/api/v2/tables/${decisionTable.id}/records`, {
    method:'POST', headers:{...headers,'Content-Type':'application/json'},
    body:JSON.stringify({run_id:`restore-${process.env.RUN_HASH}`,decision:'restore-probe'})
  });
  insertedId = inserted.json?.id;
  if (typeof insertedId !== 'number' && typeof insertedId !== 'string') throw new Error('operator_authentication_failed');
  const protectedDenied = await bounded(`/api/v2/tables/${decisionTable.id}/records`, {
    method:'PATCH', headers:{...headers,'Content-Type':'application/json'},
    body:JSON.stringify([{id:insertedId,protected_created_at:'2000-01-01T00:00:00Z'}])
  }, [400]);
  if (protectedDenied.status !== 400) throw new Error('operator_denial_failed');

  await bounded(`/api/v2/tables/${decisionTable.id}/records`, {
    method:'DELETE', headers:{...headers,'Content-Type':'application/json'}, body:JSON.stringify([{id:insertedId}])
  });
  insertedId = null;
  console.log('nocodb_restore_assertions=passed');
} finally {
  if (insertedId !== null && decisionTable?.id && jwt) {
    try {
      await bounded(`/api/v2/tables/${decisionTable.id}/records`, {
        method:'DELETE', headers:{'xc-auth':jwt,'Content-Type':'application/json'}, body:JSON.stringify([{id:insertedId}])
      });
    } catch {}
  }
  rmSync(root, {recursive:true,force:true});
}
EOF
}

nocodb_restore_bundle_is_complete() { # <bundle-directory>
	local candidate="$1" candidate_name expected_files actual_files
	candidate_name="$(basename "$candidate")"
	[[ "$candidate_name" =~ ^automation-data-[0-9]{8}T[0-9]{6}Z$ ]] || return 1
	[[ -s "$candidate/globals.sql" && -s "$candidate/registry.tsv" &&
		-s "$candidate/manifest.tsv" && -s "$candidate/SHA256SUMS" &&
		-s "$candidate/COMPLETE" ]] || return 1
	(cd "$candidate" && sha256sum -c SHA256SUMS >/dev/null 2>&1 &&
		sha256sum -c COMPLETE >/dev/null 2>&1) || return 1

	expected_files="$(mktemp "${TMPDIR:-/tmp}/nocodb-restore-expected.XXXXXX")"
	actual_files="$(mktemp "${TMPDIR:-/tmp}/nocodb-restore-actual.XXXXXX")"
	awk 'NF == 2 {print $2}' "$candidate/SHA256SUMS" | LC_ALL=C sort -u >"$expected_files"
	printf '%s\n' COMPLETE SHA256SUMS >>"$expected_files"
	LC_ALL=C sort -u -o "$expected_files" "$expected_files"
	(cd "$candidate" && find . -type f -print | sed 's#^./##' | LC_ALL=C sort -u) \
		>"$actual_files"
	cmp -s "$expected_files" "$actual_files"
	local result="$?"
	rm -f -- "$expected_files" "$actual_files"
	return "$result"
}

nocodb_restore_select_complete_bundle() { # <backup-directory>
	local backup_dir="$1" candidate
	[[ -d "$backup_dir" ]] || return 1
	while IFS= read -r candidate; do
		[[ -n "$candidate" ]] || continue
		if nocodb_restore_bundle_is_complete "$candidate"; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done < <(find "$backup_dir" -mindepth 1 -maxdepth 1 -type d \
		-name 'automation-data-*' -print | LC_ALL=C sort -r)
	return 1
}

nocodb_restore_validate_source_registry() { # <registry-json>
	local registry_json="$1"
	jq -e '
    (.items | type) == "array" and
    ([.items[] | select(.domain == "issue334_acceptance")] | length) == 2 and
    ([.items[] | select(
      .domain == "issue334_acceptance" and .accessKind == "reader" and
      .state == "ready" and .valid == true and
      (.baseId | type == "string" and length > 0) and
      (.sourceId | type == "string" and length > 0) and
      (.integrationId | type == "string" and length > 0)
    )] | length) == 1 and
    ([.items[] | select(
      .domain == "issue334_acceptance" and .accessKind == "operator" and
      .state == "ready" and .valid == true and
      (.baseId | type == "string" and length > 0) and
      (.sourceId | type == "string" and length > 0) and
      (.integrationId | type == "string" and length > 0)
    )] | length) == 1 and
    ([.items[] | select(.domain == "issue334_acceptance") | .baseId] | unique | length) == 1 and
    ([.items[] | select(.domain == "issue334_acceptance") | .sourceId] | unique | length) == 2 and
    ([.items[] | select(.domain == "issue334_acceptance") | .integrationId] | unique | length) == 2
  ' "$registry_json" >/dev/null
}

nocodb_restore_select_attachment_backup() { # <bundle-name> <volume> <target> <backups-json>
	local bundle_name="$1" volume_name="$2" target_name="$3" backups_json="$4"
	[[ "$bundle_name" =~ ^automation-data-([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$ ]] || return 1
	local bundle_time="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}T${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}Z"
	jq -er --arg volume "$volume_name" --arg target "$target_name" \
		--arg captured_at "$bundle_time" '
      ($captured_at | fromdateiso8601) as $captured_epoch |
      [.items[] | select(
        .status.state == "Completed" and
        .status.volumeName == $volume and
        .spec.backupTargetName == $target and
        (.status.backupCreatedAt | type == "string") and
        (.status.url | type == "string" and length > 0)
      ) | {
        url: .status.url,
        volumeSize: .status.volumeSize,
        created: (.status.backupCreatedAt | fromdateiso8601),
        distance: (((.status.backupCreatedAt | fromdateiso8601) - $captured_epoch) | fabs),
        name: .metadata.name
      }] |
      sort_by(.distance, .created, .name) |
      if length > 0 then .[0] | {name, url, volumeSize} |
        if .volumeSize == "10737418240" and (.url | test("^[A-Za-z][A-Za-z0-9+.-]*://[^\\s]+$"))
        then . else error("invalid attachment backup URL or size") end
      else error("no completed matching backup") end
    ' "$backups_json"
}

nocodb_restore_require_inputs() { # <bundle-path> <backup-url> <volume-size>
	local bundle_path="$1" backup_url="$2" volume_size="$3" bundle_name
	bundle_name="$(basename "$bundle_path")"
	[[ "$bundle_name" =~ ^automation-data-[0-9]{8}T[0-9]{6}Z$ &&
		"$backup_url" =~ ^[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]]+$ && "$volume_size" == 10737418240 ]]
}

nocodb_restore_longhorn_volume_manifest() { # <volume-name> <backup-url> <volume-size> <run-hash>
	local volume_name="$1" backup_url="$2" volume_size="$3" run_hash="$4"
	[[ "$volume_size" == 10737418240 ]] || return 1
	VOLUME_NAME="$volume_name" BACKUP_URL="$backup_url" VOLUME_SIZE="$volume_size" RUN_HASH="$run_hash" \
		yq --null-input --output-format yaml '
      {
        "apiVersion": "longhorn.io/v1beta2",
        "kind": "Volume",
        "metadata": {
          "name": strenv(VOLUME_NAME),
          "namespace": "longhorn-system",
          "labels": {
            "homelab-talos/test": "nocodb-restore-drill",
            "homelab-talos/run-id": strenv(RUN_HASH),
            "homelab-talos/role": "attachments"
          }
        },
        "spec": {
          "accessMode": "rwo",
          "backupTargetName": "default",
          "dataEngine": "v1",
          "dataLocality": "disabled",
          "frontend": "blockdev",
          "fromBackup": strenv(BACKUP_URL),
          "numberOfReplicas": 2,
          "size": strenv(VOLUME_SIZE),
          "staleReplicaTimeout": 30
        }
      }
    '
}

nocodb_restore_static_binding_manifests() { # <pv-name> <pvc-name> <volume-name> <run-hash>
	local pv_name="$1" pvc_name="$2" volume_name="$3" run_hash="$4"
	# shellcheck disable=SC2016 # yq evaluates its own variables.
	PV_NAME="$pv_name" PVC_NAME="$pvc_name" VOLUME_NAME="$volume_name" RUN_HASH="$run_hash" \
		yq --null-input --output-format yaml '
      {
        "homelab-talos/test": "nocodb-restore-drill",
        "homelab-talos/run-id": strenv(RUN_HASH)
      } as $labels |
      [
        {
          "apiVersion": "v1", "kind": "PersistentVolume",
          "metadata": {"name": strenv(PV_NAME), "labels": ($labels * {"homelab-talos/role":"attachment-pv"})},
          "spec": {
            "accessModes": ["ReadWriteOnce"], "capacity": {"storage":"10Gi"},
            "claimRef": {"name":strenv(PVC_NAME),"namespace":"automation-data"},
            "csi": {
              "driver":"driver.longhorn.io", "fsType":"ext4",
              "volumeAttributes":{"numberOfReplicas":"2","staleReplicaTimeout":"30"},
              "volumeHandle":strenv(VOLUME_NAME)
            },
            "persistentVolumeReclaimPolicy":"Retain", "storageClassName":"longhorn",
            "volumeMode":"Filesystem"
          }
        },
        {
          "apiVersion":"v1", "kind":"PersistentVolumeClaim",
          "metadata":{"name":strenv(PVC_NAME),"namespace":"automation-data","labels":($labels * {"homelab-talos/role":"attachment-pvc"})},
          "spec": {
            "accessModes":["ReadWriteOnce"], "resources":{"requests":{"storage":"10Gi"}},
            "storageClassName":"longhorn", "volumeMode":"Filesystem", "volumeName":strenv(PV_NAME)
          }
        }
      ] | .[] | split_doc
    '
}

nocodb_restore_application_manifests() { # <app> <service> <pvc> <database-ip> <run-hash>
	local app_name="$1" service_name="$2" pvc_name="$3" database_ip="$4" run_hash="$5"
	# shellcheck disable=SC2016 # yq evaluates its own variables.
	APP_NAME="$app_name" SERVICE_NAME="$service_name" PVC_NAME="$pvc_name" \
		DATABASE_IP="$database_ip" RUN_HASH="$run_hash" \
		yq --null-input --output-format yaml '
      {
        "homelab-talos/test":"nocodb-restore-drill",
        "homelab-talos/run-id":strenv(RUN_HASH),
        "homelab-talos/role":"nocodb"
      } as $labels |
      [
        {
          "apiVersion":"v1", "kind":"Service",
          "metadata":{"name":strenv(SERVICE_NAME),"namespace":"automation-data","labels":$labels},
          "spec":{"type":"ClusterIP","selector":$labels,"ports":[{"name":"http","port":8080,"targetPort":"http"}]}
        },
        {
          "apiVersion":"apps/v1", "kind":"Deployment",
          "metadata":{"name":strenv(APP_NAME),"namespace":"automation-data","labels":$labels},
          "spec": {
            "replicas":1, "strategy":{"type":"Recreate"}, "selector":{"matchLabels":$labels},
            "template":{"metadata":{"labels":$labels},"spec": {
              "automountServiceAccountToken":false,
              "hostAliases":[{"ip":strenv(DATABASE_IP),"hostnames":[
                "automation-data-postgresql",
                "automation-data-postgresql.automation-data.svc.cluster.local"
              ]}],
              "securityContext":{"fsGroup":1000,"fsGroupChangePolicy":"OnRootMismatch","seccompProfile":{"type":"RuntimeDefault"}},
              "containers":[{
                "name":"nocodb",
                "image":"docker.io/nocodb/nocodb@sha256:4b760f0d25471fb49707d515f161d9d36b49c88e7ecbe25eded774af385be5a9",
                "imagePullPolicy":"IfNotPresent", "ports":[{"name":"http","containerPort":8080}],
                "env":[
                  {"name":"DATABASE_URL","valueFrom":{"secretKeyRef":{"name":"nocodb-credentials","key":"DATABASE_URL"}}},
                  {"name":"NC_AUTH_JWT_SECRET","valueFrom":{"secretKeyRef":{"name":"nocodb-credentials","key":"NC_AUTH_JWT_SECRET"}}},
                  {"name":"NC_CONNECTION_ENCRYPT_KEY","valueFrom":{"secretKeyRef":{"name":"nocodb-credentials","key":"NC_CONNECTION_ENCRYPT_KEY"}}},
                  {"name":"NC_SITE_URL","value":("http://" + strenv(SERVICE_NAME) + ".automation-data.svc.cluster.local:8080")},
                  {"name":"NC_ALLOW_LOCAL_EXTERNAL_DBS","value":"true"},
                  {"name":"NC_DISABLE_TELE","value":"true"},
                  {"name":"NC_DISABLE_SUPPORT_CHAT","value":"true"}
                ],
                "readinessProbe":{"httpGet":{"path":"/api/v1/health","port":"http"},"periodSeconds":5,"failureThreshold":120},
                "resources":{"requests":{"cpu":"50m","memory":"256Mi"},"limits":{"memory":"1Gi"}},
                "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true,"runAsNonRoot":true,"runAsUser":1000,"runAsGroup":1000},
                "volumeMounts":[{"name":"data","mountPath":"/usr/app/data"},{"name":"tmp","mountPath":"/tmp"}]
              }],
              "volumes":[{"name":"data","persistentVolumeClaim":{"claimName":strenv(PVC_NAME)}},{"name":"tmp","emptyDir":{}}]
            }}
          }
        }
      ] | .[] | split_doc
    '
}

nocodb_restore_policy_manifest() { # <policy> <database> <app> <request> <run-hash>
	local policy_name="$1" database_name="$2" app_name="$3" request_name="$4" run_hash="$5"
	# shellcheck disable=SC2016 # yq evaluates its own variables.
	POLICY_NAME="$policy_name" DATABASE_NAME="$database_name" APP_NAME="$app_name" \
		REQUEST_NAME="$request_name" RUN_HASH="$run_hash" \
		yq --null-input --output-format yaml '
      {"homelab-talos/test":"nocodb-restore-drill","homelab-talos/run-id":strenv(RUN_HASH)} as $run |
      {"toEndpoints":[{"matchLabels":{"k8s:io.kubernetes.pod.namespace":"kube-system","k8s:k8s-app":"kube-dns"}}],"toPorts":[{"ports":[{"port":"53","protocol":"TCP"},{"port":"53","protocol":"UDP"}]}]} as $dns |
      {
        "apiVersion":"cilium.io/v2", "kind":"CiliumNetworkPolicy",
        "metadata":{"name":strenv(POLICY_NAME),"namespace":"automation-data","labels":($run * {"homelab-talos/role":"policy"})},
        "specs":[
          {"endpointSelector":{"matchLabels":($run * {"homelab-talos/role":"database"})},"ingress":[{"fromEndpoints":[
            {"matchLabels":($run * {"homelab-talos/role":"restore"})},
            {"matchLabels":($run * {"homelab-talos/role":"nocodb"})}
          ],"toPorts":[{"ports":[{"port":"5432","protocol":"TCP"}]}]}],"egress":[]},
          {"endpointSelector":{"matchLabels":($run * {"homelab-talos/role":"restore"})},"ingress":[],"egress":[$dns,{"toEndpoints":[{"matchLabels":($run * {"homelab-talos/role":"database"})}],"toPorts":[{"ports":[{"port":"5432","protocol":"TCP"}]}]}]},
          {"endpointSelector":{"matchLabels":($run * {"homelab-talos/role":"nocodb"})},"ingress":[{"fromEndpoints":[
            {"matchLabels":($run * {"homelab-talos/role":"request"})}
          ],"toPorts":[{"ports":[{"port":"8080","protocol":"TCP"}]}]}],"egress":[$dns,{"toEndpoints":[{"matchLabels":($run * {"homelab-talos/role":"database"})}],"toPorts":[{"ports":[{"port":"5432","protocol":"TCP"}]}]}]},
          {"endpointSelector":{"matchLabels":($run * {"homelab-talos/role":"request"})},"ingress":[],"egress":[$dns,{"toEndpoints":[{"matchLabels":($run * {"homelab-talos/role":"nocodb"})}],"toPorts":[{"ports":[{"port":"8080","protocol":"TCP"}]}]}]}
        ]
      }
    '
}

nocodb_restore_validate_isolation() { # <app-yaml> <policy-yaml> <database-ip> <run-hash>
	local app_yaml="$1" policy_yaml="$2" database_ip="$3" run_hash="$4"
	DATABASE_IP="$database_ip" RUN_HASH="$run_hash" yq ea -e '
    select(.kind == "Deployment") |
    .spec.replicas == 1 and .spec.strategy.type == "Recreate" and
    .spec.template.metadata.labels."homelab-talos/test" == "nocodb-restore-drill" and
    .spec.template.metadata.labels."homelab-talos/run-id" == strenv(RUN_HASH) and
    (.spec.template.spec.hostAliases | length) == 1 and
    .spec.template.spec.hostAliases[0].ip == strenv(DATABASE_IP) and
    (.spec.template.spec.hostAliases[0].hostnames | length) == 2 and
    .spec.template.spec.hostAliases[0].hostnames[0] == "automation-data-postgresql" and
    .spec.template.spec.hostAliases[0].hostnames[1] == "automation-data-postgresql.automation-data.svc.cluster.local" and
    (.spec.template.spec.containers | length) == 1 and
    .spec.template.spec.containers[0].image == "docker.io/nocodb/nocodb@sha256:4b760f0d25471fb49707d515f161d9d36b49c88e7ecbe25eded774af385be5a9"
  ' "$app_yaml" >/dev/null || return 1

	# shellcheck disable=SC2016 # yq evaluates its own variables.
	RUN_HASH="$run_hash" yq -e '
    .kind == "CiliumNetworkPolicy" and .metadata.namespace == "automation-data" and
    .metadata.labels."homelab-talos/test" == "nocodb-restore-drill" and
    .metadata.labels."homelab-talos/run-id" == strenv(RUN_HASH) and
    (.specs | length) == 4 and
    ([.specs[].endpointSelector.matchLabels."homelab-talos/role"] | sort | join(",")) == "database,nocodb,request,restore" and
    ([.specs[] | select(.endpointSelector.matchLabels."homelab-talos/test" != "nocodb-restore-drill" or .endpointSelector.matchLabels."homelab-talos/run-id" != strenv(RUN_HASH))] | length) == 0 and
    ([.specs[] | select((.endpointSelector.matchLabels | length) != 3)] | length) == 0 and
    ([.specs[].ingress[]?.fromEndpoints[]? | select(
      (.matchLabels | length) != 3 or
      .matchLabels."homelab-talos/test" != "nocodb-restore-drill" or
      .matchLabels."homelab-talos/run-id" != strenv(RUN_HASH)
    )] | length) == 0 and
    ([.specs[].egress[]?.toEndpoints[]? | select(
      ((.matchLabels | length) != 2 or
       .matchLabels."k8s:io.kubernetes.pod.namespace" != "kube-system" or
       .matchLabels."k8s:k8s-app" != "kube-dns") and
      ((.matchLabels | length) != 3 or
       .matchLabels."homelab-talos/test" != "nocodb-restore-drill" or
       .matchLabels."homelab-talos/run-id" != strenv(RUN_HASH))
    )] | length) == 0 and
    ([.. | select(tag == "!!map") | select(has("toCIDR") or has("toCIDRSet") or has("toEntities") or has("toFQDNs"))] | length) == 0 and
    ([.specs[] as $destination | $destination.ingress[]? as $rule |
      $rule.fromEndpoints[]? as $source | $rule.toPorts[]?.ports[]? |
      (($source.matchLabels."homelab-talos/role" // "") + ">" + $destination.endpointSelector.matchLabels."homelab-talos/role" + ":" + .port + "/" + .protocol)
    ] | sort | join(",")) == "nocodb>database:5432/TCP,request>nocodb:8080/TCP,restore>database:5432/TCP" and
    ([.specs[] as $source | $source.egress[]? as $rule |
      $rule.toEndpoints[]? as $destination | $rule.toPorts[]?.ports[]? |
      ($source.endpointSelector.matchLabels."homelab-talos/role" + ">" +
        ($destination.matchLabels."homelab-talos/role" // ($destination.matchLabels."k8s:k8s-app" // "")) +
        ":" + .port + "/" + .protocol)
    ] | sort | join(",")) == "nocodb>database:5432/TCP,nocodb>kube-dns:53/TCP,nocodb>kube-dns:53/UDP,request>kube-dns:53/TCP,request>kube-dns:53/UDP,request>nocodb:8080/TCP,restore>database:5432/TCP,restore>kube-dns:53/TCP,restore>kube-dns:53/UDP"
  ' "$policy_yaml" >/dev/null
}

nocodb_restore_validate_volume_pre_bind() { # <volume-name> <backup-url> <volume-size> <volume-json>
	local volume_name="$1" backup_url="$2" volume_size="$3" volume_json="$4"
	VOLUME_NAME="$volume_name" BACKUP_URL="$backup_url" VOLUME_SIZE="$volume_size" jq -e '
    .metadata.name == env.VOLUME_NAME and
    .spec.fromBackup == env.BACKUP_URL and .spec.size == env.VOLUME_SIZE and
    .spec.numberOfReplicas == 2 and
    .status.state == "detached" and .status.robustness == "unknown" and
    .status.restoreRequired == false and .status.replicaModeMap == {}
  ' "$volume_json" >/dev/null
}

nocodb_restore_validate_volume_attached() { # <volume-name> <backup-url> <volume-size> <volume-json>
	local volume_name="$1" backup_url="$2" volume_size="$3" volume_json="$4"
	VOLUME_NAME="$volume_name" BACKUP_URL="$backup_url" VOLUME_SIZE="$volume_size" jq -e '
    .metadata.name == env.VOLUME_NAME and
    .spec.fromBackup == env.BACKUP_URL and .spec.size == env.VOLUME_SIZE and
    .spec.numberOfReplicas == 2 and
    .status.state == "attached" and
    .status.robustness == "healthy" and .status.restoreRequired == false and
    ([.status.replicaModeMap[]] | length) == 2 and
    all(.status.replicaModeMap[]; . == "RW")
  ' "$volume_json" >/dev/null
}

nocodb_restore_resource_is_owned() { # <run-hash> <resource-json>
	local run_hash="$1" resource_json="$2"
	RUN_HASH="$run_hash" jq -e '
    .metadata.labels."homelab-talos/test" == "nocodb-restore-drill" and
    .metadata.labels."homelab-talos/run-id" == env.RUN_HASH
  ' "$resource_json" >/dev/null
}
