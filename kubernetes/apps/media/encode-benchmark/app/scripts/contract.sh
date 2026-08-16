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

contract_is_icq_setting() {
	local file="$1" value="$2"
	jq -e --argjson value "$value" \
		'.strategy.globalQualityCandidates | index($value) != null' "$file" >/dev/null
}

contract_chosen_record() {
	local file="$1" cohort="$2" required_state="${3:-}"
	jq -e -c --arg cohort "$cohort" --arg required_state "$required_state" '
		def exact_keys($expected): type == "object" and keys == ($expected | sort);
		def run_id: type == "string" and test("^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$");
		def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
		def reviewed_at:
			type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
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
