#!/usr/bin/env bats

setup() {
	SCRIPTS="$BATS_TEST_DIRNAME/../app/scripts"
	FIXTURES="$BATS_TEST_DIRNAME/fixtures"
	GOLDEN="$BATS_TEST_DIRNAME/golden"
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

# Catches any widening or reordering of the fixed ICQ candidate set.
@test "test interface publishes the canonical ICQ setting membership" {
	export BENCHMARK_SAMPLES_FILE="$BATS_TEST_TMPDIR/samples.json"
	yq -r '.data."samples.json"' "$BATS_TEST_DIRNAME/../app/samples.yaml" >"$BENCHMARK_SAMPLES_FILE"

	run "$SCRIPTS/benchmark.sh" _test icq-settings
	[ "$status" -eq 0 ]
	[ "$output" = '16 18 20 22 24 26 28 30' ]

	run "$SCRIPTS/benchmark.sh" _test icq-setting 30
	[ "$status" -eq 0 ]

	run "$SCRIPTS/benchmark.sh" _test icq-setting 32
	[ "$status" -eq 1 ]
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
	export BENCHMARK_TEST_TITLE_SOURCE_PROBE="$FIXTURES/metrics/probe-source.json"
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

prepare_quality_panel_with_six_titles_three_clips() {
	local quality='[]' index source size sha cohort item
	for index in 1 2 3 4 5 6; do
		source="$BATS_TEST_TMPDIR/quality-source-$index.mkv"
		printf 'quality source fixture bytes %s' "$index" >"$source"
		size="$(wc -c <"$source" | tr -d ' ')"
		sha="$(sha256sum "$source" | awk '{print $1}')"
		case "$index" in
		1 | 2) cohort='avc' ;;
		3 | 4) cohort='vc1' ;;
		5 | 6) cohort='hdr10' ;;
		esac
		item="$(jq -n --arg id "quality-$index" --arg cohort "$cohort" --arg path "$source" \
			--arg sha "$sha" --argjson size "$size" '{
				id: $id, cohort: $cohort, path: $path, sizeBytes: $size, sha256: $sha,
				clips: {detail: "00:17:23.456", motion: "00:27:23.456", dark: "00:37:23.456"}
			}')"
		quality="$(jq -c --argjson item "$item" '. + [$item]' <<<"$quality")"
	done
	jq --argjson quality "$quality" '.qualityPanel = $quality' \
		"$BENCHMARK_SAMPLES_FILE" >"$BENCHMARK_SAMPLES_FILE.tmp"
	mv -f -- "$BENCHMARK_SAMPLES_FILE.tmp" "$BENCHMARK_SAMPLES_FILE"
}

# Each mutation names a state-machine break that would authorize work from an
# ambiguous or contradictory one-record visual decision.
@test "results header is the exact 41-column ICQ resume schema" {
	run "$SCRIPTS/benchmark.sh" _test results-header
	[ "$status" -eq 0 ]
	[ "$output" = 'run_id,panel,sample_id,cohort,source_sha256,clip_id,encoder,requested_setting,selected_rate_control,status,attempt,input_bytes,output_bytes,reduction_percent,input_bit_rate,output_bit_rate,wall_seconds,encode_fps,encode_speed,vmaf_harmonic_mean,vmaf_1pct_low,ssim,gpu_busy_percent,qsv_proof,validation_codec,validation_duration,validation_resolution,validation_frame_rate,validation_bit_depth,validation_hdr,validation_audio_tracks,validation_subtitle_tracks,validation_chapters,validation_failures,log_path,output_disposition,strategy_id,qsv_initialization,video_busy_nanoseconds,quality_evidence_path,quality_evidence_sha256' ]
}

