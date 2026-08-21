#!/usr/bin/env bash
# Read and redact the one approved diagnostic run.  This script deliberately
# accepts a directory supplied by the Job mount, never an artifact path from a
# retained summary, so evidence cannot escape the read-only mounted subtree.
set -euo pipefail

readonly EVIDENCE_RUN_ID='20260820T223425Z-082b3d38'
readonly EVIDENCE_MAX_BYTES=65536
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_directory/contract.sh"
vmaf_reason_classes="$(contract_diagnostics_terminal_vmaf_reason_classes_json)"
hdr_reason_classes="$(contract_diagnostics_terminal_hdr_reason_classes_json)"
readonly script_directory vmaf_reason_classes hdr_reason_classes

if (($# != 3)) || [[ "$1" != 'collect' ]]; then
	echo 'usage: diagnostic-evidence.sh collect <run-id> <evidence-root>' >&2
	exit 64
fi

requested_run_id="$2"
evidence_root="$3"
[[ "$requested_run_id" == "$EVIDENCE_RUN_ID" ]] || {
	echo 'diagnostic evidence reader rejects an unapproved run id' >&2
	exit 65
}
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
jq -e --arg run "$EVIDENCE_RUN_ID" '
	type == "object" and .schemaVersion == 2 and .mode == "diagnostics" and .runId == $run and
	(.upstream.diagnostics | type == "object" and
	 .manifestSchemaVersion == 1 and .resultSchemaVersion == 1 and
	 .acceptedFindingsSha256 == "sha256:eb7ddcb42bffecb0ac0f8ab2df58be8317c586c56bb4485d48169568a6061294" and
	 .decisionSha256 == "sha256:17c476c4646e28bef71514bb48473771f449aa2c749b1d611f6c69ed518cc330" and
	 .historicalQualityRunId == "20260817T233546Z-debc0498" and
	 .historicalFindingsRunId == "20260818T214739Z-8bc2de3e" and
	 (.panelSha256 | type == "string" and test("^sha256:[0-9a-f]{64}$")))
' "$manifest" >/dev/null || {
	echo 'diagnostic manifest does not bind the approved immutable run' >&2
	exit 65
}
jq -e --arg run "$EVIDENCE_RUN_ID" --argjson vmaf_reason_classes "$vmaf_reason_classes" --argjson hdr_reason_classes "$hdr_reason_classes" '
	def status: . == "complete" or . == "failed" or . == "harness-blocked";
	def exact($expected): type == "object" and (keys | sort) == ($expected | sort);
	def reasons($classes; $classification):
		type == "array" and length >= 1 and length <= 16 and length == (unique | length) and
		all(.[]; type == "string" and ($classes[.] | type == "array") and ($classes[.] | index($classification)) != null);
	def vmaf_class: . == "temporal-alignment-defect" or . == "encoder-output-defect" or . == "vmaf-measurement-defect" or . == "unresolved";
	def hdr_class: . == "source-probe-defect" or . == "clip-boundary-defect" or . == "encoder-output-defect" or . == "preserved" or . == "unresolved-oracle";
	def vmaf_entry: . as $entry | exact(["classification","clipId","evidence","reasons","sampleId","status"]) and (.status|status) and (.classification|vmaf_class) and (.reasons|reasons($vmaf_reason_classes; $entry.classification)) and (.evidence|type == "string" and test("^vmaf/[a-z0-9-]+/[a-z0-9-]+/evidence[.]json$"));
	def hdr_entry: . as $entry | exact(["classification","evidence","reasons","sampleId","status"]) and (.status|status) and (.classification|hdr_class) and (.reasons|reasons($hdr_reason_classes; $entry.classification)) and (.evidence|type == "string" and test("^hdr/[a-z0-9-]+/evidence[.]json$"));
	exact(["hdr","mode","runId","schemaVersion","status","strategyId","vmaf"]) and .schemaVersion == 1 and .strategyId == "qsv-hevc-icq-v1" and .mode == "diagnostics" and .runId == $run and (.status|status) and
	(.vmaf | exact(["entries","total"]) and .total == 5 and (.entries | type == "array" and length == 5 and all(.[]; vmaf_entry) and ([.[] | [.sampleId,.clipId] | join("/")] | sort) == ["avc-clean-coco/motion","avc-grain-memento/dark","avc-grain-memento/detail","vc1-fugitive/detail","vc1-fugitive/motion"])) and
	(.hdr | exact(["entries","total"]) and .total == 3 and (.entries | type == "array" and length == 3 and all(.[]; hdr_entry) and ([.[] | .sampleId] | sort) == ["hdr10-clean-ministry","hdr10-grain-goodfellas","hdr10-motion-john-wick-2"]))
' "$summary" >/dev/null || {
	echo 'diagnostic summary does not bind the approved panel' >&2
	exit 65
}

