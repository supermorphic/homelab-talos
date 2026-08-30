#!/usr/bin/env bats

setup() {
	SCRIPTS="$BATS_TEST_DIRNAME/../app/scripts"
	export BENCHMARK_TEST_MODE=1
	export BENCHMARK_NOW=20260802T120000Z
	export BENCHMARK_OUT="$BATS_TEST_TMPDIR/out"
	export BENCHMARK_IDENTITY_FIXTURE="$BATS_TEST_DIRNAME/fixtures/manifests/identity.json"
	export BENCHMARK_SAMPLES_FILE="$BATS_TEST_TMPDIR/samples.json"
	yq -r '.data."samples.json"' "$BATS_TEST_DIRNAME/../app/samples.yaml" >"$BENCHMARK_SAMPLES_FILE"
	export BENCHMARK_DISPATCH_IMAGE='docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	export BENCHMARK_RUNNING_IMAGE='sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	export BENCHMARK_I915_VERSION='fixture-i915'
	export BENCHMARK_VPL_VERSION='fixture-vpl'
	mkdir -p "$BENCHMARK_OUT/runs"
}

results_header() {
	quality_results_header_v3
}

results_row() {
	local run_id="$1" encoder="${2:-qsv}" strategy="${3:-qsv-hevc-icq-v1}"
	local initialization="${4:-passed}" busy="${5:-800000000}"
	local row
	[[ "$encoder" == 'qsv' ]] || return 64
	row="$(quality_evidence_row_v3 "$run_id" 22 passed "$strategy")"
	awk -F, -v initialization="$initialization" -v busy="$busy" \
		'BEGIN {OFS=FS} {$38=initialization; $39=busy; print}' <<<"$row"
}

quality_results_header_v3() {
	printf '%s\n' 'run_id,panel,sample_id,cohort,source_sha256,clip_id,encoder,requested_setting,selected_rate_control,status,attempt,input_bytes,output_bytes,reduction_percent,input_bit_rate,output_bit_rate,wall_seconds,encode_fps,encode_speed,vmaf_harmonic_mean,vmaf_1pct_low,ssim,gpu_busy_percent,qsv_proof,validation_codec,validation_duration,validation_resolution,validation_frame_rate,validation_bit_depth,validation_hdr,validation_audio_tracks,validation_subtitle_tracks,validation_chapters,validation_failures,log_path,output_disposition,strategy_id,qsv_initialization,video_busy_nanoseconds,quality_evidence_path,quality_evidence_sha256'
}

quality_evidence_row_v3() {
	local run_id="$1" setting="${2:-22}" row_status="${3:-passed}"
	local strategy="${4:-qsv-hevc-icq-v1}" evidence_path evidence_file evidence_digest
	evidence_path="quality-evidence/sample-avc-detail-qsv-$setting-attempt-1.json"
	evidence_file="$BENCHMARK_OUT/runs/$run_id/$evidence_path"
	mkdir -p "${evidence_file%/*}"
	jq -S -c -n --arg run "$run_id" --arg strategy "$strategy" --argjson setting "$setting" '{
		clipId:"detail",cohort:"avc",globalQuality:$setting,hdr:null,psnr:40,
		runId:$run,sampleId:"sample-avc",schemaVersion:1,sourceSha256:"abc123",
		ssim:0.99,strategyId:$strategy,
		vmaf:{rawFrameCount:100,evaluatedFrameCount:100,excludedFrames:[],harmonicMean:95,onePercentLow:90}
	}' >"$evidence_file"
	chmod 0600 "$evidence_file"
	evidence_digest="sha256:$(sha256sum "$evidence_file" | awk 'NR == 1 { print $1 }')"
	printf '%s\n' "$run_id,quality,sample-avc,avc,abc123,detail,qsv,$setting,ICQ,$row_status,1,100,50,50,1000,500,10,30,1.0,95,90,0.99,80,passed,hevc,10,1920x1080,24,10,passed,1,2,3,,logs/a.log,discarded,$strategy,passed,800000000,$evidence_path,$evidence_digest"
}

