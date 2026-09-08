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
job_name=''
namespace='automation-data'
job_cleanup_pending=false
job_uid=''
temp_dir=''
captured_main_sha=''
run_marker=''

job_name_if_present() {
	local found
	found="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get job \
		"$job_name" --ignore-not-found --output name 2>/dev/null)" || {
		echo "Could not determine whether $namespace/$job_name exists." >&2
		return 1
	}
	case "$found" in
	'') ;;
	job.batch/"$job_name") printf '%s\n' "$found" ;;
	*)
		echo "Unexpected identity returned for $namespace/$job_name." >&2
		return 1
		;;
	esac
}

delete_owned_job() {
	local job_json observed_uid remaining delete_options
	job_json="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get job \
		"$job_name" --ignore-not-found --output json 2>/dev/null)" || {
		echo "Could not inspect run-owned Job $namespace/$job_name." >&2
		return 1
	}
	[[ -n "$job_json" ]] || return 0
	jq -e --arg marker "$run_marker" --arg name "$job_name" '
    .metadata.name == $name and
    .metadata.labels."homelab-talos/role" == "nocodb-platform-upgrade" and
    .metadata.labels."homelab-talos/run-id" == $marker
  ' >/dev/null <<<"$job_json" || {
		echo "Refusing to delete $namespace/$job_name because its run ownership differs." >&2
		return 1
	}
	observed_uid="$(jq -er '.metadata.uid | select(type == "string" and length > 0)' <<<"$job_json")" || return 1
	if [[ -n "$job_uid" && "$observed_uid" != "$job_uid" ]]; then
		echo "Refusing to delete $namespace/$job_name because its object identity changed." >&2
		return 1
	fi
	job_uid="$observed_uid"
	delete_options="$temp_dir/delete-job.json"
	jq -n --arg uid "$job_uid" '{
    apiVersion:"v1", kind:"DeleteOptions", propagationPolicy:"Foreground",
    preconditions:{uid:$uid}
  }' >"$delete_options"
	kubectl --kubeconfig "$kubeconfig" delete \
		--raw "/apis/batch/v1/namespaces/$namespace/jobs/$job_name" \
		--filename "$delete_options" >/dev/null || return 1
	kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" wait \
		--for=delete "job/$job_name" --timeout=2m >/dev/null || return 1
	remaining="$(job_name_if_present)" || return 1
	[[ -z "$remaining" ]] || {
		echo "Failed to prove removal of run-owned Job $namespace/$job_name." >&2
		return 1
	}
}

cleanup_upgrade() {
	local original_exit="$?" cleanup_failed=false
	trap - EXIT
	set +e
	if [[ "$job_cleanup_pending" == true ]]; then
		delete_owned_job || cleanup_failed=true
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
run_marker="${captured_main_sha:0:12}-$$-$RANDOM"
job_name="automation-data-nocodb-upgrade-$run_marker"

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
	local deployed_revision applied_state
	deployed_revision="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
		get gitrepository flux-system --output jsonpath='{.status.artifact.revision}')"
	[[ "$deployed_revision" == "main@sha1:$captured_main_sha" ]] || {
		echo 'Refusing automation-data upgrade: Flux does not serve captured origin/main.' >&2
		return 1
	}
	applied_state="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
		get kustomization automation-data-postgresql --output json)" || return 1
	CAPTURED_REVISION="main@sha1:$captured_main_sha" jq -e '
    .metadata.name == "automation-data-postgresql" and
    .metadata.generation == .status.observedGeneration and
    .status.lastAppliedRevision == env.CAPTURED_REVISION and
    any(.status.conditions[]?; .type == "Ready" and .status == "True")
  ' >/dev/null <<<"$applied_state" || {
		echo 'Refusing automation-data upgrade: PostgreSQL has not applied captured origin/main.' >&2
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
	local inventory
	inventory="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get jobs \
		--selector='homelab-talos/role=nocodb-platform-upgrade' --output json)" || return 1
	jq -e '.items | type == "array" and length == 0' >/dev/null <<<"$inventory" || {
		echo 'Refusing automation-data upgrade: another platform-upgrade Job exists.' >&2
		return 1
	}
}

render_expected_upgrade_configmap() { # <output-json>
	local output="$1" package_yaml="$temp_dir/postgresql-package.yaml"
	local package_json="$temp_dir/postgresql-package.json"
	kustomize build kubernetes/apps/automation-data/postgresql/app >"$package_yaml" || return 1
	# shellcheck disable=SC2016 # yq evaluates its own expression.
	yq ea -o=json -I=0 '. as $item ireduce ([]; . + [$item])' \
		"$package_yaml" >"$package_json" || return 1
	jq -e '
    [.[] | select(
      .kind == "ConfigMap" and .metadata.namespace == "automation-data" and
      (.metadata.name | test("^automation-data-postgresql-upgrade-[a-z0-9]+$")) and
      ((.data | keys | sort) == ["nocodb-extension.sql", "nocodb-metadata.sql", "upgrade-nocodb.sql"])
    )] | if length == 1 then .[0] else error("expected one rendered upgrade ConfigMap") end
  ' "$package_json" >"$output"
}