@test "benchmark failure hooks are rejected outside test mode" {
	unset BENCHMARK_OUT BENCHMARK_SCRATCH BENCHMARK_SAMPLES_FILE
	export BENCHMARK_TEST_MODE=0
	export BENCHMARK_TEST_FAIL_RESULT_APPEND=1
	run "$SCRIPTS/benchmark.sh" _test results-header
	[ "$status" -eq 64 ]
	[ "$output" = 'BENCHMARK_TEST_* hooks require BENCHMARK_TEST_MODE=1' ]
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
@test "quality command construction preserves exact clip QSV VMAF SSIM and PSNR contracts" {
	for setting in 16 18 30; do
		run "$SCRIPTS/benchmark.sh" _test commands \
			'/media/Movie.mkv' '00:17:23.456' '/scratch/detail.mkv' \
			"/scratch/qsv-$setting.mkv" '/scratch/vmaf.json' "$setting"
		[ "$status" -eq 0 ]
		commands="$output"

		run jq -e --arg setting "$setting" '
		.clip == ["ffmpeg","-nostdin","-v","error","-ss","00:17:23.456","-i","/media/Movie.mkv","-t","90","-map","0","-c","copy","/scratch/detail.mkv"] and
		.qsv == ["ffmpeg","-nostdin","-v","verbose","-init_hw_device","qsv=hw:/dev/dri/renderD128","-filter_hw_device","hw","-i","/scratch/detail.mkv","-map","0","-c:v","hevc_qsv","-preset","veryslow","-global_quality",$setting,"-look_ahead","0","-extbrc","0","-c:a","copy","-c:s","copy","-map_metadata","0","-map_chapters","0",("/scratch/qsv-" + $setting + ".mkv")] and
		.vmaf == ["ffmpeg","-nostdin","-v","error","-i",("/scratch/qsv-" + $setting + ".mkv"),"-i","/scratch/detail.mkv","-lavfi","[0:v][1:v]libvmaf=model=version=vmaf_4k_v0.6.1:log_fmt=json:log_path=/scratch/vmaf.json","-f","null","-"] and
		.ssim == ["ffmpeg","-nostdin","-v","info","-i",("/scratch/qsv-" + $setting + ".mkv"),"-i","/scratch/detail.mkv","-lavfi","[0:v][1:v]ssim","-f","null","-"] and
		.psnr == ["ffmpeg","-nostdin","-v","info","-i",("/scratch/qsv-" + $setting + ".mkv"),"-i","/scratch/detail.mkv","-lavfi","[0:v][1:v]psnr","-f","null","-"]
	' <<<"$commands"
		[ "$status" -eq 0 ]
	done
}

# Catches a production break where arithmetic mean replaces the mandated VMAF
# harmonic mean or the low-tail score stops using ceil(frame_count * 1%).
@test "VMAF frame metrics produce the hand-derived harmonic mean and one-percent low" {
	run "$SCRIPTS/benchmark.sh" _test vmaf-stats "$FIXTURES/metrics/vmaf-frames.json"
	[ "$status" -eq 0 ]
	[ "$output" = '{"frame_count":4,"harmonic_mean":91.719745,"one_percent_low":80.000000}' ]
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

# Catches validation short-circuiting after the first failure, wrong duration
# tolerances, or HDR static metadata being omitted from the HDR field.
@test "output validation reports every failed field in stable semicolon order" {
	run "$SCRIPTS/benchmark.sh" _test validate-probes \
		"$FIXTURES/metrics/probe-source.json" "$FIXTURES/metrics/probe-output-valid.json" clip 0
	[ "$status" -eq 0 ]
	run jq -e '
		.validation_codec == "passed" and .validation_duration == "passed" and
		.validation_resolution == "passed" and .validation_frame_rate == "passed" and
		.validation_bit_depth == "passed" and .validation_hdr == "passed" and
		.validation_audio_tracks == "passed" and .validation_subtitle_tracks == "passed" and
		.validation_chapters == "passed" and .validation_failures == ""
	' <<<"$output"
	[ "$status" -eq 0 ]

	run "$SCRIPTS/benchmark.sh" _test validate-probes \
		"$FIXTURES/metrics/probe-source.json" "$FIXTURES/metrics/probe-output-invalid.json" clip 0
	[ "$status" -eq 0 ]
	run jq -e '
		[.validation_codec,.validation_duration,.validation_resolution,
		 .validation_frame_rate,.validation_bit_depth,.validation_hdr,
		 .validation_audio_tracks,.validation_subtitle_tracks,.validation_chapters]
		== ["failed","failed","failed","failed","failed","failed","failed","failed","failed"] and
		.validation_failures == "codec;duration;resolution;frame-rate;bit-depth;hdr;audio-tracks;subtitle-tracks;chapters"
	' <<<"$output"
	[ "$status" -eq 0 ]

	boundary="$BATS_TEST_TMPDIR/duration-boundary.json"
	jq '.durationSeconds = 91.5' "$FIXTURES/metrics/probe-output-valid.json" >"$boundary"
	run "$SCRIPTS/benchmark.sh" _test validate-probes \
		"$FIXTURES/metrics/probe-source.json" "$boundary" clip 0
	[ "$status" -eq 0 ]
	[ "$(jq -r '.validation_duration' <<<"$output")" = 'failed' ]
	run "$SCRIPTS/benchmark.sh" _test validate-probes \
		"$FIXTURES/metrics/probe-source.json" "$boundary" full 0
	[ "$status" -eq 0 ]
	[ "$(jq -r '.validation_duration' <<<"$output")" = 'passed' ]
}

@test "output validation uses exact normalized rationals and fails closed on incomplete probes" {
	equivalent="$BATS_TEST_TMPDIR/equivalent.json"
	close_but_unequal="$BATS_TEST_TMPDIR/close-but-unequal.json"
	incomplete="$BATS_TEST_TMPDIR/incomplete.json"
	jq '.frameRate = "48000/2002"' "$FIXTURES/metrics/probe-output-valid.json" >"$equivalent"
	jq '.frameRate = "24000001/1001000"' "$FIXTURES/metrics/probe-output-valid.json" >"$close_but_unequal"
	jq 'del(.width) | .height = null | .audioTrackCount = "2"' \
		"$FIXTURES/metrics/probe-output-valid.json" >"$incomplete"

	run "$SCRIPTS/benchmark.sh" _test validate-probes \
		"$FIXTURES/metrics/probe-source.json" "$equivalent" clip 0
	[ "$status" -eq 0 ]
	[ "$(jq -r '.validation_frame_rate' <<<"$output")" = 'passed' ]
	run "$SCRIPTS/benchmark.sh" _test validate-probes \
		"$FIXTURES/metrics/probe-source.json" "$close_but_unequal" clip 0
	[ "$status" -eq 0 ]
	[ "$(jq -r '.validation_frame_rate' <<<"$output")" = 'failed' ]
	run "$SCRIPTS/benchmark.sh" _test validate-probes \
		"$FIXTURES/metrics/probe-source.json" "$incomplete" clip 0
	[ "$status" -eq 0 ]
	[ "$(jq -r '.validation_resolution' <<<"$output")" = 'failed' ]
	[ "$(jq -r '.validation_audio_tracks' <<<"$output")" = 'failed' ]
}

@test "quality passes title HDR metadata through orchestration and rejects missing output metadata" {
	prepare_execution_run
	export BENCHMARK_TEST_SOURCE_PROBE="$FIXTURES/metrics/probe-source-clip-hdr-missing.json"
	export BENCHMARK_TEST_INVALID_OUTPUT_MATCH='qsv-20-.*[.]mkv$'
	export BENCHMARK_TEST_INVALID_OUTPUT_PROBE="$FIXTURES/metrics/probe-output-hdr-missing.json"
	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 0 ]
	results="$BENCHMARK_OUT/runs/$output/results.csv"
	[ "$(awk -F, '$7 == "qsv" && $8 == 20 {print $30}' "$results")" = 'failed' ]
	[ "$(awk -F, '$7 == "qsv" && $8 == 22 {print $30}' "$results")" = 'passed' ]
}

# Catches a regression where failed/invalid attempts overwrite evidence, a
# fallback mode resumes, suspect output survives scratch, or the exact passed
# row is encoded again.
@test "result recording increments attempts resumes only passed rows and discards quality video" {
	run_id='20260802T120000Z-aaaaaaaa'
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	mkdir -p "$run_dir"

	attempt=0
	for fixture in variant-fallback variant-invalid-output variant-passed; do
		attempt=$((attempt + 1))
		scratch_output="$BENCHMARK_SCRATCH/$fixture.mkv"
		printf '%s' 'encoded bytes' >"$scratch_output"
		bound_fixture="$BATS_TEST_TMPDIR/$fixture-bound.json"
		bind_quality_fixture_evidence "$run_id" "$FIXTURES/metrics/$fixture.json" "$attempt" "$bound_fixture"
		run "$SCRIPTS/benchmark.sh" _test record-result \
			"$run_id" "$bound_fixture" "$scratch_output"
		[ "$status" -eq 0 ]
		[ ! -e "$scratch_output" ]
	done
	[ "$output" = '{"status":"passed","attempt":3,"output_disposition":"discarded"}' ]
	cmp -s "$GOLDEN/results.csv" "$run_dir/results.csv"

	scratch_output="$BENCHMARK_SCRATCH/resume-must-delete.mkv"
	printf '%s' 'must not survive' >"$scratch_output"
	run "$SCRIPTS/benchmark.sh" _test record-result \
		"$run_id" "$FIXTURES/metrics/variant-passed.json" "$scratch_output"
	[ "$status" -eq 0 ]
	[ "$output" = '{"status":"skipped","attempt":3,"output_disposition":"not-created"}' ]
	[ ! -e "$scratch_output" ]
	cmp -s "$GOLDEN/results.csv" "$run_dir/results.csv"

	run "$SCRIPTS/runmeta.sh" completed "$run_id" \
		'quality|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|detail|qsv|22'
	[ "$status" -eq 0 ]
}

# Catches an artifact from another strategy entering an ICQ run before any row
# is appended and becoming an apparently resumable result.
@test "result recording rejects a fixture with a mismatched strategy before append" {
	run_id='20260802T120000Z-aaaaaaaa'
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	mkdir -p "$run_dir"
	fixture="$BATS_TEST_TMPDIR/mismatched-strategy.json"
	jq '.strategy_id = "la-hevc-icq-v1"' "$FIXTURES/metrics/variant-passed.json" >"$fixture"
	scratch_output="$BENCHMARK_SCRATCH/mismatched-strategy.mkv"
	printf '%s' 'encoded bytes' >"$scratch_output"

	run "$SCRIPTS/benchmark.sh" _test record-result "$run_id" "$fixture" "$scratch_output"
	[ "$status" -eq 65 ]
	[ "$output" = 'result fixture strategy does not match contract' ]
	[ ! -e "$scratch_output" ]
	if [[ -e "$run_dir/results.csv" ]]; then
		[ "$(wc -l <"$run_dir/results.csv" | tr -d ' ')" -eq 1 ]
	fi
}

# Catches QSV encode success being recorded as passed without the initialization
# and positive hardware-busy evidence carried in the ICQ result schema.
@test "result recording marks incomplete QSV evidence invalid" {
	run_id='20260802T120000Z-aaaaaaaa'
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	mkdir -p "$run_dir"
	fixture="$BATS_TEST_TMPDIR/missing-qsv-evidence.json"
	jq '.qsv_initialization = "failed" | .video_busy_nanoseconds = "0"' \
		"$FIXTURES/metrics/variant-passed.json" >"$fixture"
	bound_fixture="$BATS_TEST_TMPDIR/missing-qsv-evidence-bound.json"
	bind_quality_fixture_evidence "$run_id" "$fixture" 1 "$bound_fixture"
	scratch_output="$BENCHMARK_SCRATCH/missing-qsv-evidence.mkv"
	printf '%s' 'encoded bytes' >"$scratch_output"

	run "$SCRIPTS/benchmark.sh" _test record-result "$run_id" "$bound_fixture" "$scratch_output"
	[ "$status" -eq 0 ]
	[ "$output" = '{"status":"invalid","attempt":1,"output_disposition":"discarded"}' ]
	run awk -F, 'NR == 2 {print $10 "," $38 "," $39}' "$run_dir/results.csv"
	[ "$status" -eq 0 ]
	[ "$output" = 'invalid,failed,0' ]
}

# Catches a planner or loop drift that omits or duplicates work in the fixed panel.
@test "quality runs all six titles three clips and eight ICQ settings" {
	prepare_execution_run
	prepare_quality_panel_with_six_titles_three_clips
	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 0 ]
	run_id="$output"
	run_dir="$BENCHMARK_OUT/runs/$run_id"

	run python3 - "$run_dir/results.csv" <<'PYTHON'
import csv
import json
import sys

with open(sys.argv[1], newline="", encoding="utf-8") as stream:
    rows = list(csv.DictReader(stream))
keys = {(row["sample_id"], row["clip_id"], row["requested_setting"]) for row in rows}
expected = {
    (f"quality-{title}", clip, str(setting))
    for title in range(1, 7)
    for clip in ("detail", "motion", "dark")
    for setting in (16, 18, 20, 22, 24, 26, 28, 30)
}
print(json.dumps({
    "rowCount": len(rows),
    "allQsv": all(row["encoder"] == "qsv" for row in rows),
    "uniqueKeys": len(keys),
    "allExpected": keys == expected,
    "allPassed": all(row["status"] == "passed" for row in rows),
}, separators=(",", ":")))
PYTHON
	[ "$status" -eq 0 ]
	[ "$output" = '{"rowCount":144,"allQsv":true,"uniqueKeys":144,"allExpected":true,"allPassed":true}' ]
	[ ! -d "$run_dir/encodes" ]
	[ "$(find "$BENCHMARK_SCRATCH" -type f | wc -l | tr -d ' ')" -eq 0 ]
	[ -f "$run_dir/quality-candidates.json" ]

	run awk '$1 != "sha256sum" && $0 !~ /(^| )-nostdin( |$)/ {exit 1}' "$BENCHMARK_COMMAND_LOG"
	[ "$status" -eq 0 ]
	[ "$(rg -c -- 'libvmaf=model=version=vmaf_4k_v0.6.1:log_fmt=json:log_path=' "$BENCHMARK_COMMAND_LOG")" -eq 144 ]
	[ "$(rg -c -- '\[0:v\]\[1:v\]ssim' "$BENCHMARK_COMMAND_LOG")" -eq 144 ]
}

