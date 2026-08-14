#!/usr/bin/env bash
set -euo pipefail

if (($# < 2)); then
	echo 'usage: dispatch.sh <kubeconfig> <capabilities|census|run|clean> ...' >&2
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

if [[ -n "${ENCODE_BENCHMARK_APP_DIR:-}" ]]; then
	[[ "$test_mode" == '1' ]] || {
		echo 'ENCODE_BENCHMARK_APP_DIR requires ENCODE_BENCHMARK_TEST_MODE=1' >&2
		exit 64
	}
	app_directory="$ENCODE_BENCHMARK_APP_DIR"
fi

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
	[[ "$1" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]] || {
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
	configured_image="$(yq -e -r '.runtime.image | select(test("^[^@[:space:]]+@sha256:[0-9a-f]{64}$"))' "$samples_document")"
	[[ -f "$template" ]] || {
		echo 'benchmark Job template is missing' >&2
		return 66
	}
}

require_capability_evidence() {
	local configured_digest="${configured_image##*@}"
	if jq -e --arg digest "$configured_digest" '
		def immutable_image_id:
			type == "string" and
			test("^([^@[:space:]]+@)?sha256:[0-9a-f]{64}$") and
			(sub("^.*@"; "") == $digest);
		def valid_node:
			type == "object" and
			.proofSchemaVersion == 2 and
			(.nodeName | type == "string" and test("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$")) and
			.initialization == "passed" and
			.selectedRateControl == "LA-ICQ" and
			.telemetryStatus == "available" and
			.telemetryReason == "" and
			(.videoBusyNanoseconds | type == "number" and . > 0) and
			(.videoBusyPercent | type == "number" and . >= 0) and
			(.encodeFps | type == "number" and . >= 0) and
			(.encodeSpeed | type == "number" and . > 0) and
			.decode == "passed" and
			.vmaf == "passed" and
			.proofStatus == "passed" and
			.proofReasons == "" and
			(.verifiedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
			.configuredImageDigest == $digest and
			(.imageId | immutable_image_id);
		.runtime.capabilityStatus == "verified" and
		(.runtime.capabilityEvidence.nodes | type == "array") and
		any(.runtime.capabilityEvidence.nodes[]; valid_node)
	' "$samples_document" >/dev/null; then
		return 0
	fi
	echo 'Refusing benchmark dispatch: committed schema-v2 capability evidence has no current passing node.' >&2
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
	[[ "$now" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || {
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
	local command_json
	command_json="$(jq -n -c '$ARGS.positional' --args -- "$@")"
	cp "$template" "$output"
	JOB_NAME="$name" RUN_ID="$run_id" DISPATCH_ID="$dispatch_id" MODE="$mode" IMAGE="$configured_image" \
		SCRIPTS_CONFIGMAP="$scripts_configmap" COMMAND_JSON="$command_json" yq -i '
		.metadata.name = strenv(JOB_NAME) |
		.metadata.labels."app.kubernetes.io/name" = "encode-benchmark" |
		.metadata.labels."homelab-talos/benchmark-dispatch" = strenv(DISPATCH_ID) |
		.metadata.labels."homelab-talos/benchmark-run" = strenv(RUN_ID) |
		.metadata.labels."homelab-talos/benchmark-mode" = strenv(MODE) |
		.metadata.annotations."homelab-talos/benchmark-owned" = "true" |
		.metadata.annotations."homelab-talos/scripts-configmap" = strenv(SCRIPTS_CONFIGMAP) |
		.spec.template.metadata.labels."app.kubernetes.io/name" = "encode-benchmark" |
		.spec.template.metadata.labels."homelab-talos/benchmark-dispatch" = strenv(DISPATCH_ID) |
		.spec.template.metadata.labels."homelab-talos/benchmark-run" = strenv(RUN_ID) |
		.spec.template.metadata.labels."homelab-talos/benchmark-mode" = strenv(MODE) |
		.spec.template.spec.containers[0].image = strenv(IMAGE) |
		.spec.template.spec.containers[0].command = (strenv(COMMAND_JSON) | from_json) |
		.spec.template.spec.containers[0].env += [{"name":"BENCHMARK_DISPATCH_IMAGE","value":strenv(IMAGE)}] |
		(.spec.template.spec.volumes[] | select(.name == "scripts") | .configMap.name) = strenv(SCRIPTS_CONFIGMAP)
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
	local run_id job name node index
	local -a nodes=() jobs=() names=() created_names=()
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
		if ! create_job "$job" >/dev/null; then
			for name in "${created_names[@]}"; do
				kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" delete \
					"job/$name" --wait=true >/dev/null 2>&1 || true
			done
			return 1
		fi
		created_names+=("$name")
	done
	printf 'run_id=%s nodes=%s jobs=%s\n' "$run_id" "${nodes[*]}" "${created_names[*]}"
}

dispatch_census() {
	local run_id job name job_json uid inventory inventory_mode configmap configmap_name
	local configmap_json persisted_configmap persisted_owner_count
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
	remove_mounts_and_volumes "$job" scratch
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
	persisted_owner_count="$(JOB_NAME="$name" JOB_UID="$uid" yq -p=json -r '
		[.metadata.ownerReferences[]? | select(
			.apiVersion == "batch/v1" and .kind == "Job" and
			.name == strenv(JOB_NAME) and .uid == strenv(JOB_UID) and
			.controller == true and .blockOwnerDeletion == true
		)] | length
	' <<<"$persisted_configmap")"
	[[ "$(yq -p=json -r '.metadata.name // ""' <<<"$persisted_configmap")" == "$configmap_name" &&
	"$persisted_owner_count" == '1' ]] || {
		echo 'persisted census inventory ownership could not be proven' >&2
		return 65
	}
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
		setting="$(COHORT="$cohort" yq -r '.chosenSettings[strenv(COHORT)].globalQuality // ""' "$samples_document")"
		[[ "$setting" =~ ^(20|22|24|26|28)$ ]] || {
			echo "no committed setting for contention sample cohort: $cohort" >&2
			return 65
		}
	done
	printf '%s\n' "${candidates[@]}"
}

dispatch_run() {
	local mode="${1:-}" supplied_run_id='' supplied_run_pair='' sample_id='' run_id dispatch_id job name contention_case=''
	local candidate_output
	local -a candidates=() created_names=() run_ids=()
	case "$mode" in
	quality | savings)
		(($# == 1 || $# == 2)) || return 64
		supplied_run_id="${2:-}"
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
		(($# == 1 || $# == 2)) || return 64
		contention_case="${mode#contention-}"
		if [[ "$contention_case" == 'a' ]]; then
			supplied_run_id="${2:-}"
			if [[ -n "$supplied_run_id" ]]; then validate_run_id "$supplied_run_id" || return; fi
		else
			supplied_run_pair="${2:-}"
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
		fi
		;;
	*)
		echo "invalid benchmark mode: $mode" >&2
		return 64
		;;
	esac
	if [[ -n "$supplied_run_id" && -z "$contention_case" ]]; then validate_run_id "$supplied_run_id" || return; fi
	require_confirmation ENCODE_BENCHMARK_RUN_CONFIRM "run:encode-benchmark:$mode" || return
	load_source || return
	require_capability_evidence || return
	if [[ -n "$contention_case" ]]; then
		candidate_output="$(contention_samples "$contention_case")" || return
		mapfile -t candidates <<<"$candidate_output"
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
	if [[ -n "$contention_case" ]]; then
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
			if ! create_job "$job" >/dev/null; then
				for name in "${created_names[@]}"; do
					kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" delete "job/$name" --wait=true >/dev/null 2>&1 || true
				done
				return 1
			fi
			created_names+=("$name")
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
	else
		render_job "$job" "$mode" "$run_id" "$dispatch_id" '' "$name" /scripts/benchmark.sh "$mode" "$run_id"
	fi
	create_job "$job" >/dev/null
	printf 'run_id=%s job=%s\n' "$run_id" "$name"
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
	remove_mounts_and_volumes "$job" media scratch scripts samples
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

case "$action" in
capabilities)
	(($# == 0)) || exit 64
	dispatch_capabilities
	;;
census)
	(($# == 0)) || exit 64
	dispatch_census
	;;
run)
	dispatch_run "$@"
	;;
clean)
	dispatch_clean "$@"
	;;
*)
	echo "invalid dispatch action: $action" >&2
	exit 64
	;;
esac
