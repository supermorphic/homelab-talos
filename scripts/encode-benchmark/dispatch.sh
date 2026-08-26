#!/usr/bin/env bash
set -euo pipefail

if (($# < 2)); then
	echo 'usage: dispatch.sh <kubeconfig> <capabilities|census|evidence-reader|findings|run|clean> ...' >&2
	exit 64
fi

kubeconfig="$1"
action="$2"
shift 2
namespace='media'
expected_api='https://192.168.90.20:6443'
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../.." && pwd)"
app_directory="$repository_root/kubernetes/apps/media/encode-benchmark/app"
template="$repository_root/kubernetes/apps/media/encode-benchmark/templates/job.yaml"
test_mode="${ENCODE_BENCHMARK_TEST_MODE:-0}"
handoff_wait_seconds=600

if [[ -n "${ENCODE_BENCHMARK_APP_DIR:-}" ]]; then
	[[ "$test_mode" == '1' ]] || {
		echo 'ENCODE_BENCHMARK_APP_DIR requires ENCODE_BENCHMARK_TEST_MODE=1' >&2
		exit 64
	}
	app_directory="$ENCODE_BENCHMARK_APP_DIR"
fi
if [[ -n "${ENCODE_BENCHMARK_HANDOFF_WAIT_SECONDS:-}" ]]; then
	[[ "$test_mode" == '1' ]] || {
		echo 'ENCODE_BENCHMARK_HANDOFF_WAIT_SECONDS requires ENCODE_BENCHMARK_TEST_MODE=1' >&2
		exit 64
	}
	handoff_wait_seconds="$ENCODE_BENCHMARK_HANDOFF_WAIT_SECONDS"
fi
[[ "$handoff_wait_seconds" =~ ^[0-9]+$ ]] || {
	echo 'invalid running image handoff wait' >&2
	exit 64
}
# shellcheck disable=SC1091
source "$app_directory/scripts/contract.sh"

temp_directory=''
remote_cleanup_armed=0
remote_job=''
remote_configmap=''
cleanup_dispatch() {
	if [[ "$remote_cleanup_armed" == '1' ]]; then
		if [[ -n "$remote_configmap" ]]; then
			kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" delete \
				"configmap/$remote_configmap" --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
		fi
		if [[ -n "$remote_job" ]]; then
			kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" delete \
				"job/$remote_job" --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
		fi
	fi
	if [[ -n "$temp_directory" ]]; then
		rm -rf -- "$temp_directory"
	fi
}
trap cleanup_dispatch EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

validate_run_id() {
	contract_is_run_id "$1" || {
		echo "invalid run id: $1" >&2
		return 64
	}
}

validate_sample_id() {
	[[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || {
		echo "invalid sample id: $1" >&2
		return 64
	}
}

validate_client_device_label() {
	[[ "$1" =~ ^[a-z0-9][a-z0-9._-]{0,62}$ ]] || {
		echo "invalid contention client device label: $1" >&2
		return 64
	}
}

validate_node_name() {
	[[ "$1" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ && ${#1} -le 253 ]] || {
		echo "invalid node name: $1" >&2
		return 64
	}
}

require_confirmation() {
	local variable="$1" expected="$2"
	[[ "${!variable:-}" == "$expected" ]] || {
		echo "Refusing benchmark dispatch: set $variable=$expected" >&2
		return 1
	}
}

require_diagnostic_capability_evidence() {
	local nodes
	nodes="$(contract_passing_diagnostic_nodes "$samples_document")" || return
	[[ -n "$nodes" ]] || {
		echo 'diagnostic capability evidence is missing malformed stale or bound to another image' >&2
		return 65
	}
	printf '%s\n' "$nodes" | head -n 1
}

require_cluster_target() {
	local api_server
	[[ -f "$kubeconfig" ]] || {
		echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
		return 1
	}
	api_server="$(kubectl --kubeconfig "$kubeconfig" config view --minify \
		--output jsonpath='{.clusters[0].cluster.server}')"
	[[ "$api_server" == "$expected_api" ]] || {
		echo "Refusing benchmark dispatch: kubeconfig targets $api_server, not $expected_api." >&2
		return 1
	}
}

load_source() {
	local render scripts_count
	temp_directory="$(mktemp -d "${TMPDIR:-/tmp}/encode-benchmark-dispatch.XXXXXX")"
	render="$temp_directory/app.yaml"
	kustomize build "$app_directory" >"$render"
	scripts_count="$(yq -N -r 'select(.kind == "ConfigMap" and (.metadata.name | test("^encode-benchmark-scripts-[a-z0-9]{10}$"))) | .metadata.name' "$render" | wc -l | tr -d ' ')"
	[[ "$scripts_count" == '1' ]] || {
		echo 'rendered source does not contain exactly one current scripts ConfigMap' >&2
		return 65
	}
	scripts_configmap="$(yq -N -r 'select(.kind == "ConfigMap" and (.metadata.name | test("^encode-benchmark-scripts-[a-z0-9]{10}$"))) | .metadata.name' "$render")"
	samples_document="$temp_directory/samples.json"
	yq -e -r '.data."samples.json"' "$app_directory/samples.yaml" >"$samples_document"
	contract_load "$samples_document" || return
	contract_validate_chosen_settings "$samples_document" || {
		echo 'committed chosen settings are malformed' >&2
		return 65
	}
	configured_image="$(yq -e -r '.runtime.image | select(test("^[^@[:space:]]+@sha256:[0-9a-f]{64}$"))' "$samples_document")"
	[[ -f "$template" ]] || {
		echo 'benchmark Job template is missing' >&2
		return 66
	}
}

require_capability_evidence() {
	local -a capability_nodes
	mapfile -t capability_nodes < <(contract_passing_icq_nodes "$samples_document")
	if ((${#capability_nodes[@]} > 0)); then
		return 0
	fi
	echo 'Refusing benchmark dispatch: committed schema-v3 ICQ capability evidence has no current passing node.' >&2
	return 1
}

require_deployed_diagnostics_contract() {
	local configmap_json deployed_document deployed_accept deployed_decision
	local deployed_quality_run deployed_findings_run deployed_panel_sha committed_panel_sha
	configmap_json="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get \
		configmap/encode-benchmark-samples --output json)" || return
	deployed_document="$temp_directory/deployed-samples.json"
	yq -p=json -e -r '.data."samples.json"' <<<"$configmap_json" >"$deployed_document" || {
		echo 'deployed diagnostics contract is missing or malformed' >&2
		return 65
	}
	contract_validate_diagnostics_scope "$deployed_document" >/dev/null || {
		echo 'deployed diagnostics contract is missing or malformed' >&2
		return 65
	}
	deployed_accept="$(jq -r '.diagnostics.acceptedFindingsSha256' "$deployed_document")"
	[[ "$deployed_accept" == "$CONTRACT_DIAGNOSTICS_ACCEPTED_FINDINGS_SHA256" ]] || {
		echo 'deployed diagnostics accepted findings digest does not match committed source' >&2
		return 65
	}
	deployed_decision="$(jq -r '.diagnostics.decisionSha256' "$deployed_document")"
	[[ "$deployed_decision" == "$CONTRACT_DIAGNOSTICS_DECISION_SHA256" ]] || {
		echo 'deployed diagnostics decision digest does not match committed source' >&2
		return 65
	}
	deployed_quality_run="$(jq -r '.diagnostics.historicalQualityRunId' "$deployed_document")"
	deployed_findings_run="$(jq -r '.diagnostics.historicalFindingsRunId' "$deployed_document")"
	[[ "$deployed_quality_run" == "$CONTRACT_DIAGNOSTICS_HISTORICAL_QUALITY_RUN_ID" &&
		"$deployed_findings_run" == "$CONTRACT_DIAGNOSTICS_HISTORICAL_FINDINGS_RUN_ID" ]] || {
		echo 'deployed diagnostics historical run references do not match committed source' >&2
		return 65
	}
	deployed_panel_sha="$(contract_diagnostics_panel_sha256 "$deployed_document")" || {
		echo 'deployed diagnostics panel identity is malformed' >&2
		return 65
	}
	committed_panel_sha="$(contract_diagnostics_panel_sha256 "$samples_document")" || {
		echo 'committed diagnostics panel identity is malformed' >&2
		return 65
	}
	[[ "$deployed_panel_sha" == "$committed_panel_sha" ]] || {
		echo 'deployed diagnostics panel identity does not match committed source' >&2
		return 65
	}
}

require_diagnostics_run_id() {
	local run_id="$1"
	[[ "$run_id" != "$CONTRACT_DIAGNOSTICS_HISTORICAL_QUALITY_RUN_ID" ]] || {
		echo "diagnostics run id reuses the historical quality run id: $run_id" >&2
		return 65
	}
	[[ "$run_id" != "$CONTRACT_DIAGNOSTICS_HISTORICAL_FINDINGS_RUN_ID" ]] || {
		echo "diagnostics run id reuses the historical findings run id: $run_id" >&2
		return 65
	}
}

contention_passing_nodes() {
	local required="$1"
	mapfile -t contention_nodes < <(contract_passing_icq_nodes "$samples_document")
	((${#contention_nodes[@]} >= required)) || {
		echo "contention requires $required distinct committed passing capability nodes" >&2
		return 65
	}
}

require_contention_playback_sample() {
	local sample_id="$1" count
	count="$(PLAYBACK_SAMPLE_ID="$sample_id" jq -r '[.qualityPanel[]? | select(
		.id == env.PLAYBACK_SAMPLE_ID and .cohort == "hdr10" and .width == 3840 and .height == 2160 and
		(.detectionOnly // false) == false
	)] | length' "$samples_document")"
	[[ "$count" == '1' ]] || {
		echo "contention playback sample must be one committed 3840x2160 HDR10 non-DV quality title: $sample_id" >&2
		return 65
	}
}

new_run_id() {
	local mode="$1" now correlation
	if [[ -n "${ENCODE_BENCHMARK_NOW:-}" ]]; then
		[[ "$test_mode" == '1' ]] || {
			echo 'ENCODE_BENCHMARK_NOW requires ENCODE_BENCHMARK_TEST_MODE=1' >&2
			return 64
		}
		now="$ENCODE_BENCHMARK_NOW"
	else
		now="$(date -u '+%Y%m%dT%H%M%SZ')"
	fi
	contract_is_compact_utc_timestamp "$now" || {
		echo "invalid benchmark timestamp: $now" >&2
		return 64
	}
	correlation="$(printf '%s\n' "$now|$mode|$scripts_configmap|$configured_image" | sha256sum | awk '{print substr($1, 1, 8)}')"
	printf '%s-%s\n' "$now" "$correlation"
}

ensure_run_available() {
	local run_id="$1" existing
	existing="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get jobs \
		--selector "app.kubernetes.io/name=encode-benchmark,homelab-talos/benchmark-run=$run_id" \
		--output json)"
	[[ "$(yq -p=json -r '.items | length' <<<"$existing")" == '0' ]] || {
		echo "generated benchmark run already has owned Jobs: $run_id" >&2
		return 73
	}
}

require_terminal_diagnostics_job() {
	local run_id="$1" existing expected_name
	expected_name="encode-benchmark-diagnostics-${run_id,,}"
	existing="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get jobs \
		--selector "app.kubernetes.io/name=encode-benchmark,homelab-talos/benchmark-run=$run_id,homelab-talos/benchmark-mode=diagnostics" \
		--output json)"
	jq -e --arg run "$run_id" --arg name "$expected_name" '
		(.items | type == "array" and length == 1) and (.items[0] |
		.metadata.name == $name and
		.metadata.labels."app.kubernetes.io/name" == "encode-benchmark" and
		.metadata.labels."homelab-talos/benchmark-dispatch" == $run and
		.metadata.labels."homelab-talos/benchmark-run" == $run and
		.metadata.labels."homelab-talos/benchmark-mode" == "diagnostics" and
		.metadata.annotations."homelab-talos/benchmark-owned" == "true" and
		((.status.active // 0) == 0) and
		([.status.conditions[]? | select((.type == "Complete" or .type == "Failed") and .status == "True")] | length == 1))
	' <<<"$existing" >/dev/null || {
		echo "diagnostic evidence reader requires one terminal owned diagnostics Job: $run_id" >&2
		return 65
	}
}

ensure_evidence_reader_available() {
	local run_id="$1" name exact existing
	name="encode-benchmark-evidence-reader-${run_id,,}"
	exact="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get "job/$name" \
		--ignore-not-found --output json)" || {
		echo "diagnostic evidence reader availability query failed: $run_id" >&2
		return 65
	}
	[[ -z "$exact" ]] || {
		echo "diagnostic evidence reader Job already exists for run: $run_id" >&2
		return 73
	}
	existing="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get jobs \
		--selector "app.kubernetes.io/name=encode-benchmark,homelab-talos/benchmark-run=$run_id,homelab-talos/benchmark-mode=diagnostic-evidence-reader" \
		--output json)" || {
		echo "diagnostic evidence reader availability query failed: $run_id" >&2
		return 65
	}
	[[ "$(yq -p=json -r '.items | length' <<<"$existing")" == '0' ]] || {
		echo "diagnostic evidence reader Job already exists for run: $run_id" >&2
		return 73
	}
}

render_job() {
	local output="$1" mode="$2" run_id="$3" dispatch_id="$4" worker="$5" name="$6"
	shift 6
	local command_json image_configmap
	command_json="$(jq -n -c '$ARGS.positional' --args -- "$@")"
	image_configmap="$(image_evidence_configmap_name "$name")"
	cp "$template" "$output"
	JOB_NAME="$name" RUN_ID="$run_id" DISPATCH_ID="$dispatch_id" MODE="$mode" IMAGE="$configured_image" \
		SCRIPTS_CONFIGMAP="$scripts_configmap" IMAGE_CONFIGMAP="$image_configmap" COMMAND_JSON="$command_json" yq -i '
		.metadata.name = strenv(JOB_NAME) |
		.metadata.labels."app.kubernetes.io/name" = "encode-benchmark" |
		.metadata.labels."homelab-talos/benchmark-dispatch" = strenv(DISPATCH_ID) |
		.metadata.labels."homelab-talos/benchmark-run" = strenv(RUN_ID) |
		.metadata.labels."homelab-talos/benchmark-mode" = strenv(MODE) |
		.metadata.annotations."homelab-talos/benchmark-owned" = "true" |
		.metadata.annotations."homelab-talos/scripts-configmap" = strenv(SCRIPTS_CONFIGMAP) |
		.metadata.annotations."homelab-talos/image-evidence-configmap" = strenv(IMAGE_CONFIGMAP) |
		.spec.template.metadata.labels."app.kubernetes.io/name" = "encode-benchmark" |
		.spec.template.metadata.labels."homelab-talos/benchmark-dispatch" = strenv(DISPATCH_ID) |
		.spec.template.metadata.labels."homelab-talos/benchmark-run" = strenv(RUN_ID) |
		.spec.template.metadata.labels."homelab-talos/benchmark-mode" = strenv(MODE) |
		.spec.template.spec.containers[0].image = strenv(IMAGE) |
		.spec.template.spec.containers[0].command = (strenv(COMMAND_JSON) | from_json) |
		.spec.template.spec.containers[0].env += [{"name":"BENCHMARK_DISPATCH_IMAGE","value":strenv(IMAGE)}] |
		(.spec.template.spec.volumes[] | select(.name == "scripts") | .configMap.name) = strenv(SCRIPTS_CONFIGMAP) |
		(.spec.template.spec.volumes[] | select(.name == "image-evidence") | .configMap.name) = strenv(IMAGE_CONFIGMAP)
	' "$output"
	if [[ -n "$worker" ]]; then
		WORKER="$worker" yq -i '
			.metadata.labels."homelab-talos/benchmark-worker" = strenv(WORKER) |
			.spec.template.metadata.labels."homelab-talos/benchmark-worker" = strenv(WORKER)
		' "$output"
	fi
}

remove_mounts_and_volumes() {
	local job="$1"
	shift
	local name
	for name in "$@"; do
		VOLUME_NAME="$name" yq -i '
			.spec.template.spec.containers[0].volumeMounts |= map(select(.name != strenv(VOLUME_NAME))) |
			.spec.template.spec.volumes |= map(select(.name != strenv(VOLUME_NAME)))
		' "$job"
	done
}

create_job() {
	local job="$1"
	kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" create \
		--filename "$job" --output json
}

image_evidence_configmap_name() {
	local name_hash
	name_hash="$(printf '%s\n' "$1" | sha256sum | awk '{print substr($1, 1, 12)}')"
	printf 'encode-benchmark-image-%s\n' "$name_hash"
}

normalize_image_id() {
	local image_id="$1" stripped
	stripped="${image_id#docker-pullable://}"
	stripped="${stripped#containerd://}"
	[[ "$stripped" =~ ^([^@[:space:]]+@)?sha256:[0-9a-f]{64}$ ]] || return 65
	printf '%s\n' "$stripped"
}

has_exact_job_controller_owner() {
	local resource_json="$1" job_name="$2" job_uid="$3"
	jq -e --arg name "$job_name" --arg uid "$job_uid" '
		.metadata.ownerReferences as $owners |
		($owners | type == "array" and length == 1) and
		$owners[0].apiVersion == "batch/v1" and
		$owners[0].kind == "Job" and
		$owners[0].name == $name and
		$owners[0].uid == $uid and
		$owners[0].controller == true and
		$owners[0].blockOwnerDeletion == true
	' <<<"$resource_json" >/dev/null 2>&1
}

delete_created_job() {
	local job_json="$1" job="$2" name uid dispatch_id run_id mode expected_name expected_dispatch expected_run expected_mode live_job
	name="$(yq -p=json -e -r '.metadata.name | select(test("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$"))' <<<"$job_json")" || return 0
	uid="$(yq -p=json -e -r '.metadata.uid | select(test("^[a-zA-Z0-9._-]+$"))' <<<"$job_json")" || return 0
	dispatch_id="$(yq -p=json -e -r '.metadata.labels."homelab-talos/benchmark-dispatch" | select(test("^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$"))' <<<"$job_json")" || return 0
	run_id="$(yq -p=json -e -r '.metadata.labels."homelab-talos/benchmark-run" | select(test("^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$"))' <<<"$job_json")" || return 0
	mode="$(yq -p=json -e -r '.metadata.labels."homelab-talos/benchmark-mode" | select(test("^[a-z][a-z0-9-]*$"))' <<<"$job_json")" || return 0
	[[ "$(yq -p=json -r '.metadata.labels."app.kubernetes.io/name" // ""' <<<"$job_json")" == 'encode-benchmark' &&
	"$(yq -p=json -r '.metadata.annotations."homelab-talos/benchmark-owned" // ""' <<<"$job_json")" == 'true' ]] || return 0
	expected_name="$(yq -e -r '.metadata.name | select(test("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$"))' "$job")" || return 0
	expected_dispatch="$(yq -e -r '.metadata.labels."homelab-talos/benchmark-dispatch" | select(test("^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$"))' "$job")" || return 0
	expected_run="$(yq -e -r '.metadata.labels."homelab-talos/benchmark-run" | select(test("^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$"))' "$job")" || return 0
	expected_mode="$(yq -e -r '.metadata.labels."homelab-talos/benchmark-mode" | select(test("^[a-z][a-z0-9-]*$"))' "$job")" || return 0
	[[ "$name" == "$expected_name" && "$dispatch_id" == "$expected_dispatch" &&
		"$run_id" == "$expected_run" && "$mode" == "$expected_mode" ]] || return 0
	live_job="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get \
		"job/$name" --output json 2>/dev/null)" || return 0
	jq -e --arg name "$name" --arg uid "$uid" --arg dispatch "$dispatch_id" \
		--arg run "$run_id" --arg mode "$mode" '
		.metadata.name == $name and .metadata.uid == $uid and
		.metadata.labels."app.kubernetes.io/name" == "encode-benchmark" and
		.metadata.labels."homelab-talos/benchmark-dispatch" == $dispatch and
		.metadata.labels."homelab-talos/benchmark-run" == $run and
		.metadata.labels."homelab-talos/benchmark-mode" == $mode and
		.metadata.annotations."homelab-talos/benchmark-owned" == "true"
	' <<<"$live_job" >/dev/null 2>&1 || return 0
	kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" delete \
		"job/$name" --preconditions="uid=$uid" --wait=true >/dev/null 2>&1 || true
}

delete_created_findings_inputs() {
	local configmap_json="$1" job_json="$2" name uid job_name job_uid persisted
	name="$(yq -p=json -e -r '.metadata.name | select(test("^encode-benchmark-findings-inputs-[a-z0-9-]+$"))' <<<"$configmap_json")" || return 0
	uid="$(yq -p=json -e -r '.metadata.uid | select(test("^[a-zA-Z0-9._-]+$"))' <<<"$configmap_json")" || return 0
	job_name="$(yq -p=json -e -r '.metadata.name' <<<"$job_json")" || return 0
	job_uid="$(yq -p=json -e -r '.metadata.uid' <<<"$job_json")" || return 0
	persisted="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get "configmap/$name" --output json 2>/dev/null)" || return 0
	[[ "$(yq -p=json -r '.metadata.uid // ""' <<<"$persisted")" == "$uid" ]] || return 0
	has_exact_job_controller_owner "$persisted" "$job_name" "$job_uid" || return 0
	kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" delete "configmap/$name" --preconditions="uid=$uid" --wait=true >/dev/null 2>&1 || true
}

establish_running_image_handoff() {
	local job_json="$1" job="$2" output_variable="$3"
	local name uid dispatched_image configured_digest dispatched_digest deadline pods pod_count
	local pod_name='' observed_pod_name pod_json pod_phase statuses_type status_count actual_image_id normalized_image_id running_digest
	local configmap_name evidence_json configmap configmap_json persisted persisted_evidence log_line
	printf -v "$output_variable" '%s' ''
	name="$(yq -p=json -e -r '.metadata.name | select(test("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$"))' <<<"$job_json")" || return 65
	uid="$(yq -p=json -e -r '.metadata.uid | select(test("^[a-zA-Z0-9._-]+$"))' <<<"$job_json")" || return 65
	[[ "$name" == "$(yq -r '.metadata.name' "$job")" ]] || return 65
	dispatched_image="$(yq -e -r '.spec.template.spec.containers[] | select(.name == "benchmark") | .image | select(test("^[^@[:space:]]+@sha256:[0-9a-f]{64}$"))' "$job")" || return 65
	configured_digest="${configured_image##*@}"
	dispatched_digest="${dispatched_image##*@}"
	[[ "$configured_image" == "$dispatched_image" && "$configured_digest" == "$dispatched_digest" ]] || {
		echo "running image evidence handoff rejected: job=$name configured-dispatched-mismatch" >&2
		return 65
	}
	deadline=$((SECONDS + handoff_wait_seconds))
	while :; do
		pods="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get pods \
			--selector "job-name=$name" --output json)" || return
		pod_count="$(yq -p=json -r '.items | length' <<<"$pods")"
		if [[ "$pod_count" == '0' ]]; then
			if [[ -n "$pod_name" ]]; then
				echo "running image evidence handoff rejected: job=$name controlled-pod-disappeared" >&2
				return 65
			fi
			if ((SECONDS >= deadline)); then
				echo "running image evidence handoff timed out: job=$name waiting-for-pod" >&2
				return 70
			fi
			sleep 1
			continue
		elif [[ "$pod_count" != '1' ]]; then
			echo "running image evidence handoff rejected: job=$name expected-one-pod" >&2
			return 65
		fi
		pod_json="$(jq -c '.items[0]' <<<"$pods")"
		observed_pod_name="$(jq -e -r '.metadata.name | strings | select(test("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$"))' <<<"$pod_json")" || return 65
		if [[ -z "$pod_name" ]]; then
			pod_name="$observed_pod_name"
		elif [[ "$pod_name" != "$observed_pod_name" ]]; then
			echo "running image evidence handoff rejected: job=$name controlled-pod-changed" >&2
			return 65
		fi
		has_exact_job_controller_owner "$pod_json" "$name" "$uid" || {
			echo "running image evidence handoff rejected: job=$name ownership-or-phase" >&2
			return 65
		}
		pod_phase="$(jq -r '.status.phase // ""' <<<"$pod_json")"
		[[ "$pod_phase" == 'Pending' || "$pod_phase" == 'Running' ]] || {
			echo "running image evidence handoff rejected: job=$name ownership-or-phase" >&2
			return 65
		}
		statuses_type="$(jq -r '.status.containerStatuses | if . == null then "missing" else type end' <<<"$pod_json")"
		if [[ "$statuses_type" == 'missing' ]]; then
			status_count=0
		elif [[ "$statuses_type" == 'array' ]]; then
			status_count="$(jq -r '[.status.containerStatuses[] | select(.name == "benchmark")] | length' <<<"$pod_json")"
			[[ "$status_count" == '0' || "$status_count" == '1' ]] || {
				echo "running image evidence handoff rejected: job=$name malformed-container-status" >&2
				return 65
			}
		else
			echo "running image evidence handoff rejected: job=$name malformed-container-status" >&2
			return 65
		fi
		actual_image_id=''
		if [[ "$status_count" == '1' ]]; then
			actual_image_id="$(jq -r '.status.containerStatuses[] | select(.name == "benchmark") | .imageID // ""' <<<"$pod_json")"
		fi
		if [[ -n "$actual_image_id" ]]; then
			normalized_image_id="$(normalize_image_id "$actual_image_id")" || {
				echo "running image evidence handoff rejected: job=$name malformed-imageID" >&2
				return 65
			}
			running_digest="${normalized_image_id##*@}"
			[[ "$running_digest" == "$configured_digest" && "$running_digest" == "$dispatched_digest" ]] || {
				echo "running image evidence handoff rejected: job=$name digest-mismatch" >&2
				return 65
			}
			break
		fi
		if ((SECONDS >= deadline)); then
			echo "running image evidence handoff timed out: job=$name waiting-for-imageID" >&2
			return 70
		fi
		sleep 1
	done
	configmap_name="$(yq -e -r '.metadata.annotations."homelab-talos/image-evidence-configmap" | select(test("^encode-benchmark-image-[0-9a-f]{12}$"))' "$job")" || return 65
	[[ "$configmap_name" == "$(image_evidence_configmap_name "$name")" ]] || return 65
	evidence_json="$(jq -n -c --arg configured "$configured_image" --arg dispatched "$dispatched_image" \
		--arg image_id "$normalized_image_id" '{configuredImage:$configured,dispatchedImage:$dispatched,imageId:$image_id}')"
	configmap="$temp_directory/$configmap_name.yaml"
	CONFIGMAP_NAME="$configmap_name" JOB_NAME="$name" JOB_UID="$uid" RUN_ID="$(yq -r '.metadata.labels."homelab-talos/benchmark-run"' "$job")" \
	MODE="$(yq -r '.metadata.labels."homelab-talos/benchmark-mode"' "$job")" EVIDENCE_JSON="$evidence_json" yq -n '
		.apiVersion = "v1" | .kind = "ConfigMap" |
		.metadata.name = strenv(CONFIGMAP_NAME) | .metadata.namespace = "media" |
		.metadata.labels."app.kubernetes.io/name" = "encode-benchmark" |
		.metadata.labels."homelab-talos/benchmark-run" = strenv(RUN_ID) |
		.metadata.labels."homelab-talos/benchmark-mode" = strenv(MODE) |
		.metadata.ownerReferences = [{"apiVersion":"batch/v1","kind":"Job","name":strenv(JOB_NAME),"uid":strenv(JOB_UID),"controller":true,"blockOwnerDeletion":true}] |
		.data."image.json" = strenv(EVIDENCE_JSON)
	' >"$configmap" || return
	# The API server can persist this deterministic object before the client sees
	# a failed response. Record its name first so rollback always attempts it.
	printf -v "$output_variable" '%s' "$configmap_name"
	configmap_json="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" create --filename "$configmap" --output json)" || return
	[[ "$(yq -p=json -r '.metadata.name // ""' <<<"$configmap_json")" == "$configmap_name" ]] || return 65
	persisted="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get "configmap/$configmap_name" --output json)" || return
	persisted_evidence="$(yq -p=json -e -r '.data."image.json"' <<<"$persisted")" || return 65
	if [[ "$(yq -p=json -r '.metadata.name // ""' <<<"$persisted")" != "$configmap_name" ]] ||
		! has_exact_job_controller_owner "$persisted" "$name" "$uid"; then
		echo "running image evidence handoff rejected: job=$name persisted-ownership" >&2
		return 65
	fi
	jq -e --argjson expected "$evidence_json" '. == $expected' <<<"$persisted_evidence" >/dev/null 2>&1 || {
		echo "running image evidence handoff rejected: job=$name persisted-evidence" >&2
		return 65
	}
	while :; do
		log_line="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" logs "pod/$pod_name" --container benchmark --tail=20 2>/dev/null || true)"
		if grep -q -F 'running_image_evidence=accepted' <<<"$log_line"; then
			return 0
		fi
		if ((SECONDS >= deadline)); then
			echo "running image evidence handoff timed out: job=$name waiting-for-runtime" >&2
			return 70
		fi
		sleep 1
	done
}

delete_owned_image_evidence() {
	local configmap_name="$1" job_json="$2" job_name job_uid persisted configmap_uid
	[[ "$configmap_name" =~ ^encode-benchmark-image-[0-9a-f]{12}$ ]] || return 0
	job_name="$(yq -p=json -e -r '.metadata.name | select(test("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$"))' <<<"$job_json")" || return 0
	job_uid="$(yq -p=json -e -r '.metadata.uid | select(test("^[a-zA-Z0-9._-]+$"))' <<<"$job_json")" || return 0
	persisted="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get \
		"configmap/$configmap_name" --output json 2>/dev/null)" || return 0
	configmap_uid="$(yq -p=json -e -r '.metadata.uid | select(test("^[a-zA-Z0-9._-]+$"))' <<<"$persisted")" || return 0
	[[ "$(yq -p=json -r '.metadata.name // ""' <<<"$persisted")" == "$configmap_name" ]] || return 0
	has_exact_job_controller_owner "$persisted" "$job_name" "$job_uid" || return 0
	kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" delete \
		"configmap/$configmap_name" --preconditions="uid=$configmap_uid" --wait=true >/dev/null 2>&1 || true
}

eligible_capability_nodes() {
	local nodes all_pods node_json name allocatable used free plex
	nodes="$(kubectl --kubeconfig "$kubeconfig" get nodes --output json)"
	all_pods="$(kubectl --kubeconfig "$kubeconfig" get pods --all-namespaces --output json)"
	while IFS= read -r node_json; do
		[[ -n "$node_json" ]] || continue
		name="$(yq -p=json -e -r '.metadata.name | select(test("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$"))' \
			<<<"$node_json")" || return 65
		allocatable="$(yq -p=json -r '.status.allocatable."gpu.intel.com/i915" // "0"' \
			<<<"$node_json")"
		[[ "$allocatable" =~ ^[0-9]+$ ]] || allocatable=0
		used="$(NODE_NAME="$name" jq -r '
			[
				.items[]
				| select(.spec.nodeName == env.NODE_NAME)
				| select(.status.phase != "Succeeded" and .status.phase != "Failed")
				| .spec.containers[]?.resources.requests."gpu.intel.com/i915" // "0"
				| tonumber
			] | add // 0
		' <<<"$all_pods")"
		free=$((allocatable - used))
		plex="$(NODE_NAME="$name" jq -r '
			[
				.items[]
				| select(.metadata.namespace == "media")
				| select(.metadata.labels."app.kubernetes.io/name" == "plex")
				| select(.status.phase == "Running" and .spec.nodeName == env.NODE_NAME)
			] | length
		' <<<"$all_pods")"
		if ((free > 0 && plex == 0)); then
			printf '%s\n' "$name"
		fi
	done < <(yq -p=json -o=json -I=0 '.items | sort_by(.metadata.name) | .[]' <<<"$nodes")
}

capability_job_name() {
	local run_id="${1,,}" node="$2"
	local prefix="encode-benchmark-cap-$run_id-node-" name node_hash max_node_length
	name="$prefix$node"
	if ((${#name} <= 63)); then
		printf '%s\n' "$name"
		return
	fi
	node_hash="$(printf '%s\n' "$node" | sha256sum | awk '{print substr($1, 1, 8)}')"
	max_node_length=$((63 - ${#prefix} - ${#node_hash} - 1))
	((max_node_length > 0)) || {
		echo 'capability Job name prefix leaves no room for node identity' >&2
		return 65
	}
	printf '%s%s-%s\n' "$prefix" "${node:0:max_node_length}" "$node_hash"
}

dispatch_capabilities() {
	local run_id job name node index cleanup_index job_json image_configmap=''
	local -a nodes=() jobs=() names=() created_names=() created_job_jsons=() created_configmaps=()
	require_confirmation ENCODE_BENCHMARK_CAPABILITIES_CONFIRM 'run:encode-benchmark:capabilities' || return
	load_source || return
	run_id="$(new_run_id capabilities)" || return
	require_cluster_target || return
	ensure_run_available "$run_id" || return
	mapfile -t nodes < <(eligible_capability_nodes)
	((${#nodes[@]} > 0)) || {
		echo 'no eligible non-Plex node has a free i915 slot for capability proof' >&2
		return 1
	}
	for node in "${nodes[@]}"; do
		name="$(capability_job_name "$run_id" "$node")" || return
		job="$temp_directory/$name.yaml"
		render_job "$job" capabilities "$run_id" "$run_id" '' "$name" /scripts/benchmark.sh capabilities
		remove_mounts_and_volumes "$job" media out
		NODE_NAME="$node" yq -i '
			.spec.activeDeadlineSeconds = 900 |
			del(.spec.template.spec.containers[0].resources.requests."ephemeral-storage") |
			del(.spec.template.spec.containers[0].resources.limits."ephemeral-storage") |
			.spec.template.spec.nodeSelector."kubernetes.io/hostname" = strenv(NODE_NAME)
		' "$job"
		jobs+=("$job")
		names+=("$name")
	done
	for index in "${!jobs[@]}"; do
		job="${jobs[$index]}"
		name="${names[$index]}"
		if ! job_json="$(create_job "$job")"; then
			for cleanup_index in "${!created_job_jsons[@]}"; do
				delete_created_job "${created_job_jsons[$cleanup_index]}" "${jobs[$cleanup_index]}"
			done
			return 1
		fi
		created_names+=("$name")
		created_job_jsons+=("$job_json")
	done
	for index in "${!jobs[@]}"; do
		image_configmap=''
		if ! establish_running_image_handoff "${created_job_jsons[$index]}" "${jobs[$index]}" image_configmap; then
			[[ -z "$image_configmap" ]] || created_configmaps+=("$image_configmap")
			for cleanup_index in "${!created_configmaps[@]}"; do
				delete_owned_image_evidence "${created_configmaps[$cleanup_index]}" \
					"${created_job_jsons[$cleanup_index]}"
			done
			for cleanup_index in "${!created_job_jsons[@]}"; do
				delete_created_job "${created_job_jsons[$cleanup_index]}" "${jobs[$cleanup_index]}"
			done
			return 1
		fi
		created_configmaps+=("$image_configmap")
	done
	printf 'run_id=%s nodes=%s jobs=%s\n' "$run_id" "${nodes[*]}" "${created_names[*]}"
}

dispatch_census() {
	local run_id job name job_json uid inventory inventory_mode configmap configmap_name
	local configmap_json persisted_configmap
	require_confirmation ENCODE_BENCHMARK_CENSUS_CONFIRM 'run:encode-benchmark:census' || return
	load_source || return
	run_id="$(new_run_id census)" || return
	require_cluster_target || return
	ensure_run_available "$run_id" || return
	inventory="$temp_directory/inodes.jsonl"
	umask 077
	if ! kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" exec -i \
		deployment/qbit-manage -- python - <"$script_directory/torrent-inventory.py" >"$inventory"; then
		return 1
	fi
	chmod 0600 "$inventory" || return
	inventory_mode="$(stat -c '%a' "$inventory" 2>/dev/null || stat -f '%Lp' "$inventory")"
	[[ "$inventory_mode" == '600' ]] || {
		echo 'census inventory staging is not mode 0600' >&2
		return 65
	}
	job="$temp_directory/census.yaml"
	name="encode-benchmark-census-${run_id,,}"
	configmap_name="encode-benchmark-inodes-${run_id,,}"
	render_job "$job" census "$run_id" "$run_id" '' "$name" \
		/scripts/census.sh /inventory/inodes.jsonl "/out/runs/$run_id"
	remove_mounts_and_volumes "$job" scratch image-evidence
	INVENTORY_CONFIGMAP="$configmap_name" yq -i '
		.spec.suspend = true |
		del(.spec.template.spec.affinity) |
		del(.spec.template.spec.containers[0].resources.requests."ephemeral-storage") |
		del(.spec.template.spec.containers[0].resources.limits."ephemeral-storage") |
		del(.spec.template.spec.containers[0].resources.requests."gpu.intel.com/i915") |
		del(.spec.template.spec.containers[0].resources.limits."gpu.intel.com/i915") |
		.spec.template.spec.containers[0].volumeMounts += [{"name":"inventory","mountPath":"/inventory/inodes.jsonl","subPath":"inodes.jsonl","readOnly":true}] |
		.spec.template.spec.volumes += [{"name":"inventory","configMap":{"name":strenv(INVENTORY_CONFIGMAP),"items":[{"key":"inodes.jsonl","path":"inodes.jsonl"}]}}]
	' "$job"
	remote_job="$name"
	remote_cleanup_armed=1
	job_json="$(create_job "$job")" || return
	[[ "$(yq -p=json -r '.metadata.name // ""' <<<"$job_json")" == "$name" ]] || return 65
	uid="$(yq -p=json -e -r '.metadata.uid | select(test("^[a-zA-Z0-9._-]+$"))' <<<"$job_json")" || return
	configmap="$temp_directory/inventory-configmap.yaml"
	INVENTORY_FILE="$inventory" CONFIGMAP_NAME="$configmap_name" JOB_NAME="$name" JOB_UID="$uid" RUN_ID="$run_id" yq -n '
		.apiVersion = "v1" |
		.kind = "ConfigMap" |
		.metadata.name = strenv(CONFIGMAP_NAME) |
		.metadata.namespace = "media" |
		.metadata.labels."app.kubernetes.io/name" = "encode-benchmark" |
		.metadata.labels."homelab-talos/benchmark-run" = strenv(RUN_ID) |
		.metadata.labels."homelab-talos/benchmark-mode" = "census" |
		.metadata.ownerReferences = [{
			"apiVersion":"batch/v1","kind":"Job","name":strenv(JOB_NAME),
			"uid":strenv(JOB_UID),"controller":true,"blockOwnerDeletion":true
		}] |
		.data."inodes.jsonl" = load_str(strenv(INVENTORY_FILE))
	' >"$configmap"
	remote_configmap="$configmap_name"
	configmap_json="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" create \
		--filename "$configmap" --output json)" || return
	[[ "$(yq -p=json -r '.metadata.name // ""' <<<"$configmap_json")" == "$configmap_name" ]] || return 65
	persisted_configmap="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get \
		"configmap/$configmap_name" --output json)" || return
	if [[ "$(yq -p=json -r '.metadata.name // ""' <<<"$persisted_configmap")" != "$configmap_name" ]] ||
		! has_exact_job_controller_owner "$persisted_configmap" "$name" "$uid"; then
		echo 'persisted census inventory ownership could not be proven' >&2
		return 65
	fi
	kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" patch "job/$name" \
		--type merge --patch '{"spec":{"suspend":false}}' >/dev/null || return
	remote_cleanup_armed=0
	remote_job=''
	remote_configmap=''
	printf 'run_id=%s job=%s inventory_configmap=%s\n' "$run_id" "$name" "$configmap_name"
}

contention_samples() {
	local contention_case="$1" candidates candidate cohort setting
	if [[ "$contention_case" == 'a' ]]; then
		mapfile -t candidates < <(yq -o=json -I=0 '
			[.qualityPanel[]? | select(
				.cohort == "hdr10" and .width == 3840 and .height == 2160 and
				(.detectionOnly // false) == false
			)]
			| sort_by(.id) | .[]
		' "$samples_document")
		((${#candidates[@]} >= 1)) || {
			echo 'no eligible 3840x2160 HDR10 quality sample for contention case a' >&2
			return 65
		}
		candidates=("${candidates[0]}")
	else
		mapfile -t candidates < <(yq -o=json -I=0 '
			[.qualityPanel[]? | select(
				(.cohort == "avc" or .cohort == "vc1") and
				.width == 1920 and .height == 1080 and
				(.detectionOnly // false) == false
			)] | sort_by(.id) | .[]
		' "$samples_document")
		((${#candidates[@]} >= 2)) || {
			echo "fewer than two eligible 1920x1080 non-DV quality samples for contention case $contention_case" >&2
			return 65
		}
		candidates=("${candidates[0]}" "${candidates[1]}")
	fi
	for candidate in "${candidates[@]}"; do
		validate_sample_id "$(jq -r '.id' <<<"$candidate")" || return
		cohort="$(jq -r '.cohort' <<<"$candidate")"
		setting="$(contract_chosen_record "$samples_document" "$cohort" final | jq -r '.globalQuality // ""')" || {
			echo "no final setting for contention sample cohort: $cohort" >&2
			return 65
		}
		contract_is_icq_setting "$samples_document" "$setting" || {
			echo "no final setting for contention sample cohort: $cohort" >&2
			return 65
		}
	done
	printf '%s\n' "${candidates[@]}"
}

require_finalist_authorization() {
	local sample_id="$1" sample cohort expected
	sample="$(SAMPLE_ID="$sample_id" jq -c '.qualityPanel[]? | select(.id == env.SAMPLE_ID)' "$samples_document")"
	[[ -n "$sample" && "$(wc -l <<<"$sample" | tr -d ' ')" == '1' ]] || {
		echo "finalist sample not found or duplicated: $sample_id" >&2
		return 66
	}
	cohort="$(jq -r '.cohort' <<<"$sample")"
	expected="$(contract_expected_finalist "$cohort")" || {
		echo "no finalist title for cohort: $cohort" >&2
		return 65
	}
	[[ "$sample_id" == "$expected" ]] || {
		echo "finalist sample does not match cohort: $cohort" >&2
		return 65
	}
	contract_chosen_record "$samples_document" "$cohort" provisional >/dev/null || {
		echo "chosen setting for $cohort is not provisional" >&2
		return 65
	}
}

require_savings_authorization() {
	local cohort final_found=0
	for cohort in avc vc1 hdr10; do
		if jq -e --arg cohort "$cohort" '
			.chosenSettings[$cohort] | type == "object" and .state == "final"
		' "$samples_document" >/dev/null; then
			contract_chosen_record "$samples_document" "$cohort" final >/dev/null || {
				echo "claimed final chosen setting is malformed for cohort: $cohort" >&2
				return 65
			}
			final_found=1
		fi
	done
	((final_found)) && return 0
	echo 'no final chosen setting authorizes savings' >&2
	return 65
}

require_x265_authorization() {
	local sample_id="$1" sample cohort
	sample="$(SAMPLE_ID="$sample_id" jq -c '
		.qualityPanel[]? | select(.id == env.SAMPLE_ID and .x265Reference == true and
			(.detectionOnly // false) == false and (.cohort == "avc" or .cohort == "hdr10"))
	' "$samples_document")"
	[[ -n "$sample" && "$(wc -l <<<"$sample" | tr -d ' ')" == '1' ]] || {
		echo "sample is not an x265 reference: $sample_id" >&2
		return 65
	}
	cohort="$(jq -r '.cohort' <<<"$sample")"
	contract_chosen_record "$samples_document" "$cohort" final >/dev/null || {
		echo "x265 requires a final chosen setting for cohort: $cohort" >&2
		return 65
	}
}

require_cpu_node() {
	local requested_node="$1" nodes pods match_count ready plex
	nodes="$(kubectl --kubeconfig "$kubeconfig" get nodes --output json)" || return
	pods="$(kubectl --kubeconfig "$kubeconfig" get pods --all-namespaces --output json)" || return
	match_count="$(NODE_NAME="$requested_node" jq -r '[.items[] | select(.metadata.name == env.NODE_NAME)] | length' <<<"$nodes")"
	[[ "$match_count" == '1' ]] || {
		echo "requested x265 node does not exist: $requested_node" >&2
		return 66
	}
	ready="$(NODE_NAME="$requested_node" jq -r '
		[.items[] | select(.metadata.name == env.NODE_NAME) |
			.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length
	' <<<"$nodes")"
	[[ "$ready" == '1' ]] || {
		echo "requested x265 node is not Ready: $requested_node" >&2
		return 65
	}
	plex="$(NODE_NAME="$requested_node" jq -r '[.items[] | select(
		.metadata.namespace == "media" and .metadata.labels."app.kubernetes.io/name" == "plex" and
		.status.phase == "Running" and .spec.nodeName == env.NODE_NAME)] | length' <<<"$pods")"
	[[ "$plex" == '0' ]] || {
		echo "requested x265 node runs Plex: $requested_node" >&2
		return 65
	}
}

dispatch_run() {
	local mode="${1:-}" supplied_run_id='' supplied_run_pair='' sample_id='' node_name='' diagnostic_node='' run_id dispatch_id job name contention_case=''
	local client_device='' playback_sample='' candidate_output job_json image_configmap='' cleanup_index required_nodes=0
	local -a candidates=() contention_nodes=() eligible_nodes=() created_names=() created_jobs=() created_job_jsons=() created_configmaps=() run_ids=()
	case "$mode" in
	diagnostics)
		(($# == 1 || $# == 2)) || return 64
		supplied_run_id="${2:-}"
		if [[ -n "$supplied_run_id" ]]; then validate_run_id "$supplied_run_id" || return; fi
		require_confirmation ENCODE_BENCHMARK_DIAGNOSTICS_CONFIRM \
			'run:encode-benchmark:diagnostics' || return
		;;
	quality | savings)
		(($# == 1 || $# == 2)) || return 64
		supplied_run_id="${2:-}"
		;;
	x265)
		(($# == 3 || $# == 4)) || return 64
		sample_id="$2"
		node_name="$3"
		supplied_run_id="${4:-}"
		validate_sample_id "$sample_id" || return
		validate_node_name "$node_name" || return
		case "$sample_id" in
		avc-grain-memento | hdr10-grain-goodfellas) ;;
		*)
			echo "sample is not an x265 reference: $sample_id" >&2
			return 65
			;;
		esac
		if [[ -n "$supplied_run_id" ]]; then validate_run_id "$supplied_run_id" || return; fi
		require_confirmation ENCODE_BENCHMARK_X265_CONFIRM \
			"run:encode-benchmark:x265:$sample_id:$node_name" || return
		;;
	finalist)
		(($# == 3)) || return 64
		supplied_run_id="$2"
		sample_id="$3"
		validate_run_id "$supplied_run_id" || return
		validate_sample_id "$sample_id" || return
		require_confirmation ENCODE_BENCHMARK_FINALIST_CONFIRM \
			"copy:encode-benchmark:$supplied_run_id:$sample_id" || return
		;;
	contention-[a-d])
		(($# == 3 || $# == 4)) || return 64
		contention_case="${mode#contention-}"
		client_device="$2"
		playback_sample="$3"
		validate_client_device_label "$client_device" || return
		validate_sample_id "$playback_sample" || return
		if [[ "$contention_case" == 'a' ]]; then
			supplied_run_id="${4:-}"
			if [[ -n "$supplied_run_id" ]]; then validate_run_id "$supplied_run_id" || return; fi
			required_nodes=1
		else
			supplied_run_pair="${4:-}"
			if [[ -n "$supplied_run_pair" ]]; then
				IFS=, read -r -a run_ids <<<"$supplied_run_pair"
				((${#run_ids[@]} == 2)) && [[ -n "${run_ids[0]}" && -n "${run_ids[1]}" ]] || {
					echo "invalid contention resume pair: $supplied_run_pair" >&2
					return 64
				}
				validate_run_id "${run_ids[0]}" || return
				validate_run_id "${run_ids[1]}" || return
				[[ "${run_ids[0]}" != "${run_ids[1]}" ]] || {
					echo 'contention resume run IDs must be distinct' >&2
					return 64
				}
			fi
			required_nodes=2
		fi
		;;
	*)
		echo "invalid benchmark mode: $mode" >&2
		return 64
		;;
	esac
	if [[ -n "$supplied_run_id" && -z "$contention_case" ]]; then validate_run_id "$supplied_run_id" || return; fi
	if [[ "$mode" != 'x265' && "$mode" != 'diagnostics' ]]; then
		require_confirmation ENCODE_BENCHMARK_RUN_CONFIRM "run:encode-benchmark:$mode" || return
	fi
	load_source || return
	if [[ "$mode" == 'diagnostics' ]]; then
		contract_require_diagnostics "$samples_document" || return
		require_deployed_diagnostics_contract || return
		diagnostic_node="$(require_diagnostic_capability_evidence)" || return
		validate_node_name "$diagnostic_node" || return
		if [[ -n "$supplied_run_id" ]]; then
			require_diagnostics_run_id "$supplied_run_id" || return
		fi
	fi
	if [[ "$mode" == 'finalist' ]]; then
		require_finalist_authorization "$sample_id" || return
	elif [[ "$mode" == 'x265' ]]; then
		require_x265_authorization "$sample_id" || return
	elif [[ "$mode" == 'savings' ]]; then
		require_savings_authorization || return
	fi
	if [[ "$mode" != 'x265' ]]; then require_capability_evidence || return; fi
	if [[ -n "$contention_case" ]]; then
		candidate_output="$(contention_samples "$contention_case")" || return
		mapfile -t candidates <<<"$candidate_output"
		require_contention_playback_sample "$playback_sample" || return
		contention_passing_nodes "$required_nodes" || return
	fi
	if [[ -n "$contention_case" ]]; then
		if [[ "$contention_case" == 'a' ]]; then
			if [[ -n "$supplied_run_id" ]]; then
				run_ids=("$supplied_run_id")
			else
				run_ids=("$(new_run_id "$mode-worker-1")")
			fi
			dispatch_id="${run_ids[0]}"
		else
			if [[ -z "$supplied_run_pair" ]]; then
				run_ids=("$(new_run_id "$mode-worker-1")" "$(new_run_id "$mode-worker-2")")
			fi
			dispatch_id="$(new_run_id "$mode-dispatch")"
		fi
	elif [[ -n "$supplied_run_id" ]]; then
		run_id="$supplied_run_id"
		dispatch_id="$run_id"
	else
		run_id="$(new_run_id "$mode")" || return
		dispatch_id="$run_id"
	fi
	require_cluster_target || return
	if [[ "$mode" == 'x265' ]]; then require_cpu_node "$node_name" || return; fi
	if [[ -n "$contention_case" ]]; then
		mapfile -t eligible_nodes < <(eligible_capability_nodes)
		mapfile -t contention_nodes < <(printf '%s\n' "${contention_nodes[@]}" "${eligible_nodes[@]}" | sort | uniq -d)
		((${#contention_nodes[@]} >= required_nodes)) || {
			echo "contention requires $required_nodes distinct still-eligible passing capability nodes" >&2
			return 65
		}
		local index worker candidate candidate_id suffix
		for run_id in "${run_ids[@]}"; do
			ensure_run_available "$run_id" || return
		done
		for index in "${!candidates[@]}"; do
			worker="worker-$((index + 1))"
			run_id="${run_ids[$index]}"
			candidate="${candidates[$index]}"
			candidate_id="$(jq -r '.id' <<<"$candidate")"
			suffix="w$((index + 1))"
			name="encode-benchmark-$mode-${run_id,,}-$suffix"
			job="$temp_directory/$mode-$worker.yaml"
			render_job "$job" "$mode" "$run_id" "$dispatch_id" "$worker" "$name" \
				/scripts/benchmark.sh contention "$run_id" "$contention_case" "$worker" "$candidate_id"
			NODE_NAME="${contention_nodes[$index]}" CLIENT_DEVICE="$client_device" PLAYBACK_SAMPLE="$playback_sample" yq -i '
				.spec.template.spec.nodeSelector."kubernetes.io/hostname" = strenv(NODE_NAME) |
				.spec.template.spec.containers[0].env += [
					{"name":"BENCHMARK_CLIENT_DEVICE","value":strenv(CLIENT_DEVICE)},
					{"name":"BENCHMARK_PLEX_CLIENT_DEVICE","value":strenv(CLIENT_DEVICE)},
					{"name":"BENCHMARK_PLAYBACK_SAMPLE_ID","value":strenv(PLAYBACK_SAMPLE)}
				]
			' "$job"
			if ! job_json="$(create_job "$job")"; then
				for cleanup_index in "${!created_job_jsons[@]}"; do
					delete_created_job "${created_job_jsons[$cleanup_index]}" "${created_jobs[$cleanup_index]}"
				done
				return 1
			fi
			created_names+=("$name")
			created_jobs+=("$job")
			created_job_jsons+=("$job_json")
		done
		for index in "${!created_jobs[@]}"; do
			image_configmap=''
			if ! establish_running_image_handoff "${created_job_jsons[$index]}" "${created_jobs[$index]}" image_configmap; then
				[[ -z "$image_configmap" ]] || created_configmaps+=("$image_configmap")
				for cleanup_index in "${!created_configmaps[@]}"; do
					delete_owned_image_evidence "${created_configmaps[$cleanup_index]}" \
						"${created_job_jsons[$cleanup_index]}"
				done
				for cleanup_index in "${!created_job_jsons[@]}"; do
					delete_created_job "${created_job_jsons[$cleanup_index]}" "${created_jobs[$cleanup_index]}"
				done
				return 1
			fi
			created_configmaps+=("$image_configmap")
		done
		printf 'dispatch_id=%s' "$dispatch_id"
		for index in "${!run_ids[@]}"; do
			printf ' worker-%s=%s' "$((index + 1))" "${run_ids[$index]}"
		done
		printf ' jobs=%s\n' "${created_names[*]}"
		return
	fi
	ensure_run_available "$run_id" || return
	name="encode-benchmark-$mode-${run_id,,}"
	job="$temp_directory/$mode.yaml"
	if [[ "$mode" == 'finalist' ]]; then
		render_job "$job" "$mode" "$run_id" "$dispatch_id" '' "$name" /scripts/benchmark.sh finalist "$run_id" "$sample_id"
		FINALIST_CONFIRM="$ENCODE_BENCHMARK_FINALIST_CONFIRM" yq -i '
			.spec.template.spec.containers[0].env += [{"name":"ENCODE_BENCHMARK_FINALIST_CONFIRM","value":strenv(FINALIST_CONFIRM)}]
		' "$job"
	elif [[ "$mode" == 'diagnostics' ]]; then
		render_job "$job" "$mode" "$run_id" "$dispatch_id" '' "$name" /scripts/benchmark.sh diagnostics "$run_id"
		NODE_NAME="$diagnostic_node" yq -i '
			.spec.activeDeadlineSeconds = 28800 |
			.spec.template.spec.nodeSelector."kubernetes.io/hostname" = strenv(NODE_NAME)
		' "$job"
	elif [[ "$mode" == 'x265' ]]; then
		render_job "$job" "$mode" "$run_id" "$dispatch_id" '' "$name" \
			/scripts/benchmark.sh x265 "$run_id" "$sample_id"
		NODE_NAME="$node_name" yq -i '
			.spec.activeDeadlineSeconds = 216000 |
			.spec.template.spec.nodeSelector = {"kubernetes.io/hostname":strenv(NODE_NAME)} |
			del(.spec.template.spec.containers[0].resources.requests."gpu.intel.com/i915") |
			del(.spec.template.spec.containers[0].resources.limits."gpu.intel.com/i915")
		' "$job"
	else
		render_job "$job" "$mode" "$run_id" "$dispatch_id" '' "$name" /scripts/benchmark.sh "$mode" "$run_id"
		if [[ "$mode" == 'quality' && -z "$supplied_run_id" ]]; then
			DISPATCH_CORRELATION_ID="$dispatch_id" yq -i '
				.spec.template.spec.containers[0].env += [{
					"name":"BENCHMARK_DISPATCH_CORRELATION_ID",
					"value":strenv(DISPATCH_CORRELATION_ID)
				}]
			' "$job"
		fi
	fi
	job_json="$(create_job "$job")" || return
	if ! establish_running_image_handoff "$job_json" "$job" image_configmap; then
		if [[ -n "$image_configmap" ]]; then
			delete_owned_image_evidence "$image_configmap" "$job_json"
		fi
		delete_created_job "$job_json" "$job"
		return 1
	fi
	printf 'run_id=%s job=%s\n' "$run_id" "$name"
}

dispatch_contention() {
	local contention_case="${1:-}" client_device="${2:-}" playback_sample="${3:-}" run_id_or_pair="${4:-}"
	(($# == 3 || $# == 4)) || return 64
	[[ "$contention_case" =~ ^[a-d]$ ]] || {
		echo "invalid contention case: $contention_case" >&2
		return 64
	}
	if [[ -n "$run_id_or_pair" ]]; then
		dispatch_run "contention-$contention_case" "$client_device" "$playback_sample" "$run_id_or_pair"
	else
		dispatch_run "contention-$contention_case" "$client_device" "$playback_sample"
	fi
}

dispatch_clean() {
	local run_id="${1:-}" expected run_id_lower job name cleanup_command
	(($# == 1)) || return 64
	validate_run_id "$run_id" || return
	expected="delete:encode-benchmark:$run_id"
	require_confirmation ENCODE_BENCHMARK_CLEAN_CONFIRM "$expected" || return
	load_source || return
	require_cluster_target || return
	run_id_lower="${run_id,,}"
	name="encode-benchmark-clean-$run_id_lower"
	job="$temp_directory/clean.yaml"
	# shellcheck disable=SC2016 # Expanded by the cleanup Job, not this dispatcher.
	cleanup_command='run_id="$1"; confirmation="$2"; runs_root="$3"; out_root="$4"; [[ "$run_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]] || exit 64; [[ "$confirmation" == "delete:encode-benchmark:$run_id" ]] || exit 64; [[ "$out_root" == /* && -d "$out_root" && "$runs_root" == "$out_root/runs" && -d "$runs_root" && ! -L "$runs_root" ]] || exit 65; resolved_out_root="$(realpath "$out_root")" || exit 65; resolved_runs_root="$(realpath "$runs_root")" || exit 65; [[ "$resolved_runs_root" == "$resolved_out_root/runs" ]] || exit 65; run_directory="$runs_root/$run_id"; if [[ -e "$run_directory" || -L "$run_directory" ]]; then [[ -d "$run_directory" && ! -L "$run_directory" ]] || exit 65; fi; rm -rf -- "$run_directory"'
	render_job "$job" clean "$run_id" "$run_id" '' "$name" /bin/bash -euo pipefail -c \
		"$cleanup_command" cleanup "$run_id" "$expected" /out/runs /out
	remove_mounts_and_volumes "$job" media scratch scripts samples image-evidence
	yq -i '
		del(.spec.template.spec.affinity) |
		del(.spec.template.spec.containers[0].resources.requests."ephemeral-storage") |
		del(.spec.template.spec.containers[0].resources.limits."ephemeral-storage") |
		del(.spec.template.spec.containers[0].resources.requests."gpu.intel.com/i915") |
		del(.spec.template.spec.containers[0].resources.limits."gpu.intel.com/i915") |
		.spec.template.spec.containers[0].env = []
	' "$job"
	create_job "$job" >/dev/null
	printf 'run_id=%s cleanup_job=%s artifact_location=/out/runs/%s\n' "$run_id" "$name" "$run_id"
}

# The collector has no relationship to the diagnostic encoder selector.  It
# mounts only the one immutable run subtree read-only and prints its canonical
# sanitized value; it never needs media, scratch, a GPU, or pod/node identity.
dispatch_evidence_reader() {
	local run_id="$1" expected name job panel_sha256 evidence_panel
	(($# == 1)) || return 64
	validate_run_id "$run_id" || return
	expected="read:encode-benchmark:diagnostic-evidence:$run_id"
	require_confirmation ENCODE_BENCHMARK_DIAGNOSTIC_EVIDENCE_CONFIRM "$expected" || return
	load_source || return
	require_cluster_target || return
	require_terminal_diagnostics_job "$run_id" || return
	ensure_evidence_reader_available "$run_id" || return
	panel_sha256="$(contract_diagnostics_panel_sha256 "$samples_document")" || {
		echo 'committed diagnostics panel identity is malformed' >&2
		return 65
	}
	evidence_panel="$(contract_diagnostics_evidence_panel_json "$samples_document")" || {
		echo 'committed diagnostic evidence panel is malformed' >&2
		return 65
	}
	name="encode-benchmark-evidence-reader-${run_id,,}"
	job="$temp_directory/evidence-reader.yaml"
	render_job "$job" diagnostic-evidence-reader "$run_id" "$run_id" '' "$name" \
		/scripts/diagnostic-evidence.sh collect "$run_id" /evidence "$panel_sha256" "$evidence_panel"
	remove_mounts_and_volumes "$job" media out scratch samples image-evidence
	RUN_ID="$run_id" yq -i '
		del(.spec.template.spec.containers[0].env) |
		del(.spec.template.spec.containers[0].resources.requests."gpu.intel.com/i915") |
		del(.spec.template.spec.containers[0].resources.limits."gpu.intel.com/i915") |
		del(.spec.template.spec.containers[0].resources.requests."ephemeral-storage") |
		del(.spec.template.spec.containers[0].resources.limits."ephemeral-storage") |
		.spec.activeDeadlineSeconds = 300 |
		.spec.ttlSecondsAfterFinished = 3600 |
		.spec.template.spec.containers[0].resources.requests = {"cpu":"100m","memory":"128Mi"} |
		.spec.template.spec.containers[0].resources.limits = {"cpu":"500m","memory":"256Mi"} |
		.spec.template.spec.containers[0].volumeMounts += [{"name":"evidence","mountPath":"/evidence","subPath":"benchmark/runs/" + strenv(RUN_ID) + "/diagnostics","readOnly":true}] |
		.spec.template.spec.volumes += [{"name":"evidence","persistentVolumeClaim":{"claimName":"media-data","readOnly":true}}]
	' "$job"
	create_job "$job" >/dev/null
	printf 'run_id=%s collector_job=%s\n' "$run_id" "$name"
}

validate_findings_inputs_file() {
	local path="$1"
	[[ -f "$path" && ! -L "$path" ]] || return 66
	jq -e '
		def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
		def run: type == "string" and test("^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$");
		def base($suffix): type == "string" and test("^[a-zA-Z0-9][a-zA-Z0-9._-]*" + $suffix + "$");
		def quality: type == "object" and keys == ["candidatesSha256","resultsSha256","runId"] and (.runId|run) and (.resultsSha256|digest) and (.candidatesSha256|digest);
		def x265: type == "object" and keys == ["comparisonsSha256","runId","sampleId"] and (.runId|run) and (.sampleId == "avc-grain-memento" or .sampleId == "hdr10-grain-goodfellas") and (.comparisonsSha256|digest);
		def savings: type == "object" and keys == ["cohortsSha256","resultsSha256","runId"] and (.runId|run) and (.resultsSha256|digest) and (.cohortsSha256|digest);
		def fragment: type == "object" and keys == ["file","runId","sha256"] and (.runId|run) and (.file|base("[.]csv")) and (.sha256|digest);
		def contention: type == "object" and keys == ["fragments","observationsFile","observationsSha256","runId"] and (.runId|run) and (.observationsFile|base("[.]json")) and (.observationsSha256|digest) and (.fragments|type == "array" and length <= 16 and all(.[]; fragment));
		type == "object" and keys == ["contention","quality","savings","schemaVersion","strategyId","x265"] and .schemaVersion == 1 and .strategyId == "qsv-hevc-icq-v1" and (.quality|quality) and (.x265|type == "array" and length <= 2 and all(.[];x265) and ([.[]|.sampleId]|unique|length)==length) and (.savings == null or (.savings|savings)) and (.contention == null or (.contention|contention))
	' "$path" >/dev/null
}

dispatch_findings() {
	local inputs_file="${1:-}" supplied_run_id="${2:-}" run_id job name job_json uid configmap configmap_name configmap_json persisted inputs_json input_mode private_inputs
	(($# == 1 || $# == 2)) || return 64
	[[ -n "$inputs_file" ]] || return 64
	validate_findings_inputs_file "$inputs_file" || {
		echo 'invalid findings inputs' >&2
		return 65
	}
	while IFS= read -r upstream_run; do
		validate_run_id "$upstream_run" || return
	done < <(jq -r '.quality.runId, (.x265[]?.runId), (.savings?.runId // empty), (.contention?.runId // empty), (.contention?.fragments[]?.runId // empty)' "$inputs_file")
	require_confirmation ENCODE_BENCHMARK_FINDINGS_CONFIRM 'run:encode-benchmark:findings' || return
	load_source || return
	if [[ -n "$supplied_run_id" ]]; then
		validate_run_id "$supplied_run_id" || return
		run_id="$supplied_run_id"
	else run_id="$(new_run_id findings)"; fi
	require_cluster_target || return
	ensure_run_available "$run_id" || return
	private_inputs="$temp_directory/findings-inputs.json"
	(
		umask 077
		cp -- "$inputs_file" "$private_inputs"
	) || return
	chmod 0600 "$private_inputs" || return
	input_mode="$(stat -c '%a' "$private_inputs" 2>/dev/null || stat -f '%Lp' "$private_inputs")"
	[[ "$input_mode" == 600 ]] || return 65
	inputs_json="$(jq -c . "$private_inputs")" || return 65
	name="encode-benchmark-findings-${run_id,,}"
	configmap_name="encode-benchmark-findings-inputs-${run_id,,}"
	job="$temp_directory/findings.yaml"
	render_job "$job" findings "$run_id" "$run_id" '' "$name" /scripts/benchmark.sh findings "$run_id"
	remove_mounts_and_volumes "$job" media scratch image-evidence
	FINDINGS_CONFIGMAP="$configmap_name" yq -i '
		.spec.suspend = true |
		del(.spec.template.spec.containers[0].resources.requests."gpu.intel.com/i915") |
		del(.spec.template.spec.containers[0].resources.limits."gpu.intel.com/i915") |
		.spec.template.spec.containers[0].volumeMounts += [{"name":"findings-inputs","mountPath":"/inputs/findings-inputs.json","subPath":"findings-inputs.json","readOnly":true}] |
		.spec.template.spec.volumes += [{"name":"findings-inputs","configMap":{"name":strenv(FINDINGS_CONFIGMAP),"defaultMode":384,"items":[{"key":"findings-inputs.json","path":"findings-inputs.json"}]}}]
	' "$job"
	yq -i '
		.spec.template.spec.containers[0].env += [{"name":"BENCHMARK_FINDINGS_INPUTS_FILE","value":"/inputs/findings-inputs.json"}]
	' "$job"
	job_json="$(create_job "$job")" || return
	uid="$(yq -p=json -e -r '.metadata.uid | select(test("^[a-zA-Z0-9._-]+$"))' <<<"$job_json")" || {
		delete_created_job "$job_json" "$job"
		return
	}
	configmap="$temp_directory/findings-inputs.yaml"
	CONFIGMAP_NAME="$configmap_name" JOB_NAME="$name" JOB_UID="$uid" RUN_ID="$run_id" INPUTS_JSON="$inputs_json" yq -n '
		.apiVersion="v1" | .kind="ConfigMap" | .metadata.name=strenv(CONFIGMAP_NAME) | .metadata.namespace="media" |
		.metadata.labels."app.kubernetes.io/name"="encode-benchmark" | .metadata.labels."homelab-talos/benchmark-run"=strenv(RUN_ID) | .metadata.labels."homelab-talos/benchmark-mode"="findings" |
		.metadata.ownerReferences=[{"apiVersion":"batch/v1","kind":"Job","name":strenv(JOB_NAME),"uid":strenv(JOB_UID),"controller":true,"blockOwnerDeletion":true}] |
		.data."findings-inputs.json"=strenv(INPUTS_JSON)
	' >"$configmap" || {
		delete_created_job "$job_json" "$job"
		return
	}
	if ! configmap_json="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" create --filename "$configmap" --output json)"; then
		delete_created_job "$job_json" "$job"
		return 1
	fi
	persisted="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get "configmap/$configmap_name" --output json)" || {
		delete_created_findings_inputs "$configmap_json" "$job_json"
		delete_created_job "$job_json" "$job"
		return 1
	}
	if ! has_exact_job_controller_owner "$persisted" "$name" "$uid" || ! jq -e --argjson expected "$inputs_json" '.data."findings-inputs.json" | fromjson == $expected' <<<"$persisted" >/dev/null; then
		delete_created_findings_inputs "$configmap_json" "$job_json"
		delete_created_job "$job_json" "$job"
		return 65
	fi
	if ! kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" patch "job/$name" --type merge --patch '{"spec":{"suspend":false}}' >/dev/null; then
		delete_created_findings_inputs "$configmap_json" "$job_json"
		delete_created_job "$job_json" "$job"
		return 1
	fi
	printf 'run_id=%s job=%s inputs_configmap=%s\n' "$run_id" "$name" "$configmap_name"
}

case "$action" in
capabilities)
	(($# == 0)) || exit 64
	dispatch_capabilities
	;;
census)
	(($# == 0)) || exit 64
	dispatch_census
	;;
evidence-reader)
	(($# == 1)) || exit 64
	dispatch_evidence_reader "$@"
	;;
findings)
	dispatch_findings "$@"
	;;
run)
	dispatch_run "$@"
	;;
contention)
	dispatch_contention "$@"
	;;
clean)
	dispatch_clean "$@"
	;;
*)
	echo "invalid dispatch action: $action" >&2
	exit 64
	;;
esac
