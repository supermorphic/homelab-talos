#!/usr/bin/env bash
# Apply the fixed 026 NocoDB extension to the accepted automation-data platform.
set -euo pipefail
set +x

[[ "$#" -eq 1 ]] || {
	echo 'Usage: automation-data.sh <kubeconfig>' >&2
	exit 2
}

kubeconfig="$1"
expected_origin='https://github.com/supermorphic/homelab-talos.git'
expected_confirmation='upgrade:automation-data:nocodb-v1'
expected_revision='026-nocodb-v1'
job_name='automation-data-nocodb-upgrade'
namespace='automation-data'
job_created=false
temp_dir=''
captured_main_sha=''

cleanup_upgrade() {
	local original_exit="$?" cleanup_failed=false
	trap - EXIT
	set +e
	if [[ "$job_created" == true ]]; then
		kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" delete job \
			"$job_name" --wait=true --timeout=2m >/dev/null || cleanup_failed=true
		if kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get job \
			"$job_name" --output json >/dev/null 2>&1; then
			cleanup_failed=true
		fi
	fi
	[[ -z "$temp_dir" ]] || rm -rf -- "$temp_dir" || cleanup_failed=true
	set -e
	if [[ "$cleanup_failed" == true ]]; then
		echo "Failed to remove run-owned Job $namespace/$job_name." >&2
		exit 1
	fi
	exit "$original_exit"
}
trap cleanup_upgrade EXIT

[[ -f "$kubeconfig" ]] || {
	echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
	exit 1
}
[[ "$(git remote get-url origin)" == "$expected_origin" ]] || {
	echo "Refusing automation-data upgrade: origin must be $expected_origin." >&2
	exit 1
}
remote_record="$(git ls-remote --exit-code origin refs/heads/main)" || {
	echo 'Refusing automation-data upgrade: cannot resolve authoritative origin/main.' >&2
	exit 1
}
read -r captured_main_sha remote_ref extra_remote_field <<<"$remote_record"
[[ "$captured_main_sha" =~ ^[0-9a-f]{40}$ && "$remote_ref" == refs/heads/main &&
	-z "${extra_remote_field:-}" ]] || {
	echo 'Refusing automation-data upgrade: origin/main returned an invalid authority record.' >&2
	exit 1
}
git cat-file -e "${captured_main_sha}^{commit}" 2>/dev/null || {
	echo 'Refusing automation-data upgrade: captured origin/main is unavailable locally.' >&2
	exit 1
}

umask 077
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-upgrade.XXXXXX")"
chmod 700 "$temp_dir"

require_source() {
	local -a source_paths=(
		kubernetes/mod.just
		scripts/upgrade/automation-data.sh
		scripts/validate/automation-data.sh
		scripts/verify/automation-data.sh
		kubernetes/apps/automation-data/postgresql/app
	)
	[[ -z "$(git status --porcelain)" ]] || {
		echo 'Refusing automation-data upgrade: checkout must be clean.' >&2
		return 1
	}
	git diff --quiet "$captured_main_sha" -- "${source_paths[@]}" || {
		echo 'Refusing automation-data upgrade: fixed upgrade source differs from deployed origin/main.' >&2
		return 1
	}
}

require_deployed_revision() {
	local deployed_revision
	deployed_revision="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
		get gitrepository flux-system --output jsonpath='{.status.artifact.revision}')"
	[[ "$deployed_revision" == "main@sha1:$captured_main_sha" ]] || {
		echo 'Refusing automation-data upgrade: Flux does not serve captured origin/main.' >&2
		return 1
	}
}

require_target() {
	local state
	state="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
		get statefulset automation-data-postgresql --output json)"
	jq -e '
    .metadata.name == "automation-data-postgresql" and
    .metadata.generation == .status.observedGeneration and
    .spec.serviceName == "automation-data-postgresql" and
    .spec.replicas == 1 and .status.readyReplicas == 1 and
    .status.currentRevision == .status.updateRevision and
    ([.spec.template.spec.containers[] | select(
      .name == "postgresql" and .image == "postgres:17.11-alpine3.24"
    )] | length) == 1
  ' >/dev/null <<<"$state" || {
		echo 'Refusing automation-data upgrade: live PostgreSQL target identity is wrong or not Ready.' >&2
		return 1
	}
}

require_no_overlap() {
	if kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get job \
		"$job_name" --output json >/dev/null 2>&1; then
		echo "Refusing automation-data upgrade: $namespace/$job_name already exists." >&2
		return 1
	fi
}

resolve_upgrade_configmap() {
	local inventory="$1"
	jq -er '
    [.items[] | select(
      (.metadata.name | startswith("automation-data-postgresql-upgrade-")) and
      ((.data | keys | sort) == ["nocodb-extension.sql", "upgrade-nocodb.sql"])
    ) | .metadata.name] |
    if length == 1 then .[0] else error("expected one generated upgrade ConfigMap") end
  ' "$inventory"
}

require_preconditions() {
	require_source
	just kube automation-data-validate >/dev/null
	require_deployed_revision
	require_target
	# This read-only verifier supplies the current complete-backup prerequisite.
	just kube automation-data-verify >/dev/null
	require_no_overlap
}

