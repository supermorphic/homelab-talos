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
			if [[ "$command" == "quality-hdr-normalize-oracle" ]]; then
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
			if [[ "$command" == "quality-hdr-stream" ]]; then
				oracle_key="$(jq -e -r --arg id "$case_id" ".cases[] | select(.id == \$id) | .stream" "$fixture")" || return
			else
				case "$command" in
				quality-hdr-frame) kind=decoded ;;
				quality-hdr-trace) kind=trace ;;
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

# Catches a listed correction mismatch producing statistics that the evidence
# publisher and candidate ranker could treat as usable.
@test "VMAF reducer fails closed when a listed frame is absent duplicate or nonzero" {
	local case_name mutation
	for case_name in absent duplicate nonzero; do
		case "$case_name" in
		absent)
			mutation='.frames |= map(select(.frameNum != 1641))'
			;;
		duplicate)
			mutation='.frames += [{frameNum:1641,metrics:{vmaf:0}}]'
			;;
		nonzero)
			mutation='.frames[] |= if .frameNum == 1641 then .metrics.vmaf = 0.1 else . end'
			;;
		esac
		metrics="$BATS_TEST_TMPDIR/$case_name.json"
		jq "$mutation" "$FIXTURE" >"$metrics"
		quality_vmaf_stats "$metrics" avc-clean-coco motion
		[ "$status" -eq 65 ] || {
			echo "listed correction mismatch produced usable statistics: $case_name (status=$status output=$output)" >&3
			return 1
		}
		[ -z "$output" ]
	done
}

# Catches treating an unlisted exact-zero score as a wildcard correction.
@test "VMAF reducer keeps an unlisted exact-zero frame in both populations" {
	metrics="$BATS_TEST_TMPDIR/unlisted-zero.json"
	jq '.frames += [{frameNum:781,metrics:{vmaf:0}}]' "$FIXTURE" >"$metrics"

	quality_vmaf_stats "$metrics" avc-clean-coco detail
	[ "$status" -eq 0 ]
	jq -e '
		.rawFrameCount == 101 and
		.evaluatedFrameCount == 101 and
		.excludedFrames == [] and
		.onePercentLow == 0
	' <<<"$output"
}

# Catches excluding unresolved VC-1 frame 781 or accepting a caller-supplied
# contract that grants it correction permission.
@test "VMAF contract denies correction permission to unresolved VC-1 frame 781" {
	local unresolved_metrics="$BATS_TEST_TMPDIR/unresolved.json"
	local modified_samples="$BATS_TEST_TMPDIR/modified-samples.json"
	jq '.frames[0].frameNum = 781' "$FIXTURE" >"$unresolved_metrics"

	quality_vmaf_stats "$unresolved_metrics" vc1-fugitive detail
	[ "$status" -eq 0 ]
	jq -e '
		.rawFrameCount == 100 and
		.evaluatedFrameCount == 100 and
		.excludedFrames == [] and
		.onePercentLow == 0
	' <<<"$output"

	jq '.qualityCorrection.vmafMeasurementDefects += [{sampleId:"vc1-fugitive",clipId:"detail",frameIndex:781}]' \
		"$SAMPLES" >"$modified_samples"
	run bash -c 'source "$1"; quality_vmaf_stats "$2" "$3" vc1-fugitive detail' \
		quality-evidence "$QUALITY_EVIDENCE" "$unresolved_metrics" "$modified_samples"
	[ "$status" -eq 65 ]
	[ -z "$output" ]
}