validate_vmaf() {
	local sample="$1" clip="$2" index="$3" path="$4"
	jq -e --arg sample "$sample" --arg clip "$clip" --argjson index "$index" --argjson reason_classes "$vmaf_reason_classes" '
		def exact($expected): type == "object" and (keys | sort) == ($expected | sort);
		def status: . == "complete" or . == "failed" or . == "harness-blocked";
		def command: type == "array" and all(.[]; type == "string");
		def identity: exact(["sha256","sizeBytes"]) and (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and (.sizeBytes | type == "number" and floor == . and . >= 0);
		def numeric_string: type == "string" and test("^-?[0-9]+([.][0-9]+)?$");
		def rational_string: type == "string" and test("^-?[0-9]+/[1-9][0-9]*$");
		def frame: exact(["bestEffortTimestamp","frameIndex","keyFrame","packetDuration","pictureType"]) and (.frameIndex | type == "number" and floor == .) and (.bestEffortTimestamp | numeric_string) and (.packetDuration | numeric_string) and (.keyFrame | type == "boolean") and (.pictureType == "I" or .pictureType == "P" or .pictureType == "B");
		def continuity: exact(["issue","status"]) and (.status == "clean" and .issue == null or .status == "discontinuity" and (.issue | exact(["afterFrameIndex","kind"]) and (.afterFrameIndex | type == "number" and floor == .) and (.kind == "gap" or .kind == "inconsistent-duration" or .kind == "non-monotonic-timestamp" or .kind == "repeat")));
		def window: exact(["decodedFrameCount","frames","sourceWindow","stream"]) and (.decodedFrameCount | type == "number" and floor == . and . >= 0) and (.stream | exact(["averageFrameRate","duration","startTime","timeBase"]) and (.startTime | numeric_string) and (.duration | numeric_string) and (.timeBase | rational_string) and (.averageFrameRate | rational_string)) and (.frames | type == "array" and length <= 5 and all(.[]; frame)) and (.sourceWindow | continuity);
		def vmaf_frame: exact(["frameIndex","vmaf"]) and (.frameIndex | type == "number" and floor == .) and (.vmaf | type == "number");
		def metric: exact(["current","reset"]) and (.current | type == "array" and length <= 5 and all(.[]; vmaf_frame)) and (.reset | type == "array" and length <= 5 and all(.[]; vmaf_frame));
		def psnr_value: . == null or type == "number" or (type == "object" and ((keys | sort) == ["kind"] and .kind == "positive-infinity" or (keys | sort) == ["kind","value"] and .kind == "finite" and (.value | type == "number")));
		def recorded_metric(value): exact(["command","value"]) and (.command | command) and (.value | value);
		def offset: exact(["encodedFrameIndex","offset","psnr","sourceFrameIndex","ssim"]) and (.offset | type == "number" and floor == . and . >= -2 and . <= 2) and .sourceFrameIndex == $index and .encodedFrameIndex == ($index + .offset) and (.ssim | recorded_metric(. == null or type == "number")) and (.psnr | recorded_metric(psnr_value));
		def setting_reason: . == "decode-failed" or . == "encode-failed" or . == "incomplete-output-frame-window" or . == "missing-current-vmaf" or . == "missing-psnr-metric" or . == "missing-reset-vmaf" or . == "missing-ssim-metric" or . == "output-identity-unavailable" or . == "post-run-identity-drift" or . == "source-clip-unavailable" or . == "timeline-evidence-invalid";
		def classification: . as $class | exact(["classification","reasons","schemaVersion"]) and .schemaVersion == 1 and (.classification == "encoder-output-defect" or .classification == "temporal-alignment-defect" or .classification == "unresolved" or .classification == "vmaf-measurement-defect") and (.reasons | type == "array" and length >= 1 and length <= 16 and length == (unique | length) and all(.[]; type == "string" and ($reason_classes[.] | type == "array") and ($reason_classes[.] | index($class.classification)) != null));
		def setting: exact(["commands","globalQuality","offsets","outputFrameWindow","outputIdentity","reason","sourceFrameWindow","sourceIdentity","status","timeline","vmaf"]) and (.globalQuality == 16 or .globalQuality == 30) and (.status|status) and (if .status == "complete" then .reason == null else (.reason | setting_reason) end) and (.sourceIdentity | identity) and (.outputIdentity | identity) and (.sourceFrameWindow | window) and (.outputFrameWindow | window) and (.commands | exact(["decode","encode","outputFrameProbe","vmafCurrent","vmafReset"]) and all(.[]; command)) and (.vmaf|metric) and (.offsets | type == "array" and length <= 5 and all(.[]; offset)) and (.timeline | exact(["discontinuity","zeroOffsetAligned"]) and (.zeroOffsetAligned | type == "boolean") and (.discontinuity == null or (exact(["kind","offset"]) and (.kind == "drop" or .kind == "duplicate" or .kind == "timestamp-discontinuity") and (.offset | type == "number" and floor == . and . >= -2 and . <= 2 and . != 0))));
		exact(["classification","clipId","observedFrameIndex","sampleId","schemaVersion","settings","sourceClip","status","strategyId"]) and .schemaVersion == 1 and .strategyId == "qsv-hevc-icq-v1" and .sampleId == $sample and .clipId == $clip and .observedFrameIndex == $index and (.status|status) and
		(.sourceClip | exact(["command","frameProbeCommand","frameWindow","identity"]) and (.command | command) and (.frameProbeCommand | command) and (.identity | identity) and (.frameWindow | window)) and
		(.settings | type == "array" and length == 2 and all(.[]; setting) and ([.[].globalQuality] | sort) == [16,30]) and
		(.classification | classification)
	' "$path" >/dev/null
}

validate_hdr() {
	local sample="$1" path="$2"
	jq -e --arg sample "$sample" --argjson reason_classes "$hdr_reason_classes" '
		def status: . == "complete" or . == "failed" or . == "harness-blocked";
		def exact($expected): type == "object" and (keys | sort) == ($expected | sort);
		def command: type == "array" and all(.[]; type == "string");
		def identity: exact(["sha256","sizeBytes"]) and (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and (.sizeBytes | type == "number" and floor == . and . >= 0);
		def rational: exact(["denominator","numerator"]) and (.numerator | type == "number" and floor == . and . >= 0) and (.denominator | type == "number" and floor == . and . > 0);
		def chromaticity: exact(["x","y"]) and (.x | rational) and (.y | rational);
		def metadata: exact(["masteringDisplay","maxCLL","maxFALL"]) and
			(.masteringDisplay | exact(["displayPrimaries","luminance","whitePoint"]) and
				(.displayPrimaries | exact(["blue","green","red"]) and (.red | chromaticity) and (.green | chromaticity) and (.blue | chromaticity)) and
				(.whitePoint | chromaticity) and (.luminance | exact(["max","min"]) and (.min | rational) and (.max | rational))) and
			(.maxCLL | rational) and (.maxFALL | rational);
		def oracle: (exact(["status"]) and (.status == "null" or .status == "absent" or .status == "malformed")) or (exact(["metadata","status"]) and .status == "ok" and (.metadata | metadata));
		def reasons($allowed): type == "array" and length == 1 and all(.[]; . as $reason | type == "string" and ($allowed | index($reason)) != null);
		def source_window_reason: . == "decoded-trace-disagreement" or . == "source-window-absent" or . == "source-window-malformed" or . == "source-window-null";
		def source_reason: source_window_reason or . == "source-window-conflict";
		def clip_reason: . == "clip-window-absent" or . == "clip-window-malformed" or . == "clip-window-null" or . == "decoded-trace-disagreement";
		def encoded_reason: . == "decoded-trace-disagreement" or . == "encoded-window-absent" or . == "encoded-window-malformed" or . == "encoded-window-null";
		def authoritative($allowed): (exact(["metadata","status"]) and .status == "ok" and (.metadata | metadata)) or (exact(["reasons","status"]) and .status == "unresolved" and (.reasons | reasons($allowed)));
		def raw_oracle: exact(["command","oracle"]) and (.command | command) and (.oracle | oracle);
		def pair_reason: . == "decoded-frame-oracle-failed" or . == "encoded-output-unavailable" or . == "source-clip-unavailable" or . == "trace-headers-oracle-failed";
		def raw_pair: exact(["decoded","durationSeconds","reason","start","status","trace"]) and (.start | type == "string") and .durationSeconds == 10 and (.status | status) and (if .status == "complete" then .reason == null else (.reason | pair_reason) end) and (.decoded | raw_oracle) and (.trace | raw_oracle);
		def oracle_pair: exact(["decoded","trace"]) and (.decoded | oracle) and (.trace | oracle);
		def normalized: exact(["clip","encoded","schemaVersion","source"]) and .schemaVersion == 1 and
			(.source | exact(["authoritative","streamProbe","windows"]) and (.streamProbe | oracle) and (.authoritative | authoritative(["decoded-trace-disagreement","source-window-absent","source-window-conflict","source-window-malformed","source-window-null"])) and (.windows | exact(["beginning","detail","end"]) and all(.[]; exact(["authoritative","decoded","trace"]) and (.decoded | oracle) and (.trace | oracle) and (.authoritative | authoritative(["decoded-trace-disagreement","source-window-absent","source-window-malformed","source-window-null"]))))) and
			(.clip | exact(["authoritative","decoded","trace"]) and (.decoded | oracle) and (.trace | oracle) and (.authoritative | authoritative(["clip-window-absent","clip-window-malformed","clip-window-null","decoded-trace-disagreement"]))) and
			(.encoded | exact(["authoritative","decoded","trace"]) and (.decoded | oracle) and (.trace | oracle) and (.authoritative | authoritative(["decoded-trace-disagreement","encoded-window-absent","encoded-window-malformed","encoded-window-null"])));
		def evidence_reason: . == "HDR-classification-failed" or . == "HDR-oracle-normalization-failed" or . == "clip-identity-unavailable" or . == "conflicting-HDR-oracle" or . == "decode-failed" or . == "encode-failed" or . == "output-identity-unavailable" or . == "post-run-identity-drift" or . == "source-clip-unavailable" or . == "source-duration-unavailable" or . == "source-identity-unavailable" or . == "source-stream-oracle-failed";
		def classification: . as $class | exact(["classification","reasons","schemaVersion"]) and .schemaVersion == 1 and (.classification == "clip-boundary-defect" or .classification == "encoder-output-defect" or .classification == "preserved" or .classification == "source-probe-defect" or .classification == "unresolved-oracle") and (.reasons | type == "array" and length >= 1 and length <= 16 and length == (unique | length) and all(.[]; type == "string" and ($reason_classes[.] | type == "array") and ($reason_classes[.] | index($class.classification)) != null));
		exact(["classification","clip","clipId","commands","encoded","globalQuality","normalizedOracle","reason","sampleId","schemaVersion","source","status","strategyId"]) and .schemaVersion == 1 and .strategyId == "qsv-hevc-icq-v1" and .sampleId == $sample and .clipId == "detail" and .globalQuality == 16 and (.status|status) and (if .status == "complete" then .reason == null else (.reason | evidence_reason) end) and
		(.commands | exact(["clip","decode","encode"]) and all(.[]; command)) and
		(.source | exact(["identity","streamProbe","windows"]) and (.identity | identity) and (.streamProbe | exact(["command","oracle"]) and (.command | command) and (.oracle | oracle)) and (.windows | exact(["beginning","detail","end"]) and all(.[]; raw_pair))) and
		(.clip | exact(["decoded","durationSeconds","identity","reason","start","status","trace"]) and (del(.identity) | raw_pair) and (.identity | identity)) and
		(.encoded | exact(["decoded","durationSeconds","identity","reason","start","status","trace"]) and (del(.identity) | raw_pair) and (.identity | identity)) and
		(.normalizedOracle | normalized) and
		(.classification | classification)
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
	validate_vmaf "$sample" "$clip" "$index" "$evidence_path" || {
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
	validate_hdr "$sample" "$evidence_path" || {
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

canonical="$(jq -n -S -c --arg run "$EVIDENCE_RUN_ID" \
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
		def vmaf($raw): $raw[0] | {sampleId,clipId,observedFrameIndex,status,sourceContinuity:(.sourceClip.frameWindow | {decodedFrameCount,stream:(.stream | {startTime,duration,timeBase,averageFrameRate}),frames:[.frames[] | {frameIndex,bestEffortTimestamp,packetDuration,keyFrame,pictureType}]}),settings:[.settings[] | {globalQuality,status,reason,vmaf:(.vmaf | vmaf_metric),offsets:[.offsets[] | offset],timeline}],classification};
		def gcd($a; $b): if $b == 0 then $a else gcd($b; ($a % $b)) end;
		def normalize_rationals:
			walk(if type == "object" and (keys | sort) == ["denominator","numerator"] and (.numerator | type == "number" and floor == . and . >= 0) and (.denominator | type == "number" and floor == . and . > 0) then
				(gcd(.numerator; .denominator)) as $divisor | {numerator:(.numerator / $divisor),denominator:(.denominator / $divisor)}
			else . end);
		def hdr($raw): $raw[0] | {sampleId,clipId,globalQuality,status,reason,normalizedOracle:(.normalizedOracle | normalize_rationals),classification};
		{schemaVersion:1,strategyId:"qsv-hevc-icq-v1",mode:"diagnostic-evidence-reader",runId:$run,vmaf:[vmaf($vmaf0),vmaf($vmaf1),vmaf($vmaf2),vmaf($vmaf3),vmaf($vmaf4)],hdr:[hdr($hdr0),hdr($hdr1),hdr($hdr2)]}
	')" || exit 65
canonical_bytes="$(printf '%s' "$canonical" | LC_ALL=C wc -c | tr -d '[:space:]')"
[[ "$canonical_bytes" =~ ^[0-9]+$ && "$canonical_bytes" -le "$EVIDENCE_MAX_BYTES" ]] || {
	echo 'canonical diagnostic evidence exceeds the output limit' >&2
	exit 65
}
printf '%s\n' "$canonical"
