#!/usr/bin/env bash
# shellcheck disable=SC2034

CONTRACT_DIAGNOSTIC_TERMINAL_MAX_BYTES=3072
CONTRACT_DIAGNOSTIC_TERMINAL_REASON_COUNT_LIMIT=16
CONTRACT_DIAGNOSTIC_TERMINAL_REASON_LENGTH_LIMIT=64
readonly CONTRACT_DIAGNOSTIC_TERMINAL_MAX_BYTES CONTRACT_DIAGNOSTIC_TERMINAL_REASON_COUNT_LIMIT
readonly CONTRACT_DIAGNOSTIC_TERMINAL_REASON_LENGTH_LIMIT

contract_diagnostics_terminal_byte_count() {
	local value="$1"
	local LC_ALL=C
	printf '%s' "$value" | wc -c | tr -d '[:space:]'
}

contract_load() {
	local file="$1"
	jq -e '
		.schemaVersion == 2 and
		.strategy.id == "qsv-hevc-icq-v1" and
		.strategy.resultsSchemaVersion == 2 and
		.strategy.runManifestSchemaVersion == 2 and
		.strategy.capabilityProofSchemaVersion == 3 and
		.strategy.globalQualityCandidates == [16, 18, 20, 22, 24, 26, 28, 30] and
		.strategy.x265 == {
			initialCrfs: [18, 20, 22, 24], minimumCrf: 10, maximumCrf: 34, step: 2
		}
	' "$file" >/dev/null || return 65
	if jq -e 'has("diagnostics")' "$file" >/dev/null; then
		contract_validate_diagnostics_scope "$file" >/dev/null || return 65
	fi
	CONTRACT_STRATEGY_ID="$(jq -r '.strategy.id' "$file")"
	CONTRACT_ICQ_SETTINGS="$(jq -r '.strategy.globalQualityCandidates | join(" ")' "$file")"
	CONTRACT_RESULTS_SCHEMA="$(jq -r '.strategy.resultsSchemaVersion' "$file")"
	CONTRACT_MANIFEST_SCHEMA="$(jq -r '.strategy.runManifestSchemaVersion' "$file")"
	CONTRACT_CAPABILITY_SCHEMA="$(jq -r '.strategy.capabilityProofSchemaVersion' "$file")"
	readonly CONTRACT_STRATEGY_ID CONTRACT_ICQ_SETTINGS CONTRACT_RESULTS_SCHEMA
	readonly CONTRACT_MANIFEST_SCHEMA CONTRACT_CAPABILITY_SCHEMA
}