# Catches coercing malformed frame arrays or non-finite VMAF values into valid evidence.
@test "VMAF reducer rejects malformed frame arrays and nonnumeric or non-finite scores" {
	local case_name mutation
	for case_name in missing-frames empty-frames wrong-frames-type duplicate-index \
		string-frame-index string-vmaf positive-infinity negative-infinity; do
		case "$case_name" in
		missing-frames) mutation='del(.frames)' ;;
		empty-frames) mutation='.frames = []' ;;
		wrong-frames-type) mutation='.frames = {}' ;;
		duplicate-index) mutation='.frames += [.frames[1]]' ;;
		string-frame-index) mutation='.frames[0].frameNum = "1641"' ;;
		string-vmaf) mutation='.frames[0].metrics.vmaf = "0"' ;;
		positive-infinity) mutation='' ;;
		negative-infinity) mutation='' ;;
		esac
		metrics="$BATS_TEST_TMPDIR/$case_name.json"
		if [[ "$case_name" == 'positive-infinity' ]]; then
			printf '%s\n' '{"frames":[{"frameNum":1,"metrics":{"vmaf":1e9999}}]}' >"$metrics"
		elif [[ "$case_name" == 'negative-infinity' ]]; then
			printf '%s\n' '{"frames":[{"frameNum":1,"metrics":{"vmaf":-1e9999}}]}' >"$metrics"
		else
			jq "$mutation" "$FIXTURE" >"$metrics"
		fi
		quality_vmaf_stats "$metrics" avc-clean-coco detail
		[ "$status" -ne 0 ] || {
			echo "reducer accepted malformed VMAF evidence: $case_name" >&3
			return 1
		}
	done
}

# Catches computing aggregate statistics from the raw population, an arithmetic
# mean, or a percentile count other than the retained population's lowest 1%.
@test "evaluated VMAF statistics use the asymmetric retained population" {
	metrics="$BATS_TEST_TMPDIR/asymmetric.json"
	jq -n '{frames:[
		{frameNum:1641,metrics:{vmaf:0}},
		{frameNum:1642,metrics:{vmaf:50}},
		{frameNum:1643,metrics:{vmaf:100}},
		{frameNum:1644,metrics:{vmaf:100}}
	]}' >"$metrics"

	quality_vmaf_stats "$metrics" avc-clean-coco motion
	[ "$status" -eq 0 ]
	jq -e '
		.rawFrameCount == 4 and
		.evaluatedFrameCount == 3 and
		.excludedFrames == [{frameIndex:1641,vmaf:0}] and
		.harmonicMean == 75 and
		.onePercentLow == 50
	' <<<"$output"
}

