#!/usr/bin/env bats

setup() {
	SCRIPTS="$BATS_TEST_DIRNAME/../app/scripts"
	FIXTURES="$BATS_TEST_DIRNAME/fixtures"
	export BENCHMARK_TEST_MODE=1
	export REAL_SHA256SUM="$(command -v sha256sum)"
	export REAL_LN="$(command -v ln)"
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
	jq -n --argjson score "$score" '{version:"3.0.0",fps:24,frames:[range(0;4) | {frameNum:.,metrics:{vmaf:$score}}]}' >"$metrics_path"
	exit 0
fi
if [[ "$arguments" == *'[0:v][1:v]ssim'* ]]; then
	printf '%s\n' '[Parsed_ssim_0 @ 0x3000] SSIM Y:0.990000 U:0.995000 V:0.995000 All:0.991000 (20.457575)' >&2
	exit 0
fi
if [[ "$arguments" == *'[0:v][1:v]psnr'* ]]; then
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

# D07: Successful and failed rows may retain bounded evidence only inside their run.
@test "quality output and scratch remain confined and temporary" {
	local boundary marker_digest run_id run_dir results shape outside before after
	local measured_before measured_after
	boundary="$BATS_TEST_TMPDIR/outside-boundary"
	mkdir -p "$boundary"
	printf '%s\n' 'outside sentinel' >"$boundary/sentinel"
	marker_digest="$(sha256sum "$boundary/sentinel" | awk 'NR == 1 {print $1}')"

	for shape in output-root runs-root run-tree scratch-root scratch logs destination; do
		export BENCHMARK_OUT="$BATS_TEST_TMPDIR/$shape-out"
		export BENCHMARK_SCRATCH="$BATS_TEST_TMPDIR/$shape-scratch"
		outside="$BATS_TEST_TMPDIR/$shape-outside"
		mkdir -p "$outside"
		printf '%s\n' "$shape sentinel" >"$outside/sentinel"
		case "$shape" in
		output-root)
			ln -s "$outside" "$BENCHMARK_OUT"
			mkdir -p "$BENCHMARK_SCRATCH"
			;;
		runs-root)
			mkdir -p "$BENCHMARK_OUT" "$BENCHMARK_SCRATCH"
			ln -s "$outside" "$BENCHMARK_OUT/runs"
			;;
		scratch-root)
			mkdir -p "$BENCHMARK_OUT/runs"
			ln -s "$outside" "$BENCHMARK_SCRATCH"
			;;
		*) mkdir -p "$BENCHMARK_OUT/runs" "$BENCHMARK_SCRATCH" ;;
		esac
		prepare_representative_run "sample-$shape" avc "$FIXTURES/media/avc-8bit.mkv"
		start_representative_plan
		append_representative_plan_row "sample-$shape" detail 16
		# Use literal valid IDs; the shape label remains only the case diagnostic.
		case "$shape" in
		output-root) run_id='20260802T120000Z-a0000001' ;;
		runs-root) run_id='20260802T120000Z-a0000002' ;;
		run-tree) run_id='20260802T120000Z-a0000003' ;;
		scratch-root) run_id='20260802T120000Z-a0000004' ;;
		scratch) run_id='20260802T120000Z-a0000005' ;;
		logs) run_id='20260802T120000Z-a0000006' ;;
		destination) run_id='20260802T120000Z-a0000007' ;;
		esac
		if [[ "$shape" != output-root && "$shape" != runs-root ]]; then
			if [[ "$shape" == run-tree ]]; then
				ln -s "$outside" "$BENCHMARK_OUT/runs/$run_id"
			else
				run "$SCRIPTS/runmeta.sh" create quality "$run_id"
				[ "$status" -eq 0 ]
				run_dir="$BENCHMARK_OUT/runs/$run_id"
				if [[ "$shape" == scratch ]]; then
					ln -s "$outside" "$BENCHMARK_SCRATCH/$run_id"
				elif [[ "$shape" == logs ]]; then
					ln -s "$outside" "$run_dir/logs"
				elif [[ "$shape" == destination ]]; then
					ln -s "$outside" "$run_dir/quality-evidence"
				fi
			fi
		fi
		before="$(find "$outside" -mindepth 1 -maxdepth 1 -print | sed 's#.*/##' | LC_ALL=C sort)"
		measured_before="$(<"$BENCHMARK_COMMAND_LOG")"
		run "$SCRIPTS/benchmark.sh" quality "$run_id"
		[ "$status" -ne 0 ] || {
			echo "symlink escape passed: $shape" >&3
			return 1
		}
		measured_after="$(<"$BENCHMARK_COMMAND_LOG")"
		[ "$measured_after" = "$measured_before" ] || {
			echo "symlink escape reached measured work: $shape" >&3
			return 1
		}
		after="$(find "$outside" -mindepth 1 -maxdepth 1 -print | sed 's#.*/##' | LC_ALL=C sort)"
		[ "$after" = "$before" ]
		[ "$(<"$outside/sentinel")" = "$shape sentinel" ]
	done

	export BENCHMARK_OUT="$BATS_TEST_TMPDIR/first-run-out"
	export BENCHMARK_SCRATCH="$BATS_TEST_TMPDIR/first-run-scratch"
	outside="$BATS_TEST_TMPDIR/first-run-outside"
	mkdir -p "$BENCHMARK_OUT" "$BENCHMARK_SCRATCH" "$outside"
	printf '%s\n' 'first-run outside sentinel' >"$outside/sentinel"
	[ ! -e "$BENCHMARK_OUT/runs" ]
	prepare_representative_run sample-first-run avc "$FIXTURES/media/avc-8bit.mkv"
	start_representative_plan
	append_representative_plan_row sample-first-run detail 16
	measured_before="$(<"$BENCHMARK_COMMAND_LOG")"
	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 0 ]
	run_id="$output"
	[[ "$run_id" =~ ^20260802T120000Z-[0-9a-f]{8}$ ]]
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	[ -d "$BENCHMARK_OUT/runs" ]
	[ -d "$run_dir" ]
	[ "$(find "$BENCHMARK_OUT/runs" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq 1 ]
	results="$run_dir/results.csv"
	run awk -F, 'NR == 2 {print $3 ":" $10} END {if (NR != 2) exit 1}' "$results"
	[ "$status" -eq 0 ]
	[ "$output" = 'sample-first-run:passed' ]
	evidence_path="$(awk -F, 'NR == 2 {print $40}' "$results")"
	[ "$evidence_path" = 'quality-evidence/sample-first-run-detail-qsv-16-attempt-1.json' ]
	run jq -e --arg run "$run_id" '
		.schemaVersion == 1 and .strategyId == "qsv-hevc-icq-v1" and
		.runId == $run and .sampleId == "sample-first-run" and
		.clipId == "detail" and .globalQuality == 16
	' "$run_dir/$evidence_path"
	[ "$status" -eq 0 ] || {
		echo "first-run evidence contract failed: $output" >&3
		return 1
	}
	measured_after="$(<"$BENCHMARK_COMMAND_LOG")"
	[ "$measured_after" != "$measured_before" ]
	[[ "$measured_after" == *'-global_quality 16 -look_ahead 0 -extbrc 0'* ]]
	[ "$(<"$outside/sentinel")" = 'first-run outside sentinel' ]

	export BENCHMARK_OUT="$BATS_TEST_TMPDIR/success-out"
	export BENCHMARK_SCRATCH="$BATS_TEST_TMPDIR/success-scratch"
	mkdir -p "$BENCHMARK_OUT/runs" "$BENCHMARK_SCRATCH"
	printf '%s\n' 'output boundary sentinel' >"$BENCHMARK_OUT/boundary-sentinel"
	prepare_representative_run sample-confined avc "$FIXTURES/media/avc-8bit.mkv"
	start_representative_plan
	append_representative_plan_row sample-confined detail 16
	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 0 ]
	run_id="$output"
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	[ -d "$run_dir" ]
	[ "$(find "$BENCHMARK_OUT" -type f ! -path "$run_dir/*" \
		! -path "$BENCHMARK_OUT/boundary-sentinel" | wc -l | tr -d ' ')" -eq 0 ]
	[ "$(<"$BENCHMARK_OUT/boundary-sentinel")" = 'output boundary sentinel' ]
	[ "$(find "$run_dir" -type f \( -name '*.mkv' -o -name '*.mp4' -o -name '*.hevc' \) |
		wc -l | tr -d ' ')" -eq 0 ]
	[ "$(find "$BENCHMARK_SCRATCH" -mindepth 1 | wc -l | tr -d ' ')" -eq 0 ]
	[ "$(sha256sum "$boundary/sentinel" | awk 'NR == 1 {print $1}')" = "$marker_digest" ]

	export BENCHMARK_OUT="$BATS_TEST_TMPDIR/failure-out"
	export BENCHMARK_SCRATCH="$BATS_TEST_TMPDIR/failure-scratch"
	mkdir -p "$BENCHMARK_OUT/runs" "$BENCHMARK_SCRATCH"
	printf '%s\n' 'failure boundary sentinel' >"$BENCHMARK_OUT/boundary-sentinel"
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
	results="$run_dir/results.csv"
	run awk -F, 'NR > 1 {print $3 ":" $10}' "$results"
	[ "$status" -eq 0 ]
	[ "$output" = $'sample-invalid:invalid\nsample-valid:passed' ]
	[ "$(find "$BENCHMARK_OUT" -type f ! -path "$run_dir/*" \
		! -path "$BENCHMARK_OUT/boundary-sentinel" | wc -l | tr -d ' ')" -eq 0 ]
	[ "$(<"$BENCHMARK_OUT/boundary-sentinel")" = 'failure boundary sentinel' ]
	[ "$(find "$run_dir" -type f \( -name '*.mkv' -o -name '*.mp4' -o -name '*.hevc' \) |
		wc -l | tr -d ' ')" -eq 0 ]
	[ "$(find "$BENCHMARK_SCRATCH" -mindepth 1 | wc -l | tr -d ' ')" -eq 0 ]
	[ "$(sha256sum "$boundary/sentinel" | awk 'NR == 1 {print $1}')" = "$marker_digest" ]
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
