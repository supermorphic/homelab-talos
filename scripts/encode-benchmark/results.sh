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

configured_image="$(yq -e -r '.data."samples.json" | from_yaml | .runtime.image | select(test("^[^@[:space:]]+@sha256:[0-9a-f]{64}$"))' "$samples_source")"
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
if ((capability_job_count > 0 && capability_job_count != job_count)); then
	echo 'capability result provenance rejected: capability dispatch contains mixed Job modes' >&2
	exit 1
fi
if ((capability_job_count > 0)); then
	unique_job_names="$(yq -p=json -r '[.items[].metadata.name] | unique | length' <<<"$jobs")"
	unique_target_nodes="$(yq -p=json -r \
		'[.items[].spec.template.spec.nodeSelector."kubernetes.io/hostname" // ""] | unique | length' \
		<<<"$jobs")"
	all_target_nodes="$(yq -p=json -r \
		'[.items[].spec.template.spec.nodeSelector."kubernetes.io/hostname" // "" | select(length > 0)] | length' \
		<<<"$jobs")"
	if ((unique_job_names != job_count || unique_target_nodes != job_count || all_target_nodes != job_count)); then
		echo 'capability result provenance rejected: Job names and targeted nodes must be unique' >&2
		exit 1
	fi
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
	if yq -p=json -e '.status.conditions[]? | select(.type == "Complete" and .status == "True")' <<<"$job_json" >/dev/null 2>&1; then
		printf '%s\n' 'Complete'
	elif yq -p=json -e '.status.conditions[]? | select(.type == "Failed" and .status == "True")' <<<"$job_json" >/dev/null 2>&1; then
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

sanitize_capability_evidence() {
	local log_line="$1" node="$2" verified_at="$3" image_id="$4"
	jq -e -c --arg node "$node" --arg verified_at "$verified_at" \
		--arg image_id "$image_id" --arg digest "$configured_digest" '
		def reason_list:
			[]
			+ (if .initialization == "passed" then [] else ["initialization"] end)
			+ (if .selectedRateControl == "LA-ICQ" then [] else ["rate-control"] end)
			+ (if .telemetryStatus == "available" and .videoBusyNanoseconds > 0 then [] else ["telemetry"] end)
			+ (if .encodeSpeed > 0 then [] else ["progress"] end)
			+ (if .decode == "passed" then [] else ["decode"] end)
			+ (if .vmaf == "passed" then [] else ["vmaf"] end);
		def expected_status:
			if .telemetryStatus != "available" then "harness-blocked"
			elif (reason_list | length) == 0 then "passed"
			else "failed" end;
		select(
			type == "object" and
			.proofSchemaVersion == 2 and
			.nodeName == $node and
			(.initialization == "passed" or .initialization == "failed") and
			(.selectedRateControl | type == "string") and
			(.telemetryStatus == "available" or .telemetryStatus == "harness-blocked") and
			(.telemetryReason | type == "string") and
			((.telemetryStatus == "available" and .telemetryReason == "") or
				(.telemetryStatus == "harness-blocked" and (.telemetryReason | length) > 0)) and
			(.videoBusyNanoseconds | type == "number" and . >= 0) and
			(.videoBusyPercent | type == "number" and . >= 0) and
			(.encodeFps | type == "number" and . >= 0) and
			(.encodeSpeed | type == "number" and . >= 0) and
			(.decode == "passed" or .decode == "failed") and
			(.vmaf == "passed" or .vmaf == "failed") and
			.configuredImageDigest == $digest and
			.proofStatus == expected_status and .status == expected_status and
			.proofReasons == (reason_list | join(";")) and
			($verified_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
		) |
		{
			nodeName, proofSchemaVersion, initialization, selectedRateControl,
			telemetryStatus, telemetryReason, videoBusyNanoseconds, videoBusyPercent,
			encodeFps, encodeSpeed, decode, vmaf, proofStatus, proofReasons,
			verifiedAt: $verified_at, configuredImageDigest,
			imageId: $image_id
		}
	' <<<"$log_line"
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
	completion="$(yq -p=json -r '
		.status.completionTime //
		([.status.conditions[]? | select(.type == "Failed" and .status == "True") | .lastTransitionTime][0]) //
		""
	' <<<"$job_json")"
	matching_pods="$(JOB_NAME="$name" yq -p=json -o=json -I=0 \
		'[.items[] | select(.metadata.labels."job-name" == strenv(JOB_NAME))]' <<<"$pods")"
	pod_count="$(yq -p=json -r 'length' <<<"$matching_pods")"
	node=''
	if ((pod_count > 0)); then
		node="$(yq -p=json -r '.[0].spec.nodeName // ""' <<<"$matching_pods")"
	fi
	if [[ "$mode" == 'capabilities' ]]; then
		[[ "$phase" == 'Complete' || "$phase" == 'Failed' ]] || {
			echo "capability result provenance rejected: Job $name is not terminal" >&2
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
		target_node="$(yq -p=json -r '.spec.template.spec.nodeSelector."kubernetes.io/hostname" // ""' \
			<<<"$job_json")"
		[[ ("$pod_phase" == 'Succeeded' || "$pod_phase" == 'Failed') &&
			"$controller_count" == '1' && "$target_node" == "$node" ]] || {
			echo "capability result provenance rejected: pod is not terminal, controlled, and targeted for Job $name" >&2
			exit 1
		}
	fi
	printf 'job=%s mode=%s phase=%s succeeded=%s failed=%s start=%s completion=%s node=%s\n' \
		"$name" "$mode" "$phase" "$succeeded" "$failed" "$start" "$completion" "$node"
	normalized_image_id=''
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
	if [[ "$mode" == 'capabilities' ]]; then
		[[ -n "$normalized_image_id" ]] || continue
		capability_evidence="$(sanitize_capability_evidence "$log_line" "$node" "$completion" \
			"$normalized_image_id")" || {
			echo "capability result schema rejected: job=$name" >&2
			exit 1
		}
		proof_status="$(jq -r '.proofStatus' <<<"$capability_evidence")"
		if [[ ("$proof_status" == 'passed' && "$phase" == 'Complete' && "$pod_phase" == 'Succeeded') ||
			("$proof_status" != 'passed' && "$phase" == 'Failed' && "$pod_phase" == 'Failed') ]]; then
			printf 'capability_evidence=%s\n' "$capability_evidence"
		else
			echo "capability result provenance rejected: terminal phase contradicts proof for Job $name" >&2
			exit 1
		fi
	else
		printf 'summary=%s\n' "$(sanitize_summary "$mode" "$log_line")"
	fi
done < <(yq -p=json -o=json -I=0 '.items[]' <<<"$jobs")

printf 'artifact_location=/out/runs/%s\n' "$run_id"
exit "$evidence_status"