# Catches a generated quality Job publishing unbounded candidate evidence or
# omitting one cohort from the authenticated dispatch-to-runtime completion.
@test "generated quality completion publishes only bounded ranked cohort values" {
	prepare_execution_run
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
		(.cohorts.hdr10.candidates | map(.globalQuality)) == [16,18,20,22,24,26,30]
	' <<<"$output"
	[ "$status" -eq 0 ]
	[[ "$output" != *'sample-hdr'* ]]
	[[ "$output" != *'source.mkv'* ]]
	[[ "$output" != *'quality-evidence'* ]]
	[[ "$output" != *'sha256'* ]]
}

@test "PGS decode maps video only while probe validation still detects subtitle loss" {
	prepare_execution_run
	export BENCHMARK_TEST_PGS_DECODE=1
	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 0 ]
	run rg -F -- '-nostdin -v error -i ' "$BENCHMARK_COMMAND_LOG"
	[ "$status" -eq 0 ]
	run awk '
		/-f null -$/ && !/nullsrc=size=16x16/ && !/libvmaf=/ &&
			!/\[0:v\]\[1:v\]ssim/ && !/\[0:v\]\[1:v\]psnr/ && !/trace_headers/ {
			seen = 1
			if ($0 !~ /(^| )-map 0:v:0( |$)/) { bad = 1; exit }
		}
		END { if (bad || !seen) exit 1 }
	' "$BENCHMARK_COMMAND_LOG"
	[ "$status" -eq 0 ]
	run "$SCRIPTS/benchmark.sh" _test validate-probes \
		"$FIXTURES/metrics/probe-source.json" \
		"$FIXTURES/metrics/probe-output-subtitle-loss.json" clip 0
	[ "$status" -eq 0 ]
	[ "$(jq -r '.validation_subtitle_tracks' <<<"$output")" = 'failed' ]
}

