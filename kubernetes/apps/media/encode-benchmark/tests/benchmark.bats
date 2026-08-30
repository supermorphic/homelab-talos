#!/usr/bin/env bats

setup() {
	SCRIPTS="$BATS_TEST_DIRNAME/../app/scripts"
	FIXTURES="$BATS_TEST_DIRNAME/fixtures"
	export BENCHMARK_TEST_MODE=1
	export REAL_SHA256SUM="$(command -v sha256sum)"
	export REAL_LN="$(command -v ln)"
	QUALITY_RUN_ID='20260815T120000Z-c4b9c436'
	export BENCHMARK_OUT="$BATS_TEST_TMPDIR/out"
	export BENCHMARK_SCRATCH="$BATS_TEST_TMPDIR/scratch"
	export BENCHMARK_SAMPLES_FILE="$BATS_TEST_TMPDIR/samples.json"
	yq -r '.data."samples.json"' "$BATS_TEST_DIRNAME/../app/samples.yaml" >"$BENCHMARK_SAMPLES_FILE"
	mkdir -p "$BENCHMARK_OUT/runs" "$BENCHMARK_SCRATCH"
}

snapshot_tree_state() {
	local root="$1" snapshot="$2"
	(
		cd "$root"
		find . -mindepth 1 -print | LC_ALL=C sort | while IFS= read -r path; do
			if [[ -d "$path" ]]; then
				printf 'dir\t%s\n' "$path"
			elif [[ -L "$path" ]]; then
				printf 'symlink\t%s\t%s\n' "$path" "$(readlink "$path")"
			else
				printf 'file\t%s\t%s\t%s\n' \
					"$path" \
					"$(wc -c <"$path" | tr -d ' ')" \
					"$("$REAL_SHA256SUM" "$path" | awk 'NR == 1 { print $1 }')"
			fi
		done
	) >"$snapshot"
}

snapshot_regular_file_state() {
	local path="$1" snapshot="$2"
	python3 - "$path" <<'PYTHON' >"$snapshot"
import os
import stat
import sys

value = os.stat(sys.argv[1], follow_symlinks=False)
print(f"{value.st_dev}:{value.st_ino}:{stat.S_IMODE(value.st_mode):o}:{value.st_size}")
PYTHON
	sha256sum "$path" | awk 'NR == 1 { print $1 }' >>"$snapshot"
}

bind_quality_fixture_evidence() {
	local run_id="$1" fixture="$2" attempt="$3" output_fixture="$4"
	local sample_id cohort source_sha clip setting strategy vmaf_harmonic vmaf_low ssim
	local evidence_path evidence_file evidence_digest hdr='null'
	sample_id="$(jq -r '.sample_id' "$fixture")"
	cohort="$(jq -r '.cohort' "$fixture")"
	source_sha="$(jq -r '.source_sha256' "$fixture")"
	clip="$(jq -r '.clip_id' "$fixture")"
	setting="$(jq -r '.requested_setting' "$fixture")"
	strategy="$(jq -r '.strategy_id' "$fixture")"
	vmaf_harmonic="$(jq -r '.vmaf_harmonic_mean' "$fixture")"
	vmaf_low="$(jq -r '.vmaf_1pct_low' "$fixture")"
	ssim="$(jq -r '.ssim' "$fixture")"
	if [[ "$cohort" == 'hdr10' ]]; then
		hdr='{"classification":"preserved","reasons":["source-clip-encoded-metadata-agree"],"normalizedOracle":{}}'
	fi
	evidence_path="quality-evidence/$sample_id-$clip-qsv-$setting-attempt-$attempt.json"
	evidence_file="$BENCHMARK_OUT/runs/$run_id/$evidence_path"
	mkdir -p "${evidence_file%/*}"
	jq -S -c -n \
		--arg run "$run_id" --arg sample "$sample_id" --arg cohort "$cohort" \
		--arg source_sha "$source_sha" --arg clip "$clip" --arg strategy "$strategy" \
		--argjson setting "$setting" --argjson vmaf_harmonic "$vmaf_harmonic" \
		--argjson vmaf_low "$vmaf_low" --argjson ssim "$ssim" --argjson hdr "$hdr" '{
			clipId:$clip,cohort:$cohort,globalQuality:$setting,hdr:$hdr,psnr:40,
			runId:$run,sampleId:$sample,schemaVersion:1,sourceSha256:$source_sha,
			ssim:$ssim,strategyId:$strategy,
			vmaf:{rawFrameCount:100,evaluatedFrameCount:100,excludedFrames:[],
				harmonicMean:$vmaf_harmonic,onePercentLow:$vmaf_low}
		}' >"$evidence_file"
	chmod 0600 "$evidence_file"
	evidence_digest="sha256:$(sha256sum "$evidence_file" | awk 'NR == 1 { print $1 }')"
	jq --arg path "$evidence_path" --arg digest "$evidence_digest" '
		.quality_evidence_path = $path | .quality_evidence_sha256 = $digest
	' "$fixture" >"$output_fixture"
}

quality_evidence_reference() {
	local run_id="$1" sample_id="$2" cohort="$3" source_sha="$4" clip="$5"
	local setting="$6" attempt="$7" vmaf_harmonic="$8" vmaf_low="$9" ssim="${10}"
	local evidence_path evidence_file evidence_digest hdr='null'
	if [[ "$cohort" == 'hdr10' ]]; then
		hdr='{"classification":"preserved","reasons":["source-clip-encoded-metadata-agree"],"normalizedOracle":{}}'
	fi
	evidence_path="quality-evidence/$sample_id-$clip-qsv-$setting-attempt-$attempt.json"
	evidence_file="$BENCHMARK_OUT/runs/$run_id/$evidence_path"
	mkdir -p "${evidence_file%/*}"
	jq -S -c -n \
		--arg run "$run_id" --arg sample "$sample_id" --arg cohort "$cohort" \
		--arg source_sha "$source_sha" --arg clip "$clip" --argjson setting "$setting" \
		--argjson vmaf_harmonic "$vmaf_harmonic" --argjson vmaf_low "$vmaf_low" \
		--argjson ssim "$ssim" --argjson hdr "$hdr" '{
			clipId:$clip,cohort:$cohort,globalQuality:$setting,hdr:$hdr,psnr:40,
			runId:$run,sampleId:$sample,schemaVersion:1,sourceSha256:$source_sha,
			ssim:$ssim,strategyId:"qsv-hevc-icq-v1",
			vmaf:{rawFrameCount:100,evaluatedFrameCount:100,excludedFrames:[],
				harmonicMean:$vmaf_harmonic,onePercentLow:$vmaf_low}
		}' >"$evidence_file"
	chmod 0600 "$evidence_file"
	evidence_digest="sha256:$(sha256sum "$evidence_file" | awk 'NR == 1 { print $1 }')"
	printf '%s,%s\n' "$evidence_path" "$evidence_digest"
}

initialize_quality_results() {
	local results="$1"
	printf '%s\n' 'run_id,panel,sample_id,cohort,source_sha256,clip_id,encoder,requested_setting,selected_rate_control,status,attempt,input_bytes,output_bytes,reduction_percent,input_bit_rate,output_bit_rate,wall_seconds,encode_fps,encode_speed,vmaf_harmonic_mean,vmaf_1pct_low,ssim,gpu_busy_percent,qsv_proof,validation_codec,validation_duration,validation_resolution,validation_frame_rate,validation_bit_depth,validation_hdr,validation_audio_tracks,validation_subtitle_tracks,validation_chapters,validation_failures,log_path,output_disposition,strategy_id,qsv_initialization,video_busy_nanoseconds,quality_evidence_path,quality_evidence_sha256' >"$results"
}

append_quality_result() {
	local results="$1" run_id="$2" sample_id="$3" cohort="$4" source_sha="$5"
	local clip="$6" setting="$7" attempt="$8" reduction="$9" vmaf_harmonic="${10}"
	local vmaf_low="${11}" ssim="${12}" status="${13:-passed}"
	local evidence_ref evidence_path evidence_digest
	evidence_ref="$(quality_evidence_reference "$run_id" "$sample_id" "$cohort" "$source_sha" \
		"$clip" "$setting" "$attempt" "$vmaf_harmonic" "$vmaf_low" "$ssim")"
	evidence_path="${evidence_ref%%,*}"
	evidence_digest="${evidence_ref#*,}"
	printf '%s\n' "$run_id,quality,$sample_id,$cohort,$source_sha,$clip,qsv,$setting,ICQ,$status,$attempt,1000,600,$reduction,8000,4800,10,30,1.0,$vmaf_harmonic,$vmaf_low,$ssim,50,passed,passed,passed,passed,passed,passed,passed,passed,passed,passed,,logs/$sample_id-$clip-qsv-$setting-attempt-$attempt.log,discarded,qsv-hevc-icq-v1,passed,800000000,$evidence_path,$evidence_digest" >>"$results"
}

set_ranking_panel() {
	local panel_json="$1"
	jq --argjson panel "$panel_json" '.qualityPanel = $panel' \
		"$BENCHMARK_SAMPLES_FILE" >"$BENCHMARK_SAMPLES_FILE.tmp"
	mv -f -- "$BENCHMARK_SAMPLES_FILE.tmp" "$BENCHMARK_SAMPLES_FILE"
}

# Catches a planner that drops, duplicates, or relabels any fixed quality row.
# The expected Cartesian product is built only from literals in this test.
@test "quality planner emits the exact 144 unique row keys" {
	run "$SCRIPTS/benchmark.sh" _test quality-work-plan
	[ "$status" -eq 0 ]
	plan="$output"
	run "$SCRIPTS/benchmark.sh" _test quality-work-plan
	[ "$status" -eq 0 ]
	[ "$output" = "$plan" ]

	run python3 - "$plan" <<'PYTHON'
import json
import sys

rows = [json.loads(line) for line in sys.argv[1].splitlines()]
sample_ids = (
    "vc1-fugitive",
    "avc-clean-coco",
    "avc-grain-memento",
    "hdr10-clean-ministry",
    "hdr10-grain-goodfellas",
    "hdr10-motion-john-wick-2",
)
clips = {
    "vc1-fugitive": {
        "detail": ("vc1", "01:15:00.000"),
        "dark": ("vc1", "00:35:00.000"),
        "motion": ("vc1", "01:20:00.000"),
    },
    "avc-clean-coco": {
        "detail": ("avc", "00:10:00.000"),
        "dark": ("avc", "00:45:00.000"),
        "motion": ("avc", "00:05:00.000"),
    },
    "avc-grain-memento": {
        "detail": ("avc", "00:23:00.000"),
        "dark": ("avc", "00:38:00.000"),
        "motion": ("avc", "01:15:30.000"),
    },
    "hdr10-clean-ministry": {
        "detail": ("hdr10", "01:04:15.000"),
        "dark": ("hdr10", "01:19:15.000"),
        "motion": ("hdr10", "00:29:15.000"),
    },
    "hdr10-grain-goodfellas": {
        "detail": ("hdr10", "01:06:25.000"),
        "dark": ("hdr10", "00:36:55.000"),
        "motion": ("hdr10", "00:40:45.000"),
    },
    "hdr10-motion-john-wick-2": {
        "detail": ("hdr10", "01:04:50.000"),
        "dark": ("hdr10", "00:06:30.000"),
        "motion": ("hdr10", "01:38:00.000"),
    },
}
clip_ids = ("detail", "dark", "motion")
settings = (16, 18, 20, 22, 24, 26, 28, 30)
expected = {
    (sample_id, clip_id, setting)
    for sample_id in sample_ids
    for clip_id in clip_ids
    for setting in settings
}
actual = {
    (row["sampleId"], row["clipId"], row["requestedSetting"])
    for row in rows
}
assert len(rows) == 144, len(rows)
assert len(actual) == 144, len(actual)
assert actual == expected, sorted(expected ^ actual)
for row in rows:
    cohort, timestamp = clips[row["sampleId"]][row["clipId"]]
    assert row["cohort"] == cohort
    assert row["timestamp"] == timestamp
PYTHON
	[ "$status" -eq 0 ]
}