require_deployed_upgrade_configmap() { # <expected-json> <deployed-json>
	local expected="$1" deployed="$2" configmap_name
	configmap_name="$(jq -er '.metadata.name' "$expected")" || return 1
	kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get configmap \
		"$configmap_name" --output json >"$deployed" || return 1
	EXPECTED_CONFIGMAP="$expected" CONFIGMAP_NAME="$configmap_name" jq -e --slurpfile expected "$expected" '
    .kind == "ConfigMap" and .metadata.namespace == "automation-data" and
    .metadata.name == env.CONFIGMAP_NAME and
    (.binaryData // {}) == {} and .data == $expected[0].data
  ' "$deployed" >/dev/null
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
	local configmap_name="$1"
	JOB_NAME="$job_name" RUN_ID="$run_marker" CONFIGMAP_NAME="$configmap_name" \
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

report_job_failure() {
	local job_json pod_json raw_log failure
	job_json="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get job \
		"$job_name" --ignore-not-found --output json 2>/dev/null)" || return 1
	[[ -n "$job_json" ]] || return 1
	jq -r '
    "upgrade_job_state=active=" + ((.status.active // 0) | tostring) +
    ",succeeded=" + ((.status.succeeded // 0) | tostring) +
    ",failed=" + ((.status.failed // 0) | tostring),
    ((.status.conditions // [])[] |
      (.type // "Unknown") as $type |
      (.status // "Unknown") as $status |
      (.reason // "Unknown") as $reason |
      "upgrade_job_condition=" +
      (if ($type | test("^[A-Za-z0-9_.-]{1,64}$")) then $type else "Unknown" end) + ":" +
      (if ($status | test("^[A-Za-z0-9_.-]{1,64}$")) then $status else "Unknown" end) + ":" +
      (if ($reason | test("^[A-Za-z0-9_.-]{1,64}$")) then $reason else "Unknown" end))
  ' <<<"$job_json" >&2
	pod_json="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get pods \
		--selector="job-name=$job_name,homelab-talos/run-id=$run_marker" \
		--output json 2>/dev/null)" || return 1
	jq -r '
    if (.items | length) == 0 then "upgrade_pod_state=absent"
    else .items[] |
      (.status.phase // "Unknown") as $phase |
      ([.status.containerStatuses[]? | select(.name == "upgrade") |
        .state.terminated][0] // {}) as $terminated |
      "upgrade_pod_state=phase=" +
      (if ($phase | test("^[A-Za-z0-9_.-]{1,64}$")) then $phase else "Unknown" end) +
      ",reason=" +
      (if (($terminated.reason // "Unknown") | test("^[A-Za-z0-9_.-]{1,64}$"))
        then ($terminated.reason // "Unknown") else "Unknown" end) +
      ",exit_code=" + (($terminated.exitCode // -1) | tostring)
    end
  ' <<<"$pod_json" >&2
	raw_log="$temp_dir/failed-job.log"
	if kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" logs "job/$job_name" \
		--container=upgrade >"$raw_log" 2>/dev/null; then
		failure="$(rg -o -m1 'platform_upgrade_already_running|unknown_platform_revision|incomplete_nocodb_extension|invalid_nocodb_[a-z_]+|incompatible_pre_extension_[a-z_]+' "$raw_log" || true)"
		[[ -z "$failure" ]] || printf 'upgrade_failure=%s\n' "$failure" >&2
	fi
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

expected_configmap="$temp_dir/expected-upgrade-configmap.json"
render_expected_upgrade_configmap "$expected_configmap" || {
	echo 'Refusing automation-data upgrade: captured source did not render one exact upgrade ConfigMap.' >&2
	exit 1
}
configmap_name="$(jq -er '.metadata.name' "$expected_configmap")"
deployed_configmap="$temp_dir/deployed-upgrade-configmap.json"
require_deployed_upgrade_configmap "$expected_configmap" "$deployed_configmap" || {
	echo 'Refusing automation-data upgrade: deployed upgrade ConfigMap differs from captured source.' >&2
	exit 1
}

require_source
require_deployed_revision
require_target
just kube automation-data-verify >/dev/null
require_no_overlap
require_deployed_upgrade_configmap "$expected_configmap" "$deployed_configmap" || {
	echo 'Refusing automation-data upgrade: deployed upgrade ConfigMap changed before Job creation.' >&2
	exit 1
}

job_cleanup_pending=true
if ! render_job "$configmap_name" | kubectl --kubeconfig "$kubeconfig" \
	--namespace "$namespace" create --filename - >/dev/null; then
	echo 'The fixed automation-data upgrade Job create response was ambiguous.' >&2
	exit 1
fi
created_job_json="$temp_dir/created-job.json"
kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get job \
	"$job_name" --output json >"$created_job_json" || {
	echo 'The created automation-data upgrade Job could not be read back.' >&2
	exit 1
}
job_uid="$(RUN_ID="$run_marker" JOB_NAME="$job_name" jq -er '
  select(
    .metadata.name == env.JOB_NAME and
    .metadata.labels."homelab-talos/role" == "nocodb-platform-upgrade" and
    .metadata.labels."homelab-talos/run-id" == env.RUN_ID
  ) | .metadata.uid | select(type == "string" and length > 0)
' "$created_job_json")" || {
	echo 'The created automation-data upgrade Job did not retain its exact object identity.' >&2
	exit 1
}

if ! kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" wait \
	--for=condition=Complete "job/$job_name" --timeout=5m >/dev/null; then
	echo 'The fixed automation-data upgrade Job did not complete.' >&2
	report_job_failure || echo 'upgrade_job_diagnostics=unavailable' >&2
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

delete_owned_job
job_cleanup_pending=false

trap - EXIT
rm -rf -- "$temp_dir"
temp_dir=''
printf 'installed_revision=%s\n' "$expected_revision"
printf '%s\n' 'extension_contract_valid=true'