@test "quality processes every sample when FFmpeg would otherwise consume loop stdin" {
	prepare_execution_run
	expand_execution_panels_to_three_samples
	export BENCHMARK_TEST_FFMPEG_CONSUME_STDIN=1
	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 0 ]
	results="$BENCHMARK_OUT/runs/$output/results.csv"
	[ "$(awk -F, 'NR > 1 && $7 == "qsv" {count += 1} END {print count + 0}' "$results")" -eq 24 ]
	run awk '$1 != "sha256sum" && $0 !~ /(^| )-nostdin( |$)/ {exit 1}' "$BENCHMARK_COMMAND_LOG"
	[ "$status" -eq 0 ]
}

@test "quality candidates authenticate corrected evidence and rank cohorts independently at exact gates" {
	prepare_execution_run
	prepare_quality_panel_with_six_titles_three_clips
	run_id='20260815T120000Z-aaaaaaaa'
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	mkdir -p "$run_dir"
	results="$run_dir/results.csv"
	write_quality_ranking_results "$results" "$run_id"

	run "$SCRIPTS/benchmark.sh" _test rank-quality-candidates "$results" "$BENCHMARK_SAMPLES_FILE" "$run_id"
	[ "$status" -eq 0 ]
	artifact="$run_dir/quality-candidates.json"
	actual_digest="sha256:$(sha256sum "$results" | awk '{print $1}')"
	run jq --arg digest "$actual_digest" '.resultsSha256 = $digest' \
		"$FIXTURES/metrics/quality-candidates.json"
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/expected-quality-candidates.json"
	run diff -u "$BATS_TEST_TMPDIR/expected-quality-candidates.json" "$artifact"
	[ "$status" -eq 0 ]

	# A malformed results file must fail before publication and leave the prior
	# artifact intact; a ranker that truncates first loses completed-run evidence.
	cp "$artifact" "$BATS_TEST_TMPDIR/prior-quality-candidates.json"
	printf '%s\n' 'malformed,row' >"$results"
	run "$SCRIPTS/benchmark.sh" _test rank-quality-candidates "$results" "$BENCHMARK_SAMPLES_FILE" "$run_id"
	[ "$status" -ne 0 ]
	run cmp -s "$BATS_TEST_TMPDIR/prior-quality-candidates.json" "$artifact"
	[ "$status" -eq 0 ]
}

# Catches either parsing replacement bytes or retaining eligibility after the
# canonical evidence path changes during authentication.
@test "quality candidates reject canonical replacement after stable evidence capture" {
	prepare_execution_run
	prepare_quality_panel_with_six_titles_three_clips
	run_id='20260815T120000Z-acde0000'
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	mkdir -p "$run_dir"
	results="$run_dir/results.csv"
	write_quality_ranking_results "$results" "$run_id"

	target="$run_dir/quality-evidence/quality-1-detail-qsv-16-attempt-1.json"
	replacement="$BATS_TEST_TMPDIR/replacement-quality-evidence.json"
	# Keep the serialized file size unchanged so inode identity, not size drift,
	# must detect the atomic replacement.
	jq '.vmaf.harmonicMean = 94' "$target" >"$replacement"
	chmod 0600 "$replacement"
	export BENCHMARK_TEST_SHA256_REPLACE_TARGET="$target"
	export BENCHMARK_TEST_SHA256_REPLACEMENT="$replacement"

	run "$SCRIPTS/benchmark.sh" _test rank-quality-candidates "$results" "$BENCHMARK_SAMPLES_FILE" "$run_id"
	[ "$status" -eq 0 ]
	[ ! -e "$replacement" ]
	run jq -e '
		.cohorts.avc.status == "eligible" and
		(.cohorts.avc.candidates | map(.globalQuality)) == [24,18,26] and
		.cohorts.avc.candidates[2] == {globalQuality:26, medianReductionPercent:10}
	' "$run_dir/quality-candidates.json"
	[ "$status" -eq 0 ]
}

# Catches treating an early row's final helper check as sufficient when a
# later row can change that canonical evidence before candidate publication.
@test "quality candidates revalidate every authenticated binding immediately before publication" {
	prepare_execution_run
	prepare_quality_panel_with_six_titles_three_clips
	run_id='20260815T120000Z-acde0005'
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	mkdir -p "$run_dir"
	results="$run_dir/results.csv"
	write_quality_ranking_results "$results" "$run_id"
	artifact="$run_dir/quality-candidates.json"
	printf '%s\n' '{"sentinel":"prior-candidates"}' >"$artifact"
	cp "$artifact" "$BATS_TEST_TMPDIR/prior-delayed-race-candidates.json"

	target="$run_dir/quality-evidence/quality-1-detail-qsv-16-attempt-1.json"
	replacement="$BATS_TEST_TMPDIR/delayed-replacement-quality-evidence.json"
	jq '.vmaf.harmonicMean = 94' "$target" >"$replacement"
	chmod 0600 "$replacement"
	export BENCHMARK_TEST_SHA256_REPLACE_TARGET="$target"
	export BENCHMARK_TEST_SHA256_REPLACEMENT="$replacement"
	export BENCHMARK_TEST_SHA256_REPLACE_AFTER_CALLS=3
	export BENCHMARK_TEST_SHA256_REPLACE_COUNTER="$BATS_TEST_TMPDIR/sha256-replacement-calls"

	run "$SCRIPTS/benchmark.sh" _test rank-quality-candidates "$results" "$BENCHMARK_SAMPLES_FILE" "$run_id"
	[ "$status" -ne 0 ]
	[ ! -e "$replacement" ]
	run cmp -s "$BATS_TEST_TMPDIR/prior-delayed-race-candidates.json" "$artifact"
	[ "$status" -eq 0 ]
}