# Catches permissive matching of unrelated, ambiguous, malformed, or non-finite
# FFmpeg output as an admissible report-only metric.
@test "metric parser returns one finite decimal from closed SSIM and PSNR summaries" {
	local ssim_log="$BATS_TEST_TMPDIR/ssim.log" psnr_log="$BATS_TEST_TMPDIR/psnr.log"
	local signed_ssim_log="$BATS_TEST_TMPDIR/signed-ssim.log"
	local signed_psnr_log="$BATS_TEST_TMPDIR/signed-psnr.log"
	printf '%s\n' '[Parsed_ssim_0 @ 0x3000] SSIM Y:0.990000 U:0.995000 V:0.995000 All:0.991000 (20.457575)' >"$ssim_log"
	printf '%s\n' 'n:1 mse_avg:1.00 average:40.000000 psnr_y:40.000000' >"$psnr_log"
	printf '%s\n' 'SSIM All:+0.875000 (9.030900)' >"$signed_ssim_log"
	printf '%s\n' 'PSNR average:-1.250000 min:-2.000000 max:0.000000' >"$signed_psnr_log"

	run bash -c 'source "$1"; quality_parse_metric ssim "$2"' quality-evidence "$QUALITY_EVIDENCE" "$ssim_log"
	[ "$status" -eq 0 ]
	[ "$output" = '0.991000' ]
	run bash -c 'source "$1"; quality_parse_metric psnr "$2"' quality-evidence "$QUALITY_EVIDENCE" "$psnr_log"
	[ "$status" -eq 0 ]
	[ "$output" = '40.000000' ]
	run bash -c 'source "$1"; quality_parse_metric ssim "$2"' quality-evidence "$QUALITY_EVIDENCE" "$signed_ssim_log"
	[ "$status" -eq 0 ] || {
		echo "metric parser rejected optional positive sign: status=$status output=$output" >&3
		return 1
	}
	[ "$output" = '0.875000' ]
	run bash -c 'source "$1"; quality_parse_metric psnr "$2"' quality-evidence "$QUALITY_EVIDENCE" "$signed_psnr_log"
	[ "$status" -eq 0 ] || {
		echo "metric parser rejected optional negative sign: status=$status output=$output" >&3
		return 1
	}
	[ "$output" = '-1.250000' ]
	run "$QUALITY_EVIDENCE" metric ssim "$ssim_log"
	[ "$status" -eq 64 ]
	run "$QUALITY_EVIDENCE" _test metric ssim "$ssim_log"
	[ "$status" -eq 0 ]
	[ "$output" = '0.991000' ]
	run bash -c 'source "$1"; source "$2"; quality_parse_metric ssim "$3"' \
		quality-evidence "$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/contract.sh" "$QUALITY_EVIDENCE" "$ssim_log"
	[ "$status" -eq 0 ]
	[ "$output" = '0.991000' ]
	for case_name in unknown-kind ssim-false-boundary ssim-suffix-junk ssim-exponent \
		ssim-malformed ssim-ambiguous ssim-infinite ssim-valid-then-infinite \
		ssim-infinite-then-valid ssim-valid-then-exponent psnr-false-boundary \
		psnr-suffix-junk psnr-exponent psnr-malformed psnr-ambiguous psnr-infinite \
		psnr-exponent-then-valid psnr-valid-then-suffix psnr-suffix-then-valid; do
		kind="${case_name%%-*}"
		log="$BATS_TEST_TMPDIR/$case_name.log"
		case "$case_name" in
		unknown-kind)
			kind=unknown
			printf '%s\n' 'All:0.991000' >"$log"
			;;
		ssim-false-boundary) printf '%s\n' 'NotAll:0.991000' >"$log" ;;
		ssim-suffix-junk) printf '%s\n' 'All:0.991000junk' >"$log" ;;
		ssim-exponent) printf '%s\n' 'All:4e-1' >"$log" ;;
		ssim-malformed) printf '%s\n' 'All:.991000' >"$log" ;;
		ssim-ambiguous) printf '%s\n' 'All:0.991000' 'All:0.992000' >"$log" ;;
		ssim-infinite) printf '%s\n' 'All:inf' >"$log" ;;
		ssim-valid-then-infinite) printf '%s\n' 'All:0.991000 All:inf' >"$log" ;;
		ssim-infinite-then-valid) printf '%s\n' 'All:inf All:0.991000' >"$log" ;;
		ssim-valid-then-exponent) printf '%s\n' 'All:0.991000 All:4e-1' >"$log" ;;
		psnr-false-boundary) printf '%s\n' 'meanaverage:40.000000' >"$log" ;;
		psnr-suffix-junk) printf '%s\n' 'average:40.000000junk' >"$log" ;;
		psnr-exponent) printf '%s\n' 'average:40e2' >"$log" ;;
		psnr-malformed) printf '%s\n' 'average:.40' >"$log" ;;
		psnr-ambiguous) printf '%s\n' 'average:40.000000' 'average:41.000000' >"$log" ;;
		psnr-infinite) printf '%s\n' 'average:nan' >"$log" ;;
		psnr-exponent-then-valid) printf '%s\n' 'average:40e2 average:40.000000' >"$log" ;;
		psnr-valid-then-suffix) printf '%s\n' 'average:40.000000 average:41junk' >"$log" ;;
		psnr-suffix-then-valid) printf '%s\n' 'average:41junk average:40.000000' >"$log" ;;
		esac
		run bash -c 'source "$1"; quality_parse_metric "$2" "$3"' quality-evidence "$QUALITY_EVIDENCE" "$kind" "$log"
		[ "$status" -ne 0 ] || {
			echo "metric parser accepted invalid summary: $case_name ($output)" >&3
			return 1
		}
	done
}

