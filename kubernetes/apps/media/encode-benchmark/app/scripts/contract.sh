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

contract_is_icq_setting() {
	local file="$1" value="$2"
	jq -e --argjson value "$value" \
		'.strategy.globalQualityCandidates | index($value) != null' "$file" >/dev/null
}

contract_chosen_record() {
	local file="$1" cohort="$2" required_state="${3:-}"
	if [[ -n "$required_state" ]]; then
		jq -e -c --arg cohort "$cohort" --arg state "$required_state" \
			'.chosenSettings[$cohort] | select(type == "object" and .state == $state)' "$file"
	else
		jq -e -c --arg cohort "$cohort" \
			'.chosenSettings[$cohort] | select(type == "object")' "$file"
	fi
}