contract_validate_diagnostics_scope() {
	local file="$1"
	jq -e '
		. as $root |
		def exact_keys($expected): type == "object" and keys == $expected;
		def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
		def compact_utc:
			type == "string" and test("^[0-9]{8}T[0-9]{6}Z$") and
			. as $original |
			(capture("^(?<year>[0-9]{4})(?<month>[0-9]{2})(?<day>[0-9]{2})T(?<hour>[0-9]{2})(?<minute>[0-9]{2})(?<second>[0-9]{2})Z$") |
				"\(.year)-\(.month)-\(.day)T\(.hour):\(.minute):\(.second)Z") as $iso |
			try (($iso | fromdateiso8601 | strftime("%Y%m%dT%H%M%SZ")) == $original) catch false;
		def run_id:
			type == "string" and test("^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$") and
			(split("-")[0] | compact_utc);
		def sample_id: type == "string" and test("^[a-z0-9][a-z0-9._-]*$");
		def clip_id: type == "string" and test("^[a-z0-9][a-z0-9._-]*$");
		def quality_clip_exists($sample; $clip):
			any($root.qualityPanel[]?;
				.id == $sample and (.clips | (type == "object" and has($clip))));
		def diagnostics_contract:
			exact_keys([
				"acceptedFindingsSha256", "decisionSha256", "frameOffsets", "frameRadius",
				"hdrPanel", "hdrSetting", "historicalFindingsRunId", "historicalQualityRunId",
				"resultSchemaVersion", "schemaVersion", "strategyId", "traceWindowSeconds",
				"vmafPanel", "vmafSettings"
			]) and
			.schemaVersion == 1 and
			.resultSchemaVersion == 1 and
			.strategyId == "qsv-hevc-icq-v1" and
			(.acceptedFindingsSha256 | digest) and
			(.decisionSha256 | digest) and
			(.historicalQualityRunId | run_id) and
			(.historicalFindingsRunId | run_id) and
			.vmafSettings == [16, 30] and
			.hdrSetting == 16 and
			.frameRadius == 2 and
			.frameOffsets == [-2, -1, 0, 1, 2] and
			.traceWindowSeconds == 10 and
			(.vmafPanel | type == "array" and length == 5 and
				all(.[];
					exact_keys(["clipId", "observedFrameIndex", "sampleId"]) and
					(.sampleId | sample_id) and
					(.clipId | clip_id) and
					(.observedFrameIndex | type == "number" and floor == . and . >= 0) and
					quality_clip_exists(.sampleId; .clipId)) and
				([.[] | "\(.sampleId)|\(.clipId)"] | unique | length) == 5 and
				([.[] | "\(.sampleId)/\(.clipId)/\(.observedFrameIndex)"] == [
					"avc-clean-coco/motion/1641",
					"avc-grain-memento/dark/523",
					"avc-grain-memento/detail/370",
					"vc1-fugitive/detail/781",
					"vc1-fugitive/motion/798"
				])) and
			(.hdrPanel | type == "array" and length == 3 and
				all(.[];
					exact_keys(["clipId", "sampleId"]) and
					(.sampleId | sample_id) and
					(.clipId | clip_id) and
					quality_clip_exists(.sampleId; .clipId)) and
				([.[] | .sampleId] | unique | length) == 3 and
				([.[] | "\(.sampleId)/\(.clipId)"] == [
					"hdr10-clean-ministry/detail",
					"hdr10-grain-goodfellas/detail",
					"hdr10-motion-john-wick-2/detail"
				]));
		(.diagnostics | diagnostics_contract)
	' "$file" >/dev/null
}

contract_require_diagnostics() {
	local file="$1"
	jq -e 'has("diagnostics")' "$file" >/dev/null || {
		echo 'diagnostic contract is missing or malformed' >&2
		return 65
	}
	contract_validate_diagnostics_scope "$file" >/dev/null || {
		echo 'diagnostic contract is missing or malformed' >&2
		return 65
	}
	CONTRACT_DIAGNOSTICS_MANIFEST_SCHEMA="$(jq -r '.diagnostics.schemaVersion' "$file")"
	CONTRACT_DIAGNOSTICS_RESULT_SCHEMA="$(jq -r '.diagnostics.resultSchemaVersion' "$file")"
	CONTRACT_DIAGNOSTICS_ACCEPTED_FINDINGS_SHA256="$(jq -r '.diagnostics.acceptedFindingsSha256' "$file")"
	CONTRACT_DIAGNOSTICS_DECISION_SHA256="$(jq -r '.diagnostics.decisionSha256' "$file")"
	CONTRACT_DIAGNOSTICS_HISTORICAL_QUALITY_RUN_ID="$(jq -r '.diagnostics.historicalQualityRunId' "$file")"
	CONTRACT_DIAGNOSTICS_HISTORICAL_FINDINGS_RUN_ID="$(jq -r '.diagnostics.historicalFindingsRunId' "$file")"
	readonly CONTRACT_DIAGNOSTICS_MANIFEST_SCHEMA CONTRACT_DIAGNOSTICS_RESULT_SCHEMA
	readonly CONTRACT_DIAGNOSTICS_ACCEPTED_FINDINGS_SHA256 CONTRACT_DIAGNOSTICS_DECISION_SHA256
	readonly CONTRACT_DIAGNOSTICS_HISTORICAL_QUALITY_RUN_ID CONTRACT_DIAGNOSTICS_HISTORICAL_FINDINGS_RUN_ID
}

