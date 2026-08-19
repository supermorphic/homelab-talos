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
# shellcheck disable=SC1091
source "$repository_root/kubernetes/apps/media/encode-benchmark/app/scripts/contract.sh"
samples_document="$(mktemp "${TMPDIR:-/tmp}/encode-benchmark-results-samples.XXXXXX")"
trap 'rm -f -- "$samples_document"' EXIT
yq -e -r '.data."samples.json"' "$samples_source" >"$samples_document"
contract_load "$samples_document" || exit $?

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

configured_image="$(yq -e -r '.runtime.image | select(test("^[^@[:space:]]+@sha256:[0-9a-f]{64}$"))' "$samples_document")"
configured_digest="${configured_image##*@}"
selector="app.kubernetes.io/name=encode-benchmark,homelab-talos/benchmark-run=$run_id"

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

diagnostic_terminal_schema_error() {
	local reason="$1"
	printf 'terminal-summary-schema-error:%s\n' "$reason"
}

diagnostic_sanitize_terminal() {
	local terminal_message="$1" requested_run_id="$2"
	local parsed reason
	if [[ -z "$terminal_message" ]]; then
		printf '%s\n' 'no-sanitized-summary'
		return 65
	fi
	parsed="$(jq -e -c . <<<"$terminal_message" 2>/dev/null)" || {
		printf '%s\n' 'no-sanitized-summary'
		return 65
	}
	reason="$(jq -r --arg run "$requested_run_id" '
		def sorted_unique: sort == unique;
		def allowed_vmaf_reason:
			. == "classification-failed" or
			. == "classification-predicate-not-met" or
			. == "incomplete-or-failed-evidence" or
			. == "incomplete-setting-evidence" or
			. == "independent-metrics-not-target-minimum" or
			. == "missing-offset-window" or
			. == "nonzero-ssim-psnr-offset-agreement" or
			. == "offset-best-tie" or
			. == "one-setting-evidence" or
			. == "post-run-identity-drift" or
			. == "pts-reset-clears-vmaf-zero" or
			. == "source-window-clean" or
			. == "ssim-psnr-offset-disagreement" or
			. == "target-frame-local-metric-minimum" or
			. == "timeline-discontinuity-at-offset" or
			. == "vmaf-only-exact-zero" or
			. == "zero-offset-timeline-agreement";
		def allowed_hdr_reason:
			. == "authoritative-source-metadata" or
			. == "classification-failed" or
			. == "clip-metadata-changed" or
			. == "clip-window-absent" or
			. == "clip-window-malformed" or
			. == "clip-window-null" or
			. == "decoded-trace-disagreement" or
			. == "encoded-metadata-changed" or
			. == "encoded-window-absent" or
			. == "encoded-window-malformed" or
			. == "encoded-window-null" or
			. == "incomplete-or-failed-evidence" or
			. == "post-run-identity-drift" or
			. == "source-clip-encoded-metadata-agree" or
			. == "source-stream-probe-absent" or
			. == "source-stream-probe-conflict" or
			. == "source-stream-probe-malformed" or
			. == "source-probe-null" or
			. == "source-window-absent" or
			. == "source-window-conflict" or
			. == "source-window-malformed" or
			. == "source-window-null" or
			. == "stream-probe-null";
		def vmaf_counts:
			type == "object" and
			(keys | sort) == ["encoder-output-defect","reasons","temporal-alignment-defect","total","unresolved","vmaf-measurement-defect"] and
			.total == 5 and
			(."encoder-output-defect" | type == "number" and floor == . and . >= 0) and
			(."temporal-alignment-defect" | type == "number" and floor == . and . >= 0) and
			(.unresolved | type == "number" and floor == . and . >= 0) and
			(."vmaf-measurement-defect" | type == "number" and floor == . and . >= 0) and
			(."encoder-output-defect" + ."temporal-alignment-defect" + .unresolved + ."vmaf-measurement-defect" == 5) and
			(.reasons | type == "array" and length >= 1 and sorted_unique and all(.[]; type == "string" and allowed_vmaf_reason));
		def hdr_counts:
			type == "object" and
			(keys | sort) == ["clip-boundary-defect","encoder-output-defect","preserved","reasons","source-probe-defect","total","unresolved-oracle"] and
			.total == 3 and
			(."clip-boundary-defect" | type == "number" and floor == . and . >= 0) and
			(."encoder-output-defect" | type == "number" and floor == . and . >= 0) and
			(.preserved | type == "number" and floor == . and . >= 0) and
			(."source-probe-defect" | type == "number" and floor == . and . >= 0) and
			(."unresolved-oracle" | type == "number" and floor == . and . >= 0) and
			(."clip-boundary-defect" + ."encoder-output-defect" + .preserved + ."source-probe-defect" + ."unresolved-oracle" == 3) and
			(.reasons | type == "array" and length >= 1 and sorted_unique and all(.[]; type == "string" and allowed_hdr_reason));
		if type != "object" then "not-object"
		elif (keys | sort) != ["artifactLocation","hdr","mode","runId","schemaVersion","status","strategyId","vmaf"] then "wrong-keys"
		elif .schemaVersion != 1 then "wrong-schema-version"
		elif .strategyId != "qsv-hevc-icq-v1" then "wrong-strategy"
		elif .mode != "diagnostics" then "wrong-mode"
		elif .status != "complete" and .status != "harness-blocked" and .status != "failed" then "wrong-status"
		elif .runId != $run then "wrong-run-id"
		elif .artifactLocation != ("/out/runs/" + $run + "/diagnostics") then "wrong-artifact-location"
		elif (.vmaf | vmaf_counts | not) then "wrong-vmaf-counts"
		elif (.hdr | hdr_counts | not) then "wrong-hdr-counts"
		else "" end
	' <<<"$parsed")" || {
		printf '%s\n' "$(diagnostic_terminal_schema_error invalid-json)"
		return 65
	}
	if [[ -n "$reason" ]]; then
		printf '%s\n' "$(diagnostic_terminal_schema_error "$reason")"
		return 65
	fi
	jq -r '
		"mode=diagnostics " +
		"run_id=\(.runId) " +
		"status=\(.status) " +
		"vmaf_total=\(.vmaf.total) " +
		"vmaf_encoder_output_defect=\(.vmaf["encoder-output-defect"]) " +
		"vmaf_temporal_alignment_defect=\(.vmaf["temporal-alignment-defect"]) " +
		"vmaf_unresolved=\(.vmaf.unresolved) " +
		"vmaf_vmaf_measurement_defect=\(.vmaf["vmaf-measurement-defect"]) " +
		"vmaf_reasons=\(.vmaf.reasons | join(",")) " +
		"hdr_total=\(.hdr.total) " +
		"hdr_clip_boundary_defect=\(.hdr["clip-boundary-defect"]) " +
		"hdr_encoder_output_defect=\(.hdr["encoder-output-defect"]) " +
		"hdr_preserved=\(.hdr.preserved) " +
		"hdr_source_probe_defect=\(.hdr["source-probe-defect"]) " +
		"hdr_unresolved_oracle=\(.hdr["unresolved-oracle"]) " +
		"hdr_reasons=\(.hdr.reasons | join(","))"
	' <<<"$parsed"
}

