#!/usr/bin/env bash
# shellcheck disable=SC2034

contract_load() {
	local file="$1"
	jq -e '
		.schemaVersion == 3 and
		.strategy.id == "qsv-hevc-icq-v1" and
		.strategy.resultsSchemaVersion == 3 and
		.strategy.runManifestSchemaVersion == 2 and
		.strategy.capabilityProofSchemaVersion == 3 and
		.strategy.globalQualityCandidates == [16, 18, 20, 22, 24, 26, 28, 30] and
		.qualityCorrection == {
			schemaVersion: 1,
			diagnosticRunId: "20260829T020752Z-43984d8d",
			vmafMeasurementDefects: [
				{sampleId: "avc-clean-coco", clipId: "motion", frameIndex: 1641},
				{sampleId: "avc-grain-memento", clipId: "dark", frameIndex: 523},
				{sampleId: "avc-grain-memento", clipId: "detail", frameIndex: 370},
				{sampleId: "vc1-fugitive", clipId: "motion", frameIndex: 798}
			]
		}
	' "$file" >/dev/null || return 65
	CONTRACT_STRATEGY_ID="$(jq -r '.strategy.id' "$file")"
	CONTRACT_ICQ_SETTINGS="$(jq -r '.strategy.globalQualityCandidates | join(" ")' "$file")"
	CONTRACT_RESULTS_SCHEMA="$(jq -r '.strategy.resultsSchemaVersion' "$file")"
	CONTRACT_MANIFEST_SCHEMA="$(jq -r '.strategy.runManifestSchemaVersion' "$file")"
	CONTRACT_CAPABILITY_SCHEMA="$(jq -r '.strategy.capabilityProofSchemaVersion' "$file")"
	CONTRACT_QUALITY_EVIDENCE_SCHEMA="$(jq -r '.qualityCorrection.schemaVersion' "$file")"
	CONTRACT_QUALITY_CANDIDATES_SCHEMA=2
	CONTRACT_QUALITY_DIAGNOSTIC_RUN_ID="$(jq -r '.qualityCorrection.diagnosticRunId' "$file")"
	readonly CONTRACT_STRATEGY_ID CONTRACT_ICQ_SETTINGS CONTRACT_RESULTS_SCHEMA
	readonly CONTRACT_MANIFEST_SCHEMA CONTRACT_CAPABILITY_SCHEMA
	readonly CONTRACT_QUALITY_EVIDENCE_SCHEMA CONTRACT_QUALITY_CANDIDATES_SCHEMA
	readonly CONTRACT_QUALITY_DIAGNOSTIC_RUN_ID
}

contract_quality_vmaf_exclusion() {
	local file="$1" sample_id="$2" clip_id="$3"
	jq -e -r --arg sample "$sample_id" --arg clip "$clip_id" '
		[.qualityCorrection.vmafMeasurementDefects[] |
			select(.sampleId == $sample and .clipId == $clip)] |
		if length == 1 then .[0].frameIndex else empty end
	' "$file" || return 1
}

contract_is_compact_utc_timestamp() {
	local value="$1"
	jq -e -n --arg value "$value" '
		def compact_utc:
			type == "string" and test("^[0-9]{8}T[0-9]{6}Z$") and
			. as $original |
			(capture("^(?<year>[0-9]{4})(?<month>[0-9]{2})(?<day>[0-9]{2})T(?<hour>[0-9]{2})(?<minute>[0-9]{2})(?<second>[0-9]{2})Z$") |
				"\(.year)-\(.month)-\(.day)T\(.hour):\(.minute):\(.second)Z") as $iso |
			try (($iso | fromdateiso8601 | strftime("%Y%m%dT%H%M%SZ")) == $original) catch false;
		$value | compact_utc
	' >/dev/null
}

contract_is_run_id() {
	local value="$1" timestamp
	[[ "$value" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]] || return 1
	timestamp="${value%-*}"
	contract_is_compact_utc_timestamp "$timestamp"
}