# Catches a non-QSV encoder or a broadened row shape entering the quality plan.
@test "quality work plan contains QSV rows only" {
	run "$SCRIPTS/benchmark.sh" _test quality-work-plan
	[ "$status" -eq 0 ]
	plan="$output"

	run jq -e -s '
		length == 144 and
		all(.[];
			type == "object" and
			(keys | sort) == (["clipId","cohort","encoder","requestedSetting","sampleId",
				"sourcePath","sourceSha256","timestamp"] | sort) and
			.encoder == "qsv" and
			(.requestedSetting | type == "number")
		)
	' <<<"$plan"
	[ "$status" -eq 0 ]
	[ "$(jq -r -s '[.[] | select(.sampleId == "dolby-vision-sisu")] | length' <<<"$plan")" -eq 0 ]

	run_directory="$BENCHMARK_OUT/runs/20260815T120000Z-d0000001"
	mkdir -p "$run_directory"
	run "$SCRIPTS/benchmark.sh" _test record-quality-skips "$run_directory"
	[ "$status" -eq 0 ]
	[ "$(<"$run_directory/skips.csv")" = 'dolby-vision-sisu,dolby-vision,detection-only' ]
}

create_capability_tools() {
	stub_bin="$BATS_TEST_TMPDIR/capability-bin"
	mkdir -p "$stub_bin"
	cat >"$stub_bin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$BENCHMARK_COMMAND_LOG"
case "$*" in
*'-hide_banner -encoders'*)
	printf '%s\n' ' V..... hevc_qsv Intel Quick Sync Video HEVC encoder'
	exit 0
	;;
*'-hide_banner -filters'*)
	if [[ "${BENCHMARK_CAPABILITY_MISSING_FILTER:-}" != 'libvmaf' ]]; then
		printf '%s\n' ' ... libvmaf VV->V Calculate the VMAF between two video streams.'
	fi
	if [[ "${BENCHMARK_CAPABILITY_MISSING_FILTER:-}" != 'ssim' ]]; then
		printf '%s\n' ' ... ssim VV->V Calculate the SSIM between two video streams.'
	fi
	if [[ "${BENCHMARK_CAPABILITY_MISSING_FILTER:-}" != 'psnr' ]]; then
		printf '%s\n' ' ... psnr VV->V Calculate the PSNR between two video streams.'
	fi
	exit 0
	;;
*'-hide_banner -bsfs'*)
	[[ "${BENCHMARK_CAPABILITY_MISSING_BSF:-0}" == '1' ]] || printf '%s\n' 'trace_headers'
	exit 0
	;;
*'-version'*)
	printf '%s\n' 'ffmpeg version 8.1.2 fixture-build'
	exit 0
	;;
esac
if [[ "$*" == *"nullsrc=size=16x16:rate=1"* ]]; then
	while IFS= read -r line || [[ -n "$line" ]]; do
		printf '%s\n' "$line"
	done <"${BENCHMARK_CAPABILITY_INITIALIZATION_FIXTURE:?}" >&2
elif [[ "$*" == *'-c:v hevc_qsv'* ]]; then
	while IFS= read -r line || [[ -n "$line" ]]; do
		printf '%s\n' "$line"
	done <"${BENCHMARK_CAPABILITY_ENCODE_FIXTURE:?}" >&2
fi
if [[ "$*" == *'libvmaf=model=version=vmaf_4k_v0.6.1'* &&
	"${BENCHMARK_CAPABILITY_VMAF_FAILURE:-0}" == '1' ]]; then
	exit 86
fi
if [[ "$*" == *'-map 0:v:0 -f null -'* && "$*" != *'libvmaf='* &&
	"${BENCHMARK_CAPABILITY_DECODE_FAILURE:-0}" == '1' ]]; then
	exit 87
fi
last="${!#}"
if [[ "$last" != '-' && "$last" != '/dev/null' ]]; then
	mkdir -p "$(dirname "$last")"
	printf 'fixture media' >"$last"
fi
EOF
	cat >"$stub_bin/ffprobe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == '-version' ]]; then
	printf '%s\n' 'ffprobe version 8.1.2 fixture-build'
	exit 0
fi
if [[ -n "${BENCHMARK_CAPABILITY_FRAME_FIXTURE:-}" ]]; then
	printf '%s\n' "$BENCHMARK_CAPABILITY_FRAME_FIXTURE"
else
	printf '%s\n' '{"frames":[{"best_effort_timestamp_time":"0.000000","pkt_duration_time":"0.041667","key_frame":1,"pict_type":"I"}]}'
fi
EOF
	cat >"$stub_bin/id" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == '-u' ]] || exit 97
printf '%s\n' '568'
EOF
	chmod +x "$stub_bin/ffmpeg" "$stub_bin/ffprobe" "$stub_bin/id"
	export PATH="$stub_bin:$PATH"
	export BENCHMARK_COMMAND_LOG="$BATS_TEST_TMPDIR/capability-commands.log"
	export BENCHMARK_CAPABILITY_ENCODE_FIXTURE="$FIXTURES/logs/qsv-icq.log"
	export BENCHMARK_CAPABILITY_INITIALIZATION_FIXTURE="$FIXTURES/logs/qsv-init-success-no-phrase.log"
	export BENCHMARK_TEST_FDINFO_FIXTURE="$FIXTURES/logs/drm-fdinfo-active.log"
	unset BENCHMARK_CAPABILITY_DECODE_FAILURE BENCHMARK_CAPABILITY_VMAF_FAILURE
	unset BENCHMARK_CAPABILITY_MISSING_FILTER BENCHMARK_CAPABILITY_MISSING_BSF
	unset BENCHMARK_CAPABILITY_FRAME_FIXTURE
	: >"$BENCHMARK_COMMAND_LOG"
}

write_capability_samples() {
	image="${1:-docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb}"
	export BENCHMARK_SAMPLES_FILE="$BATS_TEST_TMPDIR/capability-samples.json"
	jq -n \
		--arg image "$image" \
		--argjson strategy "$(strategy_contract)" \
		--argjson quality_correction "$(quality_correction_contract)" \
		--argjson required "$(capability_declared_list requiredCommands "${@:2}")" \
		'{schemaVersion: 3, strategy: $strategy, qualityCorrection: $quality_correction,
			runtime: {image: $image, requiredCommands: $required}}' \
		>"$BENCHMARK_SAMPLES_FILE"
}

capability_declared_list() {
	local key="$1"
	shift
	local samples="$BATS_TEST_TMPDIR/declared-$key.json"
	yq -r '.data."samples.json"' "$BATS_TEST_DIRNAME/../app/samples.yaml" >"$samples"
	# The file must arrive on stdin: with --args, jq treats a file argument as a
	# positional string and then blocks reading stdin.
	jq -c --args ".runtime.$key + [\$ARGS.positional[]]" -- "$@" <"$samples"
}

strategy_contract() {
	yq -r '.data."samples.json"' "$BATS_TEST_DIRNAME/../app/samples.yaml" | jq -c '.strategy'
}

quality_correction_contract() {
	yq -r '.data."samples.json"' "$BATS_TEST_DIRNAME/../app/samples.yaml" | jq -c '.qualityCorrection'
}

create_execution_tools() {
	stub_bin="$BATS_TEST_TMPDIR/execution-bin"
	mkdir -p "$stub_bin"
	cat >"$stub_bin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$BENCHMARK_COMMAND_LOG"
arguments="$*"
case "$arguments" in
*'-hide_banner -encoders'*)
	printf '%s\n' ' V..... hevc_qsv Intel Quick Sync Video HEVC encoder'
	exit 0
	;;
*'-hide_banner -filters'*)
	printf '%s\n' \
		' ... libvmaf VV->V Calculate the VMAF between two video streams.' \
		' ... ssim VV->V Calculate the SSIM between two video streams.' \
		' ... psnr VV->V Calculate the PSNR between two video streams.'
	exit 0
	;;
*'-hide_banner -bsfs'*)
	printf '%s\n' 'trace_headers'
	exit 0
	;;
*'-version'*)
	printf '%s\n' 'ffmpeg version 8.1.2 fixture-build'
	exit 0
	;;
esac
encoded=''
previous=''
for argument in "$@"; do
	if [[ "$previous" == '-i' && -z "$encoded" ]]; then
		encoded="$argument"
	fi
	previous="$argument"
done
if [[ "$arguments" == *'libvmaf=model=version=vmaf_4k_v0.6.1:log_fmt=json:log_path='* ]]; then
	filter=''
	for argument in "$@"; do
		if [[ "$argument" == *'libvmaf='* ]]; then filter="$argument"; fi
	done
	metrics_path="${filter##*log_path=}"
	case "$encoded" in
	*qsv-20*) score=98 ;;
	*qsv-22*) score=97 ;;
	*qsv-24*) score=96 ;;
	*qsv-26*) score=95 ;;
	*qsv-28*) score=94 ;;
	*) score=96 ;;
	esac
	mkdir -p "$(dirname "$metrics_path")"
	if [[ "${BENCHMARK_TEST_VMAF_COMMAND_FAILURE:-0}" == '1' ]]; then
		exit 88
	fi
	if [[ "${BENCHMARK_TEST_VMAF_PARSE_FAILURE:-0}" == '1' ]]; then
		printf '%s\n' '{"frames":"invalid"}' >"$metrics_path"
		exit 0
	fi
	jq -n --argjson score "$score" '{version:"3.0.0",fps:24,frames:[range(0;4) | {frameNum:.,metrics:{vmaf:$score}}]}' >"$metrics_path"
	exit 0
fi
if [[ "$arguments" == *'[0:v][1:v]ssim'* ]]; then
	if [[ "${BENCHMARK_TEST_SSIM_COMMAND_FAILURE:-0}" == '1' ]]; then
		exit 89
	fi
	if [[ "${BENCHMARK_TEST_SSIM_PARSE_FAILURE:-0}" == '1' ]]; then
		printf '%s\n' '[Parsed_ssim_0 @ 0x3000] no aggregate score' >&2
		exit 0
	fi
	printf '%s\n' '[Parsed_ssim_0 @ 0x3000] SSIM Y:0.990000 U:0.995000 V:0.995000 All:0.991000 (20.457575)' >&2
	exit 0
fi
if [[ "$arguments" == *'[0:v][1:v]psnr'* ]]; then
	if [[ "${BENCHMARK_TEST_PSNR_COMMAND_FAILURE:-0}" == '1' ]]; then
		exit 90
	fi
	if [[ "${BENCHMARK_TEST_PSNR_PARSE_FAILURE:-0}" == '1' ]]; then
		printf '%s\n' '[Parsed_psnr_0 @ 0x3000] no aggregate score' >&2
		exit 0
	fi
	printf '%s\n' '[Parsed_psnr_0 @ 0x3000] PSNR y:40.000000 u:40.000000 v:40.000000 average:40.000000 min:40.000000 max:40.000000' >&2
	exit 0
fi
if [[ "$arguments" == *'-bsf:v trace_headers'* ]]; then
	if [[ -n "${BENCHMARK_TEST_INVALID_OUTPUT_MATCH:-}" &&
		"$arguments" =~ ${BENCHMARK_TEST_INVALID_OUTPUT_MATCH} ]]; then
		exit 0
	fi
	printf '%s\n' \
		'Mastering Display Colour Volume' \
		'display_primaries_x[0] = 13250' 'display_primaries_y[0] = 34500' \
		'display_primaries_x[1] = 7500' 'display_primaries_y[1] = 3000' \
		'display_primaries_x[2] = 34000' 'display_primaries_y[2] = 16000' \
		'white_point_x = 15635' 'white_point_y = 16450' \
		'max_display_mastering_luminance = 10000000' \
		'min_display_mastering_luminance = 1' \
		'Content Light Level Information' \
		'max_content_light_level = 1000' 'max_pic_average_light_level = 400' >&2
	exit 0
fi
if [[ "${BENCHMARK_TEST_PGS_DECODE:-0}" == '1' && "$arguments" == *'-f null -'* &&
	"$arguments" != *'libvmaf='* && " $arguments " == *' -map 0 '* ]]; then
	exit 92
fi
if [[ "${BENCHMARK_TEST_FFMPEG_CONSUME_STDIN:-0}" == '1' && " $arguments " != *' -nostdin '* ]]; then
	while IFS= read -r _line || [[ -n "${_line:-}" ]]; do :; done
