#!/usr/bin/env bats

setup() {
	app='kubernetes/apps/media/encode-benchmark/app'
	contract="$app/scripts/contract.sh"
	samples="$app/samples.yaml"
	samples_json="$BATS_TEST_TMPDIR/samples.json"
	yq -r '.data."samples.json"' "$samples" >"$samples_json"
}

# Catches the source contract reverting to the older schema or a partial ICQ
# sweep that cannot compare every agreed candidate across later benchmark modes.
@test "embedded samples publish the exact ordered ICQ strategy contract" {
	run jq -e '
		.schemaVersion == 2 and
		.strategy == {
			id: "qsv-hevc-icq-v1",
			resultsSchemaVersion: 2,
			runManifestSchemaVersion: 2,
			capabilityProofSchemaVersion: 3,
			globalQualityCandidates: [16, 18, 20, 22, 24, 26, 28, 30],
			x265: {initialCrfs: [18, 20, 22, 24], minimumCrf: 10, maximumCrf: 34, step: 2}
		} and
		.runtime.capabilityStatus == "pending" and
		.runtime.capabilityEvidence == {nodes: []}
	' "$samples_json"
	[ "$status" -eq 0 ]
}

# Catches accepting a configuration that has the right values but changes their
# order, cardinality, or integer representation, which would make benchmark
# evidence non-comparable across producers.
@test "shared contract rejects every non-canonical ICQ candidate list" {
	for mutation in \
		'.strategy.globalQualityCandidates = [18, 16, 20, 22, 24, 26, 28, 30]' \
		'.strategy.globalQualityCandidates = [16, 18, 20, 22, 24, 26, 28]' \
		'.strategy.globalQualityCandidates = [16, 18, 20, 22, 24, 26, 28, 28]' \
		'.strategy.globalQualityCandidates = [16, 18, 20, 22.5, 24, 26, 28, 30]' \
		'.strategy.globalQualityCandidates = [16, 18, 20, 22, 24, 26, 28, 30, 32]'; do
		candidate="$BATS_TEST_TMPDIR/$(printf '%s' "$mutation" | sha256sum | awk '{print $1}').json"
		jq "$mutation" "$samples_json" >"$candidate"
		run bash -c 'source "$1"; contract_load "$2"' _ "$contract" "$candidate"
		[ "$status" -eq 65 ]
	done
}

# Catches producers drifting from the shared candidate membership check used by
# the runtime, dispatch, and result helpers.
@test "shared contract admits only the canonical ICQ settings" {
	for setting in 16 18 30; do
		run bash -c 'source "$1"; contract_load "$2"; contract_is_icq_setting "$2" "$3"' \
			_ "$contract" "$samples_json" "$setting"
		[ "$status" -eq 0 ]
	done
	for setting in 14 17 32; do
		run bash -c 'source "$1"; contract_load "$2"; contract_is_icq_setting "$2" "$3"' \
			_ "$contract" "$samples_json" "$setting"
		[ "$status" -eq 1 ]
	done
}

# Catches a production break where the app Kustomization reconciles a benchmark
# Job automatically or loses the deliberately background-only scheduling class.
@test "Flux renders inert resources but no Job" {
	run kustomize build kubernetes/apps/media/encode-benchmark/app
	[ "$status" -eq 0 ]
	[ "$(yq -r 'select(.kind == "Job") | .metadata.name' <<<"$output")" = "" ]
	[ "$(yq -r 'select(.kind == "PriorityClass") | .value' <<<"$output")" = "-10" ]
}

# Catches a production break where the render-only Job can traverse the shared
# PVC outside the movies subtree or can mutate the movie library.
@test "template cannot see TV or downloads and movies are read-only" {
	template=kubernetes/apps/media/encode-benchmark/templates/job.yaml
	[ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "media") | .persistentVolumeClaim.claimName' "$template")" = media-data ]
	[ "$(yq -r '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "media") | .readOnly' "$template")" = true ]
	[ "$(yq -r '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "media") | .mountPath' "$template")" = /media ]
	[ "$(yq -r '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "media") | .subPath' "$template")" = media/movies ]
	! rg -n '/data|media/tv|downloads' "$template"
}

# Catches every rendered benchmark Job inheriting Kubernetes API credentials
# even though none of the runtime commands needs in-cluster API access.
@test "template disables automatic service account token mounting" {
	template=kubernetes/apps/media/encode-benchmark/templates/job.yaml
	[ "$(yq -r '.spec.template.spec.automountServiceAccountToken' "$template")" = false ]
}

# Catches malformed or misplaced x265 reference markers widening the expensive
# comparison sweep beyond the accepted grain-heavy AVC and HDR10 samples.
@test "quality panel has exactly one Boolean x265 reference per accepted cohort" {
	samples=kubernetes/apps/media/encode-benchmark/app/samples.yaml
	run yq -e '
		.data."samples.json" | from_yaml | .qualityPanel as $panel |
		(([$panel[].x265Reference | tag == "!!bool"] | all) and
		 (([$panel[] | select(.x265Reference == true and .cohort == "avc")] | length) == 1) and
		 (([$panel[] | select(.x265Reference == true and .cohort == "hdr10")] | length) == 1) and
		 ([$panel[] | select(.x265Reference == true) | (.cohort == "avc" or .cohort == "hdr10")] | all) and
		 ([$panel[] | select(.detectionOnly == true) | .x265Reference == false] | all))
	' "$samples"
	[ "$status" -eq 0 ]
}