contract_normalize_run_identity() {
	local input_json="$1" mode="$2"
	jq -e -S -c \
		--arg mode "$mode" --arg strategy "$CONTRACT_STRATEGY_ID" \
		--argjson manifest_schema "$CONTRACT_MANIFEST_SCHEMA" \
		--argjson results_schema "$CONTRACT_RESULTS_SCHEMA" '
		def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
		def string_object($keys):
			(type == "object" and keys == $keys and ([.[] | type == "string"] | all));
		def nonempty_string_object($keys):
			(type == "object" and keys == $keys and
				([.[] | type == "string" and length > 0] | all));
		if
			(keys == [
				"encoderCommands", "gpu", "images", "mode", "node", "resultsSchemaVersion",
				"samplesDigest", "schemaVersion", "scriptDigests", "sources", "strategyId", "vmaf"
			]) and
			(.images | type == "object" and keys == ["configured", "dispatched", "running"]) and
			(.node | string_object(["kernel", "name"])) and
			(.vmaf | string_object(["model", "version"])) and
			(.gpu | nonempty_string_object(["i915", "vpl"])) and
			(.sources | type == "array" and all(.[];
				type == "object" and keys == ["path", "sha256", "size"]))
		then . else error("invalid benchmark identity") end
		| {
			encoderCommands, gpu, images, mode: $mode,
			node: {kernel: .node.kernel, name: .node.name},
			resultsSchemaVersion, samplesDigest, schemaVersion, scriptDigests,
			sources: (.sources | map({path: .path, sha256: .sha256, size: .size}) | sort_by(.path)),
			strategyId, vmaf: {model: .vmaf.model, version: .vmaf.version}
		}
		| if
			($mode == "capabilities" or $mode == "quality") and
			.schemaVersion == $manifest_schema and
			.strategyId == $strategy and
			.resultsSchemaVersion == $results_schema and
			(.images | ([.configured, .dispatched, .running] as $digests |
				($digests | all(digest)) and ($digests | unique | length == 1))) and
			(.scriptDigests | type == "object" and all(.[]; digest)) and
			(.samplesDigest | digest) and
			(.sources | type == "array" and all(.[];
				(.path | type == "string") and
				(.size | type == "number" and . >= 0 and floor == .) and
				(.sha256 | digest))) and
			(.encoderCommands | type == "array" and all(.[]; type == "string")) and
			(.gpu | type == "object")
		then . else error("invalid benchmark identity") end
	' <<<"$input_json"
}

contract_is_icq_setting() {
	local file="$1" value="$2"
	jq -e --argjson value "$value" \
		'.strategy.globalQualityCandidates | index($value) != null' "$file" >/dev/null
}

# Print each node that has a complete, passing schema-v3 ICQ capability record.
# Dispatch and the workload use the same proof contract so a weaker record cannot
# admit an otherwise incomplete node.
contract_passing_icq_nodes() {
	local file="$1"
	jq -r '
		def immutable_image_id($digest):
			type == "string" and test("^([^@[:space:]]+@)?sha256:[0-9a-f]{64}$") and
			(sub("^.*@"; "") == $digest);
		def passing_node($digest):
			type == "object" and
			.strategyId == "qsv-hevc-icq-v1" and .proofSchemaVersion == 3 and
			(.nodeName | type == "string" and test("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$")) and
			.initialization == "passed" and .initializationReason == "" and
			.renderNode == "/dev/dri/renderD128" and .drmDriver == "i915" and
			.selectedRateControl == "ICQ" and .telemetryStatus == "available" and
			.telemetryReason == "" and
			(.videoBusyNanoseconds | type == "number" and . > 0) and
			(.videoBusyPercent | type == "number" and . >= 0) and
			(.encodeFps | type == "number" and . >= 0) and
			(.encodeSpeed | type == "number" and . > 0) and
			.decode == "passed" and .vmaf == "passed" and
			. as $node |
			(.diagnosticCapabilities | type == "object" and
				keys == ["bestEffortTimestampTime","imageId","keyFrame","libvmaf","packetDurationTime","pictType","psnr","ssim","traceHeaders","verifiedAt"] and
				.traceHeaders == "passed" and .libvmaf == "passed" and
				.ssim == "passed" and .psnr == "passed" and
				.bestEffortTimestampTime == "passed" and .packetDurationTime == "passed" and
				.keyFrame == "passed" and .pictType == "passed" and
				.imageId == $node.imageId and .verifiedAt == $node.verifiedAt and
				(.imageId | immutable_image_id($digest))) and
			.proofStatus == "passed" and .proofReasons == "" and
			(.verifiedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
			.configuredImageDigest == $digest and (.imageId | immutable_image_id($digest));
		.runtime.image as $image |
		($image | capture("@(?<digest>sha256:[0-9a-f]{64})$").digest) as $digest |
		select(.runtime.capabilityStatus == "verified") |
		.runtime.capabilityEvidence.nodes[]? | select(passing_node($digest)) | .nodeName
	' "$file" | sort -u
}