render_job() {
	local configmap_name="$1" run_id="${captured_main_sha:0:12}"
	JOB_NAME="$job_name" RUN_ID="$run_id" CONFIGMAP_NAME="$configmap_name" \
		yq --null-input --output-format yaml '
      {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {
          "name": strenv(JOB_NAME),
          "namespace": "automation-data",
          "labels": {
            "app.kubernetes.io/name": "automation-data-postgresql-backup",
            "homelab-talos/role": "nocodb-platform-upgrade",
            "homelab-talos/run-id": strenv(RUN_ID)
          }
        },
        "spec": {
          "activeDeadlineSeconds": 300,
          "backoffLimit": 0,
          "template": {
            "metadata": {"labels": {
              "app.kubernetes.io/name": "automation-data-postgresql-backup",
              "homelab-talos/role": "nocodb-platform-upgrade",
              "homelab-talos/run-id": strenv(RUN_ID)
            }},
            "spec": {
              "automountServiceAccountToken": false,
              "restartPolicy": "Never",
              "securityContext": {
                "runAsNonRoot": true, "runAsUser": 70, "runAsGroup": 70,
                "seccompProfile": {"type": "RuntimeDefault"}
              },
              "containers": [{
                "name": "upgrade",
                "image": "postgres:17.11-alpine3.24",
                "imagePullPolicy": "IfNotPresent",
                "command": ["psql"],
                "args": [
                  "--no-psqlrc", "--no-align", "--tuples-only",
                  "--set=ON_ERROR_STOP=1", "--file=/scripts/upgrade-nocodb.sql"
                ],
                "env": [
                  {"name": "PGDATABASE", "value": "automation_data_control"},
                  {"name": "PGHOST", "value": "automation-data-postgresql"},
                  {"name": "PGPORT", "value": "5432"},
                  {"name": "PGUSER", "value": "automation_data_backup"},
                  {"name": "PGPASSWORD", "valueFrom": {"secretKeyRef": {
                    "name": "postgresql-credentials", "key": "backup-password"
                  }}}
                ],
                "resources": {
                  "requests": {"cpu": "10m", "memory": "32Mi"},
                  "limits": {"memory": "128Mi"}
                },
                "securityContext": {
                  "allowPrivilegeEscalation": false,
                  "capabilities": {"drop": ["ALL"]},
                  "readOnlyRootFilesystem": true
                },
                "volumeMounts": [
                  {"name": "scripts", "mountPath": "/scripts", "readOnly": true},
                  {"name": "tmp", "mountPath": "/tmp"}
                ]
              }],
              "volumes": [
                {"name": "scripts", "configMap": {"name": strenv(CONFIGMAP_NAME)}},
                {"name": "tmp", "emptyDir": {}}
              ]
            }
          }
        }
      }
    '
}

# Reviewable preflight, attended confirmation, then the same safety-critical checks
# immediately before the only mutation.
require_preconditions
[[ "${AUTOMATION_DATA_UPGRADE_CONFIRM:-}" == "$expected_confirmation" ]] || {
	echo 'Refusing to apply the fixed automation-data NocoDB extension upgrade.' >&2
	echo "Set AUTOMATION_DATA_UPGRADE_CONFIRM='$expected_confirmation' after review." >&2
	exit 1
}
require_preconditions

configmap_inventory="$temp_dir/configmaps.json"
kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get configmaps \
	--output json >"$configmap_inventory"
configmap_name="$(resolve_upgrade_configmap "$configmap_inventory")" || {
	echo 'Refusing automation-data upgrade: exact generated upgrade ConfigMap is unavailable.' >&2
	exit 1
}

require_deployed_revision
require_target
just kube automation-data-verify >/dev/null
require_no_overlap

render_job "$configmap_name" | kubectl --kubeconfig "$kubeconfig" \
	--namespace "$namespace" create --filename - >/dev/null
job_created=true

if ! kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" wait \
	--for=condition=Complete "job/$job_name" --timeout=5m >/dev/null; then
	echo 'The fixed automation-data upgrade Job did not complete.' >&2
	exit 1
fi

job_output="$temp_dir/job-output"
kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" logs "job/$job_name" \
	--container=upgrade >"$job_output"
[[ "$(rg -c -x "installed_revision=$expected_revision" "$job_output")" == 1 ]] || {
	echo 'The upgrade Job did not read back the expected installed revision.' >&2
	exit 1
}
[[ "$(rg -c -x 'extension_contract_valid=true' "$job_output")" == 1 ]] || {
	echo 'The upgrade Job did not validate the installed extension contract.' >&2
	exit 1
}

kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" delete job \
	"$job_name" --wait=true --timeout=2m >/dev/null
if kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get job \
	"$job_name" --output json >/dev/null 2>&1; then
	echo "Failed to prove removal of run-owned Job $namespace/$job_name." >&2
	exit 1
fi
job_created=false

trap - EXIT
rm -rf -- "$temp_dir"
temp_dir=''
printf 'installed_revision=%s\n' "$expected_revision"
printf '%s\n' 'extension_contract_valid=true'
