#!/usr/bin/env bash
# Read the bounded collector result without opening any retained artifact.
set -euo pipefail

if (($# != 1)); then
	echo 'usage: diagnostic-evidence-results.sh <kubeconfig>' >&2
	exit 64
fi

readonly RUN_ID='20260820T223425Z-082b3d38'
readonly MODE='diagnostic-evidence-reader'
readonly MAX_BYTES=65536
kubeconfig="$1"
namespace='media'
expected_api='https://192.168.90.20:6443'
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../.." && pwd)"
samples_source="$repository_root/kubernetes/apps/media/encode-benchmark/app/samples.yaml"
app_directory="$repository_root/kubernetes/apps/media/encode-benchmark/app"
# shellcheck disable=SC1091
source "$repository_root/kubernetes/apps/media/encode-benchmark/app/scripts/contract.sh"

failed_collector_reason() {
	case "${1:-}" in
	'diagnostic evidence reader panel identity is malformed') printf '%s\n' 'diagnostic-evidence-reader-panel-identity-malformed' ;;
	'diagnostic evidence reader panel bounds are malformed') printf '%s\n' 'diagnostic-evidence-reader-panel-bounds-malformed' ;;
	'diagnostic evidence reader rejects an unapproved run id') printf '%s\n' 'diagnostic-evidence-reader-unapproved-run-id' ;;
	'diagnostic evidence root is missing or unsafe') printf '%s\n' 'diagnostic-evidence-root-unsafe' ;;
	'diagnostic evidence contains a symlink') printf '%s\n' 'diagnostic-evidence-symlink-present' ;;
	'diagnostic evidence files are missing or unexpected') printf '%s\n' 'diagnostic-evidence-files-unexpected' ;;
	'diagnostic evidence file is unsafe') printf '%s\n' 'diagnostic-evidence-file-unsafe' ;;
	'diagnostic evidence input exceeds its bounded size') printf '%s\n' 'diagnostic-evidence-input-exceeds-bounded-size' ;;
	'diagnostic evidence is malformed JSON') printf '%s\n' 'diagnostic-evidence-malformed-json' ;;
	'diagnostic summary does not bind the approved panel') printf '%s\n' 'diagnostic-summary-binding-invalid' ;;
	'VMAF diagnostic evidence violates its approved schema') printf '%s\n' 'vmaf-diagnostic-evidence-schema-invalid' ;;
	'VMAF diagnostic evidence does not match its retained summary') printf '%s\n' 'vmaf-diagnostic-evidence-summary-mismatch' ;;
	'HDR diagnostic evidence violates its approved schema') printf '%s\n' 'hdr-diagnostic-evidence-schema-invalid' ;;
	'HDR diagnostic evidence does not match its retained summary') printf '%s\n' 'hdr-diagnostic-evidence-summary-mismatch' ;;
	'canonical diagnostic evidence exceeds the output limit') printf '%s\n' 'canonical-diagnostic-evidence-output-limit-exceeded' ;;
	*) return 1 ;;
	esac
}