fi
if [[ "$arguments" == *'-c:v hevc_qsv'* ]]; then
	printf '%s\n' \
		'[hevc_qsv @ 0x2000] Using the intelligent constant quality (ICQ) ratecontrol method' \
		'frame= 2160 fps=72.0 q=-0.0 Lsize= 60123KiB time=00:01:30.00 bitrate=5473.0kbits/s speed=1.25x' >&2
fi
last="${!#}"
if [[ "$last" != '-' && "$last" != '/dev/null' ]]; then
	mkdir -p "$(dirname "$last")"
	printf 'encoded fixture bytes' >"$last"
fi
EOF
	cat >"$stub_bin/ffprobe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == '-version' ]]; then
	printf '%s\n' 'ffprobe version 8.1.2 fixture-build'
	exit 0
fi
if [[ "$*" == *'-show_packets -select_streams a -show_entries packet=stream_index,size -of csv=p=0'* ]]; then
	if [[ "${BENCHMARK_TEST_PACKET_FAILURE:-0}" == '1' ]]; then exit 91; fi
	exec cat "$BENCHMARK_PACKET_FIXTURE"
fi
if [[ "$*" == *'-show_streams -show_entries stream_side_data'* ]]; then
	printf '%s\n' '{"streams":[{}]}'
	exit 0
fi
if [[ "$*" == *'-show_frames -show_entries frame=side_data_list'* ]]; then
	if [[ -n "${BENCHMARK_TEST_INVALID_OUTPUT_MATCH:-}" &&
		"$*" =~ ${BENCHMARK_TEST_INVALID_OUTPUT_MATCH} ]]; then
		printf '%s\n' '{"frames":[{}]}'
		exit 0
	fi
	jq -n '{frames:[{side_data_list:[
		{side_data_type:"Mastering display metadata",red_x:"34000/50000",red_y:"16000/50000",green_x:"13250/50000",green_y:"34500/50000",blue_x:"7500/50000",blue_y:"3000/50000",white_point_x:"15635/50000",white_point_y:"16450/50000",min_luminance:"1/10000",max_luminance:"10000000/10000"},
		{side_data_type:"Content light level metadata",max_content:1000,max_average:400}
	]}]}'
	exit 0
fi
if [[ "$*" == *'-read_intervals 0%+1 -show_frames'* ]]; then
	printf '%s\n' '{"frames":[{"best_effort_timestamp_time":"0.000000","pkt_duration_time":"0.041667","key_frame":1,"pict_type":"I"}]}'
	exit 0
fi
exit 97
EOF
	cat >"$stub_bin/id" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == '-u' ]] || exit 97
printf '%s\n' '568'
EOF
	cat >"$stub_bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sha256sum %s\n' "$*" >>"$BENCHMARK_COMMAND_LOG"
"$REAL_SHA256SUM" "$@"
if [[ -n "${BENCHMARK_TEST_SHA256_REPLACE_TARGET:-}" &&
	-n "${BENCHMARK_TEST_SHA256_REPLACEMENT:-}" &&
	-e "$BENCHMARK_TEST_SHA256_REPLACEMENT" ]]; then
	if [[ -n "${BENCHMARK_TEST_SHA256_REPLACE_AFTER_CALLS:-}" ]]; then
		calls=0
		if [[ -f "$BENCHMARK_TEST_SHA256_REPLACE_COUNTER" ]]; then
			IFS= read -r calls <"$BENCHMARK_TEST_SHA256_REPLACE_COUNTER"
		fi
		calls="$((calls + 1))"
		printf '%s\n' "$calls" >"$BENCHMARK_TEST_SHA256_REPLACE_COUNTER"
		if ((calls < BENCHMARK_TEST_SHA256_REPLACE_AFTER_CALLS)); then
			exit 0
		fi
	fi
	mv -f -- "$BENCHMARK_TEST_SHA256_REPLACEMENT" "$BENCHMARK_TEST_SHA256_REPLACE_TARGET"
fi
EOF
	cat >"$stub_bin/ln" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == '-T' && "${2:-}" == '--' && "$#" -eq 4 ]]; then
	python3 - "$3" "$4" <<'PYTHON'
import os
import sys

os.link(sys.argv[1], sys.argv[2])
PYTHON
	if [[ -n "${BENCHMARK_TEST_LINK_SWAP_OUTSIDE:-}" &&
		-n "${BENCHMARK_TEST_LINK_SWAP_MARKER:-}" &&
		! -e "$BENCHMARK_TEST_LINK_SWAP_MARKER" && "$4" == *'/.quality-ranking.'*'/evidence.json' ]]; then
		snapshot_directory="${4%/*}"
		mv -- "$snapshot_directory" "$snapshot_directory.moved"
		"$REAL_LN" -s "$BENCHMARK_TEST_LINK_SWAP_OUTSIDE" "$snapshot_directory"
		: >"$BENCHMARK_TEST_LINK_SWAP_MARKER"
	fi
	exit 0
fi
exec "$REAL_LN" "$@"
EOF
	chmod +x "$stub_bin/ffmpeg" "$stub_bin/ffprobe" "$stub_bin/id" "$stub_bin/sha256sum" "$stub_bin/ln"
	export PATH="$stub_bin:$PATH"
	export BENCHMARK_COMMAND_LOG="$BATS_TEST_TMPDIR/execution-commands.log"
	: >"$BENCHMARK_COMMAND_LOG"
}

prepare_execution_run() {
	create_execution_tools
	export BENCHMARK_NOW=20260802T120000Z
	export BENCHMARK_IDENTITY_FIXTURE="$FIXTURES/manifests/identity.json"
	export BENCHMARK_TEST_SOURCE_PROBE="$FIXTURES/metrics/probe-source.json"
	export BENCHMARK_TEST_OUTPUT_PROBE="$FIXTURES/metrics/probe-output-valid.json"
	export BENCHMARK_TEST_FDINFO_FIXTURE="$FIXTURES/logs/drm-fdinfo-active.log"
	source_media="$BATS_TEST_TMPDIR/source.mkv"
	printf '%s' 'source fixture bytes' >"$source_media"
	source_size="$(wc -c <"$source_media" | tr -d ' ')"
	source_sha="$(sha256sum "$source_media" | awk '{print $1}')"
	export BENCHMARK_SAMPLES_FILE="$BATS_TEST_TMPDIR/samples.json"
	jq -n \
		--arg source_media "$source_media" \
		--argjson source_size "$source_size" \
		--arg source_sha "$source_sha" \
		--argjson strategy "$(strategy_contract)" \
		--argjson quality_correction "$(quality_correction_contract)" \
		--argjson required "$(capability_declared_list requiredCommands)" \
		'{
			schemaVersion: 3,
			strategy: $strategy,
			qualityCorrection: $quality_correction,
			runtime: {
				image: "docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb",
				requiredCommands: $required
			},
			qualityPanel: [{
				id: "sample-hdr", cohort: "hdr10", path: $source_media,
				sizeBytes: $source_size, sha256: $source_sha,
				clips: {detail: "00:17:23.456"}
			}]
		}' >"$BENCHMARK_SAMPLES_FILE"
	export BENCHMARK_DISPATCH_IMAGE='docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	export NODE_NAME='nuc1'
}

prepare_representative_run() {
	local sample_id="$1" cohort="$2" media_fixture="$3"
	local size sha
	prepare_execution_run
	size="$(wc -c <"$media_fixture" | tr -d ' ')"
	sha="$(sha256sum "$media_fixture" | awk 'NR == 1 { print $1 }')"
	source_media="$media_fixture"
	source_size="$size"
	source_sha="$sha"
	jq --arg id "$sample_id" --arg cohort "$cohort" --arg path "$media_fixture" \
		--arg sha "$sha" --argjson size "$size" '
		.qualityPanel = [{
			id:$id, cohort:$cohort, path:$path, sizeBytes:$size, sha256:$sha,
			clips:{detail:"00:00:00.000"}
		}]
	' "$BENCHMARK_SAMPLES_FILE" >"$BENCHMARK_SAMPLES_FILE.tmp"
	mv -f -- "$BENCHMARK_SAMPLES_FILE.tmp" "$BENCHMARK_SAMPLES_FILE"
}

append_representative_dv_skip() {
	jq --arg path "$source_media" --arg sha "$source_sha" --argjson size "$source_size" '
		.qualityPanel += [{
			id:"dolby-vision-sisu",cohort:"dolby-vision",detectionOnly:true,
			path:$path,sizeBytes:$size,sha256:$sha,clips:{}
		}]
	' "$BENCHMARK_SAMPLES_FILE" >"$BENCHMARK_SAMPLES_FILE.tmp"
	mv -f -- "$BENCHMARK_SAMPLES_FILE.tmp" "$BENCHMARK_SAMPLES_FILE"
}

start_representative_plan() {
	export BENCHMARK_TEST_QUALITY_PLAN_FILE="$BATS_TEST_TMPDIR/quality-plan.jsonl"
	: >"$BENCHMARK_TEST_QUALITY_PLAN_FILE"
}

append_representative_plan_row() {
	local sample_id="$1" clip_id="$2" setting="$3"
	jq -e -c --arg sample "$sample_id" --arg clip "$clip_id" --argjson setting "$setting" '
		.qualityPanel[] | select(.id == $sample) |
		{
			sampleId:.id, cohort:.cohort, sourcePath:.path, sourceSha256:.sha256,
			clipId:$clip, timestamp:.clips[$clip], encoder:"qsv", requestedSetting:$setting
		}
	' "$BENCHMARK_SAMPLES_FILE" >>"$BENCHMARK_TEST_QUALITY_PLAN_FILE"
}

# Each mutation names a state-machine break that would authorize work from an
# ambiguous or contradictory one-record visual decision.
@test "quality result and evidence schemas are exact and mutually bound" {
	run "$SCRIPTS/benchmark.sh" _test results-header
	[ "$status" -eq 0 ]
	[ "$output" = 'run_id,panel,sample_id,cohort,source_sha256,clip_id,encoder,requested_setting,selected_rate_control,status,attempt,input_bytes,output_bytes,reduction_percent,input_bit_rate,output_bit_rate,wall_seconds,encode_fps,encode_speed,vmaf_harmonic_mean,vmaf_1pct_low,ssim,gpu_busy_percent,qsv_proof,validation_codec,validation_duration,validation_resolution,validation_frame_rate,validation_bit_depth,validation_hdr,validation_audio_tracks,validation_subtitle_tracks,validation_chapters,validation_failures,log_path,output_disposition,strategy_id,qsv_initialization,video_busy_nanoseconds,quality_evidence_path,quality_evidence_sha256' ]

	run_id='20260802T120000Z-aaaaaaaa'
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	mkdir -p "$run_dir"
	bound="$BATS_TEST_TMPDIR/schema-bound.json"
	bind_quality_fixture_evidence "$run_id" "$FIXTURES/metrics/variant-passed.json" 1 "$bound"
	scratch_output="$BENCHMARK_SCRATCH/schema-output.mkv"
	printf '%s' 'encoded bytes' >"$scratch_output"
	run "$SCRIPTS/benchmark.sh" _test record-result "$run_id" "$bound" "$scratch_output"
	[ "$status" -eq 0 ]
	results="$run_dir/results.csv"
	[ "$(awk -F, 'NR == 2 {print NF}' "$results")" -eq 41 ]
	evidence="$run_dir/$(awk -F, 'NR == 2 {print $40}' "$results")"
	run jq -e '
		keys == ["clipId","cohort","globalQuality","hdr","psnr","runId","sampleId",
			"schemaVersion","sourceSha256","ssim","strategyId","vmaf"] and
		.schemaVersion == 1 and .strategyId == "qsv-hevc-icq-v1" and
		(.globalQuality | type == "number") and (.ssim | type == "number") and
		(.psnr | type == "number") and .hdr == null and
		(.vmaf | keys == ["evaluatedFrameCount","excludedFrames","harmonicMean","onePercentLow","rawFrameCount"]) and
		(.vmaf.rawFrameCount | type == "number") and
		(.vmaf.evaluatedFrameCount | type == "number") and
		(.vmaf.excludedFrames | type == "array") and
		(.vmaf.harmonicMean | type == "number") and (.vmaf.onePercentLow | type == "number")
	' "$evidence"
	[ "$status" -eq 0 ]
}

