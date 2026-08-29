#!/usr/bin/env bats

setup() {
	PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)"
	QUALITY_EVIDENCE="$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/quality-evidence.sh"
	PROBE="$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/probe.sh"
	SAMPLES="$BATS_TEST_TMPDIR/samples.json"
	FIXTURE="$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/tests/fixtures/metrics/vmaf-correctable-zero.json"
	HDR_FIXTURE="$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/tests/fixtures/encode-benchmark/quality-hdr-cases.json"
	mise exec -- yq -r '.data."samples.json"' "$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/samples.yaml" >"$SAMPLES"
}

quality_vmaf_stats() {
	local metrics_file="$1" sample_id="$2" clip_id="$3"
	run bash -c 'source "$1"; quality_vmaf_stats "$2" "$3" "$4" "$5"' \
		quality-evidence "$QUALITY_EVIDENCE" "$metrics_file" "$SAMPLES" "$sample_id" "$clip_id"
}

quality_hdr_case() {
	local case_id="$1" call_log="$2"
	touch "$BATS_TEST_TMPDIR/source.mkv" "$BATS_TEST_TMPDIR/clip.mkv" "$BATS_TEST_TMPDIR/output.mkv"
	run bash -c '
		source "$1"
		probe_script="$2"
		fixture="$3"
		case_id="$4"
		call_log="$5"
		source_path="$6"
		clip_path="$7"
		encoded_path="$8"
		quality_hdr_probe() {
			local command="$1" path entity oracle_key
			if [[ "$command" == "diagnostic-hdr-normalize-oracle" ]]; then
				"$probe_script" "$@"
				return
			fi
			path="$2"
			printf "%s\t%s\t%s\t%s\n" "$command" "$path" "$3" "$4" >>"$call_log"
			case "$path" in
			"$source_path") entity=source ;;
			"$clip_path") entity=clip ;;
			"$encoded_path") entity=encoded ;;
			*) return 64 ;;
			esac
			if [[ "$command" == "diagnostic-hdr-stream" ]]; then
				oracle_key="$(jq -e -r --arg id "$case_id" ".cases[] | select(.id == \$id) | .stream" "$fixture")" || return
			else
				case "$command" in
				diagnostic-hdr-frame) kind=decoded ;;
				diagnostic-hdr-trace) kind=trace ;;
				*) return 64 ;;
				esac
				oracle_key="$(jq -e -r --arg id "$case_id" --arg entity "$entity" --arg kind "$kind" ".cases[] | select(.id == \$id) | .[\$entity][\$kind]" "$fixture")" || return
			fi
			jq -e -c --arg key "$oracle_key" ".oracles[\$key]" "$fixture"
		}
		quality_hdr_evidence "$source_path" 37.5 "$clip_path" "$encoded_path"
	' quality-hdr "$QUALITY_EVIDENCE" "$PROBE" "$HDR_FIXTURE" "$case_id" "$call_log" \
		"$BATS_TEST_TMPDIR/source.mkv" "$BATS_TEST_TMPDIR/clip.mkv" "$BATS_TEST_TMPDIR/output.mkv"
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

# Catches retaining only the loaded contract state while reading a different
# caller-supplied file for exclusions on a later reducer call.
@test "VMAF reducer rejects a second contract that grants unresolved frame 781" {
	local unresolved_metrics="$BATS_TEST_TMPDIR/unresolved.json"
	local modified_samples="$BATS_TEST_TMPDIR/modified-samples.json"
	jq '.frames[0].frameNum = 781' "$FIXTURE" >"$unresolved_metrics"
	jq '.qualityCorrection.vmafMeasurementDefects += [{sampleId:"vc1-fugitive",clipId:"detail",frameIndex:781}]' \
		"$SAMPLES" >"$modified_samples"

	run bash -c 'source "$1"; quality_vmaf_stats "$2" "$3" avc-clean-coco motion >/dev/null; quality_vmaf_stats "$4" "$5" vc1-fugitive detail' \
		quality-evidence "$QUALITY_EVIDENCE" "$FIXTURE" "$SAMPLES" "$unresolved_metrics" "$modified_samples"
	[ "$status" -eq 65 ]
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

# Catches trusting either HDR oracle alone, comparing unreduced rationals, or
# collapsing source, clip-boundary, and encoder-output defects into one verdict.
@test "quality HDR classifier returns authoritative classifications" {
	local case_id calls expected
	for case_id in preserved source-oracle-defect clip-boundary-defect encoder-output-defect; do
		calls="$BATS_TEST_TMPDIR/$case_id.calls"
		quality_hdr_case "$case_id" "$calls"
		[ "$status" -eq 0 ] || {
			echo "HDR classifier rejected $case_id: status=$status output=$output" >&3
			return 1
		}
		expected="$(jq -e -c --arg id "$case_id" '.cases[] | select(.id == $id) | .expected' "$HDR_FIXTURE")"
		run jq -e -c --argjson expected "$expected" '
			{classification,reasons} == $expected and
			(.normalizedOracle.source.decoded.status == "ok") and
			(.normalizedOracle.source.trace.status == "ok") and
			(.. | objects | select(has("numerator") and has("denominator")) |
				(.numerator | type) == "number" and (.denominator | type) == "number")
		' <<<"$output"
		[ "$status" -eq 0 ]
	done
}

# Catches promoting the known-null stream probe into an HDR preservation veto
# or probing the clip/output at the full-title source timestamp.
@test "quality HDR keeps null stream status auxiliary and captures committed timestamps" {
	local calls="$BATS_TEST_TMPDIR/auxiliary-null.calls"
	quality_hdr_case auxiliary-null "$calls"
	[ "$status" -eq 0 ]
	run jq -e '
		.classification == "preserved" and
		.reasons == ["source-clip-encoded-metadata-agree"] and
		.normalizedOracle.source.streamProbe == {status:"null"} and
		.normalizedOracle.source.authoritative.metadata == .normalizedOracle.clip.authoritative.metadata and
		.normalizedOracle.clip.authoritative.metadata == .normalizedOracle.encoded.authoritative.metadata
	' <<<"$output"
	[ "$status" -eq 0 ]
	run diff -u - "$calls" <<EOF
diagnostic-hdr-stream	$BATS_TEST_TMPDIR/source.mkv	37.5	10
diagnostic-hdr-frame	$BATS_TEST_TMPDIR/source.mkv	37.5	10
diagnostic-hdr-trace	$BATS_TEST_TMPDIR/source.mkv	37.5	10
diagnostic-hdr-frame	$BATS_TEST_TMPDIR/clip.mkv	0	10
diagnostic-hdr-trace	$BATS_TEST_TMPDIR/clip.mkv	0	10
diagnostic-hdr-frame	$BATS_TEST_TMPDIR/output.mkv	0	10
diagnostic-hdr-trace	$BATS_TEST_TMPDIR/output.mkv	0	10
EOF
	[ "$status" -eq 0 ]
}