# Catches cleanup through a private snapshot directory after another process
# replaces that directory with a symlink to an outside location.
@test "quality candidate authentication cannot remove through a replaced snapshot path" {
	prepare_execution_run
	prepare_quality_panel_with_six_titles_three_clips
	run_id='20260815T120000Z-acde0004'
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	mkdir -p "$run_dir"
	results="$run_dir/results.csv"
	write_quality_ranking_results "$results" "$run_id"

	outside="$BATS_TEST_TMPDIR/outside-snapshot-target"
	mkdir -p "$outside"
	printf '%s\n' 'must-survive' >"$outside/evidence.json"
	export BENCHMARK_TEST_LINK_SWAP_OUTSIDE="$outside"
	export BENCHMARK_TEST_LINK_SWAP_MARKER="$BATS_TEST_TMPDIR/link-swap-triggered"

	run "$SCRIPTS/benchmark.sh" _test rank-quality-candidates "$results" "$BENCHMARK_SAMPLES_FILE" "$run_id"
	[ "$status" -eq 0 ]
	[ -f "$outside/evidence.json" ]
	[ "$(<"$outside/evidence.json")" = 'must-survive' ]
}

# Catches accepting evidence that is not a confined regular file, has a false
# schema or identity, or contains non-finite comparison metrics.
@test "quality candidates reject link escape identity schema and non-finite evidence" {
	prepare_execution_run
	prepare_quality_panel_with_six_titles_three_clips
	run_id='20260815T120000Z-acde0003'
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	mkdir -p "$run_dir"
	results="$run_dir/results.csv"
	write_quality_ranking_results "$results" "$run_id"

	linked="$run_dir/quality-evidence/quality-1-detail-qsv-16-attempt-1.json"
	escaped="$BATS_TEST_TMPDIR/escaped-quality-evidence.json"
	mv -f -- "$linked" "$escaped"
	"$REAL_LN" -s "$escaped" "$linked"

	schema="$run_dir/quality-evidence/quality-1-detail-qsv-24-attempt-1.json"
	jq '.schemaVersion = 2' "$schema" >"$schema.tmp"
	mv -f -- "$schema.tmp" "$schema"
	chmod 0600 "$schema"
	schema_digest="sha256:$(sha256sum "$schema" | awk 'NR == 1 { print $1 }')"
	rewrite_quality_result_evidence_digest "$results" quality-1 detail 24 "$schema_digest"

	identity="$run_dir/quality-evidence/quality-1-detail-qsv-18-attempt-1.json"
	jq '.sampleId = "quality-2"' "$identity" >"$identity.tmp"
	mv -f -- "$identity.tmp" "$identity"
	chmod 0600 "$identity"
	identity_digest="sha256:$(sha256sum "$identity" | awk 'NR == 1 { print $1 }')"
	rewrite_quality_result_evidence_digest "$results" quality-1 detail 18 "$identity_digest"

	ssim="$run_dir/quality-evidence/quality-1-detail-qsv-26-attempt-1.json"
	sed 's/"ssim":0.991/"ssim":1e999/' "$ssim" >"$ssim.tmp"
	mv -f -- "$ssim.tmp" "$ssim"
	chmod 0600 "$ssim"
	ssim_digest="sha256:$(sha256sum "$ssim" | awk 'NR == 1 { print $1 }')"
	rewrite_quality_result_evidence_digest "$results" quality-1 detail 26 "$ssim_digest"

	psnr="$run_dir/quality-evidence/quality-5-detail-qsv-16-attempt-1.json"
	sed 's/"psnr":40/"psnr":1e999/' "$psnr" >"$psnr.tmp"
	mv -f -- "$psnr.tmp" "$psnr"
	chmod 0600 "$psnr"
	psnr_digest="sha256:$(sha256sum "$psnr" | awk 'NR == 1 { print $1 }')"
	rewrite_quality_result_evidence_digest "$results" quality-5 detail 16 "$psnr_digest"

	run "$SCRIPTS/benchmark.sh" _test rank-quality-candidates "$results" "$BENCHMARK_SAMPLES_FILE" "$run_id"
	[ "$status" -eq 0 ]
	run jq -e '
		.cohorts.avc == {
			status:"no-verdict", expectedClipCount:6, candidates:[], reason:"incomplete-evidence"
		} and
		(.cohorts.hdr10.candidates | map(.globalQuality)) == [24,18,26]
	' "$run_dir/quality-candidates.json"
	[ "$status" -eq 0 ]
}

# Catches a ranker that treats missing, changed, or non-preserved evidence as
# passing because the unauthenticated CSV metric columns still pass.
@test "quality candidates reject unavailable changed and non-preserved evidence per setting" {
	prepare_execution_run
	prepare_quality_panel_with_six_titles_three_clips
	run_id='20260815T120000Z-acde0001'
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	mkdir -p "$run_dir"
	results="$run_dir/results.csv"
	write_quality_ranking_results "$results" "$run_id"

	missing="$run_dir/quality-evidence/quality-1-detail-qsv-24-attempt-1.json"
	changed="$run_dir/quality-evidence/quality-1-detail-qsv-16-attempt-1.json"
	hdr="$run_dir/quality-evidence/quality-5-detail-qsv-16-attempt-1.json"
	rm -f -- "$missing"
	jq '.psnr = 41' "$changed" >"$changed.tmp"
	mv -f -- "$changed.tmp" "$changed"
	chmod 0600 "$changed"
	jq '.hdr.classification = "encoder-output-defect" | .hdr.reasons = ["encoded-metadata-differs"]' \
		"$hdr" >"$hdr.tmp"
	mv -f -- "$hdr.tmp" "$hdr"
	chmod 0600 "$hdr"
	hdr_digest="sha256:$(sha256sum "$hdr" | awk 'NR == 1 { print $1 }')"
	rewrite_quality_result_evidence_digest "$results" quality-5 detail 16 "$hdr_digest"

	run "$SCRIPTS/benchmark.sh" _test rank-quality-candidates "$results" "$BENCHMARK_SAMPLES_FILE" "$run_id"
	[ "$status" -eq 0 ]
	run jq -e '
		(.cohorts.avc.candidates | map(.globalQuality)) == [18,26] and
		(.cohorts.hdr10.candidates | map(.globalQuality)) == [24,18,26] and
		.cohorts.vc1.status == "no-verdict"
	' "$run_dir/quality-candidates.json"
	[ "$status" -eq 0 ]
}