@test "benchmark failure hooks are rejected outside test mode" {
	unset BENCHMARK_OUT BENCHMARK_SCRATCH BENCHMARK_SAMPLES_FILE
	export BENCHMARK_TEST_MODE=0
	export BENCHMARK_TEST_FAIL_RESULT_APPEND=1
	run "$SCRIPTS/benchmark.sh" _test results-header
	[ "$status" -eq 64 ]
	[ "$output" = 'BENCHMARK_TEST_* hooks require BENCHMARK_TEST_MODE=1' ]

	unset BENCHMARK_TEST_FAIL_RESULT_APPEND
	export BENCHMARK_TEST_QUALITY_PLAN_FILE=/tmp/quality-plan.jsonl
	run "$SCRIPTS/benchmark.sh" _test results-header
	[ "$status" -eq 64 ]
	[ "$output" = 'BENCHMARK_TEST_QUALITY_PLAN_FILE requires BENCHMARK_TEST_MODE=1' ]
}

# Catches capability claims based only on encoder exit status: this public mode
# must prove exact ICQ, render-node binding, video-engine work, progress, decode,
# and vmaf_4k without relying on a version-specific success sentence.
@test "capabilities proves the phrase-free ICQ path with schema-v3 evidence" {
	create_capability_tools
	write_capability_samples
	export BENCHMARK_DISPATCH_IMAGE='docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	export NODE_NAME='talos-03'
	export KUBERNETES_IMAGE_ID='containerd://sha256:must-not-be-claimed-by-the-job'

	run "$SCRIPTS/benchmark.sh" capabilities
	[ "$status" -eq 0 ]
	[[ "$output" != *"$BENCHMARK_SCRATCH"* ]]
	run jq -e -c '
		.status == "passed" and .strategyId == "qsv-hevc-icq-v1" and
		.proofSchemaVersion == 3 and .uid == 568 and
		.initialization == "passed" and .initializationReason == "" and
		.renderNode == "/dev/dri/renderD128" and .drmDriver == "i915" and
		.selectedRateControl == "ICQ" and
		.telemetryStatus == "available" and .videoBusyNanoseconds == 800000000 and
		.videoBusyPercent == 40 and .encodeFps == 72 and .encodeSpeed == 1.25 and
		.decode == "passed" and .vmaf == "passed" and
		.proofStatus == "passed" and .proofReasons == "" and
		.hevcQsv == true and
		.ffmpegVersion == "8.1.2" and .ffprobeVersion == "8.1.2" and
		.nodeName == "talos-03" and
		.configuredImage == "docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb" and
		.configuredImageDigest == "sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb" and
		(has("imageId") | not)
	' <<<"$output"
	[ "$status" -eq 0 ]

	run rg -F -- '-f lavfi -i testsrc2=size=1920x1080:rate=30 -t 5' "$BENCHMARK_COMMAND_LOG"
	[ "$status" -eq 0 ]
	run rg -F -- '-init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw' "$BENCHMARK_COMMAND_LOG"
	[ "$status" -eq 0 ]
	run rg -F -- '-f lavfi -i nullsrc=size=16x16:rate=1 -frames:v 1 -f null -' "$BENCHMARK_COMMAND_LOG"
	[ "$status" -eq 0 ]
	run rg -F -- '-nostdin -v verbose -init_hw_device qsv=hw:/dev/dri/renderD128' "$BENCHMARK_COMMAND_LOG"
	[ "$status" -eq 0 ]
	run rg -F -- '-c:v hevc_qsv -preset veryslow -global_quality 16 -look_ahead 0 -extbrc 0' "$BENCHMARK_COMMAND_LOG"
	[ "$status" -eq 0 ]
	run rg -F -- '-f null -' "$BENCHMARK_COMMAND_LOG"
	[ "$status" -eq 0 ]
	run rg -F -- 'libvmaf=model=version=vmaf_4k_v0.6.1' "$BENCHMARK_COMMAND_LOG"
	[ "$status" -eq 0 ]
}

# Catches semantic capability failures being collapsed into encode success and
# keeps telemetry-contract failures distinct from a proven platform failure.
@test "capability proof rejects semantic failures and reports telemetry blocks" {
	create_capability_tools
	write_capability_samples
	export BENCHMARK_DISPATCH_IMAGE='docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	export NODE_NAME='talos-03'

	export BENCHMARK_CAPABILITY_ENCODE_FIXTURE="$FIXTURES/logs/qsv-fallback.log"
	run "$SCRIPTS/benchmark.sh" capabilities
	[ "$status" -eq 1 ]
	[ "$(jq -r '.proofStatus + ":" + .proofReasons' <<<"$output")" = 'failed:rate-control' ]

	export BENCHMARK_CAPABILITY_INITIALIZATION_FIXTURE="$FIXTURES/logs/qsv-init-known-failure.log"
	run "$SCRIPTS/benchmark.sh" capabilities
	[ "$status" -eq 1 ]
	[ "$(jq -r '.proofStatus + ":" + .initialization' <<<"$output")" = 'failed:failed' ]
	[[ "$(jq -r '.proofReasons' <<<"$output")" == initialization* ]]
	export BENCHMARK_CAPABILITY_INITIALIZATION_FIXTURE="$FIXTURES/logs/qsv-init-success-no-phrase.log"

	export BENCHMARK_CAPABILITY_ENCODE_FIXTURE="$FIXTURES/logs/qsv-icq.log"
	export BENCHMARK_TEST_FDINFO_FIXTURE="$FIXTURES/logs/drm-fdinfo-idle.log"
	run "$SCRIPTS/benchmark.sh" capabilities
	[ "$status" -eq 1 ]
	[ "$(jq -r '.proofStatus + ":" + .proofReasons' <<<"$output")" = 'failed:telemetry' ]
	jq -e '.encodeSpeed == 1.25' <<<"$output" >/dev/null

	export BENCHMARK_TEST_FDINFO_FIXTURE="$FIXTURES/logs/drm-fdinfo-active.log"
	export BENCHMARK_CAPABILITY_DECODE_FAILURE=1
	run "$SCRIPTS/benchmark.sh" capabilities
	[ "$status" -eq 1 ]
	[ "$(jq -r '.proofStatus + ":" + .proofReasons' <<<"$output")" = 'failed:decode' ]
	unset BENCHMARK_CAPABILITY_DECODE_FAILURE

	export BENCHMARK_CAPABILITY_VMAF_FAILURE=1
	run "$SCRIPTS/benchmark.sh" capabilities
	[ "$status" -eq 1 ]
	[ "$(jq -r '.proofStatus + ":" + .proofReasons' <<<"$output")" = 'failed:vmaf' ]
	unset BENCHMARK_CAPABILITY_VMAF_FAILURE

	export BENCHMARK_TEST_FDINFO_FIXTURE="$FIXTURES/logs/drm-fdinfo-malformed.log"
	run "$SCRIPTS/benchmark.sh" capabilities
	[ "$status" -eq 2 ]
	[ "$(jq -r '.proofStatus + ":" + .proofReasons' <<<"$output")" = 'harness-blocked:telemetry' ]
}

# Catches a capability producer authorizing quality when the retained HDR,
# metric, or frame-field tools are absent from the exact runtime image.
@test "capability proof folds every quality diagnostic readiness failure into status" {
	create_capability_tools
	write_capability_samples
	export BENCHMARK_DISPATCH_IMAGE='docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	export NODE_NAME='talos-03'

	for mutation in \
		'missing-bsf' \
		'missing-libvmaf' \
		'missing-ssim' \
		'missing-psnr' \
		'missing-best-effort-timestamp' \
		'missing-packet-duration' \
		'malformed-key-frame' \
		'malformed-picture-type'; do
		unset BENCHMARK_CAPABILITY_MISSING_FILTER BENCHMARK_CAPABILITY_MISSING_BSF
		unset BENCHMARK_CAPABILITY_FRAME_FIXTURE
		case "$mutation" in
		missing-bsf) export BENCHMARK_CAPABILITY_MISSING_BSF=1 ;;
		missing-libvmaf) export BENCHMARK_CAPABILITY_MISSING_FILTER=libvmaf ;;
		missing-ssim) export BENCHMARK_CAPABILITY_MISSING_FILTER=ssim ;;
		missing-psnr) export BENCHMARK_CAPABILITY_MISSING_FILTER=psnr ;;
		missing-best-effort-timestamp)
			export BENCHMARK_CAPABILITY_FRAME_FIXTURE='{"frames":[{"pkt_duration_time":"0.041667","key_frame":1,"pict_type":"I"}]}'
			;;
		missing-packet-duration)
			export BENCHMARK_CAPABILITY_FRAME_FIXTURE='{"frames":[{"best_effort_timestamp_time":"0.000000","key_frame":1,"pict_type":"I"}]}'
			;;
		malformed-key-frame)
			export BENCHMARK_CAPABILITY_FRAME_FIXTURE='{"frames":[{"best_effort_timestamp_time":"0.000000","pkt_duration_time":"0.041667","key_frame":2,"pict_type":"I"}]}'
			;;
		malformed-picture-type)
			export BENCHMARK_CAPABILITY_FRAME_FIXTURE='{"frames":[{"best_effort_timestamp_time":"0.000000","pkt_duration_time":"0.041667","key_frame":1,"pict_type":"X"}]}'
			;;
		esac
		run "$SCRIPTS/benchmark.sh" capabilities
		[ "$status" -eq 1 ]
		actual="$(jq -r '.proofStatus + ":" + .proofReasons' <<<"$output")"
		[ "$actual" = 'failed:quality-capabilities' ] || {
			echo "unexpected quality capability proof for $mutation: $actual" >&3
			return 1
		}
		[ "$(jq -r '[.diagnosticCapabilities[] | select(. == "failed")] | length' <<<"$output")" -eq 1 ]
	done
}

# Catches capability mode running even a synthetic ffmpeg encode before the
# immutable image chosen by dispatch is proven identical to committed source.
@test "capabilities rejects missing or mismatched dispatch image before ffmpeg" {
	create_capability_tools
	write_capability_samples
	export NODE_NAME='talos-03'

	unset BENCHMARK_DISPATCH_IMAGE
	run "$SCRIPTS/benchmark.sh" capabilities
	[ "$status" -eq 65 ]
	[ "$output" = 'runtime image identity does not match dispatched source' ]
	[ ! -s "$BENCHMARK_COMMAND_LOG" ]

	export BENCHMARK_DISPATCH_IMAGE='docker.io/linuxserver/ffmpeg@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	run "$SCRIPTS/benchmark.sh" capabilities
	[ "$status" -eq 65 ]
	[ "$output" = 'runtime image identity does not match dispatched source' ]
	[ ! -s "$BENCHMARK_COMMAND_LOG" ]
}

@test "capabilities refuses missing or malformed configured immutable image evidence" {
	create_capability_tools
	export BENCHMARK_SAMPLES_FILE="$BATS_TEST_TMPDIR/missing-image.json"
	jq -n '{schemaVersion: 1}' >"$BENCHMARK_SAMPLES_FILE"
	run "$SCRIPTS/benchmark.sh" capabilities
	[ "$status" -ne 0 ]
	[[ "$output" != *'"status":"passed"'* ]]

	write_capability_samples 'docker.io/linuxserver/ffmpeg:latest'
	run "$SCRIPTS/benchmark.sh" capabilities
	[ "$status" -ne 0 ]
	[[ "$output" != *'"status":"passed"'* ]]
}