[[ -f "$kubeconfig" ]] || {
	echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
	exit 1
}
api_server="$(kubectl --kubeconfig "$kubeconfig" config view --minify --output jsonpath='{.clusters[0].cluster.server}')"
[[ "$api_server" == "$expected_api" ]] || {
	echo "Refusing diagnostic evidence results: kubeconfig targets $api_server, not $expected_api." >&2
	exit 1
}
configured_image="$(yq -e -r '.data."samples.json" | from_json | .runtime.image | select(test("^[^@[:space:]]+@sha256:[0-9a-f]{64}$"))' "$samples_source")"
samples_document="$(yq -e -r '.data."samples.json"' "$samples_source")"
expected_panel_sha256="$(contract_diagnostics_panel_sha256 /dev/stdin <<<"$samples_document")"
expected_evidence_panel="$(contract_diagnostics_evidence_panel_json /dev/stdin <<<"$samples_document")"
vmaf_reason_classes="$(contract_diagnostics_terminal_vmaf_reason_classes_json)"
hdr_reason_classes="$(contract_diagnostics_terminal_hdr_reason_classes_json)"
rendered_source="$(kustomize build "$app_directory")"
scripts_count="$(yq -N -r 'select(.kind == "ConfigMap" and (.metadata.name | test("^encode-benchmark-scripts-[a-z0-9]{10}$"))) | .metadata.name' <<<"$rendered_source" | wc -l | tr -d '[:space:]')"
[[ "$scripts_count" == '1' ]] || {
	echo 'diagnostic evidence result provenance rejected: rendered scripts identity is ambiguous' >&2
	exit 65
}
expected_scripts_configmap="$(yq -N -r 'select(.kind == "ConfigMap" and (.metadata.name | test("^encode-benchmark-scripts-[a-z0-9]{10}$"))) | .metadata.name' <<<"$rendered_source")"
selector="app.kubernetes.io/name=encode-benchmark,homelab-talos/benchmark-run=$RUN_ID,homelab-talos/benchmark-mode=$MODE"
jobs="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get jobs --selector "$selector" --output json)"
[[ "$(jq -r '.items | length' <<<"$jobs")" == '1' ]] || {
	echo 'diagnostic evidence result provenance rejected: expected one collector Job' >&2
	exit 1
}
job="$(jq -c '.items[0]' <<<"$jobs")"
name="$(jq -e -r '.metadata.name | select(. == "encode-benchmark-evidence-reader-20260820t223425z-082b3d38")' <<<"$job")" || exit 65
uid="$(jq -e -r '.metadata.uid | select(type == "string" and length > 0)' <<<"$job")" || exit 65
job_state="$(jq -e -r --arg run "$RUN_ID" --arg mode "$MODE" --arg name "$name" --arg image "$configured_image" --arg scripts "$expected_scripts_configmap" --arg panel_sha "$expected_panel_sha256" --arg evidence_panel "$expected_evidence_panel" '
	def base_contract:
		.metadata.name == $name and
		.metadata.labels."app.kubernetes.io/name" == "encode-benchmark" and
		.metadata.labels."homelab-talos/benchmark-dispatch" == $run and
		.metadata.labels."homelab-talos/benchmark-run" == $run and .metadata.labels."homelab-talos/benchmark-mode" == $mode and
		.metadata.annotations."homelab-talos/benchmark-owned" == "true" and
		.metadata.annotations."homelab-talos/scripts-configmap" == $scripts and
		.spec.backoffLimit == 0 and .spec.activeDeadlineSeconds == 300 and .spec.ttlSecondsAfterFinished == 3600 and
		(.spec.template.metadata.labels."app.kubernetes.io/name" == "encode-benchmark" and
		 .spec.template.metadata.labels."homelab-talos/benchmark-dispatch" == $run and
		 .spec.template.metadata.labels."homelab-talos/benchmark-run" == $run and
		 .spec.template.metadata.labels."homelab-talos/benchmark-mode" == $mode) and
		(.spec.template.spec.automountServiceAccountToken == false and .spec.template.spec.restartPolicy == "Never" and
		 .spec.template.spec.securityContext == {runAsNonRoot:true,runAsUser:568,runAsGroup:568,fsGroup:568,fsGroupChangePolicy:"OnRootMismatch",seccompProfile:{type:"RuntimeDefault"}} and
		 (.spec.template.spec | has("initContainers") | not)) and
		(.spec.template.spec.containers | type == "array" and length == 1) and
		(.spec.template.spec.containers[0] | .name == "benchmark" and .image == $image and
			 .command == ["/scripts/diagnostic-evidence.sh","collect",$run,"/evidence",$panel_sha,$evidence_panel] and
		 (has("env") | not) and (has("envFrom") | not) and (has("volumeDevices") | not) and
		 .securityContext == {allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]}} and
		 .resources == {requests:{cpu:"100m",memory:"128Mi"},limits:{cpu:"500m",memory:"256Mi"}} and
		 (.volumeMounts | type == "array" and length == 2 and
		  ([.[] | select(.name == "scripts" and .mountPath == "/scripts" and .readOnly == true)] | length) == 1 and
		  ([.[] | select(.name == "evidence" and .mountPath == "/evidence" and .subPath == "benchmark/runs/20260820T223425Z-082b3d38/diagnostics" and .readOnly == true)] | length) == 1)) and
		(.spec.template.spec.volumes | type == "array" and length == 2 and
		 ([.[] | select(.name == "scripts" and .configMap.name == $scripts and .configMap.defaultMode == 365)] | length) == 1 and
		 ([.[] | select(.name == "evidence" and .persistentVolumeClaim == {claimName:"media-data",readOnly:true})] | length) == 1);
	if base_contract and
		([.status.conditions[]? | select(.type == "Complete" and .status == "True")] | length == 1) and
		(.status.succeeded == 1 and (.status.failed // 0) == 0)
	then "complete"
	elif base_contract and
		([.status.conditions[]? | select(.type == "Complete" and .status == "True")] | length == 0) and
		([.status.conditions[]? | select(.type == "Failed" and .status == "True" and .reason == "BackoffLimitExceeded")] | length == 1) and
		((.status.active // 0) == 0) and ((.status.succeeded // 0) == 0) and ((.status.failed // 0) == 1)
	then "failed"
	else empty end
' <<<"$job")" || true
[[ "$job_state" == 'complete' || "$job_state" == 'failed' ]] || {
	echo 'diagnostic evidence result provenance rejected: Job is not the terminal collector' >&2
	exit 1
}

pods="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get pods --selector "$selector" --output json)"
[[ "$(jq -r '.items | length' <<<"$pods")" == '1' ]] || {
	echo 'diagnostic evidence result provenance rejected: expected one collector Pod' >&2
	exit 1
}
pod="$(jq -c '.items[0]' <<<"$pods")"
pod_state="$(jq -e -r --arg run "$RUN_ID" --arg mode "$MODE" --arg name "$name" --arg uid "$uid" --arg image "$configured_image" --arg scripts "$expected_scripts_configmap" --arg panel_sha "$expected_panel_sha256" --arg evidence_panel "$expected_evidence_panel" '
	def image_matches:
		([.status.containerStatuses[] | select(.name == "benchmark") | .imageID | sub("^(docker-pullable|containerd)://"; "")] | .[0]) as $image_id |
		($image_id == $image or $image_id == ($image | split("@") | .[1]));
	def base_contract:
		.metadata.labels."app.kubernetes.io/name" == "encode-benchmark" and
		.metadata.labels."homelab-talos/benchmark-dispatch" == $run and
		.metadata.labels."homelab-talos/benchmark-run" == $run and
		.metadata.labels."homelab-talos/benchmark-mode" == $mode and
		.metadata.labels."job-name" == $name and
		([(.metadata.annotations // {}) | keys[] | select(test("apparmor|seccomp"; "i"))] | length) == 0 and
		(.metadata.ownerReferences | type == "array" and length == 1 and .[0].apiVersion == "batch/v1" and .[0].kind == "Job" and .[0].name == $name and .[0].uid == $uid and .[0].controller == true and .[0].blockOwnerDeletion == true) and
		(.spec.automountServiceAccountToken == false and .spec.restartPolicy == "Never" and
		 .spec.securityContext == {runAsNonRoot:true,runAsUser:568,runAsGroup:568,fsGroup:568,fsGroupChangePolicy:"OnRootMismatch",seccompProfile:{type:"RuntimeDefault"}} and
		 (.spec.hostNetwork // false) == false and (.spec.hostPID // false) == false and (.spec.hostIPC // false) == false and
		 (.spec.shareProcessNamespace // false) == false and
		 ((.spec.initContainers // []) | type == "array" and length == 0) and
		 ((.spec.ephemeralContainers // []) | type == "array" and length == 0)) and
		(.spec.containers | type == "array" and length == 1) and
		(.spec.containers[0] |
		 .name == "benchmark" and .image == $image and
		 .command == ["/scripts/diagnostic-evidence.sh","collect",$run,"/evidence",$panel_sha,$evidence_panel] and
		 (has("env") | not) and (has("envFrom") | not) and (has("volumeDevices") | not) and
		 .securityContext == {allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]}} and
		 .resources == {requests:{cpu:"100m",memory:"128Mi"},limits:{cpu:"500m",memory:"256Mi"}} and
		 (.volumeMounts | type == "array" and length == 2 and
		  ([.[] | select(.name == "scripts" and .mountPath == "/scripts" and .readOnly == true)] | length) == 1 and
		  ([.[] | select(.name == "evidence" and .mountPath == "/evidence" and .subPath == "benchmark/runs/20260820T223425Z-082b3d38/diagnostics" and .readOnly == true)] | length) == 1)) and
		(.spec.volumes | type == "array" and length == 2 and
		 ([.[] | select(.name == "scripts" and .configMap.name == $scripts and .configMap.defaultMode == 365)] | length) == 1 and
		 ([.[] | select(.name == "evidence" and .persistentVolumeClaim == {claimName:"media-data",readOnly:true})] | length) == 1) and
		(.status.containerStatuses | type == "array" and length == 1 and .[0].name == "benchmark") and
		image_matches;
	if base_contract and .status.phase == "Succeeded" then "complete"
	elif base_contract and .status.phase == "Failed" and
		(.status.containerStatuses[0].ready == false) and
		(.status.containerStatuses[0].restartCount == 0) and
		((.status.containerStatuses[0].lastState // {}) == {}) and
		(.status.containerStatuses[0].state | type == "object" and (keys | sort) == ["terminated"]) and
		(.status.containerStatuses[0].state.terminated.exitCode == 65) and
		(.status.containerStatuses[0].state.terminated.reason == "Error")
	then "failed"
	else empty end
' <<<"$pod")" || true
[[ "$pod_state" == "$job_state" ]] || {
	echo 'diagnostic evidence result provenance rejected: Pod ownership or image identity is invalid' >&2
	exit 1
}

payload="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" logs "job/$name" --container benchmark)"
[[ "$(wc -l <<<"$payload" | tr -d '[:space:]')" == '1' ]] || {
	echo 'diagnostic evidence result is ambiguous' >&2
	exit 65
}
payload_bytes="$(printf '%s' "$payload" | LC_ALL=C wc -c | tr -d '[:space:]')"
[[ "$payload_bytes" =~ ^[0-9]+$ && "$payload_bytes" -le "$MAX_BYTES" ]] || {
	echo 'diagnostic evidence result exceeds its bounded size' >&2
	exit 65
}
if [[ "$job_state" == 'failed' ]]; then
	manifest_issues="$(jq -e -S -c '
		def exact($expected_keys): type == "object" and (keys | sort) == ($expected_keys | sort);
		def issue_kind: . == "missing" or . == "wrong-type" or . == "mismatch";
		. as $payload |
		[
			"manifest",
			"schemaVersion",
			"mode",
			"createdAt",
			"upstream.diagnostics",
			"upstream.diagnostics.manifestSchemaVersion",
			"upstream.diagnostics.resultSchemaVersion",
			"upstream.diagnostics.acceptedFindingsSha256",
			"upstream.diagnostics.decisionSha256",
			"upstream.diagnostics.historicalQualityRunId",
			"upstream.diagnostics.historicalFindingsRunId",
			"upstream.diagnostics.panelSha256"
		] as $fields |
		select(exact(["manifestIssues","reason","schemaVersion","status"]) and
		.schemaVersion == 1 and .status == "failed" and .reason == "diagnostic-manifest-binding-invalid" and
		(.manifestIssues | type == "array" and length >= 1 and
		 all(.[]; exact(["field","kind"]) and (.field as $field | ($field | type) == "string" and ($fields | index($field)) != null) and (.kind | issue_kind)) and
		 length == (unique_by(.field) | length) and
		 ([.[].field as $field | $fields | index($field)] | . == sort) and
		 (if any(.[]; .field == "manifest") then length == 1 else true end) and
		 (if any(.[]; .field == "upstream.diagnostics") then all(.[]; (.field | startswith("upstream.diagnostics.")) | not) else true end))) |
		$payload.manifestIssues
	' <<<"$payload" 2>/dev/null || true)"
	if [[ -n "$manifest_issues" && "$(jq -S -c . <<<"$payload")" == "$payload" ]]; then
		jq -n -S -c --arg run "$RUN_ID" --argjson issues "$manifest_issues" '
			{
				schemaVersion:1,
				strategyId:"qsv-hevc-icq-v1",
				mode:"diagnostic-evidence-reader",
				runId:$run,
				status:"failed",
				reason:"diagnostic-manifest-binding-invalid",
				manifestIssues:$issues
			}
		'
		exit 0
	fi
	failed_reason="$(failed_collector_reason "$payload" || true)"
	[[ -n "$failed_reason" ]] || {
		echo 'diagnostic evidence failed result is not allowlisted' >&2
		exit 65
	}
	jq -n -S -c --arg run "$RUN_ID" --arg reason "$failed_reason" '
		{
			schemaVersion:1,
			strategyId:"qsv-hevc-icq-v1",
			mode:"diagnostic-evidence-reader",
			runId:$run,
			status:"failed",
			reason:$reason
		}
	'
	exit 0
fi
[[ "$(jq -S -c . <<<"$payload")" == "$payload" ]] || {
	echo 'diagnostic evidence result is not canonical' >&2
	exit 65
}
jq -e -c -L "$app_directory/scripts" --arg run "$RUN_ID" --argjson panel "$expected_evidence_panel" --argjson vmaf_reason_classes "$vmaf_reason_classes" --argjson hdr_reason_classes "$hdr_reason_classes" '
	include "diagnostic-contract";
	def exact($expected): type == "object" and (keys | sort) == ($expected | sort);
	def status: . == "complete" or . == "failed" or . == "harness-blocked";
	def numeric_string: type == "string" and test("^-?[0-9]+([.][0-9]+)?$");
	def rational_string: type == "string" and test("^-?[0-9]+/[1-9][0-9]*$");
	def gcd($a; $b): if $b == 0 then $a else gcd($b; ($a % $b)) end;
	def rational: exact(["denominator","numerator"]) and (.numerator | type == "number" and floor == . and . >= 0) and (.denominator | type == "number" and floor == . and . > 0) and (gcd(.numerator; .denominator) == 1);
	def chromaticity: exact(["x","y"]) and (.x | rational) and (.y | rational);
	def metadata: exact(["masteringDisplay","maxCLL","maxFALL"]) and (.masteringDisplay | exact(["displayPrimaries","luminance","whitePoint"]) and (.displayPrimaries | exact(["blue","green","red"]) and (.red | chromaticity) and (.green | chromaticity) and (.blue | chromaticity)) and (.whitePoint | chromaticity) and (.luminance | exact(["max","min"]) and (.min | rational) and (.max | rational))) and (.maxCLL | rational) and (.maxFALL | rational);
	def stream_oracle: (exact(["status"]) and .status == "null") or (exact(["metadata","status"]) and .status == "ok" and (.metadata | metadata));
	def pair_oracle: (exact(["status"]) and .status == "absent") or (exact(["metadata","status"]) and .status == "ok" and (.metadata | metadata));
	def expected_pair_authoritative($absent_reason):
		if .decoded.status == "ok" and .trace.status == "ok" then
			if .decoded.metadata == .trace.metadata then {status:"ok",metadata:.decoded.metadata}
			else {status:"unresolved",reasons:["decoded-trace-disagreement"]} end
		else {status:"unresolved",reasons:[$absent_reason]} end;
	def normalized_pair($absent_reason):
		exact(["authoritative","decoded","trace"]) and (.decoded | pair_oracle) and (.trace | pair_oracle) and
		.authoritative == expected_pair_authoritative($absent_reason);
	def expected_source_authoritative:
		([.beginning.authoritative,.detail.authoritative,.end.authoritative]) as $windows |
		if any($windows[]; .status != "ok") then ($windows | map(select(.status != "ok"))[0])
		elif ([$windows[].metadata] | unique | length) != 1 then {status:"unresolved",reasons:["source-window-conflict"]}
		else {status:"ok",metadata:$windows[0].metadata} end;
	def normalized_oracle:
		exact(["clip","encoded","schemaVersion","source"]) and .schemaVersion == 1 and
		(.source | exact(["authoritative","streamProbe","windows"]) and (.streamProbe | stream_oracle) and
			(.windows | exact(["beginning","detail","end"]) and (.beginning | normalized_pair("source-window-absent")) and (.detail | normalized_pair("source-window-absent")) and (.end | normalized_pair("source-window-absent"))) and
			.authoritative == (.windows | expected_source_authoritative)) and
		(.clip | normalized_pair("clip-window-absent")) and
		(.encoded | normalized_pair("encoded-window-absent"));
	def class($classes; $allowed; $evidence_status; $unresolved): . as $class | exact(["classification","reasons","schemaVersion"]) and .schemaVersion == 1 and ($allowed | index($class.classification)) != null and (if $evidence_status == "complete" then true else $class.classification == $unresolved end) and (.reasons | type == "array" and length >= 1 and length <= 16 and length == (unique | length) and all(.[]; type == "string" and ($classes[.] | type == "array") and ($classes[.] | index($class.classification)) != null));
	def psnr: . == null or type == "number" or (exact(["kind"]) and .kind == "positive-infinity") or (exact(["kind","value"]) and .kind == "finite" and (.value | type == "number"));
	def vmaf_frame: exact(["frameIndex","vmaf"]) and (.frameIndex | type == "number" and floor == .) and (.vmaf | type == "number");
	def partial_vmaf_frames($observed): type == "array" and all(.[]; vmaf_frame) and (length == 0 or (length == 5 and ([.[].frameIndex] | sort) == [range($observed - 2; $observed + 3)]));
	def setting_reason: . == "decode-failed" or . == "encode-failed" or . == "incomplete-output-frame-window" or . == "missing-current-vmaf" or . == "missing-psnr-metric" or . == "missing-reset-vmaf" or . == "missing-ssim-metric" or . == "output-identity-unavailable" or . == "post-run-identity-drift" or . == "source-clip-unavailable" or . == "timeline-evidence-invalid";
	def empty_metrics: (.vmaf.current | length == 0) and (.vmaf.reset | length == 0);
	def current_metrics_only: (.vmaf.current | length == 5) and (.vmaf.reset | length == 0);
	def complete_metrics: (.vmaf.current | length == 5) and (.vmaf.reset | length == 5);
	def offset_metric_presence:
		[.offsets | sort_by(.offset)[] | (.ssim != null), (.psnr != null)];
	def offset_metric_count:
		offset_metric_presence | map(select(.)) | length;
	def offset_metric_prefix:
		offset_metric_presence as $present |
		any(range(0; 11); . as $count |
			all(range(0; $count); $present[.] == true) and
			all(range($count; 10); $present[.] == false));
	def baseline_timeline: .timeline.zeroOffsetAligned == false and .timeline.discontinuity == null;
	def reachable_setting_shape($source):
		if $source == null then
			empty_metrics and offset_metric_count == 0 and baseline_timeline
		else
			(empty_metrics and offset_metric_count == 0 and baseline_timeline) or
			(current_metrics_only and offset_metric_count == 0 and baseline_timeline) or
			(complete_metrics and offset_metric_prefix and
				(if offset_metric_count < 10 then baseline_timeline else true end))
		end;
	def normal_setting_coupling($source):
		if .status == "complete" then
			.reason == null and $source != null and complete_metrics and offset_metric_count == 10
		elif .status == "failed" then
			(.reason == "encode-failed" or .reason == "decode-failed") and $source != null and empty_metrics and offset_metric_count == 0 and baseline_timeline
		elif .reason == "source-clip-unavailable" then
			empty_metrics and offset_metric_count == 0 and baseline_timeline
		elif .reason == "output-identity-unavailable" or .reason == "incomplete-output-frame-window" or .reason == "missing-current-vmaf" then
			$source != null and empty_metrics and offset_metric_count == 0 and baseline_timeline
		elif .reason == "missing-reset-vmaf" then
			$source != null and current_metrics_only and offset_metric_count == 0 and baseline_timeline
		elif .reason == "missing-ssim-metric" then
			$source != null and complete_metrics and (offset_metric_count % 2) == 0 and offset_metric_count < 10 and baseline_timeline
		elif .reason == "missing-psnr-metric" then
			$source != null and complete_metrics and (offset_metric_count % 2) == 1 and baseline_timeline
		elif .reason == "timeline-evidence-invalid" then
			$source != null and complete_metrics and offset_metric_count == 10 and baseline_timeline
		else false end;
	def setting($observed; $source): exact(["globalQuality","offsets","reason","status","timeline","vmaf"]) and (.globalQuality == 16 or .globalQuality == 30) and (.status | status) and (if .status == "complete" then .reason == null else (.reason | setting_reason) end) and (.vmaf | exact(["current","reset"]) and (.current | partial_vmaf_frames($observed)) and (.reset | partial_vmaf_frames($observed))) and (.offsets | type == "array" and length == 5 and ([.[].offset] | sort) == [-2,-1,0,1,2] and all(.[]; exact(["offset","psnr","ssim"]) and (.offset | type == "number" and floor == . and . >= -2 and . <= 2) and (.ssim == null or (.ssim | type == "number")) and (.psnr | psnr))) and (.timeline | exact(["discontinuity","zeroOffsetAligned"]) and (.zeroOffsetAligned | type == "boolean") and (.discontinuity == null or (exact(["kind","offset"]) and (.kind == "drop" or .kind == "duplicate" or .kind == "timestamp-discontinuity") and (.offset | type == "number" and floor == . and . >= -2 and . <= 2 and . != 0)))) and reachable_setting_shape($source);
	def merged_status:
		if any(.[]; .status == "failed") then "failed"
		elif any(.[]; .status == "harness-blocked") then "harness-blocked"
		else "complete" end;
	def continuity: exact(["issue","status"]) and (.status == "clean" and .issue == null or .status == "discontinuity" and (.issue | exact(["afterFrameIndex","kind"]) and (.afterFrameIndex | type == "number" and floor == .) and (.kind == "gap" or .kind == "inconsistent-duration" or .kind == "non-monotonic-timestamp" or .kind == "repeat")));
	def source_object($observed): exact(["decodedFrameCount","frames","sourceWindow","stream"]) and (.decodedFrameCount | type == "number" and floor == . and . >= 0) and (.stream | exact(["averageFrameRate","duration","startTime","timeBase"]) and (.startTime | numeric_string) and (.duration | numeric_string) and (.timeBase | rational_string) and (.averageFrameRate | rational_string)) and (.frames | type == "array" and length == 5 and all(.[]; exact(["bestEffortTimestamp","frameIndex","keyFrame","packetDuration","pictureType"]) and (.frameIndex | type == "number" and floor == .) and (.bestEffortTimestamp | numeric_string) and (.packetDuration | numeric_string) and (.keyFrame | type == "boolean") and (.pictureType == "I" or .pictureType == "P" or .pictureType == "B")) and ([.[].frameIndex] | sort) == [range($observed - 2; $observed + 3)]) and (.sourceWindow | continuity) and .sourceWindow == (.frames | diagnostic_continuity);
	def source($observed): . == null or source_object($observed);
	def evidence_reason: . == "HDR-classification-failed" or . == "HDR-oracle-normalization-failed" or . == "clip-identity-unavailable" or . == "conflicting-HDR-oracle" or . == "decode-failed" or . == "encode-failed" or . == "output-identity-unavailable" or . == "post-run-identity-drift" or . == "source-clip-unavailable" or . == "source-duration-unavailable" or . == "source-identity-unavailable" or . == "source-stream-oracle-failed";
	def classifier_setting($observed; $source):
		. as $setting |
		{
			globalQuality:$setting.globalQuality,
			completeEvidence:($setting.status == "complete"),
			currentTargetVmaf:([$setting.vmaf.current[] | select(.frameIndex == $observed) | .vmaf][0] // 0),
			resetTargetVmaf:([$setting.vmaf.reset[] | select(.frameIndex == $observed) | .vmaf][0] // 0),
			sourceWindow:{status:(if $setting.status == "failed" then "decode-error" else ($source.sourceWindow.status // "discontinuity") end)},
			timeline:$setting.timeline,
			offsets:$setting.offsets
		};
	def expected_vmaf_classification:
		. as $row |
		{schemaVersion:1,sampleId:.sampleId,clipId:.clipId,observedFrameIndex:.observedFrameIndex,settings:[.settings[] | classifier_setting($row.observedFrameIndex; $row.sourceContinuity)]} |
		diagnostic_vmaf_classify;
	def vmaf_classifier_failure_override:
		.status == "harness-blocked" and all(.settings[]; .status == "complete" and .reason == null) and
		.classification == {schemaVersion:1,classification:"unresolved",reasons:["classification-failed"]};
	def vmaf_row:
		. as $evidence |
		([$panel.vmaf[] | select(.sampleId == $evidence.sampleId and .clipId == $evidence.clipId)][0]) as $binding |
		exact(["classification","clipId","observedFrameIndex","sampleId","settings","sourceContinuity","status"]) and
		$binding != null and .observedFrameIndex == $binding.observedFrameIndex and (.status | status) and
		(.sourceContinuity | source($evidence.observedFrameIndex)) and
		(.settings | type == "array" and length == 2 and
			all(.[]; setting($evidence.observedFrameIndex; $evidence.sourceContinuity)) and
			([.[].globalQuality] | sort) == [16,30]) and
		(if any($evidence.settings[]; .reason == "post-run-identity-drift") then
			$evidence.status == "harness-blocked" and
			all($evidence.settings[]; .status == "harness-blocked" and .reason == "post-run-identity-drift") and
			$evidence.classification == {schemaVersion:1,classification:"unresolved",reasons:["post-run-identity-drift"]}
		elif vmaf_classifier_failure_override then
			true
		else
			all($evidence.settings[]; normal_setting_coupling($evidence.sourceContinuity)) and
			$evidence.status == ($evidence.settings | merged_status) and
			$evidence.classification == expected_vmaf_classification
		end) and
		(.classification | class($vmaf_reason_classes; ["encoder-output-defect","temporal-alignment-defect","unresolved","vmaf-measurement-defect"]; $evidence.status; "unresolved"));
	def reachable_hdr_shape: .normalizedOracle == null or (.normalizedOracle | normalized_oracle);
	def normalized_conflict:
		[
			.normalizedOracle.source.authoritative.reasons[]?,
			.normalizedOracle.source.windows[].authoritative.reasons[]?,
			.normalizedOracle.clip.authoritative.reasons[]?,
			.normalizedOracle.encoded.authoritative.reasons[]?
		] | any(. == "decoded-trace-disagreement" or . == "source-window-conflict");
	def normal_hdr_coupling:
		if .status == "complete" then
			.reason == null and (.normalizedOracle | normalized_oracle) and (normalized_conflict | not)
		elif .status == "failed" then
			(.reason == "encode-failed" or .reason == "decode-failed") and .normalizedOracle == null
		elif .reason == "conflicting-HDR-oracle" then
			(.normalizedOracle | normalized_oracle) and normalized_conflict
		elif .reason == "HDR-classification-failed" then
			(.normalizedOracle | normalized_oracle) and (normalized_conflict | not)
		else
			.reason != "encode-failed" and .reason != "decode-failed" and
			(.reason == null or (.reason | evidence_reason)) and .normalizedOracle == null
		end;
	def expected_hdr_classification:
		if .status == "complete" then (.normalizedOracle | diagnostic_hdr_classify_normalized)
		else {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]} end;
	def hdr_classifier_failure_override:
		.status == "harness-blocked" and .reason == "HDR-classification-failed" and
		(.normalizedOracle | normalized_oracle) and (normalized_conflict | not) and
		.classification == {schemaVersion:1,classification:"unresolved-oracle",reasons:["classification-failed"]};
	def hdr_row:
		. as $evidence |
		exact(["classification","clipId","globalQuality","normalizedOracle","reason","sampleId","status"]) and
		(.sampleId | type == "string") and .clipId == "detail" and .globalQuality == 16 and
		(.status | status) and reachable_hdr_shape and
		(if .reason == "post-run-identity-drift" then
			.status == "harness-blocked" and
			.classification == {schemaVersion:1,classification:"unresolved-oracle",reasons:["post-run-identity-drift"]}
		elif .reason == "HDR-classification-failed" then
			hdr_classifier_failure_override
		else normal_hdr_coupling and .classification == expected_hdr_classification end) and
		(.classification | class($hdr_reason_classes; ["clip-boundary-defect","encoder-output-defect","preserved","source-probe-defect","unresolved-oracle"]; $evidence.status; "unresolved-oracle"));
	type == "object" and keys == ["hdr","mode","runId","schemaVersion","strategyId","vmaf"] and
	.schemaVersion == 1 and .strategyId == "qsv-hevc-icq-v1" and .mode == "diagnostic-evidence-reader" and .runId == $run and
	(.vmaf | type == "array" and length == 5 and all(.[]; vmaf_row) and ([.[] | [.sampleId,.clipId] | join("/")] | sort) == ["avc-clean-coco/motion","avc-grain-memento/dark","avc-grain-memento/detail","vc1-fugitive/detail","vc1-fugitive/motion"]) and
	(.hdr | type == "array" and length == 3 and all(.[]; hdr_row) and ([.[] | .sampleId] | sort) == ["hdr10-clean-ministry","hdr10-grain-goodfellas","hdr10-motion-john-wick-2"])
' <<<"$payload" >/dev/null || {
	echo 'diagnostic evidence result schema rejected' >&2
	exit 65
}
printf '%s\n' "$payload"
