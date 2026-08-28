#!/usr/bin/env bash
# Read and redact an explicitly requested immutable diagnostic run. This script deliberately
# accepts a directory supplied by the Job mount, never an artifact path from a
# retained summary, so evidence cannot escape the read-only mounted subtree.
set -euo pipefail

readonly EVIDENCE_MAX_BYTES=65536
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_directory/contract.sh"
vmaf_reason_classes="$(contract_diagnostics_terminal_vmaf_reason_classes_json)"
hdr_reason_classes="$(contract_diagnostics_terminal_hdr_reason_classes_json)"
readonly script_directory vmaf_reason_classes hdr_reason_classes

if (($# != 6)) || [[ "$1" != 'collect' ]]; then
	echo 'usage: diagnostic-evidence.sh collect <run-id> <evidence-root> <panel-sha256> <evidence-panel> <configured-image>' >&2
	exit 64
fi

requested_run_id="$2"
evidence_root="$3"
expected_panel_sha256="$4"
expected_evidence_panel="$5"
expected_configured_image="$6"
contract_is_run_id "$requested_run_id" || {
	echo "invalid run id: $requested_run_id" >&2
	exit 64
}
[[ "$expected_panel_sha256" =~ ^sha256:[0-9a-f]{64}$ ]] || {
	echo 'diagnostic evidence reader panel identity is malformed' >&2
	exit 65
}
jq -e -n --argjson actual "$expected_evidence_panel" '
	$actual == {
		durationSeconds:10,
		hdr:[
			{clipId:"detail",evidence:"hdr/hdr10-clean-ministry/evidence.json",sampleId:"hdr10-clean-ministry",starts:{beginning:"0",clip:"01:04:15.000",detail:"01:04:15.000",encoded:"01:04:15.000",end:"<end-start>"}},
			{clipId:"detail",evidence:"hdr/hdr10-grain-goodfellas/evidence.json",sampleId:"hdr10-grain-goodfellas",starts:{beginning:"0",clip:"01:06:25.000",detail:"01:06:25.000",encoded:"01:06:25.000",end:"<end-start>"}},
			{clipId:"detail",evidence:"hdr/hdr10-motion-john-wick-2/evidence.json",sampleId:"hdr10-motion-john-wick-2",starts:{beginning:"0",clip:"01:04:50.000",detail:"01:04:50.000",encoded:"01:04:50.000",end:"<end-start>"}}
		],
		schemaVersion:1,
		vmaf:[
			{clipId:"motion",evidence:"vmaf/avc-clean-coco/motion/evidence.json",observedFrameIndex:1641,sampleId:"avc-clean-coco"},
			{clipId:"dark",evidence:"vmaf/avc-grain-memento/dark/evidence.json",observedFrameIndex:523,sampleId:"avc-grain-memento"},
			{clipId:"detail",evidence:"vmaf/avc-grain-memento/detail/evidence.json",observedFrameIndex:370,sampleId:"avc-grain-memento"},
			{clipId:"detail",evidence:"vmaf/vc1-fugitive/detail/evidence.json",observedFrameIndex:781,sampleId:"vc1-fugitive"},
			{clipId:"motion",evidence:"vmaf/vc1-fugitive/motion/evidence.json",observedFrameIndex:798,sampleId:"vc1-fugitive"}
		]
	}
' >/dev/null || {
	echo 'diagnostic evidence reader panel bounds are malformed' >&2
	exit 65
}
[[ "$expected_configured_image" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]] || {
	echo 'diagnostic evidence reader image identity is malformed' >&2
	exit 65
}
expected_image_digest="${expected_configured_image##*@}"
script_identity_unavailable() {
	echo 'diagnostic evidence reader script identity is unavailable' >&2
	exit 65
}
script_directory_physical="$(cd -P "$script_directory" && pwd)" || script_identity_unavailable
current_script_digests='{}'
for script_path in "$script_directory"/*.sh; do
	script_name="${script_path##*/}"
	if [[ -L "$script_path" ]] && [[ "$(readlink "$script_path")" != "..data/$script_name" ]]; then
		script_identity_unavailable
	fi
	resolved_script_path="$(realpath "$script_path" 2>/dev/null)" || script_identity_unavailable
	[[ "$resolved_script_path" == "$script_directory_physical/"* &&
		-f "$resolved_script_path" && ! -L "$resolved_script_path" ]] || script_identity_unavailable
	script_digest="sha256:$(sha256sum "$resolved_script_path" | awk '{print $1}')"
	current_script_digests="$(jq -c --arg name "$script_name" --arg digest "$script_digest" '. + {($name):$digest}' <<<"$current_script_digests")"
done
historical_script_digests='{"benchmark.sh":"sha256:8bc91c7ca04168c648509eb778dcd384e9af50d05ee6e2a6dd3c2553be6022b4","census.sh":"sha256:505c58d595fad640cec7fbac2eefcb02b4e1c96b3c64094afd785f2b72d39f07","contract.sh":"sha256:e62192d0e6f03a1f44ee96760da32c4efe0f52436305f0d83a5e89c0759632c8","diagnostic-evidence.sh":"sha256:da81c1a8725d95ccd1a0e992c789c09387750d9df2efaa73877ded6e0c1bfc70","probe.sh":"sha256:537724eac650d8bdf8a38412b5b2125ca26d4925d88caa8ef5958b9053ae20fb","runmeta.sh":"sha256:df5891bea05ee4ebb9c920c62fd363bc5c8a54744ac60ff558a265c4646128a3","stills.sh":"sha256:5887426ee150673a91604916a8a860a7e3395a8172557ff2e3e3456358eb510e"}'
completed_run_script_digests='{"benchmark.sh":"sha256:749746d12b6c8c9398061314e3a8918707ed620830165c6ffaf71e22ebfe7b37","census.sh":"sha256:505c58d595fad640cec7fbac2eefcb02b4e1c96b3c64094afd785f2b72d39f07","contract.sh":"sha256:b6a2b679556932773f7804843822e750640453a9700dc41f0351a43a0c83675b","diagnostic-evidence.sh":"sha256:f13bf66d0f3af7675f2121c4529e0679a594e03ef08e2165ba1f0b6e15389c25","probe.sh":"sha256:ccf31501570406304ad6292ba77901610b2d3dffe59d53d19128e9d1facff82d","runmeta.sh":"sha256:df5891bea05ee4ebb9c920c62fd363bc5c8a54744ac60ff558a265c4646128a3","stills.sh":"sha256:5887426ee150673a91604916a8a860a7e3395a8172557ff2e3e3456358eb510e"}'
expected_script_digests="$current_script_digests"
legacy_source_clip_unavailable_allowed=false
if [[ "$requested_run_id" == '20260826T014246Z-373a665e' ]]; then
	expected_script_digests="$historical_script_digests"
	legacy_source_clip_unavailable_allowed=true
