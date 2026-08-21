#!/usr/bin/env bash
# Read and redact the one approved diagnostic run.  This script deliberately
# accepts a directory supplied by the Job mount, never an artifact path from a
# retained summary, so evidence cannot escape the read-only mounted subtree.
set -euo pipefail

readonly EVIDENCE_RUN_ID='20260820T223425Z-082b3d38'
readonly EVIDENCE_MAX_BYTES=65536

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
jq -e --arg run "$EVIDENCE_RUN_ID" '
	def status: . == "complete" or . == "failed" or . == "harness-blocked";
	def class: type == "string" and test("^(temporal-alignment-defect|encoder-output-defect|vmaf-measurement-defect|unresolved|source-probe-defect|clip-boundary-defect|preserved|unresolved-oracle)$");
	def reason_list: type == "array" and length <= 8 and all(.[]; type == "string" and test("^[a-z0-9][a-z0-9-]*$"));
	def vmaf_entry: type == "object" and has("sampleId") and has("clipId") and has("status") and has("classification") and has("reasons") and has("evidence") and (.status|status) and (.classification|class) and (.reasons|reason_list) and (.evidence|type == "string" and test("^vmaf/[a-z0-9-]+/[a-z0-9-]+/evidence[.]json$"));
	def hdr_entry: type == "object" and has("sampleId") and has("status") and has("classification") and has("reasons") and has("evidence") and (.status|status) and (.classification|class) and (.reasons|reason_list) and (.evidence|type == "string" and test("^hdr/[a-z0-9-]+/evidence[.]json$"));
	type == "object" and .schemaVersion == 1 and .strategyId == "qsv-hevc-icq-v1" and .mode == "diagnostics" and .runId == $run and (.status|status) and
	(.vmaf | type == "object" and .total == 5 and (.entries | type == "array" and length == 5 and all(.[]; vmaf_entry) and ([.[] | [.sampleId,.clipId] | join("/")] | sort) == ["avc-clean-coco/motion","avc-grain-memento/dark","avc-grain-memento/detail","vc1-fugitive/detail","vc1-fugitive/motion"])) and
	(.hdr | type == "object" and .total == 3 and (.entries | type == "array" and length == 3 and all(.[]; hdr_entry) and ([.[] | .sampleId] | sort) == ["hdr10-clean-ministry","hdr10-grain-goodfellas","hdr10-motion-john-wick-2"]))
' "$summary" >/dev/null || {
	echo 'diagnostic summary does not bind the approved panel' >&2
	exit 65
}

validate_vmaf() {
	local sample="$1" clip="$2" index="$3" path="$4"
	jq -e --arg sample "$sample" --arg clip "$clip" --argjson index "$index" '
		def status: . == "complete" or . == "failed" or . == "harness-blocked";
		def frame: type == "object" and has("frameIndex") and (.frameIndex | type == "number");
		def window: type == "object" and has("decodedFrameCount") and has("stream") and has("frames") and (.decodedFrameCount | type == "number" and . >= 0) and (.stream | type == "object") and (.frames | type == "array" and length <= 5 and all(.[]; frame));
		def metric: type == "object" and has("current") and has("reset") and (.current | type == "array" and length <= 5) and (.reset | type == "array" and length <= 5);
		def offset: type == "object" and has("offset") and has("ssim") and has("psnr") and (.offset | type == "number" and floor == . and . >= -2 and . <= 2);
		def setting: type == "object" and has("globalQuality") and has("status") and has("reason") and has("vmaf") and has("offsets") and has("timeline") and (.globalQuality == 16 or .globalQuality == 30) and (.status|status) and (.reason == null or (.reason | type == "string")) and (.vmaf|metric) and (.offsets | type == "array" and length <= 5 and all(.[]; offset)) and (.timeline | type == "object");
		type == "object" and .schemaVersion == 1 and .strategyId == "qsv-hevc-icq-v1" and .sampleId == $sample and .clipId == $clip and .observedFrameIndex == $index and (.status|status) and
		(.sourceClip | type == "object" and (.frameWindow | window)) and
		(.settings | type == "array" and length == 2 and all(.[]; setting) and ([.[].globalQuality] | sort) == [16,30]) and
		(.classification | type == "object" and .schemaVersion == 1 and (.classification | type == "string") and (.reasons | type == "array"))
	' "$path" >/dev/null
}

validate_hdr() {
	local sample="$1" path="$2"
	jq -e --arg sample "$sample" '
		def status: . == "complete" or . == "failed" or . == "harness-blocked";
		type == "object" and .schemaVersion == 1 and .strategyId == "qsv-hevc-icq-v1" and .sampleId == $sample and .clipId == "detail" and .globalQuality == 16 and (.status|status) and (.reason == null or (.reason | type == "string")) and
		(.normalizedOracle | type == "object" and .schemaVersion == 1 and (.source | type == "object") and (.clip | type == "object") and (.encoded | type == "object")) and
		(.classification | type == "object" and .schemaVersion == 1 and (.classification | type == "string") and (.reasons | type == "array"))
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
	validate_vmaf "$sample" "$clip" "$index" "$evidence_root/vmaf/$sample/$clip/evidence.json" || {
		echo 'VMAF diagnostic evidence violates its approved schema' >&2
		exit 65
	}
done
for sample in hdr10-clean-ministry hdr10-grain-goodfellas hdr10-motion-john-wick-2; do
	validate_hdr "$sample" "$evidence_root/hdr/$sample/evidence.json" || {
		echo 'HDR diagnostic evidence violates its approved schema' >&2
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
		def vmaf($raw): $raw[0] | {sampleId,clipId,observedFrameIndex,status,sourceContinuity:(.sourceClip.frameWindow | {decodedFrameCount,stream:(.stream | {startTime,duration,timeBase,averageFrameRate}),frames:[.frames[] | {frameIndex,bestEffortTimestamp,packetDuration,keyFrame,pictureType}]}),settings:[.settings[] | {globalQuality,status,reason,vmaf,offsets,timeline}],classification};
		def hdr($raw): $raw[0] | {sampleId,clipId,globalQuality,status,reason,normalizedOracle,classification};
		{schemaVersion:1,strategyId:"qsv-hevc-icq-v1",mode:"diagnostic-evidence-reader",runId:$run,vmaf:[vmaf($vmaf0),vmaf($vmaf1),vmaf($vmaf2),vmaf($vmaf3),vmaf($vmaf4)],hdr:[hdr($hdr0),hdr($hdr1),hdr($hdr2)]}
	')" || exit 65
canonical_bytes="$(printf '%s' "$canonical" | LC_ALL=C wc -c | tr -d '[:space:]')"
[[ "$canonical_bytes" =~ ^[0-9]+$ && "$canonical_bytes" -le "$EVIDENCE_MAX_BYTES" ]] || {
	echo 'canonical diagnostic evidence exceeds the output limit' >&2
	exit 65
}
printf '%s\n' "$canonical"