# Catches compact, historical, diagnostic, failed, malformed, or drifted rows
# suppressing the exact authenticated schema-3 quality work.
@test "quality resume skips only an exact authenticated passed row" {
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	results="$BENCHMARK_OUT/runs/$run_id/results.csv"
	results_header >"$results"
	canonical="$(results_row "$run_id")"
	printf '%s\n' "$canonical" >>"$results"
	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
	[ "$status" -eq 0 ]

	evidence="$BENCHMARK_OUT/runs/$run_id/quality-evidence/sample-avc-detail-qsv-22-attempt-1.json"
	baseline_evidence="$BATS_TEST_TMPDIR/resume-evidence.json"
	cp "$evidence" "$baseline_evidence"
	for mutation in failed compact historical diagnostic malformed drifted rate-la-icq rate-cqp \
		rate-non-icq strategy qsv-proof initialization zero-video nonnumeric-video invalid-setting; do
		cp "$baseline_evidence" "$evidence"
		results_header >"$results"
		printf '%s\n' "$canonical" >>"$results"
		completed_key='quality|abc123|detail|qsv|22'
		case "$mutation" in
		failed)
			awk -F, 'BEGIN {OFS=FS} NR == 2 {$10="failed"} {print}' "$results" >"$results.tmp"
			mv -f -- "$results.tmp" "$results"
			expected_status=1
			;;
		compact)
			printf '%s\n' 'quality|abc123|detail|qsv|22,passed' >"$results"
			expected_status=65
			;;
		historical)
			results_header >"$results"
			cut -d, -f1-38 <<<"$canonical" >>"$results"
			expected_status=65
			;;
		diagnostic)
			awk -F, 'BEGIN {OFS=FS} NR == 2 {$2="diagnostic"} {print}' "$results" >"$results.tmp"
			mv -f -- "$results.tmp" "$results"
			expected_status=65
			;;
		malformed)
			results_header >"$results"
			printf '%s\n' "$run_id,quality,sample-avc,avc,abc123,detail,qsv,22,ICQ,passed" >>"$results"
			expected_status=65
			;;
		drifted)
			printf '%s\n' 'changed' >>"$evidence"
			expected_status=65
			;;
		rate-la-icq | rate-cqp | rate-non-icq)
			case "$mutation" in
			rate-la-icq) value='LA-ICQ' ;;
			rate-cqp) value='CQP' ;;
			rate-non-icq) value='VBR' ;;
			esac
			awk -F, -v value="$value" 'BEGIN {OFS=FS} NR == 2 {$9=value} {print}' \
				"$results" >"$results.tmp"
			mv -f -- "$results.tmp" "$results"
			expected_status=65
			;;
		strategy)
			awk -F, 'BEGIN {OFS=FS} NR == 2 {$37="other-strategy"} {print}' \
				"$results" >"$results.tmp"
			mv -f -- "$results.tmp" "$results"
			expected_status=65
			;;
		qsv-proof)
			awk -F, 'BEGIN {OFS=FS} NR == 2 {$24="failed"} {print}' \
				"$results" >"$results.tmp"
			mv -f -- "$results.tmp" "$results"
			expected_status=65
			;;
		initialization)
			awk -F, 'BEGIN {OFS=FS} NR == 2 {$38="failed"} {print}' \
				"$results" >"$results.tmp"
			mv -f -- "$results.tmp" "$results"
			expected_status=65
			;;
		zero-video | nonnumeric-video)
			[[ "$mutation" == zero-video ]] && value=0 || value=unavailable
			awk -F, -v value="$value" 'BEGIN {OFS=FS} NR == 2 {$39=value} {print}' \
				"$results" >"$results.tmp"
			mv -f -- "$results.tmp" "$results"
			expected_status=65
			;;
		invalid-setting)
			results_header >"$results"
			quality_evidence_row_v3 "$run_id" 17 >>"$results"
			completed_key='quality|abc123|detail|qsv|17'
			expected_status=65
			;;
		esac
		run "$SCRIPTS/runmeta.sh" completed "$run_id" "$completed_key"
		[ "$status" -eq "$expected_status" ] || {
			echo "resume mutation $mutation returned status=$status output=$output" >&3
			return 1
		}
	done
}

