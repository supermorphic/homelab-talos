#!/usr/bin/env bash
# shellcheck disable=SC2034

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
	CONTRACT_STRATEGY_ID="$(jq -r '.strategy.id' "$file")"
	CONTRACT_ICQ_SETTINGS="$(jq -r '.strategy.globalQualityCandidates | join(" ")' "$file")"
	CONTRACT_RESULTS_SCHEMA="$(jq -r '.strategy.resultsSchemaVersion' "$file")"
	CONTRACT_MANIFEST_SCHEMA="$(jq -r '.strategy.runManifestSchemaVersion' "$file")"
	CONTRACT_CAPABILITY_SCHEMA="$(jq -r '.strategy.capabilityProofSchemaVersion' "$file")"
	readonly CONTRACT_STRATEGY_ID CONTRACT_ICQ_SETTINGS CONTRACT_RESULTS_SCHEMA
	readonly CONTRACT_MANIFEST_SCHEMA CONTRACT_CAPABILITY_SCHEMA
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
			(.encoderCommands | (type == "array" and ([.[] | type == "string"] | all))) and
			(.selectedSettings | selected_settings) and
			(.upstream | type == "object") and
			(.savingsSeed | type == "number" and floor == .) and
			(.clientDevice == null or (.clientDevice | type == "string")) and
			((.gpu == null and (.cpu | type == "object")) or
				((.gpu | type == "object") and .cpu == null))
		then . else error("invalid benchmark identity") end
	' <<<"$input_json"
}

contract_is_icq_setting() {
	local file="$1" value="$2"
	jq -e --argjson value "$value" \
		'.strategy.globalQualityCandidates | index($value) != null' "$file" >/dev/null
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