elif [[ "$requested_run_id" == '20260827T233832Z-2a79502c' ]]; then
	expected_script_digests="$completed_run_script_digests"
fi
readonly expected_configured_image expected_image_digest script_directory_physical current_script_digests historical_script_digests completed_run_script_digests expected_script_digests
[[ "$evidence_root" == /* && -d "$evidence_root" && ! -L "$evidence_root" ]] || {
	echo 'diagnostic evidence root is missing or unsafe' >&2
	exit 65
}

mapfile -t expected_files <<'EOF'
diagnostic-summary.json
hdr/hdr10-clean-ministry/evidence.json
hdr/hdr10-grain-goodfellas/evidence.json
hdr/hdr10-motion-john-wick-2/evidence.json
manifest.json
vmaf/avc-clean-coco/motion/evidence.json
vmaf/avc-grain-memento/dark/evidence.json
vmaf/avc-grain-memento/detail/evidence.json
vmaf/vc1-fugitive/detail/evidence.json
vmaf/vc1-fugitive/motion/evidence.json
EOF

if [[ -n "$(find "$evidence_root" -type l -print -quit)" ]]; then
	echo 'diagnostic evidence contains a symlink' >&2
	exit 65
fi
mapfile -t actual_files < <(cd "$evidence_root" && find . -type f -print | sed 's#^./##' | LC_ALL=C sort)
[[ "${actual_files[*]}" == "${expected_files[*]}" ]] || {
	echo 'diagnostic evidence files are missing or unexpected' >&2
	exit 65
}

for relative_path in "${expected_files[@]}"; do
	[[ -f "$evidence_root/$relative_path" && ! -L "$evidence_root/$relative_path" ]] || {
		echo 'diagnostic evidence file is unsafe' >&2
		exit 65
	}
	document_bytes="$(LC_ALL=C wc -c <"$evidence_root/$relative_path" | tr -d '[:space:]')"
	[[ "$document_bytes" =~ ^[0-9]+$ && "$document_bytes" -le "$EVIDENCE_MAX_BYTES" ]] || {
		echo 'diagnostic evidence input exceeds its bounded size' >&2
		exit 65
	}
	jq -e -c . "$evidence_root/$relative_path" >/dev/null || {
		echo 'diagnostic evidence is malformed JSON' >&2
		exit 65
	}
done

summary="$evidence_root/diagnostic-summary.json"
manifest="$evidence_root/manifest.json"
manifest_issues="$(jq -S -c --arg created_at "${requested_run_id%-*}" --arg panel_sha "$expected_panel_sha256" '
	def issue($object; $key; $field; $expected_type; $expected):
		if ($object | has($key) | not) then {field:$field,kind:"missing"}
		elif ($object[$key] | type) != $expected_type then {field:$field,kind:"wrong-type"}
		elif $object[$key] != $expected then {field:$field,kind:"mismatch"}
		else empty end;
	if type != "object" then
		[{field:"manifest",kind:"wrong-type"}]
	else
		[
			issue(.; "schemaVersion"; "schemaVersion"; "number"; 2),
			issue(.; "resultsSchemaVersion"; "resultsSchemaVersion"; "number"; 2),
			issue(.; "mode"; "mode"; "string"; "diagnostics"),
			issue(.; "createdAt"; "createdAt"; "string"; $created_at)
		] +
		(if (.upstream | type) != "object" or (.upstream | has("diagnostics") | not) then
			[{field:"upstream.diagnostics",kind:"missing"}]
		 elif (.upstream.diagnostics | type) != "object" then
			[{field:"upstream.diagnostics",kind:"wrong-type"}]
		 else
			[
				issue(.upstream.diagnostics; "manifestSchemaVersion"; "upstream.diagnostics.manifestSchemaVersion"; "number"; 1),
				issue(.upstream.diagnostics; "resultSchemaVersion"; "upstream.diagnostics.resultSchemaVersion"; "number"; 1),
				issue(.upstream.diagnostics; "acceptedFindingsSha256"; "upstream.diagnostics.acceptedFindingsSha256"; "string"; "sha256:eb7ddcb42bffecb0ac0f8ab2df58be8317c586c56bb4485d48169568a6061294"),
				issue(.upstream.diagnostics; "decisionSha256"; "upstream.diagnostics.decisionSha256"; "string"; "sha256:17c476c4646e28bef71514bb48473771f449aa2c749b1d611f6c69ed518cc330"),
				issue(.upstream.diagnostics; "historicalQualityRunId"; "upstream.diagnostics.historicalQualityRunId"; "string"; "20260817T233546Z-debc0498"),
				issue(.upstream.diagnostics; "historicalFindingsRunId"; "upstream.diagnostics.historicalFindingsRunId"; "string"; "20260818T214739Z-8bc2de3e"),
				issue(.upstream.diagnostics; "panelSha256"; "upstream.diagnostics.panelSha256"; "string"; $panel_sha)
			]
		 end)
	end
' "$manifest")"
if [[ "$manifest_issues" == '[]' ]]; then
	manifest_issues="$(jq -S -c --argjson scripts "$expected_script_digests" --arg digest "$expected_image_digest" '
		[
			(if has("scriptDigests") | not then {field:"scriptDigests",kind:"missing"}
			 elif (.scriptDigests | type) != "object" then {field:"scriptDigests",kind:"wrong-type"}
			 elif .scriptDigests != $scripts then {field:"scriptDigests",kind:"mismatch"} else empty end),
			(if has("images") | not then {field:"images",kind:"missing"}
			 elif (.images | type) != "object" then {field:"images",kind:"wrong-type"}
			 elif .images != {configured:$digest,dispatched:$digest,running:$digest} then {field:"images",kind:"mismatch"} else empty end)
		]
	' "$manifest")"
fi
if [[ "$manifest_issues" == '[]' ]]; then
	manifest_identity="$(jq -c 'del(.createdAt)' "$manifest")"
	if ! CONTRACT_STRATEGY_ID='qsv-hevc-icq-v1' CONTRACT_MANIFEST_SCHEMA=2 CONTRACT_RESULTS_SCHEMA=2 \
		contract_normalize_run_identity "$manifest_identity" diagnostics >/dev/null 2>&1; then
		manifest_issues='[{"field":"manifest","kind":"mismatch"}]'
	fi
fi
if [[ "$manifest_issues" != '[]' ]]; then
	jq -n -S -c --argjson issues "$manifest_issues" '{schemaVersion:1,status:"failed",reason:"diagnostic-manifest-binding-invalid",manifestIssues:$issues}'
	exit 65
fi
jq -e --arg run "$requested_run_id" --argjson panel "$expected_evidence_panel" --argjson vmaf_reason_classes "$vmaf_reason_classes" --argjson hdr_reason_classes "$hdr_reason_classes" '
	def status: . == "complete" or . == "failed" or . == "harness-blocked";
	def exact($expected): type == "object" and (keys | sort) == ($expected | sort);
	def reasons($classes; $classification):
		type == "array" and length >= 1 and length <= 16 and length == (unique | length) and
		all(.[]; type == "string" and ($classes[.] | type == "array") and ($classes[.] | index($classification)) != null);
	def vmaf_class: . == "temporal-alignment-defect" or . == "encoder-output-defect" or . == "vmaf-measurement-defect" or . == "unresolved";
	def hdr_class: . == "source-probe-defect" or . == "clip-boundary-defect" or . == "encoder-output-defect" or . == "preserved" or . == "unresolved-oracle";
	def vmaf_entry: . as $entry | exact(["classification","clipId","evidence","reasons","sampleId","status"]) and (.status|status) and (.classification|vmaf_class) and (if .status == "complete" then true else .classification == "unresolved" end) and (.reasons|reasons($vmaf_reason_classes; $entry.classification)) and any($panel.vmaf[]; .sampleId == $entry.sampleId and .clipId == $entry.clipId and .evidence == $entry.evidence);
	def hdr_entry: . as $entry | exact(["classification","evidence","reasons","sampleId","status"]) and (.status|status) and (.classification|hdr_class) and (if .status == "complete" then true else .classification == "unresolved-oracle" end) and (.reasons|reasons($hdr_reason_classes; $entry.classification)) and any($panel.hdr[]; .sampleId == $entry.sampleId and .evidence == $entry.evidence);
	exact(["hdr","mode","runId","schemaVersion","status","strategyId","vmaf"]) and .schemaVersion == 1 and .strategyId == "qsv-hevc-icq-v1" and .mode == "diagnostics" and .runId == $run and (.status|status) and
	(.vmaf | exact(["entries","total"]) and .total == 5 and (.entries | type == "array" and length == 5 and all(.[]; vmaf_entry) and ([.[] | [.sampleId,.clipId] | join("/")] | sort) == ["avc-clean-coco/motion","avc-grain-memento/dark","avc-grain-memento/detail","vc1-fugitive/detail","vc1-fugitive/motion"])) and
	(.hdr | exact(["entries","total"]) and .total == 3 and (.entries | type == "array" and length == 3 and all(.[]; hdr_entry) and ([.[] | .sampleId] | sort) == ["hdr10-clean-ministry","hdr10-grain-goodfellas","hdr10-motion-john-wick-2"]))
' "$summary" >/dev/null || {
	echo 'diagnostic summary does not bind the approved panel' >&2
	exit 65
}

validate_vmaf() {
	local sample="$1" clip="$2" index="$3" path="$4" legacy_source_clip_unavailable_allowed="$5"
	jq -e -L "$script_directory" --arg sample "$sample" --arg clip "$clip" --argjson index "$index" --argjson reason_classes "$vmaf_reason_classes" --argjson legacy_source_clip_unavailable_allowed "$legacy_source_clip_unavailable_allowed" '
		include "diagnostic-contract";
		def exact($expected): type == "object" and (keys | sort) == ($expected | sort);
		def status: . == "complete" or . == "failed" or . == "harness-blocked";
		def command: type == "array" and all(.[]; type == "string");
		def identity: exact(["sha256","sizeBytes"]) and (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and (.sizeBytes | type == "number" and floor == . and . >= 0);
		def numeric_string: type == "string" and test("^-?[0-9]+([.][0-9]+)?$");
		def rational_string: type == "string" and test("^-?[0-9]+/[1-9][0-9]*$");
		def frame: exact(["bestEffortTimestamp","frameIndex","keyFrame","packetDuration","pictureType"]) and (.frameIndex | type == "number" and floor == .) and (.bestEffortTimestamp | numeric_string) and (.packetDuration | numeric_string) and (.keyFrame | type == "boolean") and (.pictureType == "I" or .pictureType == "P" or .pictureType == "B");
		def continuity: exact(["issue","status"]) and (.status == "clean" and .issue == null or .status == "discontinuity" and (.issue | exact(["afterFrameIndex","kind"]) and (.afterFrameIndex | type == "number" and floor == .) and (.kind == "gap" or .kind == "inconsistent-duration" or .kind == "non-monotonic-timestamp" or .kind == "repeat")));
		def window: . as $window | exact(["decodedFrameCount","frames","sourceWindow","stream"]) and (.decodedFrameCount | type == "number" and floor == . and . >= 0) and (.stream | exact(["averageFrameRate","duration","startTime","timeBase"]) and (.startTime | numeric_string) and (.duration | numeric_string) and (.timeBase | rational_string) and (.averageFrameRate | rational_string)) and (.frames | type == "array" and length <= 5 and all(.[]; frame)) and (.sourceWindow | continuity) and .sourceWindow == ($window.frames | diagnostic_continuity($window.stream.timeBase));
		def complete_window($observed): window and (.frames | length == 5 and ([.[].frameIndex]) == [range($observed - 2; $observed + 3)]);
		def optional_complete_window($observed): . == null or complete_window($observed);
		def optional_identity: . == null or identity;
		def vmaf_frame: exact(["frameIndex","vmaf"]) and (.frameIndex | type == "number" and floor == .) and (.vmaf | type == "number");
		def metric: exact(["current","reset"]) and (.current | type == "array" and length <= 5 and all(.[]; vmaf_frame)) and (.reset | type == "array" and length <= 5 and all(.[]; vmaf_frame));
		def complete_metric($observed): metric and (.current | length == 5 and ([.[].frameIndex] | sort) == [range($observed - 2; $observed + 3)]) and (.reset | length == 5 and ([.[].frameIndex] | sort) == [range($observed - 2; $observed + 3)]);
		def partial_metric($observed): metric and all(.current,.reset; length == 0 or (length == 5 and ([.[].frameIndex] | sort) == [range($observed - 2; $observed + 3)]));
		def psnr_value: . == null or type == "number" or (type == "object" and ((keys | sort) == ["kind"] and .kind == "positive-infinity" or (keys | sort) == ["kind","value"] and .kind == "finite" and (.value | type == "number")));
		def recorded_metric(value): exact(["command","value"]) and (.command | command) and (.value | value);
		def offset: exact(["encodedFrameIndex","offset","psnr","sourceFrameIndex","ssim"]) and (.offset | type == "number" and floor == . and . >= -2 and . <= 2) and .sourceFrameIndex == $index and .encodedFrameIndex == ($index + .offset) and (.ssim | recorded_metric(. == null or type == "number")) and (.psnr | recorded_metric(psnr_value));
		def offsets: type == "array" and length <= 5 and all(.[]; offset);
		def complete_offsets: offsets and length == 5 and ([.[].offset] | sort) == [-2,-1,0,1,2];
		def legacy_source_clip_reason: . == "source-clip-unavailable" and $legacy_source_clip_unavailable_allowed;
		def corrected_preparation_reason: . == "source-clip-create-failed" or . == "source-clip-identity-unavailable" or . == "source-frame-window-unavailable" or . == "source-panel-preparation-aborted";
		def preparation_reason: corrected_preparation_reason or legacy_source_clip_reason;
		def setting_reason: . == "decode-failed" or . == "encode-failed" or . == "incomplete-output-frame-window" or . == "missing-current-vmaf" or . == "missing-psnr-metric" or . == "missing-reset-vmaf" or . == "missing-ssim-metric" or . == "output-identity-unavailable" or . == "post-run-identity-drift" or preparation_reason or . == "timeline-evidence-invalid";
		def empty_metrics: (.vmaf.current | length == 0) and (.vmaf.reset | length == 0);
		def current_metrics_only: (.vmaf.current | length == 5) and (.vmaf.reset | length == 0);
		def complete_metrics: (.vmaf.current | length == 5) and (.vmaf.reset | length == 5);
		def baseline_timeline: .timeline.zeroOffsetAligned == false and .timeline.discontinuity == null;
		def source_absent: .sourceIdentity == null and .sourceFrameWindow == null;
		def source_identity_only: (.sourceIdentity | identity) and .sourceFrameWindow == null;
		def source_ready: (.sourceIdentity | identity) and (.sourceFrameWindow | complete_window($index));
		def output_absent: .outputIdentity == null and .outputFrameWindow == null;
		def output_identity_only: (.outputIdentity | identity) and .outputFrameWindow == null;
		def output_ready: (.outputIdentity | identity) and (.outputFrameWindow | complete_window($index));
		def offset_metric_presence:
			[.offsets | sort_by(.offset)[] | (.ssim.value != null), (.psnr.value != null)];
		def offset_metric_count: offset_metric_presence | map(select(.)) | length;
		def offset_metric_prefix:
			offset_metric_presence as $present |
			($present | map(select(.)) | length) as $count |
			all(range(0; 10); $present[.] == (. < $count));
		def no_metric_evidence: empty_metrics and offset_metric_count == 0 and baseline_timeline;
		def timeline_matches_windows($source_window):
			if
				source_ready and output_ready and offset_metric_count == 10 and
				.reason != "timeline-evidence-invalid"
			then
				.timeline == diagnostic_vmaf_timeline(
					$source_window;
					.outputFrameWindow;
					[.offsets[] | {offset,ssim:.ssim.value,psnr:.psnr.value}];
					$index
				)
			else true end;
		def reachable_setting_shape:
			(
				(source_ready | not) and output_absent and no_metric_evidence
			) or (
				source_ready and (
					(output_absent and no_metric_evidence) or
					(output_identity_only and no_metric_evidence) or
					(output_ready and (
						(empty_metrics and offset_metric_count == 0 and baseline_timeline) or
						(current_metrics_only and offset_metric_count == 0 and baseline_timeline) or
						(complete_metrics and offset_metric_prefix and
							(offset_metric_count == 10 or baseline_timeline))
					))
				)
			);
		def normal_setting_coupling:
			if .status == "complete" then
				.reason == null and source_ready and output_ready and complete_metrics and offset_metric_count == 10
			elif .status == "failed" then
				(.reason == "encode-failed" or .reason == "decode-failed") and source_ready and output_absent and no_metric_evidence
			elif .reason == "source-clip-create-failed" or .reason == "source-clip-identity-unavailable" or (.reason | legacy_source_clip_reason) then
				source_absent and output_absent and no_metric_evidence
			elif .reason == "source-frame-window-unavailable" then
				source_identity_only and output_absent and no_metric_evidence
			elif .reason == "source-panel-preparation-aborted" then
				source_ready and output_absent and no_metric_evidence
			elif .reason == "output-identity-unavailable" then
				source_ready and output_absent and no_metric_evidence
			elif .reason == "incomplete-output-frame-window" then
				source_ready and output_identity_only and no_metric_evidence
			elif .reason == "missing-current-vmaf" then
				source_ready and output_ready and empty_metrics and offset_metric_count == 0 and baseline_timeline
			elif .reason == "missing-reset-vmaf" then
				source_ready and output_ready and current_metrics_only and offset_metric_count == 0 and baseline_timeline
			elif .reason == "missing-ssim-metric" then
				source_ready and output_ready and complete_metrics and offset_metric_prefix and
				offset_metric_count < 10 and (offset_metric_count % 2) == 0 and baseline_timeline
			elif .reason == "missing-psnr-metric" then
				source_ready and output_ready and complete_metrics and offset_metric_prefix and
				offset_metric_count < 10 and (offset_metric_count % 2) == 1 and baseline_timeline
			elif .reason == "timeline-evidence-invalid" then
				source_ready and output_ready and complete_metrics and offset_metric_count == 10 and baseline_timeline
			else false end;
		def merged_status:
			if any(.[]; .status == "failed") then "failed"
			elif any(.[]; .status == "harness-blocked") then "harness-blocked"
			else "complete" end;
		def classification($evidence_status): . as $class | exact(["classification","reasons","schemaVersion"]) and .schemaVersion == 1 and (.classification == "encoder-output-defect" or .classification == "temporal-alignment-defect" or .classification == "unresolved" or .classification == "vmaf-measurement-defect") and (if $evidence_status == "complete" then true else .classification == "unresolved" end) and (.reasons | type == "array" and length >= 1 and length <= 16 and length == (unique | length) and all(.[]; type == "string" and ($reason_classes[.] | type == "array") and ($reason_classes[.] | index($class.classification)) != null));
		def classifier_setting:
			. as $setting |
			{
				globalQuality:$setting.globalQuality,
				completeEvidence:($setting.status == "complete"),
				currentTargetVmaf:([$setting.vmaf.current[] | select(.frameIndex == $index) | .vmaf][0] // 0),
				resetTargetVmaf:([$setting.vmaf.reset[] | select(.frameIndex == $index) | .vmaf][0] // 0),
				sourceWindow:{status:(if $setting.status == "failed" then "decode-error" else ($setting.sourceFrameWindow.sourceWindow.status // "discontinuity") end)},
				timeline:$setting.timeline,
				offsets:[$setting.offsets[] | {offset,ssim:.ssim.value,psnr:.psnr.value}]
			};
		def expected_classification:
			.settings[0].reason as $reason |
			if
				.status == "harness-blocked" and
				($reason | corrected_preparation_reason) and
				all(.settings[]; .reason == $reason)
			then {schemaVersion:1,classification:"unresolved",reasons:[$reason]}
			else
				{schemaVersion:1,sampleId:.sampleId,clipId:.clipId,observedFrameIndex:.observedFrameIndex,settings:[.settings[] | classifier_setting]} |
				diagnostic_vmaf_classify
			end;
		def classifier_failure_override:
			.status == "harness-blocked" and (has("reason") | not) and
			all(.settings[]; .status == "complete" and .reason == null) and
			.classification == {schemaVersion:1,classification:"unresolved",reasons:["classification-failed"]};
		def setting($source_identity; $source_window): exact(["commands","globalQuality","offsets","outputFrameWindow","outputIdentity","reason","sourceFrameWindow","sourceIdentity","status","timeline","vmaf"]) and (.globalQuality == 16 or .globalQuality == 30) and (.status|status) and (if .status == "complete" then .reason == null else (.reason | setting_reason) end) and .sourceIdentity == $source_identity and .sourceFrameWindow == $source_window and (.sourceIdentity | optional_identity) and (.sourceFrameWindow | optional_complete_window($index)) and (.outputIdentity | optional_identity) and (.outputFrameWindow | optional_complete_window($index)) and (.vmaf | partial_metric($index)) and (.commands | exact(["decode","encode","outputFrameProbe","vmafCurrent","vmafReset"]) and all(.[]; command)) and (.offsets | complete_offsets) and (.timeline | exact(["discontinuity","zeroOffsetAligned"]) and (.zeroOffsetAligned | type == "boolean") and (.discontinuity == null or (exact(["kind","offset"]) and (.kind == "drop" or .kind == "duplicate" or .kind == "timestamp-discontinuity") and (.offset | type == "number" and floor == . and . >= -2 and . <= 2 and . != 0)))) and reachable_setting_shape and timeline_matches_windows($source_window);
		. as $evidence |
		(exact(["classification","clipId","observedFrameIndex","sampleId","schemaVersion","settings","sourceClip","status","strategyId"]) or exact(["classification","clipId","observedFrameIndex","reason","sampleId","schemaVersion","settings","sourceClip","status","strategyId"])) and .schemaVersion == 1 and .strategyId == "qsv-hevc-icq-v1" and .sampleId == $sample and .clipId == $clip and .observedFrameIndex == $index and (.status|status) and
		(.sourceClip | exact(["command","frameProbeCommand","frameWindow","identity"]) and (.command | command) and (.frameProbeCommand | command) and (.identity | optional_identity) and (.frameWindow | optional_complete_window($index))) and
		(.settings | type == "array" and length == 2 and all(.[]; setting($evidence.sourceClip.identity; $evidence.sourceClip.frameWindow)) and ([.[].globalQuality] | sort) == [16,30]) and
		(if has("reason") then
			.status == "harness-blocked" and .reason == "post-run-identity-drift" and
			all(.settings[]; .status == "harness-blocked" and .reason == "post-run-identity-drift") and
			.classification == {schemaVersion:1,classification:"unresolved",reasons:["post-run-identity-drift"]}
		elif classifier_failure_override then
			true
		else
			.status == (.settings | merged_status) and
			all(.settings[]; .reason != "post-run-identity-drift" and normal_setting_coupling) and
			.classification == expected_classification
		end) and
		(.classification | classification($evidence.status))
	' "$path" >/dev/null
}

validate_hdr() {
	local sample="$1" path="$2" legacy_source_clip_unavailable_allowed="$3"
	jq -e -L "$script_directory" --arg sample "$sample" --argjson panel "$expected_evidence_panel" --argjson reason_classes "$hdr_reason_classes" --argjson legacy_source_clip_unavailable_allowed "$legacy_source_clip_unavailable_allowed" '
		include "diagnostic-contract";
		def status: . == "complete" or . == "failed" or . == "harness-blocked";
		def exact($expected): type == "object" and (keys | sort) == ($expected | sort);
		def command: type == "array" and all(.[]; type == "string");
		def identity: exact(["sha256","sizeBytes"]) and (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and (.sizeBytes | type == "number" and floor == . and . >= 0);
		def optional_identity: . == null or identity;
		def rational: exact(["denominator","numerator"]) and (.numerator | type == "number" and floor == . and . >= 0) and (.denominator | type == "number" and floor == . and . > 0);
		def chromaticity: exact(["x","y"]) and (.x | rational) and (.y | rational);
		def metadata: exact(["masteringDisplay","maxCLL","maxFALL"]) and
			(.masteringDisplay | exact(["displayPrimaries","luminance","whitePoint"]) and
				(.displayPrimaries | exact(["blue","green","red"]) and (.red | chromaticity) and (.green | chromaticity) and (.blue | chromaticity)) and
				(.whitePoint | chromaticity) and (.luminance | exact(["max","min"]) and (.min | rational) and (.max | rational))) and
			(.maxCLL | rational) and (.maxFALL | rational);
		def oracle: (exact(["status"]) and (.status == "null" or .status == "absent" or .status == "malformed")) or (exact(["metadata","status"]) and .status == "ok" and (.metadata | metadata));
		def successful_stream_oracle: (exact(["status"]) and .status == "null") or (exact(["metadata","status"]) and .status == "ok" and (.metadata | metadata));
		def successful_pair_oracle: (exact(["status"]) and .status == "absent") or (exact(["metadata","status"]) and .status == "ok" and (.metadata | metadata));
		def malformed_oracle: . == {status:"malformed"};
		def reasons($allowed): type == "array" and length == 1 and all(.[]; . as $reason | type == "string" and ($allowed | index($reason)) != null);
		def source_window_reason: . == "decoded-trace-disagreement" or . == "source-window-absent" or . == "source-window-malformed" or . == "source-window-null";
		def source_reason: source_window_reason or . == "source-window-conflict";
		def clip_reason: . == "clip-window-absent" or . == "clip-window-malformed" or . == "clip-window-null" or . == "decoded-trace-disagreement";
		def encoded_reason: . == "decoded-trace-disagreement" or . == "encoded-window-absent" or . == "encoded-window-malformed" or . == "encoded-window-null";
		def authoritative($allowed): (exact(["metadata","status"]) and .status == "ok" and (.metadata | metadata)) or (exact(["reasons","status"]) and .status == "unresolved" and (.reasons | reasons($allowed)));
		def raw_oracle: exact(["command","oracle"]) and (.command | command) and (.oracle | oracle);
		def stream_probe: exact(["command","oracle"]) and (.command | command) and ((.oracle | successful_stream_oracle) or (.oracle | malformed_oracle));
		def raw_pair_fields: exact(["decoded","durationSeconds","reason","start","status","trace"]) and (.start | type == "string") and .durationSeconds == 10 and (.status | status) and (.decoded | raw_oracle) and (.trace | raw_oracle);
		def dynamic_pair:
			raw_pair_fields and (
				(.status == "complete" and .reason == null and (.decoded.oracle | successful_pair_oracle) and (.trace.oracle | successful_pair_oracle)) or
				(.status == "harness-blocked" and .reason == "decoded-frame-oracle-failed" and (.decoded.oracle | malformed_oracle) and (.trace.oracle | successful_pair_oracle)) or
				(.status == "harness-blocked" and .reason == "trace-headers-oracle-failed" and (.trace.oracle | malformed_oracle) and ((.decoded.oracle | successful_pair_oracle) or (.decoded.oracle | malformed_oracle)))
			);
		def legacy_source_clip_reason: . == "source-clip-unavailable" and $legacy_source_clip_unavailable_allowed;
		def corrected_preparation_reason: . == "source-clip-create-failed" or . == "source-clip-identity-unavailable" or . == "source-panel-preparation-aborted";
		def preparation_reason: corrected_preparation_reason or legacy_source_clip_reason;
		def unavailable_pair:
			raw_pair_fields and .status == "harness-blocked" and
			(.reason | preparation_reason) and
			.decoded == {command:[],oracle:{status:"malformed"}} and .trace == {command:[],oracle:{status:"malformed"}};
		def failed_pair:
			raw_pair_fields and .status == "failed" and .reason == "encoded-output-unavailable" and
			.decoded == {command:[],oracle:{status:"malformed"}} and .trace == {command:[],oracle:{status:"malformed"}};
		def oracle_pair: exact(["decoded","trace"]) and (.decoded | oracle) and (.trace | oracle);
		def normalized: exact(["clip","encoded","schemaVersion","source"]) and .schemaVersion == 1 and
			(.source | exact(["authoritative","streamProbe","windows"]) and (.streamProbe | oracle) and (.authoritative | authoritative(["decoded-trace-disagreement","source-window-absent","source-window-conflict","source-window-malformed","source-window-null"])) and (.windows | exact(["beginning","detail","end"]) and all(.[]; exact(["authoritative","decoded","trace"]) and (.decoded | oracle) and (.trace | oracle) and (.authoritative | authoritative(["decoded-trace-disagreement","source-window-absent","source-window-malformed","source-window-null"]))))) and
			(.clip | exact(["authoritative","decoded","trace"]) and (.decoded | oracle) and (.trace | oracle) and (.authoritative | authoritative(["clip-window-absent","clip-window-malformed","clip-window-null","decoded-trace-disagreement"]))) and
			(.encoded | exact(["authoritative","decoded","trace"]) and (.decoded | oracle) and (.trace | oracle) and (.authoritative | authoritative(["decoded-trace-disagreement","encoded-window-absent","encoded-window-malformed","encoded-window-null"])));
		def gcd($a; $b): if $b == 0 then $a else gcd($b; ($a % $b)) end;
		def reduced_rational:
			(gcd(.numerator; .denominator)) as $divisor |
			{numerator:(.numerator / $divisor),denominator:(.denominator / $divisor)};
		def normalize_metadata:
			{
				masteringDisplay:{
					displayPrimaries:{
						red:{x:(.masteringDisplay.displayPrimaries.red.x | reduced_rational),y:(.masteringDisplay.displayPrimaries.red.y | reduced_rational)},
						green:{x:(.masteringDisplay.displayPrimaries.green.x | reduced_rational),y:(.masteringDisplay.displayPrimaries.green.y | reduced_rational)},
						blue:{x:(.masteringDisplay.displayPrimaries.blue.x | reduced_rational),y:(.masteringDisplay.displayPrimaries.blue.y | reduced_rational)}},
					whitePoint:{x:(.masteringDisplay.whitePoint.x | reduced_rational),y:(.masteringDisplay.whitePoint.y | reduced_rational)},
					luminance:{min:(.masteringDisplay.luminance.min | reduced_rational),max:(.masteringDisplay.luminance.max | reduced_rational)}},
				maxCLL:(.maxCLL | reduced_rational),maxFALL:(.maxFALL | reduced_rational)};
		def normalize_oracle:
			if .status == "ok" then {status:"ok",metadata:(.metadata | normalize_metadata)} else {status} end;
		def authoritative_pair($null_reason; $absent_reason; $malformed_reason):
			(.decoded | normalize_oracle) as $decoded |
			(.trace | normalize_oracle) as $trace |
			if $decoded.status == "ok" and $trace.status == "ok" then
				if $decoded.metadata == $trace.metadata then {status:"ok",metadata:$decoded.metadata}
				else {status:"unresolved",reasons:["decoded-trace-disagreement"]} end
			elif $decoded.status == "null" or $trace.status == "null" then {status:"unresolved",reasons:[$null_reason]}
			elif $decoded.status == "absent" or $trace.status == "absent" then {status:"unresolved",reasons:[$absent_reason]}
			else {status:"unresolved",reasons:[$malformed_reason]} end;
		def normalize_pair($null_reason; $absent_reason; $malformed_reason):
			. as $pair |
			{
				decoded:($pair.decoded.oracle | normalize_oracle),
				trace:($pair.trace.oracle | normalize_oracle),
				authoritative:({decoded:$pair.decoded.oracle,trace:$pair.trace.oracle} | authoritative_pair($null_reason; $absent_reason; $malformed_reason))};
		def expected_normalized:
			. as $raw |
			{
				schemaVersion:1,
				source:{
					streamProbe:($raw.source.streamProbe.oracle | normalize_oracle),
					windows:{
						beginning:($raw.source.windows.beginning | normalize_pair("source-window-null"; "source-window-absent"; "source-window-malformed")),
						detail:($raw.source.windows.detail | normalize_pair("source-window-null"; "source-window-absent"; "source-window-malformed")),
						end:($raw.source.windows.end | normalize_pair("source-window-null"; "source-window-absent"; "source-window-malformed"))}},
				clip:($raw.clip | normalize_pair("clip-window-null"; "clip-window-absent"; "clip-window-malformed")),
				encoded:($raw.encoded | normalize_pair("encoded-window-null"; "encoded-window-absent"; "encoded-window-malformed"))
			} as $expected |
			([$expected.source.windows.beginning.authoritative,$expected.source.windows.detail.authoritative,$expected.source.windows.end.authoritative]) as $windows |
			$expected |
			.source.authoritative =
				if any($windows[]; .status != "ok") then ($windows | map(select(.status != "ok"))[0])
				elif ([$windows[].metadata] | unique | length) != 1 then {status:"unresolved",reasons:["source-window-conflict"]}
				else {status:"ok",metadata:$windows[0].metadata} end;
		def normalized_conflict:
			[
				.normalizedOracle.source.authoritative.reasons[]?,
				.normalizedOracle.source.windows[].authoritative.reasons[]?,
				.normalizedOracle.clip.authoritative.reasons[]?,
				.normalizedOracle.encoded.authoritative.reasons[]?
			] | any(. == "decoded-trace-disagreement" or . == "source-window-conflict");
		def evidence_reason: . == "HDR-classification-failed" or . == "HDR-oracle-normalization-failed" or . == "clip-identity-unavailable" or . == "conflicting-HDR-oracle" or . == "decode-failed" or . == "encode-failed" or . == "output-identity-unavailable" or . == "post-run-identity-drift" or preparation_reason or . == "source-duration-unavailable" or . == "source-identity-unavailable" or . == "source-stream-oracle-failed";
		def identities_ready: (.source.identity | identity) and (.clip.identity | identity) and (.encoded.identity | identity);
		def encoded_dynamic: (del(.encoded.identity).encoded | dynamic_pair);
		def encoded_unavailable: (del(.encoded.identity).encoded | unavailable_pair);
		def encoded_failed: (del(.encoded.identity).encoded | failed_pair);
		def preparation_blocked:
			. as $evidence |
			.status == "harness-blocked" and (.reason | preparation_reason) and .normalizedOracle == null and
			(if .reason == "source-clip-create-failed" or (.reason | legacy_source_clip_reason) then
				.source.identity == null and .clip.identity == null
			 elif .reason == "source-clip-identity-unavailable" then
				(.source.identity == null or (.source.identity | identity)) and .clip.identity == null
			 elif .reason == "source-panel-preparation-aborted" then
				(.source.identity | identity) and (.clip.identity | identity)
			 else false end) and
			.source.streamProbe == {command:[],oracle:{status:"malformed"}} and
			all(.source.windows[]; unavailable_pair and .reason == $evidence.reason) and
			(del(.clip.identity).clip | unavailable_pair) and .clip.reason == $evidence.reason and
			encoded_unavailable and .encoded.reason == $evidence.reason;
		def raw_pairs_ready: all(.source.windows[]; .status == "complete") and .clip.status == "complete" and .encoded.status == "complete";
		def any_pair_blocked: any(.source.windows[]; .status == "harness-blocked") or .clip.status == "harness-blocked" or .encoded.status == "harness-blocked";
		def normalization_ready: identities_ready and (.source.streamProbe.oracle | successful_stream_oracle) and encoded_dynamic and raw_pairs_ready;
		def encoded_acquisition_shape:
			preparation_blocked or
			(encoded_dynamic and (.encoded.identity | optional_identity)) or
			(encoded_unavailable and .clip.identity == null and .encoded.identity == null) or
			(encoded_failed and .encoded.identity == null);
		def reachable_hdr_shape:
			encoded_acquisition_shape and
			(if .normalizedOracle == null then true else normalization_ready and (.normalizedOracle | normalized) and .normalizedOracle == expected_normalized end);
		def no_later_output_identity_failure:
			encoded_unavailable or (encoded_dynamic and (.encoded.identity | identity));
		def normal_hdr_coupling:
			if .status == "complete" then
				.reason == null and normalization_ready and (.normalizedOracle | normalized) and (normalized_conflict | not)
			elif .status == "failed" then
				(.reason == "encode-failed" or .reason == "decode-failed") and encoded_failed and .normalizedOracle == null
			elif (.reason | preparation_reason) then
				preparation_blocked
			elif .reason == "source-identity-unavailable" then
				.source.identity == null and (.clip.identity | identity) and encoded_dynamic and
				(.encoded.identity | identity) and .normalizedOracle == null
			elif .reason == "clip-identity-unavailable" then
				.clip.identity == null and encoded_dynamic and (.encoded.identity | identity) and .normalizedOracle == null
			elif .reason == "output-identity-unavailable" then
				encoded_dynamic and .encoded.identity == null and .normalizedOracle == null
			elif .reason == "source-duration-unavailable" then
				no_later_output_identity_failure and .normalizedOracle == null
			elif .reason == "source-stream-oracle-failed" then
				.source.streamProbe.oracle == {status:"malformed"} and no_later_output_identity_failure and .normalizedOracle == null
			elif .reason == "HDR-oracle-normalization-failed" then
				normalization_ready and .normalizedOracle == null
			elif .reason == "conflicting-HDR-oracle" then
				normalization_ready and (.normalizedOracle | normalized) and normalized_conflict
			elif .reason == "HDR-classification-failed" then
				normalization_ready and (.normalizedOracle | normalized) and (normalized_conflict | not)
			elif .reason == null then
				identities_ready and encoded_dynamic and any_pair_blocked and .normalizedOracle == null
			else false end;
		def classification($evidence_status): . as $class | exact(["classification","reasons","schemaVersion"]) and .schemaVersion == 1 and (.classification == "clip-boundary-defect" or .classification == "encoder-output-defect" or .classification == "preserved" or .classification == "source-probe-defect" or .classification == "unresolved-oracle") and (if $evidence_status == "complete" then true else .classification == "unresolved-oracle" end) and (.reasons | type == "array" and length >= 1 and length <= 16 and length == (unique | length) and all(.[]; type == "string" and ($reason_classes[.] | type == "array") and ($reason_classes[.] | index($class.classification)) != null));
		def expected_classification:
			if .status == "complete" then (.normalizedOracle | diagnostic_hdr_classify_normalized)
			elif (.reason | corrected_preparation_reason) then {schemaVersion:1,classification:"unresolved-oracle",reasons:[.reason]}
			else {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]} end;
		def classifier_failure_override:
			.status == "harness-blocked" and .reason == "HDR-classification-failed" and
			normalization_ready and (.normalizedOracle | normalized) and (normalized_conflict | not) and
			.classification == {schemaVersion:1,classification:"unresolved-oracle",reasons:["classification-failed"]};
		([$panel.hdr[] | select(.sampleId == $sample)][0]) as $binding |
		. as $evidence |
		exact(["classification","clip","clipId","commands","encoded","globalQuality","normalizedOracle","reason","sampleId","schemaVersion","source","status","strategyId"]) and .schemaVersion == 1 and .strategyId == "qsv-hevc-icq-v1" and .sampleId == $sample and .clipId == "detail" and .globalQuality == 16 and (.status|status) and (if .status == "complete" then .reason == null else .reason == null or (.reason | evidence_reason) end) and
		(.commands | exact(["clip","decode","encode"]) and all(.[]; command)) and
		(.source | exact(["identity","streamProbe","windows"]) and (.identity | optional_identity) and (.streamProbe | stream_probe) and (.windows | exact(["beginning","detail","end"]) and all(.[]; dynamic_pair or unavailable_pair) and .beginning.start == $binding.starts.beginning and .detail.start == $binding.starts.detail and .end.start == $binding.starts.end)) and
		(.clip | exact(["decoded","durationSeconds","identity","reason","start","status","trace"]) and .start == $binding.starts.clip and (.identity | optional_identity) and (del(.identity) | dynamic_pair or unavailable_pair)) and
		(.encoded | exact(["decoded","durationSeconds","identity","reason","start","status","trace"]) and (.identity | optional_identity)) and
		.encoded.start == $binding.starts.encoded and
		reachable_hdr_shape and
		(if .reason == "post-run-identity-drift" then
			.status == "harness-blocked" and
			.classification == {schemaVersion:1,classification:"unresolved-oracle",reasons:["post-run-identity-drift"]}
		elif .reason == "HDR-classification-failed" then
			classifier_failure_override
		else
			normal_hdr_coupling and .classification == expected_classification
		end) and
		(.classification | classification($evidence.status))
	' "$path" >/dev/null
}

vmaf_rows=(
	'avc-clean-coco motion 1641'
	'avc-grain-memento dark 523'
	'avc-grain-memento detail 370'
	'vc1-fugitive detail 781'
	'vc1-fugitive motion 798'
)
for row in "${vmaf_rows[@]}"; do
	read -r sample clip index <<<"$row"
	evidence_path="$evidence_root/vmaf/$sample/$clip/evidence.json"
	validate_vmaf "$sample" "$clip" "$index" "$evidence_path" "$legacy_source_clip_unavailable_allowed" || {
		echo 'VMAF diagnostic evidence violates its approved schema' >&2
		exit 65
	}
	jq -e --arg sample "$sample" --arg clip "$clip" --slurpfile evidence "$evidence_path" '
		[.vmaf.entries[] | select(.sampleId == $sample and .clipId == $clip)] as $entries |
		($entries | length) == 1 and
		$entries[0].status == $evidence[0].status and
		$entries[0].classification == $evidence[0].classification.classification and
		$entries[0].reasons == $evidence[0].classification.reasons
	' "$summary" >/dev/null || {
		echo 'VMAF diagnostic evidence does not match its retained summary' >&2
		exit 65
	}
done
for sample in hdr10-clean-ministry hdr10-grain-goodfellas hdr10-motion-john-wick-2; do
	evidence_path="$evidence_root/hdr/$sample/evidence.json"
	validate_hdr "$sample" "$evidence_path" "$legacy_source_clip_unavailable_allowed" || {
		echo 'HDR diagnostic evidence violates its approved schema' >&2
		exit 65
	}
	jq -e --arg sample "$sample" --slurpfile evidence "$evidence_path" '
		[.hdr.entries[] | select(.sampleId == $sample)] as $entries |
		($entries | length) == 1 and
		$entries[0].status == $evidence[0].status and
		$entries[0].classification == $evidence[0].classification.classification and
		$entries[0].reasons == $evidence[0].classification.reasons
	' "$summary" >/dev/null || {
		echo 'HDR diagnostic evidence does not match its retained summary' >&2
		exit 65
	}
done

canonical="$(jq -n -S -c --arg run "$requested_run_id" \
	--slurpfile summary "$summary" \
	--slurpfile vmaf0 "$evidence_root/vmaf/avc-clean-coco/motion/evidence.json" \
	--slurpfile vmaf1 "$evidence_root/vmaf/avc-grain-memento/dark/evidence.json" \
	--slurpfile vmaf2 "$evidence_root/vmaf/avc-grain-memento/detail/evidence.json" \
	--slurpfile vmaf3 "$evidence_root/vmaf/vc1-fugitive/detail/evidence.json" \
	--slurpfile vmaf4 "$evidence_root/vmaf/vc1-fugitive/motion/evidence.json" \
	--slurpfile hdr0 "$evidence_root/hdr/hdr10-clean-ministry/evidence.json" \
	--slurpfile hdr1 "$evidence_root/hdr/hdr10-grain-goodfellas/evidence.json" \
	--slurpfile hdr2 "$evidence_root/hdr/hdr10-motion-john-wick-2/evidence.json" '
		def vmaf_metric: {current:[.current[] | {frameIndex,vmaf}],reset:[.reset[] | {frameIndex,vmaf}]};
		def offset: {offset,ssim:.ssim.value,psnr:.psnr.value};
		def continuity: {decodedFrameCount,stream:(.stream | {startTime,duration,timeBase,averageFrameRate}),frames:[.frames[] | {frameIndex,bestEffortTimestamp,packetDuration,keyFrame,pictureType}],sourceWindow};
		def timeline_window: {stream:(.stream | {timeBase,averageFrameRate}),frames:[.frames[] | {frameIndex,bestEffortTimestamp,packetDuration}],sourceWindow};
		def vmaf($raw): $raw[0] | {sampleId,clipId,observedFrameIndex,status,sourceContinuity:(if .sourceClip.frameWindow == null then null else (.sourceClip.frameWindow | continuity) end),settings:[.settings[] | {globalQuality,status,reason,vmaf:(.vmaf | vmaf_metric),offsets:[.offsets[] | offset],outputContinuity:(if .outputFrameWindow == null then null else (.outputFrameWindow | timeline_window) end),timeline}],classification};
		def gcd($a; $b): if $b == 0 then $a else gcd($b; ($a % $b)) end;
		def normalize_rationals:
			walk(if type == "object" and (keys | sort) == ["denominator","numerator"] and (.numerator | type == "number" and floor == . and . >= 0) and (.denominator | type == "number" and floor == . and . > 0) then
				(gcd(.numerator; .denominator)) as $divisor | {numerator:(.numerator / $divisor),denominator:(.denominator / $divisor)}
			else . end);
		def hdr($raw): $raw[0] | {sampleId,clipId,globalQuality,status,reason,normalizedOracle:(if .normalizedOracle == null then null else (.normalizedOracle | normalize_rationals) end),classification};
		{schemaVersion:1,strategyId:"qsv-hevc-icq-v1",mode:"diagnostic-evidence-reader",runId:$run,vmaf:[vmaf($vmaf0),vmaf($vmaf1),vmaf($vmaf2),vmaf($vmaf3),vmaf($vmaf4)],hdr:[hdr($hdr0),hdr($hdr1),hdr($hdr2)]}
	')" || exit 65
canonical_bytes="$(printf '%s' "$canonical" | LC_ALL=C wc -c | tr -d '[:space:]')"
[[ "$canonical_bytes" =~ ^[0-9]+$ && "$canonical_bytes" -le "$EVIDENCE_MAX_BYTES" ]] || {
	echo 'canonical diagnostic evidence exceeds the output limit' >&2
	exit 65
}
printf '%s\n' "$canonical"