# Catches a production break where the requested ICQ controls, lossless clip
# extraction, stream preservation, or reference/distorted ordering drifts.
@test "quality commands preserve exact clip QSV VMAF SSIM and PSNR contracts" {
	for setting in 16 30; do
		if [[ "$setting" == '16' ]]; then source='/media/avc.mkv'; else source='/media/hdr10.mkv'; fi
		run "$SCRIPTS/benchmark.sh" _test commands \
			"$source" '00:17:23.456' '/scratch/detail.mkv' \
			"/scratch/qsv-$setting.mkv" '/scratch/vmaf.json' "$setting"
		[ "$status" -eq 0 ]
		commands="$output"

		run jq -e --arg setting "$setting" --arg source "$source" '
		.clip == ["ffmpeg","-nostdin","-v","error","-ss","00:17:23.456","-i",$source,"-t","90","-map","0","-c","copy","/scratch/detail.mkv"] and
		.qsv == ["ffmpeg","-nostdin","-v","verbose","-init_hw_device","qsv=hw:/dev/dri/renderD128","-filter_hw_device","hw","-i","/scratch/detail.mkv","-map","0","-c:v","hevc_qsv","-preset","veryslow","-global_quality",$setting,"-look_ahead","0","-extbrc","0","-c:a","copy","-c:s","copy","-map_metadata","0","-map_chapters","0",("/scratch/qsv-" + $setting + ".mkv")] and
		.vmaf == ["ffmpeg","-nostdin","-v","error","-i",("/scratch/qsv-" + $setting + ".mkv"),"-i","/scratch/detail.mkv","-lavfi","[0:v][1:v]libvmaf=model=version=vmaf_4k_v0.6.1:log_fmt=json:log_path=/scratch/vmaf.json","-f","null","-"] and
		.ssim == ["ffmpeg","-nostdin","-v","info","-i",("/scratch/qsv-" + $setting + ".mkv"),"-i","/scratch/detail.mkv","-lavfi","[0:v][1:v]ssim","-f","null","-"] and
		.psnr == ["ffmpeg","-nostdin","-v","info","-i",("/scratch/qsv-" + $setting + ".mkv"),"-i","/scratch/detail.mkv","-lavfi","[0:v][1:v]psnr","-f","null","-"]
	' <<<"$commands"
		[ "$status" -eq 0 ]
	done
}

@test "representative AVC ICQ 16 row publishes valid evidence and ranks" {
	prepare_representative_run sample-avc avc "$FIXTURES/media/avc-8bit.mkv"
	append_representative_dv_skip
	start_representative_plan
	append_representative_plan_row sample-avc detail 16

	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 0 ]
	run_id="$output"
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	results="$run_dir/results.csv"
	[ "$(awk 'END {print NR}' "$results")" -eq 2 ]
	run awk -F, 'NR == 2 {print $3 ":" $4 ":" $6 ":" $7 ":" $8 ":" $9 ":" $10 ":" $24 ":" $30}' "$results"
	[ "$status" -eq 0 ]
	[ "$output" = 'sample-avc:avc:detail:qsv:16:ICQ:passed:passed:passed' ]
	evidence="$run_dir/$(awk -F, 'NR == 2 {print $40}' "$results")"
	digest="sha256:$(sha256sum "$evidence" | awk 'NR == 1 { print $1 }')"
	[ "$(awk -F, 'NR == 2 {print $41}' "$results")" = "$digest" ]
	run jq -e '
		keys == ["clipId","cohort","globalQuality","hdr","psnr","runId","sampleId",
			"schemaVersion","sourceSha256","ssim","strategyId","vmaf"] and
		.schemaVersion == 1 and .strategyId == "qsv-hevc-icq-v1" and
		.sampleId == "sample-avc" and .cohort == "avc" and .clipId == "detail" and
		.globalQuality == 16 and .hdr == null and
		(.vmaf.harmonicMean >= 95) and (.vmaf.onePercentLow >= 90) and
		(.ssim | type == "number") and (.psnr | type == "number")
	' "$evidence"
	[ "$status" -eq 0 ]
	run jq -e '.cohorts.avc.status == "eligible" and
		.cohorts.avc.candidates == [{globalQuality:16,medianReductionPercent:0}]' \
		"$run_dir/quality-candidates.json"
	[ "$status" -eq 0 ]
	[ "$(rg -c -- ' -t 90 -map 0 -c copy ' "$BENCHMARK_COMMAND_LOG")" -eq 1 ]
	[ "$(rg -c -- 'sample-avc-detail-source.mkv .* -global_quality 16 -look_ahead 0 -extbrc 0' "$BENCHMARK_COMMAND_LOG")" -eq 1 ]
	[ "$(rg -c -- 'sample-avc-detail-qsv-16-attempt-1.mkv -map 0:v:0 -f null -' "$BENCHMARK_COMMAND_LOG")" -eq 1 ]
	[ "$(rg -c -- 'sample-avc-detail-qsv-16-attempt-1-vmaf.json' "$BENCHMARK_COMMAND_LOG")" -eq 1 ]
	[ "$(rg -c -- '\[0:v\]\[1:v\]ssim' "$BENCHMARK_COMMAND_LOG")" -eq 1 ]
	[ "$(rg -c -- '\[0:v\]\[1:v\]psnr' "$BENCHMARK_COMMAND_LOG")" -eq 1 ]
	[ "$(<"$run_dir/skips.csv")" = 'dolby-vision-sisu,dolby-vision,detection-only' ]
	! rg -Fq 'dolby-vision-sisu' "$BENCHMARK_COMMAND_LOG"
	[ "$(find "$BENCHMARK_SCRATCH" -type f | wc -l | tr -d ' ')" -eq 0 ]
}

@test "representative HDR10 ICQ 30 row preserves HDR and ranks" {
	prepare_representative_run sample-hdr hdr10 "$FIXTURES/media/hdr10-hevc-10bit.mkv"
	start_representative_plan
	append_representative_plan_row sample-hdr detail 30

	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 0 ]
	run_id="$output"
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	results="$run_dir/results.csv"
	[ "$(awk 'END {print NR}' "$results")" -eq 2 ]
	run awk -F, 'NR == 2 {print $3 ":" $4 ":" $6 ":" $7 ":" $8 ":" $9 ":" $10 ":" $24 ":" $30}' "$results"
	[ "$status" -eq 0 ]
	[ "$output" = 'sample-hdr:hdr10:detail:qsv:30:ICQ:passed:passed:passed' ]
	evidence="$run_dir/$(awk -F, 'NR == 2 {print $40}' "$results")"
	run jq -e '.hdr.classification == "preserved" and
		.hdr.reasons == ["source-clip-encoded-metadata-agree"] and
		(.hdr.normalizedOracle | type == "object" and length > 0)' "$evidence"
	[ "$status" -eq 0 ]
	run jq -e '.cohorts.hdr10.status == "eligible" and
		.cohorts.hdr10.candidates == [{globalQuality:30,medianReductionPercent:0}]' \
		"$run_dir/quality-candidates.json"
	[ "$status" -eq 0 ]
	[ "$(rg -c -- ' -t 90 -map 0 -c copy ' "$BENCHMARK_COMMAND_LOG")" -eq 1 ]
	[ "$(rg -c -- '-global_quality 30 -look_ahead 0 -extbrc 0' "$BENCHMARK_COMMAND_LOG")" -eq 1 ]
	[ "$(rg -c -- 'sample-hdr-detail-qsv-30-attempt-1.mkv -map 0:v:0 -f null -' "$BENCHMARK_COMMAND_LOG")" -eq 1 ]
	[ "$(rg -c -- 'libvmaf=model=version=vmaf_4k_v0.6.1:log_fmt=json:log_path=' "$BENCHMARK_COMMAND_LOG")" -eq 1 ]
	[ "$(rg -c -- '\[0:v\]\[1:v\]ssim' "$BENCHMARK_COMMAND_LOG")" -eq 1 ]
	[ "$(rg -c -- '\[0:v\]\[1:v\]psnr' "$BENCHMARK_COMMAND_LOG")" -eq 1 ]
	[ "$(rg -c -- '-bsf:v trace_headers' "$BENCHMARK_COMMAND_LOG")" -eq 3 ]
	[ "$(find "$BENCHMARK_SCRATCH" -type f | wc -l | tr -d ' ')" -eq 0 ]
}

@test "invalid quality row records failure cleans scratch and continues without a candidate" {
	prepare_representative_run sample-invalid avc "$FIXTURES/media/avc-8bit.mkv"
	jq --arg path "$source_media" --arg sha "$source_sha" --argjson size "$source_size" '
		.qualityPanel += [{id:"sample-valid",cohort:"avc",path:$path,sizeBytes:$size,
			sha256:$sha,clips:{detail:"00:00:01.000"}}]
	' "$BENCHMARK_SAMPLES_FILE" >"$BENCHMARK_SAMPLES_FILE.tmp"
	mv -f -- "$BENCHMARK_SAMPLES_FILE.tmp" "$BENCHMARK_SAMPLES_FILE"
	start_representative_plan
	append_representative_plan_row sample-invalid detail 16
	append_representative_plan_row sample-valid detail 30
	export BENCHMARK_TEST_INVALID_OUTPUT_MATCH='sample-invalid-detail-qsv-16-attempt-1'
	export BENCHMARK_TEST_INVALID_OUTPUT_PROBE="$FIXTURES/metrics/probe-output-invalid.json"

	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 0 ]
	run_id="$output"
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	run awk -F, 'NR > 1 {print $3 ":" $8 ":" $10}' "$run_dir/results.csv"
	[ "$status" -eq 0 ]
	[ "$output" = $'sample-invalid:16:invalid\nsample-valid:30:passed' ]
	run jq -e '.cohorts.avc.status == "no-verdict" and .cohorts.avc.candidates == []' \
		"$run_dir/quality-candidates.json"
	[ "$status" -eq 0 ]
	[ "$(rg -c -- ' -t 90 -map 0 -c copy ' "$BENCHMARK_COMMAND_LOG")" -eq 2 ]
	[ "$(rg -c -- 'sample-(invalid|valid)-detail-source.mkv .* -global_quality (16|30) -look_ahead 0 -extbrc 0' "$BENCHMARK_COMMAND_LOG")" -eq 2 ]
	[ "$(rg -c -- 'qsv-(16|30)-attempt-1.mkv -map 0:v:0 -f null -' "$BENCHMARK_COMMAND_LOG")" -eq 2 ]
	[ "$(rg -c -- 'libvmaf=model=version=vmaf_4k_v0.6.1:log_fmt=json:log_path=' "$BENCHMARK_COMMAND_LOG")" -eq 2 ]
	[ "$(rg -c -- '\[0:v\]\[1:v\]ssim' "$BENCHMARK_COMMAND_LOG")" -eq 2 ]
	[ "$(rg -c -- '\[0:v\]\[1:v\]psnr' "$BENCHMARK_COMMAND_LOG")" -eq 2 ]
	[ "$(find "$BENCHMARK_SCRATCH" -type f | wc -l | tr -d ' ')" -eq 0 ]
}

@test "passed quality resume skips measured work without duplicating the row" {
	prepare_representative_run sample-avc avc "$FIXTURES/media/avc-8bit.mkv"
	start_representative_plan
	append_representative_plan_row sample-avc detail 16
	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 0 ]
	run_id="$output"
	results="$BENCHMARK_OUT/runs/$run_id/results.csv"
	before="$BATS_TEST_TMPDIR/results-before.csv"
	cp "$results" "$before"
	: >"$BENCHMARK_COMMAND_LOG"

	run "$SCRIPTS/benchmark.sh" quality "$run_id"
	[ "$status" -eq 0 ]
	[ "$output" = "$run_id" ]
	run cmp -s "$before" "$results"
	[ "$status" -eq 0 ]
	[ "$(awk 'END {print NR}' "$results")" -eq 2 ]
	[ "$(awk -v run="$run_id" '$1 != "sha256sum" && index($0, run) {count += 1} END {print count + 0}' \
		"$BENCHMARK_COMMAND_LOG")" -eq 0 ]
	[ "$(find "$BENCHMARK_SCRATCH" -type f | wc -l | tr -d ' ')" -eq 0 ]
}

# Catches using percentile interpolation or including an odd population's
# overall median in both halves. The approved convention is Tukey hinges:
# median of each half, excluding the overall median when the count is odd.
@test "fdinfo metrics require valid i915 video nanosecond counters" {
	run "$SCRIPTS/benchmark.sh" _test drm-fdinfo-metrics \
		"$FIXTURES/logs/drm-fdinfo-active.log"
	[ "$status" -eq 0 ]
	[ "$output" = '{"status":"available","driver":"i915","video_busy_nanoseconds":800000000,"video_busy_percent":40.000000,"reason":""}' ]

	run "$SCRIPTS/benchmark.sh" _test drm-fdinfo-metrics \
		"$FIXTURES/logs/drm-fdinfo-idle.log"
	[ "$status" -eq 0 ]
	[ "$output" = '{"status":"available","driver":"i915","video_busy_nanoseconds":0,"video_busy_percent":0.000000,"reason":""}' ]

	run "$SCRIPTS/benchmark.sh" _test drm-fdinfo-metrics \
		"$FIXTURES/logs/drm-fdinfo-malformed.log"
	[ "$status" -eq 0 ]
	[ "$output" = '{"status":"harness-blocked","driver":"i915","video_busy_nanoseconds":0,"video_busy_percent":0.000000,"reason":"malformed-video-counter"}' ]
}