# Catches collapsing incomplete evidence into a scientific no-go. Replacing
# the unavailable quality sidecar with a complete document is the only change
# that permits the VC-1 cohort to report no-go.
@test "quality candidates distinguish incomplete no-verdict from complete no-go" {
	prepare_execution_run
	prepare_quality_panel_with_six_titles_three_clips
	run_id='20260815T120000Z-acde0002'
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	mkdir -p "$run_dir"
	results="$run_dir/results.csv"
	write_quality_ranking_results "$results" "$run_id"

	run "$SCRIPTS/benchmark.sh" _test rank-quality-candidates "$results" "$BENCHMARK_SAMPLES_FILE" "$run_id"
	[ "$status" -eq 0 ]
	run jq -e '.cohorts.vc1 == {
		status:"no-verdict", expectedClipCount:6, candidates:[], reason:"incomplete-evidence"
	}' "$run_dir/quality-candidates.json"
	[ "$status" -eq 0 ]

	sha="$(jq -r '.qualityPanel[] | select(.id == "quality-3") | .sha256' "$BENCHMARK_SAMPLES_FILE")"
	evidence_ref="$(quality_evidence_reference "$run_id" quality-3 vc1 "$sha" detail 30 1 96 89.999 0.991)"
	rewrite_quality_result_evidence_digest "$results" quality-3 detail 30 "${evidence_ref#*,}"
	run "$SCRIPTS/benchmark.sh" _test rank-quality-candidates "$results" "$BENCHMARK_SAMPLES_FILE" "$run_id"
	[ "$status" -eq 0 ]
	run jq -e '.cohorts.vc1 == {
		status:"no-go", expectedClipCount:6, candidates:[], reason:"no-objective-candidate"
	}' "$run_dir/quality-candidates.json"
	[ "$status" -eq 0 ]
}

# Catches accepting a well-shaped row that the durable results contract rejects
# and replacing the prior candidate artifact before that violation is found.
@test "quality candidate publication rejects semantic result rows without replacing the prior artifact" {
	prepare_execution_run
	prepare_quality_panel_with_six_titles_three_clips
	run_id='20260815T120000Z-bbbbbbbb'
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	mkdir -p "$run_dir"
	results="$run_dir/results.csv"
	write_quality_ranking_results "$results" "$run_id"
	run "$SCRIPTS/benchmark.sh" _test rank-quality-candidates "$results" "$BENCHMARK_SAMPLES_FILE" "$run_id"
	[ "$status" -eq 0 ]
	artifact="$run_dir/quality-candidates.json"
	cp "$artifact" "$BATS_TEST_TMPDIR/prior-semantic-quality-candidates.json"

	# This stays a 41-column QSV passed row, but cannot be resumed because
	# QSV initialization evidence is incomplete.
	awk -F, 'BEGIN { OFS = FS } NR == 2 { $38 = "not-applicable" } { print }' "$results" \
		>"$BATS_TEST_TMPDIR/semantic-invalid-results.csv"
	mv -f -- "$BATS_TEST_TMPDIR/semantic-invalid-results.csv" "$results"
	run "$SCRIPTS/benchmark.sh" _test rank-quality-candidates "$results" "$BENCHMARK_SAMPLES_FILE" "$run_id"
	[ "$status" -ne 0 ]
	run cmp -s "$BATS_TEST_TMPDIR/prior-semantic-quality-candidates.json" "$artifact"
	[ "$status" -eq 0 ]
}

# Catches a partial per-setting group being promoted from its remaining rows.
@test "quality candidates exclude a setting with one expected title clip missing" {
	prepare_execution_run
	prepare_quality_panel_with_six_titles_three_clips
	run_id='20260815T120000Z-cccccccc'
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	mkdir -p "$run_dir"
	results="$run_dir/results.csv"
	write_quality_ranking_results "$results" "$run_id"

	awk -F, 'NR == 1 || !($3 == "quality-1" && $6 == "detail" && $8 == "16")' "$results" \
		>"$BATS_TEST_TMPDIR/partial-quality-results.csv"
	mv -f -- "$BATS_TEST_TMPDIR/partial-quality-results.csv" "$results"
	run "$SCRIPTS/benchmark.sh" _test rank-quality-candidates "$results" "$BENCHMARK_SAMPLES_FILE" "$run_id"
	[ "$status" -eq 0 ]
	run jq -e '
		.cohorts.avc.candidates == [
			{globalQuality: 24, medianReductionPercent: 35},
			{globalQuality: 18, medianReductionPercent: 25},
			{globalQuality: 26, medianReductionPercent: 10}
		]
	' "$run_dir/quality-candidates.json"
	[ "$status" -eq 0 ]
}

@test "quality records probe metric and parser failures cleans scratch and continues the panel" {
	invalid_json="$BATS_TEST_TMPDIR/invalid-probe.json"
	printf '%s\n' '{' >"$invalid_json"
	case_number=0
	for failure in source-probe output-probe vmaf-command vmaf-parse ssim-command ssim-parse psnr-command psnr-parse; do
		case_number=$((case_number + 1))
		rm -rf -- "$BENCHMARK_OUT" "$BENCHMARK_SCRATCH"
		mkdir -p "$BENCHMARK_OUT/runs" "$BENCHMARK_SCRATCH"
		prepare_execution_run
		unset BENCHMARK_TEST_VMAF_COMMAND_FAILURE BENCHMARK_TEST_VMAF_PARSE_FAILURE
		unset BENCHMARK_TEST_SSIM_COMMAND_FAILURE BENCHMARK_TEST_SSIM_PARSE_FAILURE
		unset BENCHMARK_TEST_PSNR_COMMAND_FAILURE BENCHMARK_TEST_PSNR_PARSE_FAILURE
		export BENCHMARK_TEST_SOURCE_PROBE="$FIXTURES/metrics/probe-source.json"
		export BENCHMARK_TEST_OUTPUT_PROBE="$FIXTURES/metrics/probe-output-valid.json"
		case "$failure" in
		source-probe) export BENCHMARK_TEST_SOURCE_PROBE="$invalid_json" ;;
		output-probe) export BENCHMARK_TEST_OUTPUT_PROBE="$invalid_json" ;;
		vmaf-command) export BENCHMARK_TEST_VMAF_COMMAND_FAILURE=1 ;;
		vmaf-parse) export BENCHMARK_TEST_VMAF_PARSE_FAILURE=1 ;;
		ssim-command) export BENCHMARK_TEST_SSIM_COMMAND_FAILURE=1 ;;
		ssim-parse) export BENCHMARK_TEST_SSIM_PARSE_FAILURE=1 ;;
		psnr-command) export BENCHMARK_TEST_PSNR_COMMAND_FAILURE=1 ;;
		psnr-parse) export BENCHMARK_TEST_PSNR_PARSE_FAILURE=1 ;;
		esac
		run "$SCRIPTS/benchmark.sh" quality
		[ "$status" -eq 0 ]
		run_id="$output"
		results="$BENCHMARK_OUT/runs/$run_id/results.csv"
		run awk -F, 'NR > 1 { count += 1; if ($10 != "failed" && $10 != "invalid") exit 1 } END { print count + 0 }' "$results"
		[ "$status" -eq 0 ]
		case "$failure" in
		source-probe | output-probe) [ "$output" = '8' ] ;;
		*) [ "$output" = '0' ] ;;
		esac
		[ "$(find "$BENCHMARK_SCRATCH" -type f | wc -l | tr -d ' ')" -eq 0 ]
	done
}