# Catches rounded rational comparison, treating the null auxiliary stream probe
# as authoritative, or probing clip/output at the full-title timestamp.
@test "HDR oracles normalize exact rationals and preserve agreement with a null auxiliary probe" {
	local calls="$BATS_TEST_TMPDIR/auxiliary-null.calls"
	local evidence
	quality_hdr_case auxiliary-null "$calls"
	[ "$status" -eq 0 ]
	evidence="$output"
	run jq -e '
		{
			masteringDisplay:{
				displayPrimaries:{
					red:{x:{numerator:53,denominator:200},y:{numerator:69,denominator:200}},
					green:{x:{numerator:3,denominator:20},y:{numerator:3,denominator:5}},
					blue:{x:{numerator:17,denominator:250},y:{numerator:4,denominator:125}}
				},
				whitePoint:{x:{numerator:3127,denominator:10000},y:{numerator:329,denominator:1000}},
				luminance:{min:{numerator:1,denominator:200},max:{numerator:1000,denominator:1}}
			},
			maxCLL:{numerator:1000,denominator:1},
			maxFALL:{numerator:400,denominator:1}
		} as $expected |
		.classification == "preserved" and
		.reasons == ["source-clip-encoded-metadata-agree"] and
		.normalizedOracle.source.streamProbe == {status:"null"} and
		([.normalizedOracle.source.decoded.metadata,
			.normalizedOracle.source.trace.metadata,
			.normalizedOracle.source.authoritative.metadata,
			.normalizedOracle.clip.authoritative.metadata,
			.normalizedOracle.encoded.authoritative.metadata] | all(. == $expected))
	' <<<"$evidence"
	[ "$status" -eq 0 ]
	run diff -u - "$calls" <<EOF
quality-hdr-stream	$BATS_TEST_TMPDIR/source.mkv	37.5	10
quality-hdr-frame	$BATS_TEST_TMPDIR/source.mkv	37.5	10
quality-hdr-trace	$BATS_TEST_TMPDIR/source.mkv	37.5	10
quality-hdr-frame	$BATS_TEST_TMPDIR/clip.mkv	0	10
quality-hdr-trace	$BATS_TEST_TMPDIR/clip.mkv	0	10
quality-hdr-frame	$BATS_TEST_TMPDIR/output.mkv	0	10
quality-hdr-trace	$BATS_TEST_TMPDIR/output.mkv	0	10
EOF
	[ "$status" -eq 0 ]
}

# Catches blaming the encoder or accepting evidence when the source's two
# authoritative HDR oracles disagree.
@test "HDR classifier reports source decoded and trace disagreement as source-oracle-defect" {
	local calls="$BATS_TEST_TMPDIR/source-oracle-defect.calls"
	local evidence
	quality_hdr_case source-oracle-defect "$calls"
	[ "$status" -eq 0 ]
	evidence="$output"
	run jq -e '
		.classification == "source-oracle-defect" and
		.reasons == ["decoded-trace-disagreement"] and
		.normalizedOracle.source.authoritative == {
			status:"unresolved",reasons:["decoded-trace-disagreement"]
		} and
		.normalizedOracle.clip.authoritative.status == "ok" and
		.normalizedOracle.encoded.authoritative.status == "ok"
	' <<<"$evidence"
	[ "$status" -eq 0 ]
}

# Catches blaming output or accepting evidence when source agreement is lost
# across the stream-copy clip boundary.
@test "HDR classifier reports source-to-clip drift as clip-boundary-defect" {
	local calls="$BATS_TEST_TMPDIR/clip-boundary-defect.calls"
	local evidence
	quality_hdr_case clip-boundary-defect "$calls"
	[ "$status" -eq 0 ]
	evidence="$output"
	run jq -e '
		.classification == "clip-boundary-defect" and
		.reasons == ["authoritative-source-metadata","clip-metadata-changed"] and
		.normalizedOracle.source.authoritative.status == "ok" and
		.normalizedOracle.clip.authoritative.status == "ok" and
		.normalizedOracle.encoded.authoritative.status == "ok" and
		.normalizedOracle.source.authoritative.metadata != .normalizedOracle.clip.authoritative.metadata and
		.normalizedOracle.clip.authoritative.metadata == .normalizedOracle.encoded.authoritative.metadata
	' <<<"$evidence"
	[ "$status" -eq 0 ]
}

# Catches comparing source and clip before proving that the encoded decoded and
# trace_headers evidence forms an authoritative oracle.
@test "quality HDR encoded oracle defect is not masked by a clip boundary defect" {
	local calls="$BATS_TEST_TMPDIR/masked-encoded-oracle-defect.calls"
	local evidence
	quality_hdr_case masked-encoded-oracle-defect "$calls"
	[ "$status" -eq 0 ]
	evidence="$output"
	run jq -e '
		.classification == "encoder-output-defect" and
		.reasons == ["decoded-trace-disagreement"] and
		.normalizedOracle.source.authoritative.status == "ok" and
		.normalizedOracle.clip.authoritative.status == "ok" and
		.normalizedOracle.encoded.authoritative == {
			status:"unresolved",reasons:["decoded-trace-disagreement"]
		}
	' <<<"$evidence"
	[ "$status" -eq 0 ] || {
		echo "encoded oracle defect was masked: $(jq -c '{classification,reasons}' <<<"$evidence")" >&3
		return 1
	}
}