# Catches treating a permitted temporary counter decrease as negative work or
# resetting the baseline and over-counting the later recovery.
@test "fdinfo metrics retain the largest video counter across a regression" {
	run "$SCRIPTS/benchmark.sh" _test drm-fdinfo-metrics \
		"$FIXTURES/logs/drm-fdinfo-regression.log"
	[ "$status" -eq 0 ]
	[ "$output" = '{"status":"available","driver":"i915","video_busy_nanoseconds":80000000,"video_busy_percent":4.000000,"reason":""}' ]
}

# Catches telemetry from a different DRM driver or an invalid capacity being
# accepted as an i915 video-engine oracle.
@test "fdinfo metrics reject wrong drivers and invalid video capacity" {
	wrong_driver="$BATS_TEST_TMPDIR/fdinfo-wrong-driver.log"
	invalid_capacity="$BATS_TEST_TMPDIR/fdinfo-invalid-capacity.log"
	printf '%s\n' \
		'1000000000' 'drm-driver: xe' 'drm-engine-video: 100000000 ns' '' \
		'2000000000' 'drm-driver: xe' 'drm-engine-video: 200000000 ns' \
		>"$wrong_driver"
	printf '%s\n' \
		'1000000000' 'drm-driver: i915' 'drm-engine-video: 100000000 ns' \
		'drm-engine-capacity-video: 0' '' \
		'2000000000' 'drm-driver: i915' 'drm-engine-video: 200000000 ns' \
		'drm-engine-capacity-video: 0' >"$invalid_capacity"

	run "$SCRIPTS/benchmark.sh" _test drm-fdinfo-metrics "$wrong_driver"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.status + ":" + .reason' <<<"$output")" = 'harness-blocked:wrong-driver' ]

	run "$SCRIPTS/benchmark.sh" _test drm-fdinfo-metrics "$invalid_capacity"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.status + ":" + .reason' <<<"$output")" = 'harness-blocked:invalid-video-capacity' ]
}

@test "QSV proof requires phrase-free initialization exact ICQ binding telemetry and progress" {
	run "$SCRIPTS/benchmark.sh" _test qsv-proof \
		0 "$FIXTURES/logs/qsv-icq.log" "$FIXTURES/logs/drm-fdinfo-active.log" 2160
	[ "$status" -eq 0 ]
	run jq -e '.selected_rate_control == "ICQ" and .initialization == "passed" and
		.render_node == "/dev/dri/renderD128" and .drm_driver == "i915" and
		.video_busy_nanoseconds == 800000000 and .qsv_proof == "passed" and
		.suspect_reasons == ""' <<<"$output"
	[ "$status" -eq 0 ]

	for mode in LA_ICQ CQP CBR VBR AVBR QVBR; do
		mode_log="$BATS_TEST_TMPDIR/qsv-$mode.log"
		printf '%s\n' "[hevc_qsv] Runtime selected ratecontrol method: $mode" \
			'frame= 2160 fps=72.0 speed=1.25x' >"$mode_log"
		run "$SCRIPTS/benchmark.sh" _test qsv-proof \
			0 "$mode_log" "$FIXTURES/logs/drm-fdinfo-active.log" 2160
		[ "$status" -eq 0 ]
		[ "$(jq -r '.qsv_proof + ":" + .suspect_reasons' <<<"$output")" = 'failed:rate-control' ]
	done

	for evidence in 'frame= 2160 fps=72.0 speed=1.25x' \
		'[hevc_qsv] Runtime selected ratecontrol method: UNKNOWN' \
		'[hevc_qsv] Requested ratecontrol method: ICQ
frame= 2160 fps=72.0 speed=1.25x'; do
		mode_log="$BATS_TEST_TMPDIR/qsv-unparseable.log"
		printf '%s\n' "$evidence" >"$mode_log"
		run "$SCRIPTS/benchmark.sh" _test qsv-proof \
			0 "$mode_log" "$FIXTURES/logs/drm-fdinfo-active.log" 2160
		[ "$status" -eq 0 ]
		if [[ "$evidence" == frame=* || "$evidence" == *'Requested ratecontrol'* ]]; then
			expected='harness-blocked:rate-control'
		else
			expected='harness-blocked:rate-control;progress'
		fi
		[ "$(jq -r '.qsv_proof + ":" + .suspect_reasons' <<<"$output")" = "$expected" ]
	done

	run "$SCRIPTS/benchmark.sh" _test qsv-proof \
		1 "$FIXTURES/logs/qsv-init-known-failure.log" "$FIXTURES/logs/drm-fdinfo-active.log" 2160
	[ "$status" -eq 0 ]
	[ "$(jq -r '.qsv_proof + ":" + .suspect_reasons' <<<"$output")" = 'failed:initialization;rate-control;progress' ]

	run "$SCRIPTS/benchmark.sh" _test qsv-proof \
		0 "$FIXTURES/logs/qsv-icq.log" "$FIXTURES/logs/drm-fdinfo-idle.log" 2160
	[ "$status" -eq 0 ]
	[ "$(jq -r '.qsv_proof + ":" + .suspect_reasons' <<<"$output")" = 'failed:telemetry' ]

	run "$SCRIPTS/benchmark.sh" _test qsv-proof \
		0 "$FIXTURES/logs/qsv-requested-la-fallback-cqp.log" "$FIXTURES/logs/drm-fdinfo-active.log" 2160
	[ "$status" -eq 0 ]
	[ "$(jq -r '.qsv_proof + ":" + .suspect_reasons' <<<"$output")" = 'failed:rate-control' ]
}

# Catches a generated quality Job publishing unbounded candidate evidence or
# omitting one cohort from the authenticated dispatch-to-runtime completion.
@test "generated quality completion publishes only bounded ranked cohort values" {
	prepare_representative_run sample-hdr hdr10 "$FIXTURES/media/hdr10-hevc-10bit.mkv"
	start_representative_plan
	append_representative_plan_row sample-hdr detail 30
	dispatch_id='20260815T121500Z-deadbeef'
	export BENCHMARK_DISPATCH_CORRELATION_ID="$dispatch_id"

	run "$SCRIPTS/benchmark.sh" quality "$dispatch_id"
	[ "$status" -eq 0 ]
	run jq -e --arg dispatch "$dispatch_id" '
		def cohort:
			type == "object" and keys == ["candidates","status"] and
			(.status == "eligible" or .status == "no-go" or .status == "no-verdict") and
			(.candidates | type == "array" and all(.[];
				type == "object" and keys == ["globalQuality","medianReductionPercent"]));
		type == "object" and
		keys == ["artifactLocation","cohorts","dispatchId","runtimeRunId","schemaVersion","status","strategyId"] and
		.schemaVersion == 2 and .strategyId == "qsv-hevc-icq-v1" and .status == "complete" and
		.dispatchId == $dispatch and
		(.runtimeRunId | test("^20260815T121500Z-[0-9a-f]{8}$")) and
		.artifactLocation == ("/out/runs/" + .runtimeRunId) and
		(.cohorts | type == "object" and keys == ["avc","hdr10","vc1"] and all(.[]; cohort)) and
		.cohorts.avc == {status:"no-verdict",candidates:[]} and
		.cohorts.vc1 == {status:"no-verdict",candidates:[]} and
		.cohorts.hdr10.status == "eligible" and
		(.cohorts.hdr10.candidates | map(.globalQuality)) == [30]
	' <<<"$output"
	[ "$status" -eq 0 ]
	[[ "$output" != *'sample-hdr'* ]]
	[[ "$output" != *'source.mkv'* ]]
	[[ "$output" != *'quality-evidence'* ]]
	[[ "$output" != *'sha256'* ]]
}

@test "quality ranking requires every expected row exactly once" {
	prepare_execution_run
	panel="$(jq -n --arg path "$source_media" --arg sha "$source_sha" --argjson size "$source_size" '[
		{id:"rank-a",cohort:"avc",path:$path,sizeBytes:$size,sha256:$sha,clips:{detail:"00:00:00.000"}},
		{id:"rank-b",cohort:"avc",path:$path,sizeBytes:$size,sha256:$sha,clips:{detail:"00:00:01.000"}}
	]')"
	set_ranking_panel "$panel"
	run_id='20260815T120000Z-e6000001'
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	mkdir -p "$run_dir"
	results="$run_dir/results.csv"
	initialize_quality_results "$results"
	append_quality_result "$results" "$run_id" rank-a avc "$source_sha" detail 16 1 20 96 92 0.99
	append_quality_result "$results" "$run_id" rank-b avc "$source_sha" detail 16 1 30 96 92 0.99
	baseline="$BATS_TEST_TMPDIR/complete-ranking.csv"
	cp "$results" "$baseline"

	run "$SCRIPTS/benchmark.sh" _test rank-quality-candidates "$results" "$BENCHMARK_SAMPLES_FILE" "$run_id"
	[ "$status" -eq 0 ]
	run jq -e '.cohorts.avc.candidates == [{globalQuality:16,medianReductionPercent:25}]' \
		"$run_dir/quality-candidates.json"
	[ "$status" -eq 0 ]

	for mutation in missing duplicate wrong-source wrong-setting extra; do
		cp "$baseline" "$results"
		case "$mutation" in
		missing) sed -n '1,2p' "$results" >"$results.tmp" ;;
		duplicate) {
			cp "$results" "$results.tmp"
			sed -n '2p' "$results" >>"$results.tmp"
		} ;;
		wrong-source) awk -F, 'BEGIN {OFS=FS} NR == 2 {$5="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"} {print}' "$results" >"$results.tmp" ;;
		wrong-setting) awk -F, 'BEGIN {OFS=FS} NR == 2 {$8=17} {print}' "$results" >"$results.tmp" ;;
		extra) {
			cp "$results" "$results.tmp"
			sed -n '2p' "$results" | sed 's/,rank-a,/,rank-extra,/' >>"$results.tmp"
		} ;;
		esac
		mv -f -- "$results.tmp" "$results"
		run "$SCRIPTS/benchmark.sh" _test rank-quality-candidates "$results" "$BENCHMARK_SAMPLES_FILE" "$run_id"
		if [[ "$mutation" == missing || "$mutation" == duplicate ]]; then
			[ "$status" -eq 0 ]
			run jq -e '.cohorts.avc.candidates == []' "$run_dir/quality-candidates.json"
			[ "$status" -eq 0 ]
		else
			[ "$status" -eq 65 ] || {
				echo "ranking accepted $mutation row: status=$status output=$output" >&3
				return 1
			}
		fi
	done
}

@test "quality ranking enforces exact thresholds and reduction tie-break" {
	prepare_execution_run
	panel="$(jq -n --arg path "$source_media" --arg sha "$source_sha" --argjson size "$source_size" '[
		{id:"rank-avc",cohort:"avc",path:$path,sizeBytes:$size,sha256:$sha,clips:{detail:"00:00:00.000"}}
	]')"
	set_ranking_panel "$panel"
	run_id='20260815T120000Z-e7000001'
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	mkdir -p "$run_dir"
	results="$run_dir/results.csv"
	initialize_quality_results "$results"
	append_quality_result "$results" "$run_id" rank-avc avc "$source_sha" detail 16 1 20 95 90 0.99
	append_quality_result "$results" "$run_id" rank-avc avc "$source_sha" detail 18 1 90 94.999 90 0.99
	append_quality_result "$results" "$run_id" rank-avc avc "$source_sha" detail 20 1 90 95 89.999 0.99
	append_quality_result "$results" "$run_id" rank-avc avc "$source_sha" detail 22 1 30 96 92 0.99
	append_quality_result "$results" "$run_id" rank-avc avc "$source_sha" detail 24 1 30 96 92 0.99
	append_quality_result "$results" "$run_id" rank-avc avc "$source_sha" detail 26 1 40 96 92 0.99

	run "$SCRIPTS/benchmark.sh" _test rank-quality-candidates "$results" "$BENCHMARK_SAMPLES_FILE" "$run_id"
	[ "$status" -eq 0 ]
	run jq -e '.cohorts.avc.candidates == [
		{globalQuality:26,medianReductionPercent:40},
		{globalQuality:22,medianReductionPercent:30},
		{globalQuality:24,medianReductionPercent:30},
		{globalQuality:16,medianReductionPercent:20}
	]' "$run_dir/quality-candidates.json"
	[ "$status" -eq 0 ]
}