# Catches resume trusting a quality row after its bounded metric evidence is
# missing, redirected, changed, or rebound to a different row contract.
@test "quality evidence reference binds confined path digest and row identity" {
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	results="$BENCHMARK_OUT/runs/$run_id/results.csv"
	quality_results_header_v3 >"$results"
	quality_evidence_row_v3 "$run_id" >>"$results"
	evidence="$BENCHMARK_OUT/runs/$run_id/quality-evidence/sample-avc-detail-qsv-22-attempt-1.json"
	baseline_results="$BATS_TEST_TMPDIR/quality-evidence-results.csv"
	baseline_evidence="$BATS_TEST_TMPDIR/quality-evidence.json"
	cp "$results" "$baseline_results"
	cp "$evidence" "$baseline_evidence"
	literal_path='quality-evidence/sample-avc-detail-qsv-22-attempt-1.json'
	literal_digest="sha256:$(sha256sum "$baseline_evidence" | awk 'NR == 1 { print $1 }')"
	[ "$(awk -F, 'NR == 2 {print $40}' "$results")" = "$literal_path" ]
	[ "$(awk -F, 'NR == 2 {print $41}' "$results")" = "$literal_digest" ]

	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
	[ "$status" -eq 0 ]
	run "$SCRIPTS/benchmark.sh" _test quality-evidence-for-ranking \
		"$BENCHMARK_OUT/runs/$run_id" "$run_id" sample-avc avc abc123 detail 22 1 \
		"$literal_path" "$literal_digest"
	[ "$status" -eq 0 ]
	run jq -e '.quality == {vmafHarmonicMean:95,vmafOnePercentLow:90,ssim:0.99,
		psnr:40,hdrClassification:null} and (.identity | type == "string" and length > 0)' <<<"$output"
	[ "$status" -eq 0 ]

	for mutation in missing replaced symlink escaping digest-drifted wrong-row wrong-schema; do
		cp "$baseline_results" "$results"
		rm -f -- "$evidence"
		cp "$baseline_evidence" "$evidence"
		case "$mutation" in
		missing) rm -f -- "$evidence" ;;
		replaced)
			rm -f -- "$evidence"
			jq -S -c '.psnr = 41' "$baseline_evidence" >"$evidence"
			;;
		symlink)
			outside="$BATS_TEST_TMPDIR/outside-quality-evidence.json"
			cp "$baseline_evidence" "$outside"
			rm -f -- "$evidence"
			ln -s "$outside" "$evidence"
			;;
		escaping)
			awk -F, 'BEGIN {OFS=FS} NR == 2 {$40="../quality-evidence.json"} {print}' \
				"$results" >"$results.tmp"
			mv -f -- "$results.tmp" "$results"
			;;
		digest-drifted) printf '%s\n' 'changed' >>"$evidence" ;;
		wrong-row)
			jq -S -c '.sampleId = "other-sample"' "$baseline_evidence" >"$evidence"
			digest="sha256:$(sha256sum "$evidence" | awk 'NR == 1 { print $1 }')"
			awk -F, -v digest="$digest" 'BEGIN {OFS=FS} NR == 2 {$41=digest} {print}' \
				"$results" >"$results.tmp"
			mv -f -- "$results.tmp" "$results"
			;;
		wrong-schema)
			jq -S -c '.schemaVersion = 2' "$baseline_evidence" >"$evidence"
			digest="sha256:$(sha256sum "$evidence" | awk 'NR == 1 { print $1 }')"
			awk -F, -v digest="$digest" 'BEGIN {OFS=FS} NR == 2 {$41=digest} {print}' \
				"$results" >"$results.tmp"
			mv -f -- "$results.tmp" "$results"
			;;
		esac
		run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
		[ "$status" -eq 65 ] || {
			echo "resume accepted $mutation quality evidence: status=$status output=$output" >&3
			return 1
		}
		ranking_path="$(awk -F, 'NR == 2 {print $40}' "$results")"
		ranking_digest="$(awk -F, 'NR == 2 {print $41}' "$results")"
		run "$SCRIPTS/benchmark.sh" _test quality-evidence-for-ranking \
			"$BENCHMARK_OUT/runs/$run_id" "$run_id" sample-avc avc abc123 detail 22 1 \
			"$ranking_path" "$ranking_digest"
		[ "$status" -eq 65 ] || {
			echo "ranking accepted $mutation quality evidence: status=$status output=$output" >&3
			return 1
		}
	done
}