diagnostic_results() {
	local all_pods_json="$1" requested_run_id="$2" matching_pods diagnostic_pods pod_count total_count pod_json pod_phase terminal_message sanitized_terminal
	matching_pods="$(RUN_ID="$requested_run_id" jq -c '
		[
			.items[]
			| select(.metadata.labels."app.kubernetes.io/name" == "encode-benchmark")
			| select(.metadata.labels."homelab-talos/benchmark-run" == env.RUN_ID)
		]
	' <<<"$all_pods_json")" || return 65
	diagnostic_pods="$(jq -c '[.[] | select(.metadata.labels."homelab-talos/benchmark-mode" == "diagnostics")]' <<<"$matching_pods")" || return 65
	pod_count="$(jq -r 'length' <<<"$diagnostic_pods")"
	total_count="$(jq -r 'length' <<<"$matching_pods")"
	((pod_count == 1 && total_count == 1)) || {
		echo "diagnostic result provenance rejected: expected one canonical diagnostics pod for run $requested_run_id" >&2
		return 1
	}
	pod_json="$(jq -c '.[0]' <<<"$diagnostic_pods")"
	pod_phase="$(jq -r '.status.phase // ""' <<<"$pod_json")"
	case "$pod_phase" in
	Running | Pending)
		printf 'mode=diagnostics phase=%s run_id=%s status=active\n' "$pod_phase" "$requested_run_id"
		return 0
		;;
	Succeeded | Failed)
		terminal_message="$(jq -r '
			[
				.status.containerStatuses[]?
				| select(.name == "benchmark")
				| (.state.terminated.message // .lastState.terminated.message // "")
			] |
			if length == 1 then .[0]
			elif length == 0 then ""
			else error("ambiguous diagnostic terminal message")
			end
		' <<<"$pod_json" 2>/dev/null)" || {
			printf '%s\n' "$(diagnostic_terminal_schema_error ambiguous-terminal-message)" >&2
			return 1
		}
		sanitized_terminal="$(diagnostic_sanitize_terminal "$terminal_message" "$requested_run_id")" || {
			printf '%s\n' "$sanitized_terminal" >&2
			return 1
		}
		printf 'mode=diagnostics phase=%s %s\n' "$pod_phase" "${sanitized_terminal#mode=diagnostics }"
		return 0
		;;
	*)
		printf 'mode=diagnostics phase=%s run_id=%s status=active\n' "${pod_phase:-Unknown}" "$requested_run_id"
		return 0
		;;
	esac
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