@test "quality candidates distinguish incomplete no-verdict from complete no-go" {
	prepare_execution_run
	panel="$(jq -n --arg path "$source_media" --arg sha "$source_sha" --argjson size "$source_size" '[
		{id:"rank-avc",cohort:"avc",path:$path,sizeBytes:$size,sha256:$sha,clips:{detail:"00:00:00.000"}},
		{id:"rank-hdr",cohort:"hdr10",path:$path,sizeBytes:$size,sha256:$sha,clips:{detail:"00:00:01.000"}},
		{id:"rank-vc1",cohort:"vc1",path:$path,sizeBytes:$size,sha256:$sha,clips:{detail:"00:00:02.000"}}
	]')"
	set_ranking_panel "$panel"
	run_id='20260815T120000Z-e8000001'
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	mkdir -p "$run_dir"
	results="$run_dir/results.csv"
	initialize_quality_results "$results"
	append_quality_result "$results" "$run_id" rank-avc avc "$source_sha" detail 16 1 25 96 92 0.99
	for setting in 16 18 20 22 24 26 28 30; do
		append_quality_result "$results" "$run_id" rank-hdr hdr10 "$source_sha" detail \
			"$setting" 1 30 94.999 92 0.99
	done

	run "$SCRIPTS/benchmark.sh" _test rank-quality-candidates "$results" "$BENCHMARK_SAMPLES_FILE" "$run_id"
	[ "$status" -eq 0 ]
	results_digest="sha256:$(sha256sum "$results" | awk 'NR == 1 { print $1 }')"
	run jq -e --arg run "$run_id" --arg digest "$results_digest" '
		keys == ["cohorts","qualityRunId","resultsSchemaVersion","resultsSha256","schemaVersion","strategyId"] and
		.schemaVersion == 2 and .strategyId == "qsv-hevc-icq-v1" and
		.qualityRunId == $run and .resultsSchemaVersion == 3 and .resultsSha256 == $digest and
		(.cohorts | keys == ["avc","hdr10","vc1"]) and
		.cohorts.avc == {status:"eligible",expectedClipCount:1,
			candidates:[{globalQuality:16,medianReductionPercent:25}]} and
		.cohorts.hdr10 == {status:"no-go",expectedClipCount:1,candidates:[],reason:"no-objective-candidate"} and
		.cohorts.vc1 == {status:"no-verdict",expectedClipCount:1,candidates:[],reason:"incomplete-evidence"}
	' "$run_dir/quality-candidates.json"
	[ "$status" -eq 0 ]
}

@test "quality attempts increase and retain immutable evidence names" {
	run_id='20260802T120000Z-aaaaaaaa'
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	mkdir -p "$run_dir"
	results="$run_dir/results.csv"
	run "$SCRIPTS/benchmark.sh" _test results-header
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" >"$results"

	for attempt in 1 3; do
		bound="$BATS_TEST_TMPDIR/attempt-$attempt.json"
		bind_quality_fixture_evidence "$run_id" "$FIXTURES/metrics/variant-invalid-output.json" \
			"$attempt" "$bound"
		printf '%s\n' "$(jq -r '[$run,.panel,.sample_id,.cohort,.source_sha256,.clip_id,.encoder,
			.requested_setting,.selected_rate_control,"invalid",$attempt,.input_bytes,.output_bytes,
			.reduction_percent,.input_bit_rate,.output_bit_rate,.wall_seconds,.encode_fps,.encode_speed,
			.vmaf_harmonic_mean,.vmaf_1pct_low,.ssim,.gpu_busy_percent,.qsv_proof,.validation_codec,
			.validation_duration,.validation_resolution,.validation_frame_rate,.validation_bit_depth,
			.validation_hdr,.validation_audio_tracks,.validation_subtitle_tracks,.validation_chapters,
			.validation_failures,.log_path,"discarded",.strategy_id,.qsv_initialization,
			.video_busy_nanoseconds,.quality_evidence_path,.quality_evidence_sha256] | @csv' \
			--arg run "$run_id" --argjson attempt "$attempt" "$bound" | tr -d '"')" >>"$results"
	done

	bound="$BATS_TEST_TMPDIR/attempt-4.json"
	bind_quality_fixture_evidence "$run_id" "$FIXTURES/metrics/variant-passed.json" 4 "$bound"
	scratch_output="$BENCHMARK_SCRATCH/attempt-4.mkv"
	printf '%s' 'encoded bytes' >"$scratch_output"
	run "$SCRIPTS/benchmark.sh" _test record-result "$run_id" "$bound" "$scratch_output"
	[ "$status" -eq 0 ]
	[ "$output" = '{"status":"passed","attempt":4,"output_disposition":"discarded"}' ]
	run awk -F, 'NR > 1 {print $11 ":" $40}' "$results"
	[ "$status" -eq 0 ]
	[ "$output" = $'1:quality-evidence/sample-avc-detail-qsv-22-attempt-1.json\n3:quality-evidence/sample-avc-detail-qsv-22-attempt-3.json\n4:quality-evidence/sample-avc-detail-qsv-22-attempt-4.json' ]
	[ "$(find "$run_dir/quality-evidence" -type f -name '*.json' | wc -l | tr -d ' ')" -eq 3 ]
}

# Catches resume identity omitting the production commands whose bytes and
# parameters determine every measured variant.
@test "quality manifest binds the clip command and all eight QSV command identities" {
	prepare_execution_run
	run "$SCRIPTS/benchmark.sh" _test encoder-commands quality
	[ "$status" -eq 0 ]
	commands="$output"
	expected="$BATS_TEST_TMPDIR/expected-encoder-commands.json"
	jq -n -c '[
		"ffmpeg -nostdin -v error -ss <timestamp> -i <source> -t 90 -map 0 -c copy <clip>",
		"ffmpeg -nostdin -v verbose -init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw -i <input> -map 0 -c:v hevc_qsv -preset veryslow -global_quality 16 -look_ahead 0 -extbrc 0 -c:a copy -c:s copy -map_metadata 0 -map_chapters 0 <output>",
		"ffmpeg -nostdin -v verbose -init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw -i <input> -map 0 -c:v hevc_qsv -preset veryslow -global_quality 18 -look_ahead 0 -extbrc 0 -c:a copy -c:s copy -map_metadata 0 -map_chapters 0 <output>",
		"ffmpeg -nostdin -v verbose -init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw -i <input> -map 0 -c:v hevc_qsv -preset veryslow -global_quality 20 -look_ahead 0 -extbrc 0 -c:a copy -c:s copy -map_metadata 0 -map_chapters 0 <output>",
		"ffmpeg -nostdin -v verbose -init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw -i <input> -map 0 -c:v hevc_qsv -preset veryslow -global_quality 22 -look_ahead 0 -extbrc 0 -c:a copy -c:s copy -map_metadata 0 -map_chapters 0 <output>",
		"ffmpeg -nostdin -v verbose -init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw -i <input> -map 0 -c:v hevc_qsv -preset veryslow -global_quality 24 -look_ahead 0 -extbrc 0 -c:a copy -c:s copy -map_metadata 0 -map_chapters 0 <output>",
		"ffmpeg -nostdin -v verbose -init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw -i <input> -map 0 -c:v hevc_qsv -preset veryslow -global_quality 26 -look_ahead 0 -extbrc 0 -c:a copy -c:s copy -map_metadata 0 -map_chapters 0 <output>",
		"ffmpeg -nostdin -v verbose -init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw -i <input> -map 0 -c:v hevc_qsv -preset veryslow -global_quality 28 -look_ahead 0 -extbrc 0 -c:a copy -c:s copy -map_metadata 0 -map_chapters 0 <output>",
		"ffmpeg -nostdin -v verbose -init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw -i <input> -map 0 -c:v hevc_qsv -preset veryslow -global_quality 30 -look_ahead 0 -extbrc 0 -c:a copy -c:s copy -map_metadata 0 -map_chapters 0 <output>"
	]' >"$expected"
	run jq -e --argjson expected "$(<"$expected")" '. == $expected' <<<"$commands"
	[ "$status" -eq 0 ]

	unset BENCHMARK_IDENTITY_FIXTURE
	export NODE_NAME='talos-03'
	export BENCHMARK_RUNNING_IMAGE="$BENCHMARK_DISPATCH_IMAGE"
	export BENCHMARK_I915_VERSION='fixture-i915'
	export BENCHMARK_VPL_VERSION='fixture-vpl'
	export BENCHMARK_ENCODER_COMMANDS_JSON="$commands"
	run "$SCRIPTS/runmeta.sh" create quality
	[ "$status" -eq 0 ]
	run_id="$output"
	manifest="$BENCHMARK_OUT/runs/$run_id/manifest.json"
	run jq -e --argjson expected "$(<"$expected")" '.encoderCommands == $expected' "$manifest"
	[ "$status" -eq 0 ]

	export BENCHMARK_ENCODER_COMMANDS_JSON="$(jq -c '.[1] |= sub("global_quality 16"; "global_quality 17")' <<<"$commands")"
	run "$SCRIPTS/runmeta.sh" verify "$run_id"
	[ "$status" -eq 1 ]
	[[ "$output" == *'identity mismatch: encoderCommands.1'* ]]
}

# Catches quality evidence publication that is not atomically bound to the
# evaluated metrics and HDR oracle.
@test "quality evidence publication is atomic and never overwrites a destination" {
	prepare_representative_run sample-avc avc "$FIXTURES/media/avc-8bit.mkv"
	start_representative_plan
	append_representative_plan_row sample-avc detail 16
	competitor="$BATS_TEST_TMPDIR/competing-evidence.json"
	printf '%s\n' '{"competing":"evidence"}' >"$competitor"
	chmod 0640 "$competitor"
	competitor_before="$BATS_TEST_TMPDIR/competing-evidence-before.txt"
	competitor_after="$BATS_TEST_TMPDIR/competing-evidence-after.txt"
	snapshot_regular_file_state "$competitor" "$competitor_before"
	export BENCHMARK_TEST_QUALITY_EVIDENCE_COMPETITOR_SETTING=16
	export BENCHMARK_TEST_QUALITY_EVIDENCE_COMPETITOR_FILE="$competitor"

	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 0 ]
	run_id="$output"
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	evidence="$run_dir/quality-evidence/sample-avc-detail-qsv-16-attempt-1.json"
	snapshot_regular_file_state "$evidence" "$competitor_after"
	run cmp -s "$competitor_before" "$competitor_after"
	[ "$status" -eq 0 ]
	run cmp -s "$competitor" "$evidence"
	[ "$status" -eq 0 ]
	[ "$(awk -F, 'NR > 1 && $8 == 16 { count += 1 } END { print count + 0 }' "$run_dir/results.csv")" -eq 0 ]
	[ "$(find "$run_dir/logs" -type f -name '*qsv-16-attempt-*-validation.json' -exec jq -r '.validation_failures' {} \;)" = 'quality-evidence' ]
	[ -z "$(find "$run_dir/quality-evidence" -mindepth 1 \( -name '.*.tmp.*' -o -name '.*.publish.lock' \) -print)" ]
	assert_quality_evidence_does_not_link_inside_directory
	assert_quality_evidence_does_not_follow_symlinked_directory
}