@test "quality attempt evidence is immutable and a passed resume does not duplicate ICQ rows" {
	prepare_execution_run
	export BENCHMARK_TEST_INVALID_OUTPUT_MATCH='qsv-20-attempt'
	export BENCHMARK_TEST_INVALID_OUTPUT_PROBE="$FIXTURES/metrics/probe-output-invalid.json"
	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 0 ]
	run_id="$output"
	for expected_attempt in 2; do
		run "$SCRIPTS/benchmark.sh" quality "$run_id"
		[ "$status" -eq 0 ]
		[ "$output" = "$run_id" ]
	done
	unset BENCHMARK_TEST_INVALID_OUTPUT_MATCH BENCHMARK_TEST_INVALID_OUTPUT_PROBE
	run "$SCRIPTS/benchmark.sh" quality "$run_id"
	[ "$status" -eq 0 ]

	run awk -F, '$7 == "qsv" && $8 == 20 {print $10 ":" $11}' "$BENCHMARK_OUT/runs/$run_id/results.csv"
	[ "$status" -eq 0 ]
	[ "$output" = $'invalid:1\ninvalid:2\npassed:3' ]
	for evidence_pattern in \
		'sample-hdr-detail-qsv-20-attempt-[123].log' \
		'sample-hdr-detail-qsv-20-attempt-*-source-probe.json' \
		'sample-hdr-detail-qsv-20-attempt-*-output-probe.json' \
		'sample-hdr-detail-qsv-20-attempt-*-validation.json' \
		'sample-hdr-detail-qsv-20-attempt-*-vmaf.json' \
		'sample-hdr-detail-qsv-20-attempt-*-ssim.log' \
		'sample-hdr-detail-qsv-20-attempt-*-psnr.log'; do
		[ "$(find "$BENCHMARK_OUT/runs/$run_id/logs" -type f -name "$evidence_pattern" | wc -l | tr -d ' ')" -eq 3 ]
	done
	[ "$(find "$BENCHMARK_OUT/runs/$run_id/quality-evidence" -type f \
		-name 'sample-hdr-detail-qsv-20-attempt-*.json' | wc -l | tr -d ' ')" -eq 3 ]
}

# Catches resume identity omitting the production commands whose bytes and
# parameters determine every measured variant.
@test "quality manifest identities the clip command and every bounded encoder setting" {
	prepare_execution_run
	unset BENCHMARK_IDENTITY_FIXTURE
	export NODE_NAME='talos-03'
	export BENCHMARK_RUNNING_IMAGE="$BENCHMARK_DISPATCH_IMAGE"
	export BENCHMARK_I915_VERSION='fixture-i915'
	export BENCHMARK_VPL_VERSION='fixture-vpl'

	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 0 ]
	run_id="$output"
	manifest="$BENCHMARK_OUT/runs/$run_id/manifest.json"
	run jq -e '
		.encoderCommands | length == 9 and
		.[0] == "ffmpeg -nostdin -v error -ss <timestamp> -i <source> -t 90 -map 0 -c copy <clip>" and
		([.[] | select(test("-c:v hevc_qsv"))] | length) == 8 and
		any(.[]; contains("-global_quality 16 -look_ahead 0 -extbrc 0")) and
		any(.[]; contains("-global_quality 30 -look_ahead 0 -extbrc 0")) and
		all(.[]; contains("-c:v hevc_qsv") or startswith("ffmpeg -nostdin -v error -ss "))
	' "$manifest"
	[ "$status" -eq 0 ]
}

# Catches quality evidence publication that is not atomically bound to the
# evaluated metrics and HDR oracle.
@test "quality evidence publication atomically binds evaluated metrics and HDR oracle" {
	prepare_execution_run
	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 0 ]
	run_id="$output"
	run_dir="$BENCHMARK_OUT/runs/$run_id"

	run python3 - "$run_dir" <<'PYTHON'
import csv
import hashlib
import json
import os
import stat
import sys

run_dir = sys.argv[1]
with open(os.path.join(run_dir, "results.csv"), newline="", encoding="utf-8") as stream:
    rows = list(csv.DictReader(stream))