sanitize_quality_completion() {
	local log_line="$1" dispatch_id="$2" record runtime_id artifact_location
	record="$(jq -e -c --arg dispatch "$dispatch_id" '
		select(
			type == "object" and
			keys == ["artifactLocation","dispatchId","runtimeRunId","schemaVersion","status","strategyId"] and
			.schemaVersion == 1 and .strategyId == "qsv-hevc-icq-v1" and .status == "complete" and
			.dispatchId == $dispatch and
			(.runtimeRunId | type == "string") and
			.artifactLocation == ("/out/runs/" + .runtimeRunId)
		) |
		{dispatchId,runtimeRunId,artifactLocation}
	' <<<"$log_line")" || return 65
	runtime_id="$(jq -r '.runtimeRunId' <<<"$record")"
	contract_is_run_id "$runtime_id" || return 65
	[[ "${runtime_id%-*}" == "${dispatch_id%-*}" ]] || return 65
	artifact_location="$(jq -r '.artifactLocation' <<<"$record")"
	printf 'dispatch_id=%s runtime_run_id=%s artifact_location=%s\n' \
		"$dispatch_id" "$runtime_id" "$artifact_location"
}

sanitize_capability_evidence() {
	local log_line="$1" node="$2" verified_at="$3" image_id="$4"
	jq -e -c --arg node "$node" --arg verified_at "$verified_at" \
		--arg image_id "$image_id" --arg digest "$configured_digest" '
		def reason_list:
			[]
			+ (if .initialization == "passed" then [] else ["initialization"] end)
			+ (if .renderNode == "/dev/dri/renderD128" and .drmDriver == "i915" then [] else ["binding"] end)
			+ (if .selectedRateControl == "ICQ" then [] else ["rate-control"] end)
			+ (if .telemetryStatus == "available" and .videoBusyNanoseconds > 0 then [] else ["telemetry"] end)
			+ (if .encodeSpeed > 0 then [] else ["progress"] end)
			+ (if .decode == "passed" then [] else ["decode"] end)
			+ (if .vmaf == "passed" then [] else ["vmaf"] end);
		def expected_status:
			if .initialization != "passed" then "failed"
			elif .renderNode == "" or .drmDriver == "" or .selectedRateControl == "unknown" or
				.telemetryStatus != "available" then "harness-blocked"
			elif (reason_list | length) == 0 then "passed"
			else "failed" end;
		select(
			type == "object" and
				.strategyId == "qsv-hevc-icq-v1" and
				.proofSchemaVersion == 3 and
				.nodeName == $node and
				(.initialization == "passed" or .initialization == "failed") and
				(.initializationReason | type == "string") and
				((.initialization == "passed" and .initializationReason == "") or .initialization == "failed") and
				(.renderNode | type == "string") and
				(.drmDriver | type == "string") and
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
				nodeName, strategyId, proofSchemaVersion, initialization, initializationReason,
				renderNode, drmDriver, selectedRateControl,
			telemetryStatus, telemetryReason, videoBusyNanoseconds, videoBusyPercent,
			encodeFps, encodeSpeed, decode, vmaf, proofStatus, proofReasons,
			verifiedAt: $verified_at, configuredImageDigest,
			imageId: $image_id
		}
	' <<<"$log_line"
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

validate_prework_image_evidence() {
	local job_json="$1" name="$2" uid="$3" live_image_id="$4"
	local dispatched_image configmap_name configmap evidence normalized_evidence_id
	dispatched_image="$(yq -p=json -e -r '.spec.template.spec.containers[] | select(.name == "benchmark") | .image | select(test("^[^@[:space:]]+@sha256:[0-9a-f]{64}$"))' <<<"$job_json")" || return 65
	[[ "$dispatched_image" == "$configured_image" ]] || return 65
	configmap_name="$(yq -p=json -e -r '.metadata.annotations."homelab-talos/image-evidence-configmap" | select(test("^encode-benchmark-image-[a-z0-9-]+$"))' <<<"$job_json")" || return 65
	configmap="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get "configmap/$configmap_name" --output json)" || return
	[[ "$(yq -p=json -r '.metadata.name // ""' <<<"$configmap")" == "$configmap_name" ]] || return 65
	has_exact_job_controller_owner "$configmap" "$name" "$uid" || return 65
	evidence="$(yq -p=json -e -r '.data."image.json"' <<<"$configmap")" || return 65
	jq -e --arg configured "$configured_image" --arg dispatched "$dispatched_image" '
		type == "object" and keys == ["configuredImage","dispatchedImage","imageId"] and
		.configuredImage == $configured and .dispatchedImage == $dispatched and
		(.imageId | type == "string")
	' <<<"$evidence" >/dev/null || return 65
	normalized_evidence_id="$(normalize_image_id "$(jq -r '.imageId' <<<"$evidence")")" || return 65
	[[ "$normalized_evidence_id" == "$live_image_id" && "${normalized_evidence_id##*@}" == "$configured_digest" ]] || return 65
}

diagnostic_pods="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get pods \
	--selector "$selector" --output json)"
diagnostic_pod_count="$(RUN_ID="$run_id" yq -p=json -r '
	[
		.items[]
		| select(.metadata.labels."app.kubernetes.io/name" == "encode-benchmark")
		| select(.metadata.labels."homelab-talos/benchmark-run" == strenv(RUN_ID))
	] | length
' <<<"$diagnostic_pods")"
diagnostic_mode_pod_count="$(RUN_ID="$run_id" yq -p=json -r '
	[
		.items[]
		| select(.metadata.labels."app.kubernetes.io/name" == "encode-benchmark")
		| select(.metadata.labels."homelab-talos/benchmark-run" == strenv(RUN_ID))
		| select(.metadata.labels."homelab-talos/benchmark-mode" == "diagnostics")
	] | length
' <<<"$diagnostic_pods")"
if ((diagnostic_mode_pod_count > 0)); then
	diagnostic_results "$diagnostic_pods" "$run_id"
	exit $?
fi

jobs="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get jobs \
	--selector "$selector" --output json)"
pods="$diagnostic_pods"
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

evidence_status=0
quality_completion_count=0
runtime_artifact_location=''
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
		target_node="$(yq -p=json -r '.spec.template.spec.nodeSelector."kubernetes.io/hostname" // ""' \
			<<<"$job_json")"
		if [[ ("$pod_phase" != 'Succeeded' && "$pod_phase" != 'Failed') || "$target_node" != "$node" ]] ||
			! has_exact_job_controller_owner "$(jq -c '.[0]' <<<"$matching_pods")" "$name" "$job_uid"; then
			echo "capability result provenance rejected: pod is not terminal, controlled, and targeted for Job $name" >&2
			exit 1
		fi
		if [[ "$phase" == 'Complete' ]]; then
			[[ "$succeeded" == '1' && "$failed" == '0' && "$pod_phase" == 'Succeeded' ]] || {
				echo "capability result provenance rejected: terminal counts contradict Job $name" >&2
				exit 1
			}
		else
			[[ "$succeeded" == '0' && "$failed" == '1' && "$pod_phase" == 'Failed' ]] || {
				echo "capability result provenance rejected: terminal counts contradict Job $name" >&2
				exit 1
			}
		fi
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
				case "$mode" in
				capabilities | quality | savings | finalist | contention-*)
					if ! validate_prework_image_evidence "$job_json" "$name" "$job_uid" "$normalized_image_id"; then
						echo "pre-work image identity evidence rejected: job=$name" >&2
						evidence_status=1
						normalized_image_id=''
						continue
					fi
					printf 'configured_image_digest=%s actual_image_id=%s image_evidence=accepted\n' \
						"$configured_digest" "$normalized_image_id"
					;;
				*)
					printf 'configured_image_digest=%s actual_image_id=%s\n' \
						"$configured_digest" "$normalized_image_id"
					;;
				esac
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
	elif [[ "$mode" == 'quality' && "$phase" == 'Complete' ]]; then
		if ! [[ "$succeeded" == '1' && "$failed" == '0' && "$job_uid" =~ ^[a-zA-Z0-9._-]+$ &&
			"$pod_count" == '1' && "$(yq -p=json -r '.[0].status.phase // ""' <<<"$matching_pods")" == 'Succeeded' ]] ||
			! has_exact_job_controller_owner "$(jq -c '.[0]' <<<"$matching_pods")" "$name" "$job_uid"; then
			echo "quality completion provenance rejected: job=$name" >&2
			exit 1
		fi
		quality_dispatch_id="$(jq -e -r '
			[.spec.template.spec.containers[]? | select(.name == "benchmark") | .env[]? |
			 select(.name == "BENCHMARK_DISPATCH_CORRELATION_ID") | .value] |
			if length == 0 then ""
			elif length == 1 and (.[0] | type == "string" and length > 0) then .[0]
			else error("invalid quality dispatch correlation marker")
			end
		' <<<"$job_json")" || {
			echo "quality completion provenance rejected: job=$name" >&2
			exit 1
		}
		if [[ -n "$quality_dispatch_id" ]]; then
			[[ "$quality_dispatch_id" == "$run_id" ]] || {
				echo "quality completion provenance rejected: job=$name" >&2
				exit 1
			}
			quality_completion="$(sanitize_quality_completion "$log_line" "$run_id")" || {
				echo "quality completion record rejected: job=$name" >&2
				exit 1
			}
		else
			[[ "$log_line" == "$run_id" ]] || {
				echo "quality completion record rejected: job=$name" >&2
				exit 1
			}
			printf -v quality_completion 'dispatch_id=%s runtime_run_id=%s artifact_location=/out/runs/%s' \
				"$run_id" "$run_id" "$run_id"
		fi
		printf '%s\n' "$quality_completion"
		runtime_artifact_location="${quality_completion##* artifact_location=}"
		((quality_completion_count += 1))
	else
		printf 'summary=%s\n' "$(sanitize_summary "$mode" "$log_line")"
	fi
done < <(yq -p=json -o=json -I=0 '.items[]' <<<"$jobs")

if ((quality_completion_count > 0)); then
	((quality_completion_count == 1 && job_count == 1)) || {
		echo 'quality completion provenance rejected: expected one exact Job' >&2
		exit 1
	}
	printf 'artifact_location=%s\n' "$runtime_artifact_location"
else
	printf 'artifact_location=/out/runs/%s\n' "$run_id"
fi
exit "$evidence_status"
