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
cleanup_temp() {
	if [[ -n "$temp_directory" ]]; then
		rm -rf -- "$temp_directory"
	fi
}
trap cleanup_temp EXIT

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
	samples_document="$temp_directory/samples.yaml"
	yq -e -r '.data."samples.yaml"' "$app_directory/samples.yaml" >"$samples_document"
	configured_image="$(yq -e -r '.runtime.image | select(test("^[^@[:space:]]+@sha256:[0-9a-f]{64}$"))' "$samples_document")"
	[[ -f "$template" ]] || {
		echo 'benchmark Job template is missing' >&2
		return 66
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
	local output="$1" mode="$2" run_id="$3" worker="$4" name="$5"
	shift 5
	local command_json
	command_json="$(jq -n -c '$ARGS.positional' --args -- "$@")"
	cp "$template" "$output"
	JOB_NAME="$name" RUN_ID="$run_id" MODE="$mode" IMAGE="$configured_image" \
		SCRIPTS_CONFIGMAP="$scripts_configmap" COMMAND_JSON="$command_json" yq -i '
		.metadata.name = strenv(JOB_NAME) |
		.metadata.labels."app.kubernetes.io/name" = "encode-benchmark" |
		.metadata.labels."homelab-talos/benchmark-run" = strenv(RUN_ID) |
		.metadata.labels."homelab-talos/benchmark-mode" = strenv(MODE) |
		.metadata.annotations."homelab-talos/benchmark-owned" = "true" |
		.metadata.annotations."homelab-talos/scripts-configmap" = strenv(SCRIPTS_CONFIGMAP) |
		.spec.template.metadata.labels."app.kubernetes.io/name" = "encode-benchmark" |
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

dispatch_capabilities() {
	local run_id job name
	require_confirmation ENCODE_BENCHMARK_CAPABILITIES_CONFIRM 'run:encode-benchmark:capabilities' || return
	load_source || return
	run_id="$(new_run_id capabilities)" || return
	require_cluster_target || return
	ensure_run_available "$run_id" || return
	job="$temp_directory/capabilities.yaml"
	name="encode-benchmark-capabilities-${run_id,,}"
	render_job "$job" capabilities "$run_id" '' "$name" /scripts/benchmark.sh capabilities
	remove_mounts_and_volumes "$job" media out
	create_job "$job" >/dev/null
	printf 'run_id=%s job=%s\n' "$run_id" "$name"
}

dispatch_census() {
	local run_id job name job_json uid inventory configmap configmap_name configmap_json
	require_confirmation ENCODE_BENCHMARK_CENSUS_CONFIRM 'run:encode-benchmark:census' || return
	load_source || return
	run_id="$(new_run_id census)" || return
	require_cluster_target || return
	ensure_run_available "$run_id" || return
	job="$temp_directory/census.yaml"
	name="encode-benchmark-census-${run_id,,}"
	configmap_name="encode-benchmark-inodes-${run_id,,}"
	render_job "$job" census "$run_id" '' "$name" \
		/scripts/census.sh /inventory/inodes.tsv "/out/runs/$run_id"
	remove_mounts_and_volumes "$job" scratch
	INVENTORY_CONFIGMAP="$configmap_name" yq -i '
		.spec.suspend = true |
		del(.spec.template.spec.affinity) |
		del(.spec.template.spec.containers[0].resources.requests."ephemeral-storage") |
		del(.spec.template.spec.containers[0].resources.limits."ephemeral-storage") |
		del(.spec.template.spec.containers[0].resources.requests."gpu.intel.com/i915") |
		del(.spec.template.spec.containers[0].resources.limits."gpu.intel.com/i915") |
		.spec.template.spec.containers[0].volumeMounts += [{"name":"inventory","mountPath":"/inventory/inodes.tsv","subPath":"inodes.tsv","readOnly":true}] |
		.spec.template.spec.volumes += [{"name":"inventory","configMap":{"name":strenv(INVENTORY_CONFIGMAP),"items":[{"key":"inodes.tsv","path":"inodes.tsv"}]}}]
	' "$job"
	job_json="$(create_job "$job")" || return
	uid="$(yq -p=json -e -r '.metadata.uid | select(test("^[a-zA-Z0-9._-]+$"))' <<<"$job_json")" || {
		kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" delete "job/$name" --wait=true >/dev/null 2>&1 || true
		return 65
	}
	inventory="$temp_directory/inodes.tsv"
	umask 077
	if ! kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" exec -i \
		deployment/qbit-manage -- python - <"$script_directory/torrent-inventory.py" >"$inventory"; then
		kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" delete "job/$name" --wait=true >/dev/null 2>&1 || true
		return 1
	fi
	chmod 0600 "$inventory"
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
		.data."inodes.tsv" = load_str(strenv(INVENTORY_FILE))
	' >"$configmap"
	if ! configmap_json="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" create --filename "$configmap" --output json)"; then
		kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" delete "job/$name" --wait=true >/dev/null 2>&1 || true
		return 1
	fi
	if [[ "$(yq -p=json -r '.metadata.name // ""' <<<"$configmap_json")" != "$configmap_name" ]]; then
		kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" delete "job/$name" --wait=true >/dev/null 2>&1 || true
		return 65
	fi
	if ! kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" patch "job/$name" \
		--type merge --patch '{"spec":{"suspend":false}}' >/dev/null; then
		kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" delete "job/$name" --wait=true >/dev/null 2>&1 || true
		return 1
	fi
	printf 'run_id=%s job=%s inventory_configmap=%s\n' "$run_id" "$name" "$configmap_name"
}

