#!/usr/bin/env bash
set -euo pipefail

if (($# != 2)); then
	echo 'usage: results.sh <kubeconfig> <run-id>' >&2
	exit 64
fi

kubeconfig="$1"
run_id="$2"
namespace='media'
expected_api='https://192.168.90.20:6443'
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../.." && pwd)"
samples_source="$repository_root/kubernetes/apps/media/encode-benchmark/app/samples.yaml"

[[ "$run_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]] || {
	echo "invalid run id: $run_id" >&2
	exit 64
}
[[ -f "$kubeconfig" ]] || {
	echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
	exit 1
}
api_server="$(kubectl --kubeconfig "$kubeconfig" config view --minify \
	--output jsonpath='{.clusters[0].cluster.server}')"
[[ "$api_server" == "$expected_api" ]] || {
	echo "Refusing benchmark results: kubeconfig targets $api_server, not $expected_api." >&2
	exit 1
}

configured_image="$(yq -e -r '.data."samples.yaml" | from_yaml | .runtime.image | select(test("^[^@[:space:]]+@sha256:[0-9a-f]{64}$"))' "$samples_source")"
configured_digest="${configured_image##*@}"
selector="app.kubernetes.io/name=encode-benchmark,homelab-talos/benchmark-run=$run_id"
jobs="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get jobs \
	--selector "$selector" --output json)"
pods="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get pods \
	--selector "$selector" --output json)"
job_count="$(yq -p=json -r '.items | length' <<<"$jobs")"
((job_count > 0)) || {
	echo "no owned benchmark Jobs found for run $run_id" >&2
	exit 66
}
capability_job_count="$(yq -p=json -r '[.items[] | select(.metadata.labels."homelab-talos/benchmark-mode" == "capabilities")] | length' <<<"$jobs")"
if ((capability_job_count > 0 && (capability_job_count != 1 || job_count != 1))); then
	echo 'capability result provenance rejected: expected exactly one capability Job' >&2
	exit 1
fi

normalize_image_id() {
	local image_id="$1" stripped
	stripped="${image_id#docker-pullable://}"
	stripped="${stripped#containerd://}"
	if [[ "$stripped" =~ ^([^[:space:]@]+@)?sha256:[0-9a-f]{64}$ ]]; then
		printf '%s\n' "$stripped"
		return
	fi
	return 65
}

phase_for_job() {
	local job_json="$1"
	if yq -p=json -e '.status.conditions[]? | select(.type == "Complete" and .status == "True")' <<<"$job_json" >/dev/null; then
		printf '%s\n' 'Complete'
	elif yq -p=json -e '.status.conditions[]? | select(.type == "Failed" and .status == "True")' <<<"$job_json" >/dev/null; then
		printf '%s\n' 'Failed'
	elif [[ "$(yq -p=json -r '.status.active // 0' <<<"$job_json")" != '0' ]]; then
		printf '%s\n' 'Active'
	else
		printf '%s\n' 'Pending'
	fi
}

sanitize_summary() {
	local mode="$1" log_line="$2"
	if [[ "$mode" == 'capabilities' ]] && jq -e '
		(type == "object") and (.status == "passed" or .status == "failed") and
		(.uid | type == "number") and (.nodeName | type == "string") and
		(.configuredImageDigest | type == "string")
	' <<<"$log_line" >/dev/null 2>&1; then
		jq -r '
			"capabilities:status=\(.status) uid=\(.uid) node=\(.nodeName) " +
			"hevcQsv=\(.hevcQsv == true) realQsvEncode=\(.realQsvEncode == true) " +
			"libvmaf4k=\(.libvmaf4k == true) libx265=\(.libx265 == true)"
		' <<<"$log_line"
	elif [[ "$log_line" == "$run_id" ]]; then
		printf '%s\n' 'run-complete'
	else
		printf '%s\n' 'no-sanitized-summary'
	fi
}

evidence_status=0
while IFS= read -r job_json; do
	[[ -n "$job_json" ]] || continue
	name="$(yq -p=json -e -r '.metadata.name | select(test("^encode-benchmark-[a-z0-9.-]+$"))' <<<"$job_json")" || exit 65
	actual_run="$(yq -p=json -r '.metadata.labels."homelab-talos/benchmark-run" // ""' <<<"$job_json")"
	actual_app="$(yq -p=json -r '.metadata.labels."app.kubernetes.io/name" // ""' <<<"$job_json")"
	mode="$(yq -p=json -e -r '.metadata.labels."homelab-talos/benchmark-mode" | select(test("^[a-z][a-z0-9-]*$"))' <<<"$job_json")" || exit 65
	job_uid="$(yq -p=json -r '.metadata.uid // ""' <<<"$job_json")"
	[[ "$actual_run" == "$run_id" && "$actual_app" == 'encode-benchmark' ]] || {
		echo "refusing results for incorrectly owned Job: $name" >&2
		exit 65
	}
	phase="$(phase_for_job "$job_json")"
	succeeded="$(yq -p=json -r '.status.succeeded // 0' <<<"$job_json")"
	failed="$(yq -p=json -r '.status.failed // 0' <<<"$job_json")"
	start="$(yq -p=json -r '.status.startTime // ""' <<<"$job_json")"
	completion="$(yq -p=json -r '.status.completionTime // ""' <<<"$job_json")"
	matching_pods="$(JOB_NAME="$name" yq -p=json -o=json -I=0 \
		'[.items[] | select(.metadata.labels."job-name" == strenv(JOB_NAME))]' <<<"$pods")"
	pod_count="$(yq -p=json -r 'length' <<<"$matching_pods")"
	node=''
	if ((pod_count > 0)); then
		node="$(yq -p=json -r '.[0].spec.nodeName // ""' <<<"$matching_pods")"
	fi
	if [[ "$mode" == 'capabilities' ]]; then
		[[ "$phase" == 'Complete' && "$succeeded" == '1' && "$failed" == '0' ]] || {
			echo "capability result provenance rejected: Job $name is not Complete" >&2
			exit 1
		}
		[[ "$job_uid" =~ ^[a-zA-Z0-9._-]+$ && "$pod_count" == '1' ]] || {
			echo "capability result provenance rejected: Job $name does not have one exact pod" >&2
			exit 1
		}
		pod_phase="$(yq -p=json -r '.[0].status.phase // ""' <<<"$matching_pods")"
		controller_count="$(JOB_NAME="$name" JOB_UID="$job_uid" yq -p=json -r '
			[.[0].metadata.ownerReferences[]? | select(
				.controller == true and .apiVersion == "batch/v1" and .kind == "Job" and
				.name == strenv(JOB_NAME) and .uid == strenv(JOB_UID)
			)] | length
		' <<<"$matching_pods")"
		[[ "$pod_phase" == 'Succeeded' && "$controller_count" == '1' ]] || {
			echo "capability result provenance rejected: pod is not Succeeded and controlled by Job $name" >&2
			exit 1
		}
	fi
	printf 'job=%s mode=%s phase=%s succeeded=%s failed=%s start=%s completion=%s node=%s\n' \
		"$name" "$mode" "$phase" "$succeeded" "$failed" "$start" "$completion" "$node"
	if [[ "$phase" == 'Complete' || "$phase" == 'Failed' ]]; then
		actual_image_id=''
		if ((pod_count == 1)); then
			actual_image_id="$(yq -p=json -r '.[0].status.containerStatuses[]? | select(.name == "benchmark") | .imageID // ""' <<<"$matching_pods")"
		fi
		if ! normalized_image_id="$(normalize_image_id "$actual_image_id")"; then
			echo "actual image identity evidence rejected: job=$name missing-or-malformed" >&2
			evidence_status=1
		else
			actual_digest="${normalized_image_id##*@}"
			if [[ "$actual_digest" != "$configured_digest" ]]; then
				echo "actual image identity evidence rejected: job=$name digest-mismatch" >&2
				evidence_status=1
			else
				printf 'configured_image_digest=%s actual_image_id=%s image_evidence=accepted\n' \
					"$configured_digest" "$normalized_image_id"
			fi
		fi
	fi
	log_line="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" logs \
		"job/$name" --container benchmark --tail=1 2>/dev/null || true)"
	printf 'summary=%s\n' "$(sanitize_summary "$mode" "$log_line")"
done < <(yq -p=json -o=json -I=0 '.items[]' <<<"$jobs")

printf 'artifact_location=/out/runs/%s\n' "$run_id"
exit "$evidence_status"