contract_validate_chosen_settings() {
	local file="$1" cohort
	jq -e '
		(.chosenSettings | type == "object") and
		([.chosenSettings | keys[]] | all(. == "avc" or . == "vc1" or . == "hdr10"))
	' "$file" >/dev/null || return 65
	while IFS= read -r cohort; do
		contract_chosen_record "$file" "$cohort" >/dev/null || return 65
	done < <(jq -r '.chosenSettings | keys[]' "$file")
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

contract_diagnostics_panel_json() {
	local file="$1"
	jq -e -S -c '
		.diagnostics |
		{vmafPanel, hdrPanel, vmafSettings, hdrSetting, frameRadius, frameOffsets, traceWindowSeconds}
	' "$file"
}

contract_diagnostics_panel_sha256() {
	local file="$1" panel_json
	panel_json="$(contract_diagnostics_panel_json "$file")" || return 65
	printf 'sha256:%s\n' "$(printf '%s' "$panel_json" | sha256sum | awk 'NR == 1 { print $1 }')"
}

contract_diagnostics_terminal_statuses_json() {
	cat <<'EOF'
["complete","failed","harness-blocked"]
EOF
}

contract_diagnostics_terminal_vmaf_reason_classes_json() {
	cat <<'EOF'
{"assigned-node-capability-rejected":["unresolved"],"classification-failed":["unresolved"],"classification-predicate-not-met":["unresolved"],"diagnostic-preflight-rejected":["unresolved"],"incomplete-or-failed-evidence":["unresolved"],"incomplete-setting-evidence":["unresolved"],"independent-metrics-not-target-minimum":["vmaf-measurement-defect"],"missing-offset-window":["unresolved"],"nonzero-ssim-psnr-offset-agreement":["temporal-alignment-defect"],"offset-best-tie":["unresolved"],"one-setting-evidence":["unresolved"],"post-run-identity-drift":["unresolved"],"pts-reset-clears-vmaf-zero":["temporal-alignment-defect"],"runmeta-create-failed":["unresolved"],"running-image-evidence-rejected":["unresolved"],"runtime-pre-encode-gate-rejected":["unresolved"],"source-window-clean":["encoder-output-defect"],"ssim-psnr-offset-disagreement":["unresolved"],"target-frame-local-metric-minimum":["encoder-output-defect"],"timeline-discontinuity-at-offset":["temporal-alignment-defect"],"vmaf-only-exact-zero":["vmaf-measurement-defect"],"zero-offset-timeline-agreement":["encoder-output-defect","vmaf-measurement-defect"]}
EOF
}

contract_diagnostics_terminal_hdr_reason_classes_json() {
	cat <<'EOF'
{"assigned-node-capability-rejected":["unresolved-oracle"],"authoritative-source-metadata":["clip-boundary-defect","source-probe-defect"],"classification-failed":["unresolved-oracle"],"clip-metadata-changed":["clip-boundary-defect"],"clip-window-absent":["unresolved-oracle"],"clip-window-malformed":["unresolved-oracle"],"clip-window-null":["unresolved-oracle"],"decoded-trace-disagreement":["unresolved-oracle"],"diagnostic-preflight-rejected":["unresolved-oracle"],"encoded-metadata-changed":["encoder-output-defect"],"encoded-window-absent":["unresolved-oracle"],"encoded-window-malformed":["unresolved-oracle"],"encoded-window-null":["unresolved-oracle"],"incomplete-or-failed-evidence":["unresolved-oracle"],"post-run-identity-drift":["unresolved-oracle"],"runmeta-create-failed":["unresolved-oracle"],"running-image-evidence-rejected":["unresolved-oracle"],"runtime-pre-encode-gate-rejected":["unresolved-oracle"],"source-and-clip-metadata-agree":["encoder-output-defect"],"source-clip-encoded-metadata-agree":["preserved"],"source-stream-probe-absent":["unresolved-oracle"],"source-stream-probe-conflict":["unresolved-oracle"],"source-stream-probe-malformed":["unresolved-oracle"],"source-window-absent":["unresolved-oracle"],"source-window-conflict":["unresolved-oracle"],"source-window-malformed":["unresolved-oracle"],"source-window-null":["unresolved-oracle"],"stream-probe-null":["source-probe-defect"]}
EOF
}

contract_diagnostics_terminal_schema_reason() {
	local payload="$1" requested_run_id="${2:-}" expected_status="${3:-}" expected_artifact_location="${4:-}"
	local statuses vmaf_reason_classes hdr_reason_classes
	statuses="$(contract_diagnostics_terminal_statuses_json)"
	vmaf_reason_classes="$(contract_diagnostics_terminal_vmaf_reason_classes_json)"
	hdr_reason_classes="$(contract_diagnostics_terminal_hdr_reason_classes_json)"
	jq -r \
		--arg strategy "$CONTRACT_STRATEGY_ID" \
		--arg run "$requested_run_id" \
		--arg status "$expected_status" \
		--arg artifact "$expected_artifact_location" \
		--argjson statuses "$statuses" \
		--argjson vmaf_reason_classes "$vmaf_reason_classes" \
		--argjson hdr_reason_classes "$hdr_reason_classes" \
		--argjson reason_count_limit "$CONTRACT_DIAGNOSTIC_TERMINAL_REASON_COUNT_LIMIT" \
		--argjson reason_length_limit "$CONTRACT_DIAGNOSTIC_TERMINAL_REASON_LENGTH_LIMIT" '
		def sorted_unique: . == (sort | unique);
		def int_nonneg: type == "number" and floor == . and . >= 0;
		def terminal_reasons:
			[(try .vmaf.reasons[] catch empty), (try .hdr.reasons[] catch empty)];
		def has_unknown_reasons($section; $reason_classes):
			try ($section.reasons | any(.[]; . as $reason |
				($reason | type) == "string" and ($reason_classes[$reason] | type) != "array")) catch false;
		def compatible_reasons($reason_classes; $counts):
			type == "array" and
			length >= 1 and
			length <= $reason_count_limit and
			sorted_unique and
			all(.[]; . as $reason |
				($reason | type) == "string" and
				($reason | length) > 0 and
				($reason | length) <= $reason_length_limit and
				($reason_classes[$reason] | type) == "array" and
				any(($reason_classes[$reason])[]; ($counts[.] // 0) > 0));
		def vmaf_counts:
			. as $section |
			type == "object" and
			(keys | sort) == ["encoder-output-defect","reasons","temporal-alignment-defect","total","unresolved","vmaf-measurement-defect"] and
			.total == 5 and
			(."encoder-output-defect" | int_nonneg) and
			(."temporal-alignment-defect" | int_nonneg) and
			(.unresolved | int_nonneg) and
			(."vmaf-measurement-defect" | int_nonneg) and
			(."encoder-output-defect" + ."temporal-alignment-defect" + .unresolved + ."vmaf-measurement-defect" == 5) and
			($section.reasons | compatible_reasons($vmaf_reason_classes; {
				"encoder-output-defect": $section["encoder-output-defect"],
				"temporal-alignment-defect": $section["temporal-alignment-defect"],
				"unresolved": $section.unresolved,
				"vmaf-measurement-defect": $section["vmaf-measurement-defect"]
			}));
		def hdr_counts:
			. as $section |
			type == "object" and
			(keys | sort) == ["clip-boundary-defect","encoder-output-defect","preserved","reasons","source-probe-defect","total","unresolved-oracle"] and
			.total == 3 and
			(."clip-boundary-defect" | int_nonneg) and
			(."encoder-output-defect" | int_nonneg) and
			(.preserved | int_nonneg) and
			(."source-probe-defect" | int_nonneg) and
			(."unresolved-oracle" | int_nonneg) and
			(."clip-boundary-defect" + ."encoder-output-defect" + .preserved + ."source-probe-defect" + ."unresolved-oracle" == 3) and
			($section.reasons | compatible_reasons($hdr_reason_classes; {
				"clip-boundary-defect": $section["clip-boundary-defect"],
				"encoder-output-defect": $section["encoder-output-defect"],
				"preserved": $section.preserved,
				"source-probe-defect": $section["source-probe-defect"],
				"unresolved-oracle": $section["unresolved-oracle"]
			}));
		.status as $payload_status |
		if type != "object" then "not-object"
		elif (keys | sort) != ["artifactLocation","hdr","mode","runId","schemaVersion","status","strategyId","vmaf"] then "wrong-keys"
		elif .schemaVersion != 1 then "wrong-schema-version"
		elif .strategyId != $strategy then "wrong-strategy"
		elif .mode != "diagnostics" then "wrong-mode"
		elif ($statuses | index($payload_status)) == null then "wrong-status"
		elif ($status != "" and $payload_status != $status) then "wrong-status"
		elif (($run == "" and .runId != null) or ($run != "" and .runId != $run)) then "wrong-run-id"
		elif (($artifact == "" and .artifactLocation != null) or ($artifact != "" and .artifactLocation != $artifact)) then "wrong-artifact-location"
		elif (terminal_reasons | any(.[]; type == "string" and length > $reason_length_limit)) then "reason-too-long"
		elif has_unknown_reasons(.vmaf; $vmaf_reason_classes) or
			has_unknown_reasons(.hdr; $hdr_reason_classes) then "unknown-reason"
		elif (.vmaf | vmaf_counts | not) then "wrong-vmaf-counts"
		elif (.hdr | hdr_counts | not) then "wrong-hdr-counts"
		elif ((.vmaf.reasons + .hdr.reasons) | unique | length) > $reason_count_limit then "too-many-reasons"
		else "" end
	' <<<"$payload"
}

contract_normalize_selected_settings() {
	local input_json="$1"
	jq -e -S -c '
		def compact_utc:
			type == "string" and test("^[0-9]{8}T[0-9]{6}Z$") and
			. as $original |
			(capture("^(?<year>[0-9]{4})(?<month>[0-9]{2})(?<day>[0-9]{2})T(?<hour>[0-9]{2})(?<minute>[0-9]{2})(?<second>[0-9]{2})Z$") |
				"\(.year)-\(.month)-\(.day)T\(.hour):\(.minute):\(.second)Z") as $iso |
			try (($iso | fromdateiso8601 | strftime("%Y%m%dT%H%M%SZ")) == $original) catch false;
		def run_id:
			type == "string" and test("^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$") and
			(split("-")[0] | compact_utc);
		if type == "array" and length <= 3 and
			all(.[];
				type == "object" and keys == ["cohort","globalQuality","qualityRunId"] and
				(.cohort == "avc" or .cohort == "vc1" or .cohort == "hdr10") and
				(.globalQuality | type == "number" and floor == .) and
				(.globalQuality as $value | [16,18,20,22,24,26,28,30] | index($value) != null) and
				(.qualityRunId | run_id)) and
			([.[].cohort] | unique | length) == length
		then sort_by(.cohort) else error("invalid selected settings") end
	' <<<"$input_json"
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
		def compact_utc:
			type == "string" and test("^[0-9]{8}T[0-9]{6}Z$") and
			. as $original |
			(capture("^(?<year>[0-9]{4})(?<month>[0-9]{2})(?<day>[0-9]{2})T(?<hour>[0-9]{2})(?<minute>[0-9]{2})(?<second>[0-9]{2})Z$") |
				"\(.year)-\(.month)-\(.day)T\(.hour):\(.minute):\(.second)Z") as $iso |
			try (($iso | fromdateiso8601 | strftime("%Y%m%dT%H%M%SZ")) == $original) catch false;
		def run_id:
			type == "string" and test("^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$") and
			(split("-")[0] | compact_utc);
		def selected_settings:
			type == "array" and length <= 3 and
			all(.[];
				type == "object" and keys == ["cohort","globalQuality","qualityRunId"] and
				(.cohort == "avc" or .cohort == "vc1" or .cohort == "hdr10") and
				(.globalQuality | type == "number" and floor == .) and
				(.globalQuality as $value | [16,18,20,22,24,26,28,30] | index($value) != null) and
				(.qualityRunId | run_id)) and
			([.[].cohort] | unique | length) == length;
		def diagnostics_encoder_commands:
			type == "array" and length > 0 and
			all(.[]; type == "string" and length > 0);
		def diagnostics_upstream:
			type == "object" and keys == ["diagnostics"] and
			(.diagnostics | type == "object" and
				keys == [
					"acceptedFindingsSha256", "decisionSha256", "historicalFindingsRunId",
					"historicalQualityRunId", "manifestSchemaVersion", "panelSha256",
					"resultSchemaVersion"
				] and
				.manifestSchemaVersion == 1 and
				.resultSchemaVersion == 1 and
				(.acceptedFindingsSha256 | digest) and
				(.decisionSha256 | digest) and
				(.historicalQualityRunId | run_id) and
				(.historicalFindingsRunId | run_id) and
				(.panelSha256 | digest));
		if
			(keys == [
				"clientDevice", "cpu", "encoderCommands", "gpu", "images", "mode", "node",
				"resultsSchemaVersion", "samplesDigest", "savingsSeed", "schemaVersion",
				"scriptDigests", "selectedSettings", "sources", "strategyId", "upstream", "vmaf"
			]) and
			(.images | type == "object" and keys == ["configured", "dispatched", "running"]) and
			(.node | string_object(["kernel", "name"])) and
			(.vmaf | string_object(["model", "version"])) and
			(.gpu == null or (.gpu | nonempty_string_object(["i915", "vpl"]))) and
			(.cpu == null or (.cpu | nonempty_string_object(["ffmpeg", "libx265", "model"]))) and
			(.sources | (type == "array" and ([.[] | keys == ["path", "sha256", "size"]] | all)))
		then . else error("invalid benchmark identity") end
		| {
			clientDevice, cpu, encoderCommands, gpu, images, mode: $mode,
			node: {kernel: .node.kernel, name: .node.name},
			resultsSchemaVersion, samplesDigest, savingsSeed, schemaVersion, scriptDigests,
			selectedSettings: (.selectedSettings | sort_by(.cohort)),
			sources: (.sources | map({path: .path, sha256: .sha256, size: .size}) | sort_by(.path)),
			strategyId, upstream, vmaf: {model: .vmaf.model, version: .vmaf.version}
		}
		| if
			.schemaVersion == $manifest_schema and
			.strategyId == $strategy and
			.resultsSchemaVersion == $results_schema and
			(.images | ([.configured, .dispatched, .running] as $digests |
				($digests | all(digest)) and ($digests | unique | length == 1))) and
			(.scriptDigests | (type == "object" and ([.[] | digest] | all))) and
			(.samplesDigest | digest) and
			(.sources | (type == "array" and ([.[] |
				(.path | type == "string") and
				(.size | type == "number" and . >= 0 and floor == .) and
				(.sha256 | digest)
			] | all))) and
			((if $mode == "diagnostics"
				then (.encoderCommands | diagnostics_encoder_commands)
				else (.encoderCommands | (type == "array" and ([.[] | type == "string"] | all)))
			end)) and
			((if $mode == "diagnostics" then .selectedSettings == [] else (.selectedSettings | selected_settings) end)) and
			((if $mode == "diagnostics" then (.upstream | diagnostics_upstream) else (.upstream | type == "object") end)) and
			(.savingsSeed | type == "number" and floor == .) and
			(.clientDevice == null or (.clientDevice | type == "string")) and
			((.gpu == null and (.cpu | type == "object")) or
				((.gpu | type == "object") and .cpu == null))
		then . else
			if $mode == "diagnostics" and (.encoderCommands | diagnostics_encoder_commands | not) then
				error("diagnostic command identity is missing or malformed")
			else
				error("invalid benchmark identity")
			end
		end
	' <<<"$input_json"
}

contract_is_icq_setting() {
	local file="$1" value="$2"
	jq -e --argjson value "$value" \
		'.strategy.globalQualityCandidates | index($value) != null' "$file" >/dev/null
}

# Print each node that has a complete, passing schema-v3 ICQ capability record.
# Dispatch and findings use the same proof contract so a weaker contention-only
# check cannot admit an otherwise incomplete node.
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
			.proofStatus == "passed" and .proofReasons == "" and
			(.verifiedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
			.configuredImageDigest == $digest and (.imageId | immutable_image_id($digest));
		.runtime.image as $image |
		($image | capture("@(?<digest>sha256:[0-9a-f]{64})$").digest) as $digest |
		select(.runtime.capabilityStatus == "verified") |
		.runtime.capabilityEvidence.nodes[]? | select(passing_node($digest)) | .nodeName
	' "$file" | sort -u
}

# Diagnostics use the same image-bound QSV proof plus a bounded proof that the
# image exposes every independent diagnostic oracle before a diagnostic Job is
# allowed to exist.
contract_passing_diagnostic_nodes() {
	local file="$1"
	contract_passing_icq_nodes "$file" | while IFS= read -r node; do
		jq -e --arg node "$node" '
			.runtime.capabilityEvidence.nodes[]? |
			select(.nodeName == $node) |
			(.diagnosticCapabilities |
				type == "object" and
				(keys | sort) == ["bestEffortTimestampTime","imageId","keyFrame","libvmaf","packetDurationTime","pictType","psnr","ssim","traceHeaders","verifiedAt"] and
				.imageId == $node_image and .verifiedAt == $node_verified and
				.traceHeaders == "passed" and .libvmaf == "passed" and .ssim == "passed" and .psnr == "passed" and
				.bestEffortTimestampTime == "passed" and .packetDurationTime == "passed" and
				.keyFrame == "passed" and .pictType == "passed")
		' --arg node_image "$(jq -r --arg node "$node" '.runtime.capabilityEvidence.nodes[] | select(.nodeName == $node) | .imageId' "$file")" \
			--arg node_verified "$(jq -r --arg node "$node" '.runtime.capabilityEvidence.nodes[] | select(.nodeName == $node) | .verifiedAt' "$file")" "$file" >/dev/null &&
			printf '%s\n' "$node"
	done
}

contract_chosen_record() {
	local file="$1" cohort="$2" required_state="${3:-}"
	jq -e -c --arg cohort "$cohort" --arg required_state "$required_state" '
		def exact_keys($expected): type == "object" and keys == ($expected | sort);
		def compact_utc:
			type == "string" and test("^[0-9]{8}T[0-9]{6}Z$") and
			. as $original |
			(capture("^(?<year>[0-9]{4})(?<month>[0-9]{2})(?<day>[0-9]{2})T(?<hour>[0-9]{2})(?<minute>[0-9]{2})(?<second>[0-9]{2})Z$") |
				"\(.year)-\(.month)-\(.day)T\(.hour):\(.minute):\(.second)Z") as $iso |
			try (($iso | fromdateiso8601 | strftime("%Y%m%dT%H%M%SZ")) == $original) catch false;
		def run_id:
			type == "string" and test("^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$") and
			(split("-")[0] | compact_utc);
		def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
		def reviewed_at:
			type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
			. as $original |
			try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $original) catch false;
		def sample_id: type == "string" and test("^[a-z0-9][a-z0-9._-]*$");
		def clip_id: type == "string" and test("^[a-z0-9][a-z0-9._-]*$");
		def expected_finalist($value):
			if $value == "vc1" then "vc1-fugitive"
			elif $value == "avc" then "avc-grain-memento"
			elif $value == "hdr10" then "hdr10-grain-goodfellas"
			else null end;
		def crop_review:
			exact_keys(["clips","reviewedAt","status"]) and
			(.status == "passed" or .status == "failed") and (.reviewedAt | reviewed_at) and
			(.clips | type == "array" and length > 0 and
				all(.[];
					exact_keys(["clipId","result","sampleId"]) and
					(.sampleId | sample_id) and (.clipId | clip_id) and
					(.result == "passed" or .result == "failed")) and
				([.[] | (.sampleId + "|" + .clipId)] | unique | length) == length) and
			(if .status == "passed" then all(.clips[]; .result == "passed")
			 else any(.clips[]; .result == "failed") end);
		def checklist($cohort; $passed):
			exact_keys(["banding","blocking","directPlay","grainRetention","hdrHandling","motionArtifacts"]) and
			(.directPlay == "passed" or .directPlay == "failed") and
			(.motionArtifacts == "passed" or .motionArtifacts == "failed") and
			(.grainRetention == "passed" or .grainRetention == "failed") and
			(.banding == "passed" or .banding == "failed") and
			(.blocking == "passed" or .blocking == "failed") and
			(if $cohort == "hdr10" then (.hdrHandling == "passed" or .hdrHandling == "failed")
			 else .hdrHandling == "not-applicable" end) and
			(if $passed then
				.directPlay == "passed" and .motionArtifacts == "passed" and
				.grainRetention == "passed" and .banding == "passed" and .blocking == "passed" and
				(if $cohort == "hdr10" then .hdrHandling == "passed" else true end)
			 else
				any([.directPlay,.motionArtifacts,.grainRetention,.banding,.blocking,
					(if $cohort == "hdr10" then .hdrHandling else "passed" end)][]; . == "failed")
			 end);
		def finalist_review($cohort; $status):
			exact_keys(["checklist","finalistRunId","resultsSha256","reviewedAt","sampleId","status"]) and
			.status == $status and (.finalistRunId | run_id) and
			.sampleId == expected_finalist($cohort) and (.resultsSha256 | digest) and
			(.reviewedAt | reviewed_at) and (.checklist | checklist($cohort; $status == "passed"));
		def rejected_entry:
			exact_keys(["globalQuality","result","reviewedAt","runId","stage"]) and
			(.globalQuality | type == "number" and floor == .) and
			(.stage == "crop" or .stage == "plex") and (.runId | run_id) and
			.result == "failed" and (.reviewedAt | reviewed_at);
		def chosen($cohort):
			. as $record |
			exact_keys(["candidateEvidenceSha256","cropReview","finalistReview","globalQuality",
				"qualityResultsSha256","qualityRunId","rejectedSettings","state","strategyId"]) and
			.strategyId == "qsv-hevc-icq-v1" and (.qualityRunId | run_id) and
			(.qualityResultsSha256 | digest) and (.candidateEvidenceSha256 | digest) and
			(.globalQuality | type == "number" and floor == .) and
			([16,18,20,22,24,26,28,30] | index($record.globalQuality) != null) and
			(.state == "provisional" or .state == "final" or .state == "rejected") and
			(.cropReview | crop_review) and
			(.rejectedSettings | type == "array" and length <= 8 and all(.[]; rejected_entry)) and
			(.rejectedSettings | map(.globalQuality)) as $rejected_values |
			($rejected_values | unique | length) == ($rejected_values | length) and
			all(.rejectedSettings[]; .globalQuality as $value | [16,18,20,22,24,26,28,30] | index($value) != null) and
			if .state == "provisional" then
				.cropReview.status == "passed" and .finalistReview == null and
				($rejected_values | index($record.globalQuality) == null)
			elif .state == "final" then
				.cropReview.status == "passed" and (.finalistReview | finalist_review($cohort; "passed")) and
				($rejected_values | index($record.globalQuality) == null)
			else
				($rejected_values | length) > 0 and .rejectedSettings[-1].globalQuality == .globalQuality and
				(if .rejectedSettings[-1].stage == "crop" then
					.cropReview.status == "failed" and .finalistReview == null
				 else
					.cropReview.status == "passed" and (.finalistReview | finalist_review($cohort; "failed")) and
					.finalistReview.finalistRunId == .rejectedSettings[-1].runId
				 end)
			end;
		.chosenSettings[$cohort] |
		select(type == "object" and ($required_state == "" or .state == $required_state) and chosen($cohort))
	' "$file"
}

contract_expected_finalist() {
	case "$1" in
	vc1) printf '%s\n' 'vc1-fugitive' ;;
	avc) printf '%s\n' 'avc-grain-memento' ;;
	hdr10) printf '%s\n' 'hdr10-grain-goodfellas' ;;
	*) return 65 ;;
	esac
}