assert len(rows) == 8
for row in rows:
    relative = row["quality_evidence_path"]
    expected = (
        f"quality-evidence/{row['sample_id']}-{row['clip_id']}-qsv-"
        f"{row['requested_setting']}-attempt-{row['attempt']}.json"
    )
    assert relative == expected
    assert not os.path.isabs(relative) and ".." not in relative.split("/")
    evidence_path = os.path.join(run_dir, relative)
    assert os.path.isfile(evidence_path) and not os.path.islink(evidence_path)
    assert stat.S_IMODE(os.stat(evidence_path).st_mode) == 0o600
    with open(evidence_path, "rb") as stream:
        payload = stream.read()
    assert row["quality_evidence_sha256"] == "sha256:" + hashlib.sha256(payload).hexdigest()
    evidence = json.loads(payload)
    assert sorted(evidence) == sorted([
        "clipId", "cohort", "globalQuality", "hdr", "psnr", "runId",
        "sampleId", "schemaVersion", "sourceSha256", "ssim", "strategyId", "vmaf",
    ])
    assert evidence["runId"] == row["run_id"]
    assert evidence["sampleId"] == row["sample_id"]
    assert evidence["cohort"] == row["cohort"]
    assert evidence["sourceSha256"] == row["source_sha256"]
    assert evidence["clipId"] == row["clip_id"]
    assert evidence["globalQuality"] == int(row["requested_setting"])
    assert evidence["schemaVersion"] == 1
    assert evidence["strategyId"] == "qsv-hevc-icq-v1"
    assert evidence["vmaf"]["harmonicMean"] == float(row["vmaf_harmonic_mean"])
    assert evidence["vmaf"]["onePercentLow"] == float(row["vmaf_1pct_low"])
    assert evidence["ssim"] == float(row["ssim"])
    assert evidence["psnr"] == 40
    assert evidence["hdr"]["classification"] == "preserved"
assert not any(name.startswith(".") and ".tmp." in name for name in os.listdir(os.path.join(run_dir, "quality-evidence")))
print("bound")
PYTHON
	[ "$status" -eq 0 ]
	[ "$output" = 'bound' ]
	[ "$(rg -c -- '\[0:v\]\[1:v\]psnr' "$BENCHMARK_COMMAND_LOG")" -eq 8 ]
}

# Catches an append error leaving a valid sidecar that makes the same attempt
# permanently unrecordable on retry.
@test "quality evidence retry recovers an exact orphan after append failure" {
	prepare_execution_run
	export BENCHMARK_TEST_FAIL_RESULT_APPEND=1
	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 74 ]
	run_id="$(find "$BENCHMARK_OUT/runs" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)"
	[ -n "$run_id" ]
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	evidence="$run_dir/quality-evidence/sample-hdr-detail-qsv-16-attempt-1.json"
	[ "$(wc -l <"$run_dir/results.csv" | tr -d ' ')" -eq 1 ]
	[ -f "$evidence" ]
	before="$BATS_TEST_TMPDIR/orphan-before.json"
	cp "$evidence" "$before"
	before_digest="$(sha256sum "$evidence" | awk 'NR == 1 { print $1 }')"
	stale_lock="$run_dir/quality-evidence/.sample-hdr-detail-qsv-16-attempt-1.publish.lock"
	mkdir "$stale_lock"

	unset BENCHMARK_TEST_FAIL_RESULT_APPEND
	run "$SCRIPTS/benchmark.sh" quality "$run_id"
	[ "$status" -eq 0 ]
	[ "$output" = "$run_id" ]
	run cmp -s "$before" "$evidence"
	[ "$status" -eq 0 ]
	[ "$(sha256sum "$evidence" | awk 'NR == 1 { print $1 }')" = "$before_digest" ]
	[ -d "$stale_lock" ]
	run python3 - "$run_dir/results.csv" "$before_digest" <<'PYTHON'
import csv
import sys

with open(sys.argv[1], newline="", encoding="utf-8") as stream:
    rows = list(csv.DictReader(stream))
assert len(rows) == 8
row = next(row for row in rows if row["requested_setting"] == "16")
assert row["attempt"] == "1"
assert row["quality_evidence_path"] == (
    "quality-evidence/sample-hdr-detail-qsv-16-attempt-1.json"
)
assert row["quality_evidence_sha256"] == "sha256:" + sys.argv[2]
PYTHON
	[ "$status" -eq 0 ]
}

# Catches a destination appearing at the former absence-check/rename boundary.
# The injected competing bytes must survive, and no row may bind them.
@test "quality evidence publication never overwrites a competing destination" {
	prepare_execution_run
	competitor="$BATS_TEST_TMPDIR/competing-evidence.json"
	printf '%s\n' '{"competing":"evidence"}' >"$competitor"
	export BENCHMARK_TEST_QUALITY_EVIDENCE_COMPETITOR_SETTING=16
	export BENCHMARK_TEST_QUALITY_EVIDENCE_COMPETITOR_FILE="$competitor"

	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 0 ]
	run_id="$output"
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	evidence="$run_dir/quality-evidence/sample-hdr-detail-qsv-16-attempt-1.json"
	run cmp -s "$competitor" "$evidence"
	[ "$status" -eq 0 ]
	[ "$(awk -F, 'NR > 1 && $8 == 16 { count += 1 } END { print count + 0 }' "$run_dir/results.csv")" -eq 0 ]
	[ "$(find "$run_dir/logs" -type f -name '*qsv-16-attempt-*-validation.json' -exec jq -r '.validation_failures' {} \;)" = 'quality-evidence' ]
	[ -z "$(find "$run_dir/quality-evidence" -mindepth 1 \( -name '.*.tmp.*' -o -name '.*.publish.lock' \) -print)" ]
}

# Catches the hard-link tool treating the exact destination as a directory and
# installing the staged basename inside it before row validation fails.
@test "quality evidence publication never links inside a directory destination" {
	prepare_execution_run
	export BENCHMARK_TEST_FAIL_RESULT_APPEND=1
	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 74 ]
	run_id="$(find "$BENCHMARK_OUT/runs" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)"
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	evidence_directory="$run_dir/quality-evidence"
	evidence="$evidence_directory/sample-hdr-detail-qsv-16-attempt-1.json"
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
@test "quality evidence publication never follows a symlinked directory destination" {
	prepare_execution_run
	export BENCHMARK_TEST_FAIL_RESULT_APPEND=1
	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 74 ]
	run_id="$(find "$BENCHMARK_OUT/runs" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)"
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	evidence_directory="$run_dir/quality-evidence"
	evidence="$evidence_directory/sample-hdr-detail-qsv-16-attempt-1.json"
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

# Catches a missing finite metric becoming an unbound row or an apparently
# successful result. The retained validation file names the closed failure.
@test "quality evidence failure records a closed reason and appends no row" {
	prepare_execution_run
	export BENCHMARK_TEST_PSNR_PARSE_FAILURE=1
	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 0 ]
	run_id="$output"
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	[ "$(wc -l <"$run_dir/results.csv" | tr -d ' ')" -eq 1 ]
	[ ! -e "$run_dir/quality-evidence" ]
	[ "$(find "$run_dir/logs" -type f -name '*-validation.json' -exec jq -r '.validation_failures' {} \; | sort -u)" = 'psnr;quality-evidence' ]
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