contention_samples() {
	local contention_case="$1" candidates candidate cohort setting
	if [[ "$contention_case" == 'a' ]]; then
		mapfile -t candidates < <(yq -o=json -I=0 '
			[.qualityPanel[]? | select(.cohort == "hdr10" and (.detectionOnly // false) == false)]
			| sort_by(.id) | .[]
		' "$samples_document")
		((${#candidates[@]} >= 1)) || {
			echo 'no eligible 4K HDR10 quality sample for contention case a' >&2
			return 65
		}
		candidates=("${candidates[0]}")
	else
		mapfile -t candidates < <(yq -o=json -I=0 '
			[.qualityPanel[]? | select(
				(.cohort == "avc" or .cohort == "vc1") and
				(.detectionOnly // false) == false
			)] | sort_by(.id) | .[]
		' "$samples_document")
		((${#candidates[@]} >= 2)) || {
			echo "fewer than two eligible 1080p non-DV quality samples for contention case $contention_case" >&2
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
	local mode="${1:-}" supplied_run_id='' sample_id='' run_id job name contention_case=''
	local candidate_output
	local -a candidates=() created_names=()
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
		supplied_run_id="${2:-}"
		contention_case="${mode#contention-}"
		;;
	*)
		echo "invalid benchmark mode: $mode" >&2
		return 64
		;;
	esac
	if [[ -n "$supplied_run_id" ]]; then validate_run_id "$supplied_run_id" || return; fi
	require_confirmation ENCODE_BENCHMARK_RUN_CONFIRM "run:encode-benchmark:$mode" || return
	load_source || return
	if [[ -n "$contention_case" ]]; then
		candidate_output="$(contention_samples "$contention_case")" || return
		mapfile -t candidates <<<"$candidate_output"
	fi
	if [[ -n "$supplied_run_id" ]]; then run_id="$supplied_run_id"; else run_id="$(new_run_id "$mode")" || return; fi
	require_cluster_target || return
	ensure_run_available "$run_id" || return
	if [[ -n "$contention_case" ]]; then
		local index worker candidate candidate_id suffix
		for index in "${!candidates[@]}"; do
			worker="worker-$((index + 1))"
			candidate="${candidates[$index]}"
			candidate_id="$(jq -r '.id' <<<"$candidate")"
			suffix="w$((index + 1))"
			name="encode-benchmark-$mode-${run_id,,}-$suffix"
			job="$temp_directory/$mode-$worker.yaml"
			render_job "$job" "$mode" "$run_id" "$worker" "$name" \
				/scripts/benchmark.sh contention "$run_id" "$contention_case" "$worker" "$candidate_id"
			if ! create_job "$job" >/dev/null; then
				for name in "${created_names[@]}"; do
					kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" delete "job/$name" --wait=true >/dev/null 2>&1 || true
				done
				return 1
			fi
			created_names+=("$name")
		done
		printf 'run_id=%s jobs=%s\n' "$run_id" "${created_names[*]}"
		return
	fi
	name="encode-benchmark-$mode-${run_id,,}"
	job="$temp_directory/$mode.yaml"
	if [[ "$mode" == 'finalist' ]]; then
		render_job "$job" "$mode" "$run_id" '' "$name" /scripts/benchmark.sh finalist "$run_id" "$sample_id"
		FINALIST_CONFIRM="$ENCODE_BENCHMARK_FINALIST_CONFIRM" yq -i '
			.spec.template.spec.containers[0].env += [{"name":"ENCODE_BENCHMARK_FINALIST_CONFIRM","value":strenv(FINALIST_CONFIRM)}]
		' "$job"
	else
		render_job "$job" "$mode" "$run_id" '' "$name" /scripts/benchmark.sh "$mode" "$run_id"
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
	cleanup_command='run_id="$1"; confirmation="$2"; [[ "$run_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]] || exit 64; [[ "$confirmation" == "delete:encode-benchmark:$run_id" ]] || exit 64; rm -rf -- "/out/runs/$run_id"'
	render_job "$job" clean "$run_id" '' "$name" /bin/bash -euo pipefail -c \
		"$cleanup_command" cleanup "$run_id" "$expected"
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
