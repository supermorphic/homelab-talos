#!/usr/bin/env bats

setup() {
	PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)"
	QUALITY_EVIDENCE="$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/quality-evidence.sh"
	SAMPLES="$BATS_TEST_TMPDIR/samples.json"
	FIXTURE="$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/tests/fixtures/metrics/vmaf-correctable-zero.json"
	mise exec -- yq -r '.data."samples.json"' "$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/samples.yaml" >"$SAMPLES"
}

quality_vmaf_stats() {
	local metrics_file="$1" sample_id="$2" clip_id="$3"
	run bash -c 'source "$1"; quality_vmaf_stats "$2" "$3" "$4" "$5"' \
		quality-evidence "$QUALITY_EVIDENCE" "$metrics_file" "$SAMPLES" "$sample_id" "$clip_id"
}

# Catches retaining the proven measurement defect in aggregates, dropping it
# from raw evidence, or calculating either aggregate from raw scores.
@test "VMAF reducer excludes one proven exact-zero frame and aggregates evaluated scores" {
	quality_vmaf_stats "$FIXTURE" avc-clean-coco motion
	[ "$status" -eq 0 ]
	jq -e '
		.rawFrameCount == 100 and
		.evaluatedFrameCount == 99 and
		.excludedFrames == [{frameIndex:1641,vmaf:0}] and
		.harmonicMean == 96 and
		.onePercentLow == 96
	' <<<"$output"
	run bash -c 'source "$1"; quality_vmaf_stats "$2" "$3" "$4" "$5" >/dev/null; quality_vmaf_stats "$2" "$3" "$4" "$5"' \
		quality-evidence "$QUALITY_EVIDENCE" "$FIXTURE" "$SAMPLES" avc-clean-coco motion
	[ "$status" -eq 0 ]
	jq -e '.evaluatedFrameCount == 99' <<<"$output"
}

# Catches treating a candidate correction as a wildcard or a score-based rule.
@test "VMAF reducer only excludes the closed exact-zero identity" {
	local case_name mutation expected_count sample_id='avc-clean-coco' clip_id='motion'
	for case_name in absent duplicate nonzero unlisted-zero; do
		sample_id='avc-clean-coco'
		clip_id='motion'
		case "$case_name" in
		absent)
			mutation='.frames |= map(select(.frameNum != 1641))'
			expected_count=99
			;;
		duplicate)
			mutation='.frames += [{frameNum:1641,metrics:{vmaf:0}}]'
			expected_count=101
			;;
		nonzero)
			mutation='.frames[] |= if .frameNum == 1641 then .metrics.vmaf = 0.1 else . end'
			expected_count=100
			;;
		unlisted-zero)
			mutation='.frames += [{frameNum:781,metrics:{vmaf:0}}]'
			expected_count=101
			clip_id='detail'
			;;
		esac
		metrics="$BATS_TEST_TMPDIR/$case_name.json"
		jq "$mutation" "$FIXTURE" >"$metrics"
		quality_vmaf_stats "$metrics" "$sample_id" "$clip_id"
		[ "$status" -eq 0 ] || {
			echo "reducer rejected valid non-exclusion case: $case_name (status=$status output=$output)" >&3
			return 1
		}
		[ "$(jq -r '.rawFrameCount' <<<"$output")" = "$expected_count" ]
		[ "$(jq -c '.excludedFrames' <<<"$output")" = '[]' ]
		[ "$(jq -r '.evaluatedFrameCount' <<<"$output")" = "$expected_count" ]
	done
}

# Catches assigning the unresolved diagnostic identity a correction permission.
@test "VMAF reducer never excludes unresolved vc1 frame 781" {
	metrics="$BATS_TEST_TMPDIR/unresolved.json"
	jq '.frames[0].frameNum = 781' "$FIXTURE" >"$metrics"

	quality_vmaf_stats "$metrics" vc1-fugitive detail
	[ "$status" -eq 0 ]
	[ "$(jq -c '.excludedFrames' <<<"$output")" = '[]' ]
	[ "$(jq -r '.evaluatedFrameCount' <<<"$output")" = '100' ]
}

# Catches coercing malformed frame metadata or VMAF values into valid evidence.
@test "VMAF reducer rejects malformed frame arrays and string scores" {
	local case_name mutation
	for case_name in missing-frames empty-frames wrong-frames-type string-frame-index string-vmaf; do
		case "$case_name" in
		missing-frames) mutation='del(.frames)' ;;
		empty-frames) mutation='.frames = []' ;;
		wrong-frames-type) mutation='.frames = {}' ;;
		string-frame-index) mutation='.frames[0].frameNum = "1641"' ;;
		string-vmaf) mutation='.frames[0].metrics.vmaf = "0"' ;;
		esac
		metrics="$BATS_TEST_TMPDIR/$case_name.json"
		jq "$mutation" "$FIXTURE" >"$metrics"
		quality_vmaf_stats "$metrics" avc-clean-coco motion
		[ "$status" -ne 0 ] || {
			echo "reducer accepted malformed VMAF evidence: $case_name" >&3
			return 1
		}
	done
}

# Catches permissive matching of unrelated FFmpeg output or accepting non-finite
# values as admissible report-only metrics.
@test "metric parser returns one finite decimal from closed SSIM and PSNR summaries" {
	local ssim_log="$BATS_TEST_TMPDIR/ssim.log" psnr_log="$BATS_TEST_TMPDIR/psnr.log"
	printf '%s\n' '[Parsed_ssim_0 @ 0x3000] SSIM Y:0.990000 U:0.995000 V:0.995000 All:0.991000 (20.457575)' >"$ssim_log"
	printf '%s\n' 'n:1 mse_avg:1.00 average:40.000000 psnr_y:40.000000' >"$psnr_log"

	run bash -c 'source "$1"; quality_parse_metric ssim "$2"' quality-evidence "$QUALITY_EVIDENCE" "$ssim_log"
	[ "$status" -eq 0 ]
	[ "$output" = '0.991000' ]
	run bash -c 'source "$1"; quality_parse_metric psnr "$2"' quality-evidence "$QUALITY_EVIDENCE" "$psnr_log"
	[ "$status" -eq 0 ]
	[ "$output" = '40.000000' ]
	run "$QUALITY_EVIDENCE" metric ssim "$ssim_log"
	[ "$status" -eq 64 ]
	run "$QUALITY_EVIDENCE" _test metric ssim "$ssim_log"
	[ "$status" -eq 0 ]
	[ "$output" = '0.991000' ]
	run bash -c 'source "$1"; source "$2"; quality_parse_metric ssim "$3"' \
		quality-evidence "$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/contract.sh" "$QUALITY_EVIDENCE" "$ssim_log"
	[ "$status" -eq 0 ]
	[ "$output" = '0.991000' ]
	for kind in unknown ssim psnr; do
		log="$BATS_TEST_TMPDIR/$kind-invalid.log"
		printf '%s\n' 'All:nan average:inf' >"$log"
		run bash -c 'source "$1"; quality_parse_metric "$2" "$3"' quality-evidence "$QUALITY_EVIDENCE" "$kind" "$log"
		[ "$status" -ne 0 ]
	done
}
