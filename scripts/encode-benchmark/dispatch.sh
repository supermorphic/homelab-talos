#!/usr/bin/env bash
set -euo pipefail

if (($# < 2)); then
	echo 'usage: dispatch.sh <kubeconfig> <capabilities|run> ...' >&2
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
cleanup_dispatch() {
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

require_confirmation() {
	local variable="$1" expected="$2"
	[[ "${!variable:-}" == "$expected" ]] || {
		echo "Refusing benchmark dispatch: set $variable=$expected" >&2
		return 1
	}
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

dispatch_run() {
	local mode="${1:-}" supplied_run_id="${2:-}" run_id dispatch_id job name job_json image_configmap=''
	(($# == 1 || $# == 2)) || return 64
	[[ "$mode" == 'quality' ]] || {
		echo "invalid benchmark mode: $mode" >&2
		return 64
	}
	if [[ -n "$supplied_run_id" ]]; then validate_run_id "$supplied_run_id" || return; fi
	require_confirmation ENCODE_BENCHMARK_RUN_CONFIRM 'run:encode-benchmark:quality' || return
	load_source || return
	require_capability_evidence || return
	if [[ -n "$supplied_run_id" ]]; then
		run_id="$supplied_run_id"
	else
		run_id="$(new_run_id quality)" || return
	fi
	dispatch_id="$run_id"
	require_cluster_target || return
	ensure_run_available "$run_id" || return
	name="encode-benchmark-quality-${run_id,,}"
	job="$temp_directory/quality.yaml"
	render_job "$job" quality "$run_id" "$dispatch_id" '' "$name" \
		/scripts/benchmark.sh quality "$run_id"
	if [[ -z "$supplied_run_id" ]]; then
		DISPATCH_CORRELATION_ID="$dispatch_id" yq -i '
			.spec.template.spec.containers[0].env += [{
				"name":"BENCHMARK_DISPATCH_CORRELATION_ID",
				"value":strenv(DISPATCH_CORRELATION_ID)
			}]
		' "$job"
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

case "$action" in
capabilities)
	(($# == 0)) || exit 64
	dispatch_capabilities
	;;
run)
	dispatch_run "$@"
	;;
*)
	echo "invalid dispatch action: $action" >&2
	exit 64
	;;
esac