# Catches the hard-link tool treating the exact destination as a directory and
# installing the staged basename inside it before row validation fails.
assert_quality_evidence_does_not_link_inside_directory() {
	rm -rf -- "$BENCHMARK_OUT" "$BENCHMARK_SCRATCH"
	mkdir -p "$BENCHMARK_OUT/runs" "$BENCHMARK_SCRATCH"
	unset BENCHMARK_TEST_QUALITY_EVIDENCE_COMPETITOR_SETTING
	unset BENCHMARK_TEST_QUALITY_EVIDENCE_COMPETITOR_FILE
	prepare_representative_run sample-avc avc "$FIXTURES/media/avc-8bit.mkv"
	start_representative_plan
	append_representative_plan_row sample-avc detail 16
	export BENCHMARK_TEST_FAIL_RESULT_APPEND=1
	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 74 ]
	run_id="$(find "$BENCHMARK_OUT/runs" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)"
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	evidence_directory="$run_dir/quality-evidence"
	evidence="$evidence_directory/sample-avc-detail-qsv-16-attempt-1.json"
	[ -f "$evidence" ]
	rm "$evidence"
	mkdir "$evidence"
	printf '%s\n' 'directory marker' >"$evidence/marker"
	before="$BATS_TEST_TMPDIR/directory-before.txt"
	after="$BATS_TEST_TMPDIR/directory-after.txt"
	snapshot_tree_state "$evidence" "$before"

	unset BENCHMARK_TEST_FAIL_RESULT_APPEND
	run "$SCRIPTS/benchmark.sh" quality "$run_id"
	[ "$status" -eq 0 ]
	[ "$output" = "$run_id" ]
	[ -d "$evidence" ]
	[ ! -L "$evidence" ]
	snapshot_tree_state "$evidence" "$after"
	run cmp -s "$before" "$after"
	[ "$status" -eq 0 ]
	[ "$(awk -F, 'NR > 1 && $8 == 16 { count += 1 } END { print count + 0 }' "$run_dir/results.csv")" -eq 0 ]
	[ "$(find "$run_dir/logs" -type f -name '*qsv-16-attempt-*-validation.json' -exec jq -r '.validation_failures' {} \;)" = 'quality-evidence' ]
	[ -z "$(find "$evidence_directory" -maxdepth 1 -type f -name '.*.tmp.*' -print)" ]
}

# Catches the hard-link tool following a symlinked destination directory and
# publishing outside the confined run evidence directory.
assert_quality_evidence_does_not_follow_symlinked_directory() {
	rm -rf -- "$BENCHMARK_OUT" "$BENCHMARK_SCRATCH"
	mkdir -p "$BENCHMARK_OUT/runs" "$BENCHMARK_SCRATCH"
	unset BENCHMARK_TEST_QUALITY_EVIDENCE_COMPETITOR_SETTING
	unset BENCHMARK_TEST_QUALITY_EVIDENCE_COMPETITOR_FILE
	prepare_representative_run sample-avc avc "$FIXTURES/media/avc-8bit.mkv"
	start_representative_plan
	append_representative_plan_row sample-avc detail 16
	export BENCHMARK_TEST_FAIL_RESULT_APPEND=1
	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 74 ]
	run_id="$(find "$BENCHMARK_OUT/runs" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)"
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	evidence_directory="$run_dir/quality-evidence"
	evidence="$evidence_directory/sample-avc-detail-qsv-16-attempt-1.json"
	outside="$BATS_TEST_TMPDIR/competing-directory"
	[ -f "$evidence" ]
	rm "$evidence"
	mkdir "$outside"
	printf '%s\n' 'outside marker' >"$outside/marker"
	ln -s "$outside" "$evidence"
	before="$BATS_TEST_TMPDIR/symlink-directory-before.txt"
	after="$BATS_TEST_TMPDIR/symlink-directory-after.txt"
	snapshot_tree_state "$outside" "$before"

	unset BENCHMARK_TEST_FAIL_RESULT_APPEND
	run "$SCRIPTS/benchmark.sh" quality "$run_id"
	[ "$status" -eq 0 ]
	[ "$output" = "$run_id" ]
	[ -L "$evidence" ]
	[ "$(readlink "$evidence")" = "$outside" ]
	snapshot_tree_state "$outside" "$after"
	run cmp -s "$before" "$after"
	[ "$status" -eq 0 ]
	[ "$(awk -F, 'NR > 1 && $8 == 16 { count += 1 } END { print count + 0 }' "$run_dir/results.csv")" -eq 0 ]
	[ "$(find "$run_dir/logs" -type f -name '*qsv-16-attempt-*-validation.json' -exec jq -r '.validation_failures' {} \;)" = 'quality-evidence' ]
	[ -z "$(find "$evidence_directory" -maxdepth 1 -type f -name '.*.tmp.*' -print)" ]
}

# Catches extending the evidence reference to modes that do not produce the
# bounded quality document.
@test "runtime pre-encode gate rejects sample size or hash drift before production encode" {
	prepare_execution_run
	yq -i -o=json '.qualityPanel[0].sizeBytes = 999' "$BENCHMARK_SAMPLES_FILE"
	: >"$BENCHMARK_COMMAND_LOG"
	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -ne 0 ]
	[ "$output" = 'sample size mismatch: sample-hdr' ]
	rg -Fq 'testsrc2=size=1920x1080:rate=30' "$BENCHMARK_COMMAND_LOG"
	! rg -Fq "$source_media" "$BENCHMARK_COMMAND_LOG"
	! rg -q '^sha256sum ' "$BENCHMARK_COMMAND_LOG"

	prepare_execution_run
	yq -i -o=json '.qualityPanel[0].sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$BENCHMARK_SAMPLES_FILE"
	: >"$BENCHMARK_COMMAND_LOG"
	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -ne 0 ]
	[ "$output" = 'sample hash mismatch: sample-hdr' ]
	rg -Fq 'testsrc2=size=1920x1080:rate=30' "$BENCHMARK_COMMAND_LOG"
	rg -Fq "sha256sum $source_media" "$BENCHMARK_COMMAND_LOG"
	awk -v source="$source_media" '$0 !~ /^sha256sum / && index($0, source) {bad=1} END {exit bad}' "$BENCHMARK_COMMAND_LOG"
}

# Catches an assigned-node proof running after source hashing or run creation,
# which would make a scheduler mismatch expensive before it fails closed.
@test "assigned-node capability block happens before source hash and run creation" {
	prepare_execution_run
	export BENCHMARK_TEST_FDINFO_FIXTURE="$FIXTURES/logs/drm-fdinfo-malformed.log"
	: >"$BENCHMARK_COMMAND_LOG"

	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 2 ]
	! rg -q '^sha256sum ' "$BENCHMARK_COMMAND_LOG"
	[ "$(find "$BENCHMARK_OUT/runs" -mindepth 1 -print | wc -l | tr -d ' ')" -eq 0 ]
	[ "$(find "$BENCHMARK_SCRATCH" -mindepth 1 -print | wc -l | tr -d ' ')" -eq 0 ]
}

# Catches the production Job depending on test-only GPU identity variables or
# discovering a missing manifest identity only after hashing the source panel.
@test "quality derives GPU runtime identity from its assigned-node proof before source hashing" {
	prepare_execution_run
	unset BENCHMARK_IDENTITY_FIXTURE BENCHMARK_I915_VERSION BENCHMARK_VPL_VERSION
	export BENCHMARK_RUNNING_IMAGE="$BENCHMARK_DISPATCH_IMAGE"
	: >"$BENCHMARK_COMMAND_LOG"

	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 0 ]
	run_id="$output"
	manifest="$BENCHMARK_OUT/runs/$run_id/manifest.json"
	run jq -e '
		.gpu.i915 == ("driver=i915;kernel=" + .node.kernel) and
		.gpu.vpl == "backend=qsv;ffmpeg=8.1.2"
	' "$manifest"
	[ "$status" -eq 0 ]
	awk '
		/testsrc2=size=1920x1080:rate=30/ { proof = NR }
		/^sha256sum / { hash = NR; exit }
		END { exit !(proof > 0 && hash > proof) }
	' "$BENCHMARK_COMMAND_LOG"
}

# Catches a capability probe that stops after the first missing runtime command.
@test "capabilities reports every missing runtime command in one run" {
	create_capability_tools
	write_capability_samples '' benchmark-absent-one benchmark-absent-two
	export BENCHMARK_DISPATCH_IMAGE='docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	export NODE_NAME='talos-03'

	run "$SCRIPTS/benchmark.sh" capabilities
	[ "$status" -eq 1 ]
	[[ "$output" == *'runtime image is missing required commands:'* ]]
	[[ "$output" == *'benchmark-absent-one'* ]]
	[[ "$output" == *'benchmark-absent-two'* ]]
}

# Catches the declaration drifting from what the runtime scripts invoke: every
# declared command must resolve on the test host, or the sandbox contracts
# silently degrade into an unrestricted PATH.
@test "declared runtime commands all resolve for the sandbox contracts" {
	load helpers/runtime-sandbox
	samples="$BATS_TEST_DIRNAME/../app/samples.yaml"

	run runtime_sandbox_path "$samples" "$BATS_TEST_TMPDIR/sandbox"
	[ "$status" -eq 0 ]
	run bash -c "ls '$output' | wc -l"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | tr -d ' ')" -ge 25 ]
}

# Catches the builtin declaration parser drifting from the JSON it reads. The
# probe cannot use jq here -- it must report a missing jq rather than die on it --
# so jq is the independent oracle for that parse.
@test "builtin declaration parser agrees with jq on the deployed samples" {
	samples="$BATS_TEST_DIRNAME/../app/samples.yaml"
	inner="$BATS_TEST_TMPDIR/inner-samples.json"
	yq -r '.data."samples.json"' "$samples" >"$inner"

	for key in requiredCommands; do
		run "$SCRIPTS/benchmark.sh" _test declared-commands "$inner" "$key"
		[ "$status" -eq 0 ]
		jq_list="$(jq -r ".runtime.$key[]" "$inner")"
		[ -n "$jq_list" ]
		[ "$output" = "$jq_list" ]
	done
}

# Catches the QSV telemetry parsers depending on a tool the runtime image does
# not provide. These parsers decide whether an encode really used the hardware
# path, so a silent "command not found" here would let CPU fallback pass as QSV.
@test "QSV proof parses telemetry without rg, yq or python3" {
	load helpers/runtime-sandbox
	samples="$BATS_TEST_DIRNAME/../app/samples.yaml"

	run runtime_sandbox_path "$samples" "$BATS_TEST_TMPDIR/sandbox" python3 rg yq
	[ "$status" -eq 0 ]
	sandbox="$output"

	run env PATH="$sandbox" BENCHMARK_TEST_MODE=1 "$SCRIPTS/benchmark.sh" _test qsv-proof \
		0 "$FIXTURES/logs/qsv-icq.log" "$FIXTURES/logs/drm-fdinfo-active.log" 2160
	[ "$status" -eq 0 ]
	[[ "$output" == *'"selected_rate_control":"ICQ"'* ]]
	[[ "$output" == *'"qsv_proof":"passed"'* ]]

	# The fallback case must stay detectable on the reduced command surface: a
	# parser that silently returned "unknown" would mark a CPU encode as QSV.
	run env PATH="$sandbox" BENCHMARK_TEST_MODE=1 "$SCRIPTS/benchmark.sh" _test qsv-proof \
		0 "$FIXTURES/logs/qsv-fallback.log" "$FIXTURES/logs/drm-fdinfo-active.log" 2160
	[ "$status" -eq 0 ]
	[[ "$output" == *'"selected_rate_control":"CQP"'* ]]
	[[ "$output" == *'"qsv_proof":"failed"'* ]]
}

# Catches the capability probe depending on any tool the runtime image lacks. The
# probe reads the samples artifact and the encoder listings, so it exercises the
# jq and grep paths the QSV-telemetry contract never reaches. Now that no runtime
# script needs python3, rg or yq, this runs against the image's real surface.
@test "capability probe runs on the image's real command surface" {
	load helpers/runtime-sandbox
	create_capability_tools
	write_capability_samples
	export BENCHMARK_DISPATCH_IMAGE='docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	export NODE_NAME='talos-03'
	samples="$BATS_TEST_DIRNAME/../app/samples.yaml"

	run runtime_sandbox_path "$samples" "$BATS_TEST_TMPDIR/probe-sandbox" python3 rg yq
	[ "$status" -eq 0 ]
	sandbox="$output"

	run env PATH="$stub_bin:$sandbox" \
		BENCHMARK_TEST_MODE=1 \
		BENCHMARK_OUT="$BENCHMARK_OUT" \
		BENCHMARK_SCRATCH="$BENCHMARK_SCRATCH" \
		BENCHMARK_SAMPLES_FILE="$BENCHMARK_SAMPLES_FILE" \
		BENCHMARK_DISPATCH_IMAGE="$BENCHMARK_DISPATCH_IMAGE" \
		NODE_NAME="$NODE_NAME" \
		"$SCRIPTS/benchmark.sh" capabilities
	[ "$status" -eq 0 ]
	[[ "$output" == *'"status":"passed"'* ]]
	[[ "$output" == *'"hevcQsv":true'* ]]
}
