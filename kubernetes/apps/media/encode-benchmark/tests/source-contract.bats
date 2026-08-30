#!/usr/bin/env bats

setup() {
	PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)"
	app='kubernetes/apps/media/encode-benchmark/app'
	contract="$app/scripts/contract.sh"
	benchmark="$app/scripts/benchmark.sh"
	template="$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/templates/job.yaml"
	fixtures='kubernetes/apps/media/encode-benchmark/tests/fixtures'
	samples="$app/samples.yaml"
	samples_json="$BATS_TEST_TMPDIR/samples.json"
	yq -r '.data."samples.json"' "$samples" >"$samples_json"
	export BENCHMARK_TEST_MODE=1
	export BENCHMARK_SAMPLES_FILE="$samples_json"
}

# D06: The only source library projection is the read-only movies subtree.
@test "quality source visibility is one read-only movies mount" {
	run yq -o=json -I=0 '{
		"mounts":[.spec.template.spec.containers[0].volumeMounts[] |
			select(.name == "media" or (.mountPath | test("^/(media|tv|downloads|data)(/|$)")))],
		"volumes":[.spec.template.spec.volumes[] | select(.name == "media")]
	}' "$template"
	[ "$status" -eq 0 ]
	[ "$output" = '{"mounts":[{"name":"media","mountPath":"/media","subPath":"media/movies","readOnly":true}],"volumes":[{"name":"media","persistentVolumeClaim":{"claimName":"media-data"}}]}' ]
}

@test "shared contract returns only the four diagnosed VMAF exclusions" {
	run jq -e '
		.qualityCorrection.vmafMeasurementDefects == [
			{sampleId:"avc-clean-coco",clipId:"motion",frameIndex:1641},
			{sampleId:"avc-grain-memento",clipId:"dark",frameIndex:523},
			{sampleId:"avc-grain-memento",clipId:"detail",frameIndex:370},
			{sampleId:"vc1-fugitive",clipId:"motion",frameIndex:798}
		]
	' "$samples_json"
	[ "$status" -eq 0 ] || {
		echo "deployed correction array differs from the literal four-entry contract" >&3
		return 1
	}

	for identity in \
		'avc-clean-coco motion 1641' \
		'avc-grain-memento dark 523' \
		'avc-grain-memento detail 370' \
		'vc1-fugitive motion 798'; do
		read -r sample_id clip_id frame_index <<<"$identity"
		run bash -c 'source "$1"; contract_load "$2"; contract_quality_vmaf_exclusion "$2" "$3" "$4"' \
			_ "$contract" "$samples_json" "$sample_id" "$clip_id"
		[ "$status" -eq 0 ]
		[ "$output" = "$frame_index" ]
	done

	for identity in \
		'avc-clean-coco detail' \
		'vc1-fugitive detail' \
		'avc-* motion' \
		'missing-title motion'; do
		read -r sample_id clip_id <<<"$identity"
		run bash -c 'source "$1"; contract_load "$2"; contract_quality_vmaf_exclusion "$2" "$3" "$4"' \
			_ "$contract" "$samples_json" "$sample_id" "$clip_id"
		[ "$status" -eq 1 ]
		[ "$output" = "" ]
	done
}

@test "quality contract admits exactly eight ICQ settings" {
	run bash -c 'source "$1"; contract_load "$2"; printf "%s\n" "$CONTRACT_ICQ_SETTINGS"' \
		_ "$contract" "$samples_json"
	[ "$status" -eq 0 ]
	[ "$output" = '16 18 20 22 24 26 28 30' ]

	for setting in 16 18 20 22 24 26 28 30; do
		run bash -c 'source "$1"; contract_load "$2"; contract_is_icq_setting "$2" "$3"' \
			_ "$contract" "$samples_json" "$setting"
		[ "$status" -eq 0 ]
	done
	for setting in 14 15 17 19 21 23 25 27 29 31 32 -1 null; do
		run bash -c 'source "$1"; contract_load "$2"; contract_is_icq_setting "$2" "$3"' \
			_ "$contract" "$samples_json" "$setting"
		[ "$status" -eq 1 ]
	done

	run "$benchmark" _test runtime-selection-is-icq ICQ
	[ "$status" -eq 0 ]
	for selection in LA-ICQ LA_ICQ CQP CBR VBR AVBR QVBR unknown; do
		run "$benchmark" _test runtime-selection-is-icq "$selection"
		[ "$status" -eq 1 ] || {
			echo "runtime admitted non-ICQ selection: $selection" >&3
			return 1
		}
	done
	run "$benchmark" _test qsv-proof 0 \
		"$fixtures/logs/qsv-requested-la-fallback-cqp.log" \
		"$fixtures/logs/drm-fdinfo-active.log" 2160
	[ "$status" -eq 0 ]
	[ "$(jq -r '.selected_rate_control + ":" + .qsv_proof' <<<"$output")" = 'CQP:failed' ]

	for mutation in \
		'.strategy.globalQualityCandidates = [18, 16, 20, 22, 24, 26, 28, 30]' \
		'.strategy.globalQualityCandidates = [16, 18, 20, 22, 24, 26, 28]' \
		'.strategy.globalQualityCandidates = [16, 18, 20, 22, 24, 26, 28, 28]' \
		'.strategy.globalQualityCandidates = [16, 18, 20, 22.5, 24, 26, 28, 30]' \
		'.strategy.globalQualityCandidates = [16, 18, 20, 22, 24, 26, 28, 30, 32]'; do
		candidate="$BATS_TEST_TMPDIR/$(printf '%s' "$mutation" | sha256sum | awk '{print $1}').json"
		jq "$mutation" "$samples_json" >"$candidate"
		run bash -c 'source "$1"; contract_load "$2"' _ "$contract" "$candidate"
		[ "$status" -eq 65 ] || {
			echo "contract accepted non-canonical case: $mutation" >&3
			return 1
		}
	done
}
