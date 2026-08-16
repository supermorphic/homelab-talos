#!/usr/bin/env bats

setup() {
	SCRIPTS="$BATS_TEST_DIRNAME/../app/scripts"
	FIXTURES="$BATS_TEST_DIRNAME/fixtures"
	GOLDEN="$BATS_TEST_DIRNAME/golden"
	export BENCHMARK_TEST_MODE=1
	export REAL_SHA256SUM="$(command -v sha256sum)"
	QUALITY_RUN_ID='20260815T120000Z-6cdfc9f3'
	export BENCHMARK_OUT="$BATS_TEST_TMPDIR/out"
	export BENCHMARK_SCRATCH="$BATS_TEST_TMPDIR/scratch"
	export BENCHMARK_SAMPLES_FILE="$BATS_TEST_TMPDIR/samples.json"
	yq -r '.data."samples.json"' "$BATS_TEST_DIRNAME/../app/samples.yaml" >"$BENCHMARK_SAMPLES_FILE"
	mkdir -p "$BENCHMARK_OUT/runs" "$BENCHMARK_SCRATCH"
}

# Catches the runtime accepting its own stale setting range instead of the one
# shared by the mounted source configuration and host-side benchmark helpers.
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
	printf '%s\n' ' V..... hevc_qsv Intel Quick Sync Video HEVC encoder' ' V....D libx265 libx265 H.265 / HEVC'
	exit 0
	;;
*'-hide_banner -filters'*)
	printf '%s\n' ' ... libvmaf VV->V Calculate the VMAF between two video streams.'
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
exit 97
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
	: >"$BENCHMARK_COMMAND_LOG"
}

write_capability_samples() {
	image="${1:-docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb}"
	export BENCHMARK_SAMPLES_FILE="$BATS_TEST_TMPDIR/capability-samples.json"
	jq -n \
		--arg image "$image" \
		--argjson strategy "$(strategy_contract)" \
		--argjson required "$(capability_declared_list requiredCommands "${@:2}")" \
		--argjson optional "$(capability_declared_list optionalCommands)" \
		'{schemaVersion: 2, strategy: $strategy, runtime: {image: $image, requiredCommands: $required, optionalCommands: $optional}}' \
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

chosen_record() {
	local cohort="$1" state="$2" setting="${3:-22}" rejected="${4:-[]}" finalist_sample hdr
	case "$cohort" in
	avc) finalist_sample='avc-grain-memento'; hdr='not-applicable' ;;
	vc1) finalist_sample='vc1-fugitive'; hdr='not-applicable' ;;
	hdr10) finalist_sample='hdr10-grain-goodfellas'; hdr='passed' ;;
	esac
	jq -n -c \
		--arg cohort "$cohort" --arg state "$state" --arg quality_run "$QUALITY_RUN_ID" \
		--argjson setting "$setting" \
		--argjson rejected "$rejected" --arg finalist_sample "$finalist_sample" --arg hdr "$hdr" '
		{
			strategyId: "qsv-hevc-icq-v1",
			qualityRunId: $quality_run,
			qualityResultsSha256: ("sha256:" + ("a" * 64)),
			candidateEvidenceSha256: ("sha256:" + ("b" * 64)),
			globalQuality: $setting,
			state: $state,
			cropReview: {
				status: "passed", reviewedAt: "2026-08-15T12:00:00Z",
				clips: [{sampleId: $finalist_sample, clipId: "detail", result: "passed"}]
			},
			finalistReview: (if $state == "final" then {
				status: "passed", finalistRunId: "20260815T140000Z-bbbbbbbb",
				sampleId: $finalist_sample, resultsSha256: ("sha256:" + ("c" * 64)),
				reviewedAt: "2026-08-15T14:00:00Z",
				checklist: {
					directPlay: "passed", hdrHandling: $hdr, motionArtifacts: "passed",
					grainRetention: "passed", banding: "passed", blocking: "passed"
				}
			} else null end),
			rejectedSettings: $rejected
		}'
}

set_chosen_record() {
	local cohort="$1" state="$2" setting="${3:-22}" rejected="${4:-[]}" record
	record="$(chosen_record "$cohort" "$state" "$setting" "$rejected")"
	jq --arg cohort "$cohort" --argjson record "$record" '.chosenSettings[$cohort] = $record' \
		"$BENCHMARK_SAMPLES_FILE" >"$BENCHMARK_SAMPLES_FILE.tmp"
	mv -f -- "$BENCHMARK_SAMPLES_FILE.tmp" "$BENCHMARK_SAMPLES_FILE"
}

prepare_quality_upstream() {
	local cohort="$1" state="$2" setting="$3" candidates="$4" rejected="${5:-[]}"
	local quality_run="$QUALITY_RUN_ID" quality_dir results results_digest candidate_digest
	quality_dir="$BENCHMARK_OUT/runs/$quality_run"
	mkdir -p "$quality_dir"
	results="$quality_dir/results.csv"
	printf '%s\n' \
		'run_id,panel,sample_id,cohort,source_sha256,clip_id,encoder,requested_setting,selected_rate_control,status,attempt,input_bytes,output_bytes,reduction_percent,input_bit_rate,output_bit_rate,wall_seconds,encode_fps,encode_speed,vmaf_harmonic_mean,vmaf_1pct_low,ssim,gpu_busy_percent,qsv_proof,validation_codec,validation_duration,validation_resolution,validation_frame_rate,validation_bit_depth,validation_hdr,validation_audio_tracks,validation_subtitle_tracks,validation_chapters,validation_failures,log_path,output_disposition,strategy_id,qsv_initialization,video_busy_nanoseconds' \
		"$quality_run,quality,fixture-$cohort,$cohort,aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,detail,qsv,$setting,ICQ,passed,1,1000,600,40,8000,4800,10,30,1,96,92,0.99,50,passed,passed,passed,passed,passed,passed,passed,passed,passed,passed,,logs/fixture.log,discarded,qsv-hevc-icq-v1,passed,800000000" \
		>"$results"
	jq -S -c --arg created_at "${quality_run%-*}" '. + {createdAt:$created_at}' \
		"$FIXTURES/manifests/identity.json" >"$quality_dir/manifest.json"
	results_digest="sha256:$(sha256sum "$results" | awk '{print $1}')"
	if [[ -f "$quality_dir/quality-candidates.json" ]]; then
		cp "$quality_dir/quality-candidates.json" "$quality_dir/quality-candidates.base.json"
	else
		jq -n -c --arg run "$quality_run" --arg digest "$results_digest" '
		{
			schemaVersion:1,strategyId:"qsv-hevc-icq-v1",qualityRunId:$run,
			resultsSchemaVersion:2,resultsSha256:$digest,
			cohorts:{avc:{status:"no-go",expectedClipCount:0,candidates:[],reason:"no-objective-candidate"},
				vc1:{status:"no-go",expectedClipCount:0,candidates:[],reason:"no-objective-candidate"},
				hdr10:{status:"no-go",expectedClipCount:0,candidates:[],reason:"no-objective-candidate"}}
		}' >"$quality_dir/quality-candidates.base.json"
	fi
	jq -c --arg cohort "$cohort" --arg run "$quality_run" --arg digest "$results_digest" \
		--argjson candidates "$candidates" '
		.qualityRunId = $run | .resultsSha256 = $digest |
		.cohorts[$cohort] = {status:"eligible",expectedClipCount:1,
			candidates:($candidates | map({globalQuality:.,medianReductionPercent:(50 - .)}))}
	' "$quality_dir/quality-candidates.base.json" >"$quality_dir/quality-candidates.json"
	rm -f -- "$quality_dir/quality-candidates.base.json"
	candidate_digest="sha256:$(sha256sum "$quality_dir/quality-candidates.json" | awk '{print $1}')"
	set_chosen_record "$cohort" "$state" "$setting" "$rejected"
	jq --arg run "$quality_run" --arg results "$results_digest" --arg candidates "$candidate_digest" '
		.chosenSettings |= with_entries(
			.value |= if .qualityRunId == $run then
				.qualityResultsSha256 = $results | .candidateEvidenceSha256 = $candidates
			else . end)
	' "$BENCHMARK_SAMPLES_FILE" >"$BENCHMARK_SAMPLES_FILE.tmp"
	mv -f -- "$BENCHMARK_SAMPLES_FILE.tmp" "$BENCHMARK_SAMPLES_FILE"
}

# Each mutation names a state-machine break that would authorize work from an
# ambiguous or contradictory one-record visual decision.
@test "chosen setting contract rejects malformed states reviews and rejected history" {
	base="$(chosen_record hdr10 provisional 22)"
	for mutation in \
		'.state = "unknown"' \
		'del(.cropReview)' \
		'.globalQuality = 23' \
		'.strategyId = "qsv-hevc-la-icq-v1"' \
		'.qualityRunId = "wrong-run"' \
		'.qualityRunId = "20261315T120000Z-aaaaaaaa"' \
		'.qualityRunId = "20260230T120000Z-aaaaaaaa"' \
		'.qualityRunId = "20260815T250000Z-aaaaaaaa"' \
		'.qualityResultsSha256 = "sha256:ABC"' \
		'.cropReview.reviewedAt = "2026-13-15T12:00:00Z"' \
		'.cropReview.reviewedAt = "2026-02-30T12:00:00Z"' \
		'.cropReview.reviewedAt = "2026-08-15T25:00:00Z"' \
		'.rejectedSettings = [{globalQuality:24,stage:"crop",runId:"20260815T120000Z-aaaaaaaa",result:"failed",reviewedAt:"2026-08-15T12:00:00Z"},{globalQuality:24,stage:"plex",runId:"20260815T140000Z-bbbbbbbb",result:"failed",reviewedAt:"2026-08-15T14:00:00Z"}]' \
		'.rejectedSettings = [range(0;9) | {globalQuality:16,stage:"crop",runId:"20260815T120000Z-aaaaaaaa",result:"failed",reviewedAt:"2026-08-15T12:00:00Z"}]' \
		'.rejectedSettings = [{globalQuality:22,stage:"crop",runId:"20260815T120000Z-aaaaaaaa",result:"failed",reviewedAt:"2026-08-15T12:00:00Z"}]'; do
		candidate="$BATS_TEST_TMPDIR/chosen-$(printf '%s' "$mutation" | sha256sum | awk '{print $1}').json"
		jq --argjson record "$(jq -c "$mutation" <<<"$base")" \
			'.chosenSettings.hdr10 = $record' "$BENCHMARK_SAMPLES_FILE" >"$candidate"
		run bash -c 'source "$1"; contract_load "$2"; contract_chosen_record "$2" hdr10 provisional' \
			_ "$SCRIPTS/contract.sh" "$candidate"
		[ "$status" -ne 0 ]
	done

	final="$(chosen_record hdr10 final 22)"
	for mutation in \
		'.finalistReview = null' \
		'.finalistReview.sampleId = "hdr10-clean-ministry"' \
		'.finalistReview.checklist.hdrHandling = "not-applicable"' \
		'del(.finalistReview.checklist.blocking)'; do
		candidate="$BATS_TEST_TMPDIR/final-$(printf '%s' "$mutation" | sha256sum | awk '{print $1}').json"
		jq --argjson record "$(jq -c "$mutation" <<<"$final")" \
			'.chosenSettings.hdr10 = $record' "$BENCHMARK_SAMPLES_FILE" >"$candidate"
		run bash -c 'source "$1"; contract_load "$2"; contract_chosen_record "$2" hdr10 final' \
			_ "$SCRIPTS/contract.sh" "$candidate"
		[ "$status" -ne 0 ]
	done
}

@test "chosen setting contract admits provisional final and exhausted rejected states" {
	for state in provisional final; do
		candidate="$BATS_TEST_TMPDIR/$state.json"
		jq --argjson record "$(chosen_record avc "$state" 22)" \
			'.chosenSettings.avc = $record' "$BENCHMARK_SAMPLES_FILE" >"$candidate"
		run bash -c 'source "$1"; contract_load "$2"; contract_chosen_record "$2" avc "$3"' \
			_ "$SCRIPTS/contract.sh" "$candidate" "$state"
		[ "$status" -eq 0 ]
	done

	rejected='[{"globalQuality":16,"stage":"crop","runId":"20260815T120000Z-aaaaaaaa","result":"failed","reviewedAt":"2026-08-15T12:00:00Z"}]'
	record="$(chosen_record avc rejected 16 "$rejected" | jq -c '.cropReview.status="failed" | .cropReview.clips[0].result="failed"')"
	candidate="$BATS_TEST_TMPDIR/rejected.json"
	jq --argjson record "$record" '.chosenSettings.avc = $record' "$BENCHMARK_SAMPLES_FILE" >"$candidate"
	run bash -c 'source "$1"; contract_load "$2"; contract_chosen_record "$2" avc rejected' \
		_ "$SCRIPTS/contract.sh" "$candidate"
	[ "$status" -eq 0 ]
}

# Catches a stale or cross-run quality identity, and catches fallback being
# reconstructed from record order instead of the committed ranked artifact.
@test "chosen upstream verification binds digests run identity and ranked rejection prefix" {
	prepare_execution_run
	prepare_quality_upstream hdr10 provisional 24 '[22,24,26]' '[{"globalQuality":22,"stage":"crop","runId":"20260815T120000Z-aaaaaaaa","result":"failed","reviewedAt":"2026-08-15T12:00:00Z"}]'
	run "$SCRIPTS/benchmark.sh" _test chosen-upstream hdr10 provisional
	[ "$status" -eq 0 ]
	run jq -e --arg run "$QUALITY_RUN_ID" '
		.upstream.chosenSetting.state == "provisional" and
		.upstream.qualityResultsSha256 == .upstream.chosenSetting.qualityResultsSha256 and
		.upstream.candidateEvidenceSha256 == .upstream.chosenSetting.candidateEvidenceSha256 and
		.selectedSettings == [{cohort:"hdr10",globalQuality:24,qualityRunId:$run}]
	' <<<"$output"
	[ "$status" -eq 0 ]

	for mutation in \
		'.chosenSettings.hdr10.qualityResultsSha256 = ("sha256:" + ("d" * 64))' \
		'.chosenSettings.hdr10.qualityRunId = "20260815T120000Z-bbbbbbbb"' \
		'.chosenSettings.hdr10.rejectedSettings[0].globalQuality = 26'; do
		cp "$BENCHMARK_SAMPLES_FILE" "$BENCHMARK_SAMPLES_FILE.good"
		jq "$mutation" "$BENCHMARK_SAMPLES_FILE.good" >"$BENCHMARK_SAMPLES_FILE"
		run "$SCRIPTS/benchmark.sh" _test chosen-upstream hdr10 provisional
		[ "$status" -ne 0 ]
		mv -f -- "$BENCHMARK_SAMPLES_FILE.good" "$BENCHMARK_SAMPLES_FILE"
	done

	quality_manifest="$BENCHMARK_OUT/runs/$QUALITY_RUN_ID/manifest.json"
	cp "$quality_manifest" "$quality_manifest.good"

	# A complete manifest for a different identity must not be reusable under
	# this quality run directory even when results and candidates are unchanged.
	jq -S -c '.node.name = "swapped-node"' "$quality_manifest.good" >"$quality_manifest"
	run "$SCRIPTS/benchmark.sh" _test chosen-upstream hdr10 provisional
	[ "$status" -ne 0 ]
	cp "$quality_manifest.good" "$quality_manifest"

	# Missing canonical identity fields must fail complete schema validation.
	jq -S -c 'del(.clientDevice)' "$quality_manifest.good" >"$quality_manifest"
	run "$SCRIPTS/benchmark.sh" _test chosen-upstream hdr10 provisional
	[ "$status" -ne 0 ]
	cp "$quality_manifest.good" "$quality_manifest"

	# Manifest instants retain their compact UTC format and must also be real.
	for invalid_created_at in 20261315T120000Z 20260230T120000Z 20260815T250000Z; do
		jq -S -c --arg value "$invalid_created_at" '.createdAt = $value' \
			"$quality_manifest.good" >"$quality_manifest"
		run "$SCRIPTS/benchmark.sh" _test chosen-upstream hdr10 provisional
		[ "$status" -ne 0 ]
	done
	cp "$quality_manifest.good" "$quality_manifest"
	rm "$quality_manifest.good"
	mv "$BENCHMARK_OUT/runs" "$BATS_TEST_TMPDIR/outside-runs"
	ln -s "$BATS_TEST_TMPDIR/outside-runs" "$BENCHMARK_OUT/runs"
	run "$SCRIPTS/benchmark.sh" _test chosen-upstream hdr10 provisional
	[ "$status" -ne 0 ]
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
	printf '%s\n' ' V..... hevc_qsv Intel Quick Sync Video HEVC encoder' ' V....D libx265 libx265 H.265 / HEVC'
	exit 0
	;;
*'-hide_banner -filters'*)
	printf '%s\n' ' ... libvmaf VV->V Calculate the VMAF between two video streams.'
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
	*x265-10*) score="${BENCHMARK_X265_10_SCORE:-99}" ;;
	*x265-12*) score="${BENCHMARK_X265_12_SCORE:-99}" ;;
	*x265-14*) score="${BENCHMARK_X265_14_SCORE:-99}" ;;
	*x265-16*) score="${BENCHMARK_X265_16_SCORE:-98}" ;;
	*x265-18*) score="${BENCHMARK_X265_18_SCORE:-98}" ;;
	*x265-20*) score="${BENCHMARK_X265_20_SCORE:-96}" ;;
	*x265-22*) score="${BENCHMARK_X265_22_SCORE:-94}" ;;
	*x265-24*) score="${BENCHMARK_X265_24_SCORE:-90}" ;;
	*x265-26*) score="${BENCHMARK_X265_26_SCORE:-88}" ;;
	*x265-28*) score="${BENCHMARK_X265_28_SCORE:-86}" ;;
	*x265-30*) score="${BENCHMARK_X265_30_SCORE:-84}" ;;
	*x265-32*) score="${BENCHMARK_X265_32_SCORE:-82}" ;;
	*x265-34*) score="${BENCHMARK_X265_34_SCORE:-80}" ;;
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
if [[ "${BENCHMARK_TEST_PGS_DECODE:-0}" == '1' && "$arguments" == *'-f null -'* &&
	"$arguments" != *'libvmaf='* && " $arguments " == *' -map 0 '* ]]; then
	exit 92
fi
if [[ "${BENCHMARK_TEST_FFMPEG_CONSUME_STDIN:-0}" == '1' && " $arguments " != *' -nostdin '* ]]; then
	while IFS= read -r _line || [[ -n "${_line:-}" ]]; do :; done
fi
if [[ "${BENCHMARK_TEST_FAIL_X265_EXTENSION:-0}" == '1' && "$arguments" == *'-c:v libx265'* ]]; then
	last="${!#}"
	case "$last" in
	*x265-16-*) exit 90 ;;
	esac
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
exec "$REAL_SHA256SUM" "$@"
EOF
	chmod +x "$stub_bin/ffmpeg" "$stub_bin/ffprobe" "$stub_bin/id" "$stub_bin/sha256sum"
	export PATH="$stub_bin:$PATH"
	export BENCHMARK_COMMAND_LOG="$BATS_TEST_TMPDIR/execution-commands.log"
	export BENCHMARK_PACKET_FIXTURE="$FIXTURES/logs/audio-packets.log"
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
		--argjson required "$(capability_declared_list requiredCommands)" \
		--argjson optional "$(capability_declared_list optionalCommands)" \
		--argjson chosen "$(chosen_record hdr10 final 22)" \
		'{
			schemaVersion: 2,
			strategy: $strategy,
			runtime: {
				image: "docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb",
				requiredCommands: $required, optionalCommands: $optional
			},
			savingsSeed: 20260802,
			qualityPanel: [{
				id: "sample-hdr", cohort: "hdr10", path: $source_media,
				sizeBytes: $source_size, sha256: $source_sha,
				x265Reference: true,
				clips: {detail: "00:17:23.456"}
			}],
			savingsPanel: [{
				id: "savings-hdr", cohort: "hdr10", path: $source_media,
				sizeBytes: $source_size, sha256: $source_sha
			}],
			chosenSettings: {hdr10: $chosen}
		}' >"$BENCHMARK_SAMPLES_FILE"
	export BENCHMARK_DISPATCH_IMAGE='docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	export NODE_NAME='nuc1'
}

prepare_savings_execution_run() {
	prepare_execution_run
	prepare_quality_upstream hdr10 final 22 '[22,24,26]'
}

prepare_x265_execution_run() {
	local sample_id="$1" cohort="$2" qsv_vmaf="${3:-97}" quality_dir results results_digest candidate_digest
	local chosen upstream selected cpu_identity
	prepare_execution_run
	jq --arg sample "$sample_id" --arg cohort "$cohort" '
		.qualityPanel[0].id = $sample |
		.qualityPanel[0].cohort = $cohort |
		.qualityPanel[0].clips = {
			detail:"00:17:23.456", dark:"00:27:23.456", motion:"00:37:23.456"
		} |
		.chosenSettings = {}
	' "$BENCHMARK_SAMPLES_FILE" >"$BENCHMARK_SAMPLES_FILE.tmp"
	mv -f -- "$BENCHMARK_SAMPLES_FILE.tmp" "$BENCHMARK_SAMPLES_FILE"
	prepare_quality_upstream "$cohort" final 22 '[22,24,26]'
	quality_dir="$BENCHMARK_OUT/runs/$QUALITY_RUN_ID"
	results="$quality_dir/results.csv"
	printf '%s\n' \
		'run_id,panel,sample_id,cohort,source_sha256,clip_id,encoder,requested_setting,selected_rate_control,status,attempt,input_bytes,output_bytes,reduction_percent,input_bit_rate,output_bit_rate,wall_seconds,encode_fps,encode_speed,vmaf_harmonic_mean,vmaf_1pct_low,ssim,gpu_busy_percent,qsv_proof,validation_codec,validation_duration,validation_resolution,validation_frame_rate,validation_bit_depth,validation_hdr,validation_audio_tracks,validation_subtitle_tracks,validation_chapters,validation_failures,log_path,output_disposition,strategy_id,qsv_initialization,video_busy_nanoseconds' \
		"$QUALITY_RUN_ID,quality,$sample_id,$cohort,$source_sha,detail,qsv,22,ICQ,passed,1,1000,600,40,10000,8000,10,30,1,$qsv_vmaf,92,0.99,50,passed,passed,passed,passed,passed,passed,passed,passed,passed,passed,,logs/detail.log,discarded,qsv-hevc-icq-v1,passed,800000000" \
		"$QUALITY_RUN_ID,quality,$sample_id,$cohort,$source_sha,dark,qsv,22,ICQ,passed,1,1000,600,40,10000,8000,10,30,1,$qsv_vmaf,92,0.99,50,passed,passed,passed,passed,passed,passed,passed,passed,passed,passed,,logs/dark.log,discarded,qsv-hevc-icq-v1,passed,800000000" \
		"$QUALITY_RUN_ID,quality,$sample_id,$cohort,$source_sha,motion,qsv,22,ICQ,passed,1,1000,600,40,10000,8000,10,30,1,$qsv_vmaf,92,0.99,50,passed,passed,passed,passed,passed,passed,passed,passed,passed,passed,,logs/motion.log,discarded,qsv-hevc-icq-v1,passed,800000000" \
		>"$results"
	results_digest="sha256:$(sha256sum "$results" | awk '{print $1}')"
	jq --arg digest "$results_digest" '.resultsSha256 = $digest | .cohorts |= with_entries(
		.value.expectedClipCount = 3)' "$quality_dir/quality-candidates.json" \
		>"$quality_dir/quality-candidates.tmp"
	mv -f -- "$quality_dir/quality-candidates.tmp" "$quality_dir/quality-candidates.json"
	candidate_digest="sha256:$(sha256sum "$quality_dir/quality-candidates.json" | awk '{print $1}')"
	jq --arg cohort "$cohort" --arg results "$results_digest" --arg candidates "$candidate_digest" '
		.chosenSettings[$cohort].qualityResultsSha256 = $results |
		.chosenSettings[$cohort].candidateEvidenceSha256 = $candidates
	' "$BENCHMARK_SAMPLES_FILE" >"$BENCHMARK_SAMPLES_FILE.tmp"
	mv -f -- "$BENCHMARK_SAMPLES_FILE.tmp" "$BENCHMARK_SAMPLES_FILE"
	chosen="$(jq -c --arg cohort "$cohort" '.chosenSettings[$cohort]' "$BENCHMARK_SAMPLES_FILE")"
	selected="$(jq -n -c --arg cohort "$cohort" --argjson chosen "$chosen" \
		'[{cohort:$cohort,globalQuality:$chosen.globalQuality,qualityRunId:$chosen.qualityRunId}]')"
	upstream="$(jq -n -c --arg cohort "$cohort" --argjson chosen "$chosen" \
		--arg manifest "sha256:$(sha256sum "$quality_dir/manifest.json" | awk '{print $1}')" \
		--arg results "$results_digest" --arg candidates "$candidate_digest" '{
			cohort:$cohort, chosenSetting:$chosen, qualityManifestSha256:$manifest,
			qualityResultsSha256:$results, candidateEvidenceSha256:$candidates
		}')"
	cpu_identity="$BATS_TEST_TMPDIR/cpu-identity-$sample_id.json"
	jq --argjson selected "$selected" --argjson upstream "$upstream" '
		.gpu = null |
		.cpu = {model:"fixture CPU",ffmpeg:"8.1.2 fixture-build",libx265:"4.1+1"} |
		.node = {name:"nuc3",kernel:"6.12.0-fixture"} |
		.selectedSettings = $selected | .upstream = $upstream
	' "$FIXTURES/manifests/identity.json" >"$cpu_identity"
	export BENCHMARK_IDENTITY_FIXTURE="$cpu_identity"
	export NODE_NAME='nuc3'
}

expand_execution_panels_to_three_samples() {
	local quality='[]' savings='[]' index source size sha quality_item savings_item
	for index in 1 2 3; do
		source="$BATS_TEST_TMPDIR/source-$index.mkv"
		printf 'source fixture bytes %s' "$index" >"$source"
		size="$(wc -c <"$source" | tr -d ' ')"
		sha="$(sha256sum "$source" | awk '{print $1}')"
		quality_item="$(jq -n --arg id "quality-$index" --arg path "$source" \
			--arg sha "$sha" --argjson size "$size" '{
				id:$id, cohort:"hdr10", path:$path, sizeBytes:$size, sha256:$sha,
				x265Reference:false, clips:{detail:"00:17:23.456"}
			}')"
		savings_item="$(jq -n --arg id "savings-$index" --arg path "$source" \
			--arg sha "$sha" --argjson size "$size" '{
				id:$id, cohort:"hdr10", path:$path, sizeBytes:$size, sha256:$sha
			}')"
		quality="$(jq -c --argjson item "$quality_item" '. + [$item]' <<<"$quality")"
		savings="$(jq -c --argjson item "$savings_item" '. + [$item]' <<<"$savings")"
	done
	jq --argjson quality "$quality" --argjson savings "$savings" \
		'.qualityPanel = $quality | .savingsPanel = $savings' \
		"$BENCHMARK_SAMPLES_FILE" >"$BENCHMARK_SAMPLES_FILE.tmp"
	mv -f -- "$BENCHMARK_SAMPLES_FILE.tmp" "$BENCHMARK_SAMPLES_FILE"
}

prepare_quality_panel_with_six_titles_three_clips() {
	local quality='[]' index source size sha cohort item
	for index in 1 2 3 4 5 6; do
		source="$BATS_TEST_TMPDIR/quality-source-$index.mkv"
		printf 'quality source fixture bytes %s' "$index" >"$source"
		size="$(wc -c <"$source" | tr -d ' ')"
		sha="$(sha256sum "$source" | awk '{print $1}')"
		case "$index" in
		1|2) cohort='avc' ;;
		3|4) cohort='vc1' ;;
		5|6) cohort='hdr10' ;;
		esac
		item="$(jq -n --arg id "quality-$index" --arg cohort "$cohort" --arg path "$source" \
			--arg sha "$sha" --argjson size "$size" '{
				id: $id, cohort: $cohort, path: $path, sizeBytes: $size, sha256: $sha,
				clips: {detail: "00:17:23.456", motion: "00:27:23.456", grain: "00:37:23.456"}
			}')"
		quality="$(jq -c --argjson item "$item" '. + [$item]' <<<"$quality")"
	done
	jq --argjson quality "$quality" '.qualityPanel = $quality | .savingsPanel = [] | .chosenSettings = {}' \
		"$BENCHMARK_SAMPLES_FILE" >"$BENCHMARK_SAMPLES_FILE.tmp"
	mv -f -- "$BENCHMARK_SAMPLES_FILE.tmp" "$BENCHMARK_SAMPLES_FILE"
}

write_quality_ranking_results() {
	local results="$1" run_id="$2" sample sample_id cohort sha clip setting reduction vmaf status failures
	printf '%s\n' 'run_id,panel,sample_id,cohort,source_sha256,clip_id,encoder,requested_setting,selected_rate_control,status,attempt,input_bytes,output_bytes,reduction_percent,input_bit_rate,output_bit_rate,wall_seconds,encode_fps,encode_speed,vmaf_harmonic_mean,vmaf_1pct_low,ssim,gpu_busy_percent,qsv_proof,validation_codec,validation_duration,validation_resolution,validation_frame_rate,validation_bit_depth,validation_hdr,validation_audio_tracks,validation_subtitle_tracks,validation_chapters,validation_failures,log_path,output_disposition,strategy_id,qsv_initialization,video_busy_nanoseconds' >"$results"
	while IFS= read -r sample; do
		sample_id="$(jq -r '.id' <<<"$sample")"
		cohort="$(jq -r '.cohort' <<<"$sample")"
		sha="$(jq -r '.sha256' <<<"$sample")"
		for clip in detail motion grain; do
			for setting in 16 18 20 22 24; do
				case "$setting:$clip" in
				16:detail|24:detail) reduction='20' ;;
				16:motion|24:motion) reduction='35' ;;
				16:grain|24:grain) reduction='50' ;;
				18:detail) reduction='15' ;;
				18:motion) reduction='25' ;;
				18:grain) reduction='35' ;;
				*) reduction='30' ;;
				esac
				vmaf='96'
				status='passed'
				failures=''
				if [[ "$setting" == '20' && "$clip" == 'detail' ]]; then vmaf='89'; fi
				if [[ "$setting" == '22' && "$clip" == 'motion' ]]; then status='invalid'; failures='codec'; fi
				if [[ "$cohort" == 'vc1' && "$setting" == '24' && "$clip" == 'detail' ]]; then vmaf='89'; fi
				if [[ "$cohort" == 'vc1' && "$setting" == '16' && "$clip" == 'detail' ]]; then vmaf='89'; fi
				if [[ "$cohort" == 'vc1' && "$setting" == '18' && "$clip" == 'motion' ]]; then status='invalid'; failures='codec'; fi
				printf '%s,quality,%s,%s,%s,%s,qsv,%s,ICQ,%s,1,1000,650,%s,1000,650,1.000000,72.0,1.25,%s,91,0.991,50.0,passed,passed,passed,passed,passed,passed,passed,passed,passed,passed,%s,logs/%s-%s-%s.log,discarded,qsv-hevc-icq-v1,passed,800000000\n' \
					"$run_id" "$sample_id" "$cohort" "$sha" "$clip" "$setting" "$status" "$reduction" "$vmaf" "$failures" "$sample_id" "$clip" "$setting" >>"$results"
			done
		done
	done < <(jq -c '.qualityPanel[]' "$BENCHMARK_SAMPLES_FILE")
}

# Catches a production break where the durable result contract drifts from the
# exact schema that runmeta uses to decide whether a variant is resumable.
@test "results header is the exact 39-column ICQ resume schema" {
	run "$SCRIPTS/benchmark.sh" _test results-header
	[ "$status" -eq 0 ]
	[ "$output" = 'run_id,panel,sample_id,cohort,source_sha256,clip_id,encoder,requested_setting,selected_rate_control,status,attempt,input_bytes,output_bytes,reduction_percent,input_bit_rate,output_bit_rate,wall_seconds,encode_fps,encode_speed,vmaf_harmonic_mean,vmaf_1pct_low,ssim,gpu_busy_percent,qsv_proof,validation_codec,validation_duration,validation_resolution,validation_frame_rate,validation_bit_depth,validation_hdr,validation_audio_tracks,validation_subtitle_tracks,validation_chapters,validation_failures,log_path,output_disposition,strategy_id,qsv_initialization,video_busy_nanoseconds' ]
}

@test "benchmark failure hooks are rejected outside test mode" {
	unset BENCHMARK_OUT BENCHMARK_SCRATCH BENCHMARK_SAMPLES_FILE
	export BENCHMARK_TEST_MODE=0
	export BENCHMARK_TEST_FAIL_RESULT_APPEND=1
	run "$SCRIPTS/benchmark.sh" _test results-header
	[ "$status" -eq 64 ]
	[ "$output" = 'BENCHMARK_TEST_* hooks require BENCHMARK_TEST_MODE=1' ]

	unset BENCHMARK_TEST_FAIL_RESULT_APPEND
	export BENCHMARK_TEST_FAIL_AUDIO_INVENTORY_WRITE=1
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
		.hevcQsv == true and .libx265 == true and
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

# Catches a production break where the requested LA-ICQ controls, lossless clip
# extraction, stream preservation, or reference/distorted ordering drifts.
@test "quality command construction preserves exact clip QSV x265 VMAF and SSIM contracts" {
	run "$SCRIPTS/benchmark.sh" _test commands \
		'/media/Movie.mkv' '00:17:23.456' '/scratch/detail.mkv' \
		'/scratch/qsv-22.mkv' '/scratch/x265-20.mkv' '/scratch/vmaf.json' 22 20
	[ "$status" -eq 0 ]
	commands="$output"

	run jq -e '
		.clip == ["ffmpeg","-nostdin","-v","error","-ss","00:17:23.456","-i","/media/Movie.mkv","-t","90","-map","0","-c","copy","/scratch/detail.mkv"] and
		.qsv == ["ffmpeg","-nostdin","-v","verbose","-init_hw_device","qsv=hw:/dev/dri/renderD128","-filter_hw_device","hw","-i","/scratch/detail.mkv","-map","0","-c:v","hevc_qsv","-preset","veryslow","-global_quality","22","-look_ahead","0","-extbrc","0","-c:a","copy","-c:s","copy","-map_metadata","0","-map_chapters","0","/scratch/qsv-22.mkv"] and
		.x265 == ["ffmpeg","-nostdin","-v","verbose","-i","/scratch/detail.mkv","-map","0","-c:v","libx265","-preset","slow","-crf","20","-c:a","copy","-c:s","copy","-map_metadata","0","-map_chapters","0","/scratch/x265-20.mkv"] and
		.vmaf == ["ffmpeg","-nostdin","-v","error","-i","/scratch/qsv-22.mkv","-i","/scratch/detail.mkv","-lavfi","[0:v][1:v]libvmaf=model=version=vmaf_4k_v0.6.1:log_fmt=json:log_path=/scratch/vmaf.json","-f","null","-"] and
		.ssim == ["ffmpeg","-nostdin","-v","info","-i","/scratch/qsv-22.mkv","-i","/scratch/detail.mkv","-lavfi","[0:v][1:v]ssim","-f","null","-"]
	' <<<"$commands"
	[ "$status" -eq 0 ]
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
@test "savings statistics emit Tukey q1 q3 IQR median and threshold verdict" {
	run "$SCRIPTS/benchmark.sh" _test savings-stats \
		"$FIXTURES/metrics/savings-distribution.json"
	[ "$status" -eq 0 ]
	[ "$output" = '{"count":8,"median":45.000000,"q1":25.000000,"q3":65.000000,"iqr":40.000000,"verdict":"GO"}' ]

	run "$SCRIPTS/benchmark.sh" _test savings-stats \
		"$FIXTURES/metrics/savings-distribution-odd.json"
	[ "$status" -eq 0 ]
	[ "$output" = '{"count":7,"median":40.000000,"q1":20.000000,"q3":60.000000,"iqr":40.000000,"verdict":"GO"}' ]
}

# Catches extrapolation or selection of non-adjacent x265 measurements at a
# QSV operating point between two measured VMAF values.
@test "x265 comparison interpolates adjacent points and calculates bitrate premium" {
	run "$SCRIPTS/benchmark.sh" _test x265-match "$FIXTURES/metrics/x265-bracketed.json"
	[ "$status" -eq 0 ]
	[ "$output" = '{"status":"bracketed","lower_crf":24,"upper_crf":22,"matched_bit_rate":6000.000000,"premium_percent":33.333333}' ]
}

# Catches VMAF sorting selecting CRFs that are not adjacent passed points when
# a measured curve is locally non-monotonic.
@test "x265 comparison brackets only adjacent passed CRFs" {
	non_monotonic="$BATS_TEST_TMPDIR/x265-non-monotonic.json"
	printf '%s\n' '{"points":[{"crf":18,"vmaf":96,"bitRate":8000},{"crf":20,"vmaf":91,"bitRate":5000},{"crf":22,"vmaf":94,"bitRate":6500},{"crf":24,"vmaf":90,"bitRate":4000}],"qsvVmaf":95,"qsvBitRate":9000}' >"$non_monotonic"

	run "$SCRIPTS/benchmark.sh" _test x265-match "$non_monotonic"
	[ "$status" -eq 0 ]
	run jq -e '.status == "bracketed" and .lower_crf == 20 and .upper_crf == 18' <<<"$output"
	[ "$status" -eq 0 ]
}

# Catches accidental extrapolation after the lower-CRF extension has reached
# the hard CRF 10 boundary without bracketing the QSV quality point.
@test "x265 comparison emits unbracketed at the CRF boundary" {
	run "$SCRIPTS/benchmark.sh" _test x265-match "$FIXTURES/metrics/x265-unbracketed.json"
	[ "$status" -eq 0 ]
	[ "$output" = '{"status":"unbracketed"}' ]
}

# Catches extending both ends of the CPU reference sweep, skipping by more than
# two, or continuing beyond CRF 10/34.
@test "x265 sweep extends only the side needed in steps of two" {
	low_side="$BATS_TEST_TMPDIR/low-side.json"
	high_side="$BATS_TEST_TMPDIR/high-side.json"
	printf '%s\n' '{"points":[{"crf":18,"vmaf":96,"bitRate":7000},{"crf":20,"vmaf":94,"bitRate":6000},{"crf":22,"vmaf":92,"bitRate":5000},{"crf":24,"vmaf":90,"bitRate":4000}],"qsvVmaf":98,"qsvBitRate":8000}' >"$low_side"
	printf '%s\n' '{"points":[{"crf":18,"vmaf":96,"bitRate":7000},{"crf":20,"vmaf":94,"bitRate":6000},{"crf":22,"vmaf":92,"bitRate":5000},{"crf":24,"vmaf":90,"bitRate":4000}],"qsvVmaf":88,"qsvBitRate":3000}' >"$high_side"

	run "$SCRIPTS/benchmark.sh" _test x265-next "$low_side"
	[ "$status" -eq 0 ]
	[ "$output" = '{"status":"extend","next_crf":16}' ]
	run "$SCRIPTS/benchmark.sh" _test x265-next "$high_side"
	[ "$status" -eq 0 ]
	[ "$output" = '{"status":"extend","next_crf":26}' ]
}

# Catches accepting an arbitrary quality title, a renamed reference, or a
# non-reference sample before x265 creates a durable run directory.
@test "x265 mode accepts only the two exact reference sample identities" {
	prepare_execution_run
	for sample_id in sample-hdr avc-clean-coco hdr10-motion-john-wick-2 ../escape; do
		run "$SCRIPTS/benchmark.sh" x265 '20260815T130000Z-bbbbbbbb' "$sample_id"
		[ "$status" -ne 0 ]
		[ "$(find "$BENCHMARK_OUT/runs" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq 0 ]
	done
}

# Catches x265 falling back into the GPU quality path, omitting one clip or
# initial CRF, coupling SSIM to the matched-quality decision, or publishing a
# comparison that is not tied to both immutable run identities.
@test "x265 runs both reference-title shapes as independent CPU-only curves" {
	for fixture in 'avc-grain-memento avc' 'hdr10-grain-goodfellas hdr10'; do
		read -r sample_id cohort <<<"$fixture"
		rm -rf -- "$BENCHMARK_OUT" "$BENCHMARK_SCRATCH"
		mkdir -p "$BENCHMARK_OUT/runs" "$BENCHMARK_SCRATCH"
		prepare_x265_execution_run "$sample_id" "$cohort"
		run_id="20260815T130000Z-bbbbbbbb"

		run "$SCRIPTS/benchmark.sh" x265 "$run_id" "$sample_id"
		[ "$status" -eq 0 ]
		[ "$output" = "$run_id" ]
		results="$BENCHMARK_OUT/runs/$run_id/results.csv"
		comparisons="$BENCHMARK_OUT/runs/$run_id/x265-comparisons.jsonl"
		manifest="$BENCHMARK_OUT/runs/$run_id/manifest.json"
		[ "$(awk -F, 'NR > 1 {count += 1} END {print count + 0}' "$results")" -eq 12 ]
		run awk -F, '
			NR > 1 {
				if ($2 != "x265" || $3 != sample || $7 != "x265" ||
					$8 !~ /^(18|20|22|24)$/ || $9 != "CRF" || $10 != "passed" ||
					$20 == "" || $22 != "" || $38 != "not-applicable" || $39 != "0") exit 1
				keys[$6 "|" $8] = 1
			}
			END { if (length(keys) != 12) exit 1 }
		' sample="$sample_id" "$results"
		[ "$status" -eq 0 ]
		[ "$(wc -l <"$comparisons" | tr -d ' ')" -eq 3 ]
		run jq -e -s --arg quality "$QUALITY_RUN_ID" --arg x265 "$run_id" --arg sample "$sample_id" '
			length == 3 and
			all(.[];
				keys == ["clipId","lowerCrf","matchedBitRate","premiumPercent","qsvSetting",
					"qualityRunId","sampleId","status","strategyId","upperCrf","x265RunId"] and
				.strategyId == "qsv-hevc-icq-v1" and .qualityRunId == $quality and
				.x265RunId == $x265 and .sampleId == $sample and .qsvSetting == 22 and
				.status == "bracketed" and .lowerCrf == 20 and .upperCrf == 18 and
				(.matchedBitRate | type == "number") and (.premiumPercent | type == "number")) and
			([.[].clipId] | sort) == ["dark","detail","motion"]
		' "$comparisons"
		[ "$status" -eq 0 ]
		run jq -e --arg quality "$QUALITY_RUN_ID" --arg sample "$sample_id" '
			.gpu == null and .cpu == {ffmpeg:"8.1.2 fixture-build",libx265:"4.1+1",model:"fixture CPU"} and
			.node == {kernel:"6.12.0-fixture",name:"nuc3"} and
			.selectedSettings == [{cohort:(if $sample == "avc-grain-memento" then "avc" else "hdr10" end),globalQuality:22,qualityRunId:$quality}] and
			.upstream.qualityResultsSha256 == .upstream.chosenSetting.qualityResultsSha256
		' "$manifest"
		[ "$status" -eq 0 ]
		run rg -q -- '-init_hw_device|-c:v hevc_qsv' "$BENCHMARK_COMMAND_LOG"
		[ "$status" -eq 1 ]
		[ "$(rg -c -- 'libvmaf=model=version=vmaf_4k_v0.6.1:log_fmt=json:log_path=' "$BENCHMARK_COMMAND_LOG")" -eq 12 ]
		run rg -q -- '\[0:v\]\[1:v\]ssim' "$BENCHMARK_COMMAND_LOG"
		[ "$status" -eq 1 ]
	done
}

# Catches an invalid extension attempt disappearing on resume, a failed point
# becoming interpolation input, or the bounded curve moving by anything other
# than two without staying inside CRF 10 through 34.
@test "x265 retains failed attempts and extends the bounded curve by two" {
	prepare_x265_execution_run avc-grain-memento avc 99
	export BENCHMARK_TEST_FAIL_X265_EXTENSION=1
	run_id='20260815T130000Z-bbbbbbbb'

	run "$SCRIPTS/benchmark.sh" x265 "$run_id" avc-grain-memento
	[ "$status" -eq 0 ]
	results="$BENCHMARK_OUT/runs/$run_id/results.csv"
	[ "$(awk -F, 'NR > 1 && $8 == 16 && $10 == "failed" {count += 1} END {print count + 0}' "$results")" -eq 3 ]
	[ "$(awk -F, 'NR > 1 && $8 == 14 && $10 == "passed" {count += 1} END {print count + 0}' "$results")" -eq 3 ]
	run awk -F, 'NR > 1 && ($8 < 10 || $8 > 34 || $8 % 2 != 0) {exit 1}' "$results"
	[ "$status" -eq 0 ]
	run jq -e -s 'all(.[]; .status == "bracketed" and .lowerCrf == 14 and .upperCrf == 14)' \
		"$BENCHMARK_OUT/runs/$run_id/x265-comparisons.jsonl"
	[ "$status" -eq 0 ]
}

# Catches trusting the requested QSV mode instead of verbose runtime evidence or
# accepting initialization without a non-zero video-engine busy delta.
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

@test "title-level HDR metadata is the static HDR oracle for a clip" {
	run "$SCRIPTS/benchmark.sh" _test validate-probes \
		"$FIXTURES/metrics/probe-source-clip-hdr-missing.json" \
		"$FIXTURES/metrics/probe-output-valid.json" clip 0 \
		"$FIXTURES/metrics/probe-source.json"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.validation_hdr' <<<"$output")" = 'passed' ]
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

	for fixture in variant-fallback variant-invalid-output variant-passed; do
		scratch_output="$BENCHMARK_SCRATCH/$fixture.mkv"
		printf '%s' 'encoded bytes' >"$scratch_output"
		run "$SCRIPTS/benchmark.sh" _test record-result \
			"$run_id" "$FIXTURES/metrics/$fixture.json" "$scratch_output"
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
	scratch_output="$BENCHMARK_SCRATCH/missing-qsv-evidence.mkv"
	printf '%s' 'encoded bytes' >"$scratch_output"

	run "$SCRIPTS/benchmark.sh" _test record-result "$run_id" "$fixture" "$scratch_output"
	[ "$status" -eq 0 ]
	[ "$output" = '{"status":"invalid","attempt":1,"output_disposition":"discarded"}' ]
	run awk -F, 'NR == 2 {print $10 "," $38 "," $39}' "$run_dir/results.csv"
	[ "$status" -eq 0 ]
	[ "$output" = 'invalid,failed,0' ]
}

# Catches x265 rows carrying QSV proof values instead of the explicit
# not-applicable zero pair, which would make CPU and GPU evidence ambiguous.
@test "result recording rejects malformed x265 QSV evidence before append" {
	run_id='20260802T120000Z-aaaaaaaa'
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	mkdir -p "$run_dir"
	fixture="$BATS_TEST_TMPDIR/malformed-x265-evidence.json"
	jq '.encoder = "x265" | .selected_rate_control = "CRF" | .qsv_initialization = "passed" | .video_busy_nanoseconds = "800000000"' \
		"$FIXTURES/metrics/variant-passed.json" >"$fixture"
	scratch_output="$BENCHMARK_SCRATCH/malformed-x265-evidence.mkv"
	printf '%s' 'encoded bytes' >"$scratch_output"

	run "$SCRIPTS/benchmark.sh" _test record-result "$run_id" "$fixture" "$scratch_output"
	[ "$status" -eq 65 ]
	[ "$output" = 'x265 result must use not-applicable QSV evidence' ]
	[ ! -e "$scratch_output" ]
	[ ! -e "$run_dir/results.csv" ]
}

# Catches copying an invalid/unconfirmed full encode to the shared output or
# losing the run/sample binding in the operator's finalist confirmation.
@test "finalist output is copied only after passed validation and exact confirmation" {
	prepare_execution_run
	prepare_quality_upstream avc provisional 22 '[22,24,26]'
	run_id='20260802T120000Z-aaaaaaaa'
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	mkdir -p "$run_dir"
	finalist_row="$BATS_TEST_TMPDIR/finalist.json"
	jq '.panel = "finalist" | .clip_id = "full" | .sample_id = "avc-grain-memento"' \
		"$FIXTURES/metrics/variant-passed.json" >"$finalist_row"
	scratch_output="$BENCHMARK_SCRATCH/finalist.mkv"
	printf '%s' 'finalist bytes' >"$scratch_output"

	run "$SCRIPTS/benchmark.sh" _test record-result "$run_id" "$finalist_row" "$scratch_output"
	[ "$status" -eq 64 ]
	[ "$output" = "missing finalist confirmation for $run_id/avc-grain-memento" ]
	[ ! -e "$scratch_output" ]
	[ ! -e "$run_dir/encodes/avc-grain-memento-qsv-gq22.mkv" ]

	printf '%s' 'finalist bytes' >"$scratch_output"
	export ENCODE_BENCHMARK_FINALIST_CONFIRM="copy:encode-benchmark:$run_id:avc-grain-memento"
	run "$SCRIPTS/benchmark.sh" _test record-result "$run_id" "$finalist_row" "$scratch_output"
	[ "$status" -eq 0 ]
	[ "$output" = '{"status":"passed","attempt":1,"output_disposition":"copied"}' ]
	[ ! -e "$scratch_output" ]
	[ "$(<"$run_dir/encodes/avc-grain-memento-qsv-gq22.mkv")" = 'finalist bytes' ]
}

# Catches omissions from the shared eight-setting sweep, x265 work leaking into
# quality, coupled metrics, FFmpeg consuming the sample loop, and lost stills.
@test "quality runs all six titles three clips and eight ICQ settings without x265" {
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
    for clip in ("detail", "motion", "grain")
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
	[ "$(find "$run_dir/stills" -type f -name '*.png' | wc -l | tr -d ' ')" -eq 288 ]
	[ ! -d "$run_dir/encodes" ]
	[ "$(find "$BENCHMARK_SCRATCH" -type f | wc -l | tr -d ' ')" -eq 0 ]
	[ -f "$run_dir/quality-candidates.json" ]

	run awk '$1 != "sha256sum" && $0 !~ /(^| )-nostdin( |$)/ {exit 1}' "$BENCHMARK_COMMAND_LOG"
	[ "$status" -eq 0 ]
	run rg -q -- '-c:v libx265' "$BENCHMARK_COMMAND_LOG"
	[ "$status" -eq 1 ]
	[ "$(rg -c -- 'libvmaf=model=version=vmaf_4k_v0.6.1:log_fmt=json:log_path=' "$BENCHMARK_COMMAND_LOG")" -eq 144 ]
	[ "$(rg -c -- '\[0:v\]\[1:v\]ssim' "$BENCHMARK_COMMAND_LOG")" -eq 144 ]
}

@test "PGS decode maps video only while probe validation still detects subtitle loss" {
	prepare_execution_run
	export BENCHMARK_TEST_PGS_DECODE=1
	run "$SCRIPTS/benchmark.sh" quality
	[ "$status" -eq 0 ]
	run rg -F -- '-nostdin -v error -i ' "$BENCHMARK_COMMAND_LOG"
	[ "$status" -eq 0 ]
	run awk '
		/-f null -$/ && !/nullsrc=size=16x16/ && !/libvmaf=/ && !/\[0:v\]\[1:v\]ssim/ {
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

@test "savings processes every sample when FFmpeg would otherwise consume loop stdin" {
	prepare_savings_execution_run
	expand_execution_panels_to_three_samples
	export BENCHMARK_TEST_FFMPEG_CONSUME_STDIN=1
	run "$SCRIPTS/runmeta.sh" create savings
	[ "$status" -eq 0 ]
	run_id="$output"
	run "$SCRIPTS/benchmark.sh" savings "$run_id"
	[ "$status" -eq 0 ]
	results="$BENCHMARK_OUT/runs/$run_id/results.csv"
	[ "$(awk -F, 'NR > 1 {count += 1} END {print count + 0}' "$results")" -eq 3 ]
	run awk '$1 != "sha256sum" && $0 !~ /(^| )-nostdin( |$)/ {exit 1}' "$BENCHMARK_COMMAND_LOG"
	[ "$status" -eq 0 ]
}

@test "quality candidates require complete objective evidence and rank median reductions" {
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
	run jq --arg digest "$actual_digest" '.resultsSha256 = $digest' "$FIXTURES/metrics/quality-candidates.json"
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

	# This stays a 39-column QSV passed row, but cannot be resumed because
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
			{globalQuality: 18, medianReductionPercent: 25}
		]
	' "$run_dir/quality-candidates.json"
	[ "$status" -eq 0 ]
}

@test "quality records probe metric and parser failures cleans scratch and continues the panel" {
	invalid_json="$BATS_TEST_TMPDIR/invalid-probe.json"
	printf '%s\n' '{' >"$invalid_json"
	case_number=0
	for failure in source-probe output-probe vmaf-command vmaf-parse ssim-command ssim-parse; do
		case_number=$((case_number + 1))
		rm -rf -- "$BENCHMARK_OUT" "$BENCHMARK_SCRATCH"
		mkdir -p "$BENCHMARK_OUT/runs" "$BENCHMARK_SCRATCH"
		prepare_execution_run
		unset BENCHMARK_TEST_VMAF_COMMAND_FAILURE BENCHMARK_TEST_VMAF_PARSE_FAILURE
		unset BENCHMARK_TEST_SSIM_COMMAND_FAILURE BENCHMARK_TEST_SSIM_PARSE_FAILURE
		export BENCHMARK_TEST_SOURCE_PROBE="$FIXTURES/metrics/probe-source.json"
		export BENCHMARK_TEST_OUTPUT_PROBE="$FIXTURES/metrics/probe-output-valid.json"
		case "$failure" in
		source-probe) export BENCHMARK_TEST_SOURCE_PROBE="$invalid_json" ;;
		output-probe) export BENCHMARK_TEST_OUTPUT_PROBE="$invalid_json" ;;
		vmaf-command) export BENCHMARK_TEST_VMAF_COMMAND_FAILURE=1 ;;
		vmaf-parse) export BENCHMARK_TEST_VMAF_PARSE_FAILURE=1 ;;
		ssim-command) export BENCHMARK_TEST_SSIM_COMMAND_FAILURE=1 ;;
		ssim-parse) export BENCHMARK_TEST_SSIM_PARSE_FAILURE=1 ;;
		esac
		run "$SCRIPTS/benchmark.sh" quality
		[ "$status" -eq 0 ]
		run_id="$output"
		results="$BENCHMARK_OUT/runs/$run_id/results.csv"
		run awk -F, 'NR > 1 { count += 1; if ($10 != "failed" && $10 != "invalid") exit 1 } END { print count }' "$results"
		[ "$status" -eq 0 ]
		[ "$output" = '8' ]
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
		'sample-hdr-detail-qsv-20-attempt-*-vmaf.json'; do
		[ "$(find "$BENCHMARK_OUT/runs/$run_id/logs" -type f -name "$evidence_pattern" | wc -l | tr -d ' ')" -eq 3 ]
	done
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
		all(.[]; contains("-c:v libx265") | not)
	' "$manifest"
	[ "$status" -eq 0 ]
}

# Catches a full-title pass that ignores the committed cohort setting, retains
# the scratch encode, or omits packet-counted audio inventory evidence.
@test "savings mode uses committed settings inventories packets and discards full output" {
	prepare_savings_execution_run
	set_chosen_record avc final 24
	unset BENCHMARK_IDENTITY_FIXTURE
	export BENCHMARK_RUNNING_IMAGE="$BENCHMARK_DISPATCH_IMAGE"
	export BENCHMARK_I915_VERSION='fixture-i915'
	export BENCHMARK_VPL_VERSION='fixture-vpl'
	run_id='20260802T121500Z-deadbeef'

	run "$SCRIPTS/benchmark.sh" savings "$run_id"
	[ "$status" -eq 0 ]
	[ "$output" = "$run_id" ]
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	run python3 - "$run_dir/results.csv" <<'PYTHON'
import csv
import json
import sys

with open(sys.argv[1], newline="", encoding="utf-8") as stream:
    rows = list(csv.DictReader(stream))
print(json.dumps(rows, sort_keys=True, separators=(",", ":")))
PYTHON
	[ "$status" -eq 0 ]
	run jq -e '
		length == 1 and .[0].panel == "savings" and .[0].sample_id == "savings-hdr" and
		.[0].encoder == "qsv" and .[0].requested_setting == "22" and
		.[0].status == "passed" and .[0].output_disposition == "discarded"
	' <<<"$output"
	[ "$status" -eq 0 ]
	run rg -F '"packet-counted"' "$run_dir/audio-inventory.csv"
	[ "$status" -eq 0 ]
	run jq -e --arg run "$QUALITY_RUN_ID" '
		.selectedSettings == [{cohort:"hdr10",globalQuality:22,qualityRunId:$run}]
	' "$run_dir/manifest.json"
	[ "$status" -eq 0 ]
	[ "$(find "$BENCHMARK_SCRATCH" -type f | wc -l | tr -d ' ')" -eq 0 ]
}

@test "savings rejects detection-only and Dolby Vision and records packet inventory failure before resume" {
	prepare_savings_execution_run
	# jq edit rather than YAML text surgery: the samples artifact is JSON so the
	# runtime image can read it with jq instead of yq.
	source_media="$(jq -r '.savingsPanel[0].path' "$BENCHMARK_SAMPLES_FILE")"
	source_size="$(wc -c <"$source_media" | tr -d ' ')"
	source_sha="$(sha256sum "$source_media" | awk '{print $1}')"
	jq --arg path "$source_media" --argjson size "$source_size" --arg sha "$source_sha" '
		.savingsPanel += [
			{id: "savings-dv", cohort: "dolby-vision", path: $path,
			 sizeBytes: $size, sha256: $sha, detectionOnly: false},
			{id: "savings-detection", cohort: "hdr10", path: $path,
			 sizeBytes: $size, sha256: $sha, detectionOnly: true}
		]
	' "$BENCHMARK_SAMPLES_FILE" >"$BENCHMARK_SAMPLES_FILE.tmp"
	mv -f -- "$BENCHMARK_SAMPLES_FILE.tmp" "$BENCHMARK_SAMPLES_FILE"
	run "$SCRIPTS/runmeta.sh" create savings
	[ "$status" -eq 0 ]
	run_id="$output"
	run "$SCRIPTS/benchmark.sh" savings "$run_id"
	[ "$status" -eq 0 ]
	[ "$(awk -F, 'NR > 1 { count += 1 } END { print count + 0 }' "$BENCHMARK_OUT/runs/$run_id/results.csv")" -eq 1 ]
	run rg -F 'savings-dv,dolby-vision,detection-only' "$BENCHMARK_OUT/runs/$run_id/skips.csv"
	[ "$status" -eq 0 ]
	run rg -F 'savings-detection,hdr10,detection-only' "$BENCHMARK_OUT/runs/$run_id/skips.csv"
	[ "$status" -eq 0 ]

	rm -rf -- "$BENCHMARK_OUT" "$BENCHMARK_SCRATCH"
	mkdir -p "$BENCHMARK_OUT/runs" "$BENCHMARK_SCRATCH"
	prepare_savings_execution_run
	export BENCHMARK_TEST_PACKET_FAILURE=1
	run "$SCRIPTS/runmeta.sh" create savings
	[ "$status" -eq 0 ]
	run_id="$output"
	run "$SCRIPTS/benchmark.sh" savings "$run_id"
	[ "$status" -eq 0 ]
	results="$BENCHMARK_OUT/runs/$run_id/results.csv"
	[ "$(awk -F, 'NR == 2 { print $10 }' "$results")" != 'passed' ]
	run "$SCRIPTS/runmeta.sh" completed "$run_id" \
		"savings|$source_sha|full|qsv|22"
	[ "$status" -eq 1 ]
	[ "$(find "$BENCHMARK_SCRATCH" -type f | wc -l | tr -d ' ')" -eq 0 ]
}

@test "savings retry upserts packet inventory instead of duplicating source tracks" {
	prepare_savings_execution_run
	export BENCHMARK_TEST_INVALID_OUTPUT_MATCH='qsv-22-attempt'
	export BENCHMARK_TEST_INVALID_OUTPUT_PROBE="$FIXTURES/metrics/probe-output-invalid.json"
	run "$SCRIPTS/runmeta.sh" create savings
	[ "$status" -eq 0 ]
	run_id="$output"
	run "$SCRIPTS/benchmark.sh" savings "$run_id"
	[ "$status" -eq 0 ]

	unset BENCHMARK_TEST_INVALID_OUTPUT_MATCH BENCHMARK_TEST_INVALID_OUTPUT_PROBE
	run "$SCRIPTS/benchmark.sh" savings "$run_id"
	[ "$status" -eq 0 ]
	[ "$(awk 'NR > 1 { count += 1 } END { print count + 0 }' "$BENCHMARK_OUT/runs/$run_id/audio-inventory.csv")" -eq 2 ]
}

@test "savings staged inventory write failure records non-passed and preserves no partial inventory" {
	prepare_savings_execution_run
	export BENCHMARK_TEST_FAIL_AUDIO_INVENTORY_WRITE=1
	run "$SCRIPTS/runmeta.sh" create savings
	[ "$status" -eq 0 ]
	run_id="$output"

	run "$SCRIPTS/benchmark.sh" savings "$run_id"
	[ "$status" -eq 0 ]
	results="$BENCHMARK_OUT/runs/$run_id/results.csv"
	[ "$(awk -F, 'NR == 2 { print $10 }' "$results")" != 'passed' ]
	[ ! -e "$BENCHMARK_OUT/runs/$run_id/audio-inventory.csv" ]
	[ "$(find "$BENCHMARK_OUT/runs/$run_id" -type f -name 'audio-inventory.csv.*.tmp' | wc -l | tr -d ' ')" -eq 0 ]
	run "$SCRIPTS/runmeta.sh" completed "$run_id" \
		"savings|$source_sha|full|qsv|22"
	[ "$status" -eq 1 ]
	[ "$(find "$BENCHMARK_SCRATCH" -type f | wc -l | tr -d ' ')" -eq 0 ]
}

@test "savings retry strictly upserts multiline CSV source paths by source and track" {
	prepare_savings_execution_run
	newline_source="$BATS_TEST_TMPDIR/"$'movie\nname.mkv'
	cp "$source_media" "$newline_source"
	export NEWLINE_SOURCE="$newline_source"
	yq -i -o=json '.savingsPanel[0].path = strenv(NEWLINE_SOURCE)' "$BENCHMARK_SAMPLES_FILE"
	newline_probe="$BATS_TEST_TMPDIR/newline-source-probe.json"
	jq --arg path "$newline_source" '.path = $path' \
		"$FIXTURES/metrics/probe-source.json" >"$newline_probe"
	export BENCHMARK_TEST_SOURCE_PROBE="$newline_probe"
	export BENCHMARK_TEST_INVALID_OUTPUT_MATCH='qsv-22-attempt'
	export BENCHMARK_TEST_INVALID_OUTPUT_PROBE="$FIXTURES/metrics/probe-output-invalid.json"
	run "$SCRIPTS/runmeta.sh" create savings
	[ "$status" -eq 0 ]
	run_id="$output"
	run "$SCRIPTS/benchmark.sh" savings "$run_id"
	[ "$status" -eq 0 ]

	unset BENCHMARK_TEST_INVALID_OUTPUT_MATCH BENCHMARK_TEST_INVALID_OUTPUT_PROBE
	run "$SCRIPTS/benchmark.sh" savings "$run_id"
	[ "$status" -eq 0 ]
	run python3 - "$BENCHMARK_OUT/runs/$run_id/audio-inventory.csv" "$newline_source" <<'PYTHON'
import csv
import sys

with open(sys.argv[1], newline="", encoding="utf-8") as stream:
    rows = list(csv.DictReader(stream))
assert len(rows) == 2, rows
assert {row["track_index"] for row in rows} == {"1", "2"}, rows
assert all(row["source_path"] == sys.argv[2] for row in rows), rows
PYTHON
	[ "$status" -eq 0 ]
}

@test "savings accepts a zero-audio title with durable header-only inventory" {
	prepare_savings_execution_run
	zero_source_probe="$BATS_TEST_TMPDIR/zero-audio-source.json"
	zero_output_probe="$BATS_TEST_TMPDIR/zero-audio-output.json"
	empty_packets="$BATS_TEST_TMPDIR/zero-audio-packets.csv"
	jq '.audioTrackCount = 0 | .audioTracks = []' \
		"$FIXTURES/metrics/probe-source.json" >"$zero_source_probe"
	jq '.audioTrackCount = 0 | .audioTracks = []' \
		"$FIXTURES/metrics/probe-output-valid.json" >"$zero_output_probe"
	: >"$empty_packets"
	export BENCHMARK_TEST_SOURCE_PROBE="$zero_source_probe"
	export BENCHMARK_TEST_OUTPUT_PROBE="$zero_output_probe"
	export BENCHMARK_PACKET_FIXTURE="$empty_packets"
	run "$SCRIPTS/runmeta.sh" create savings
	[ "$status" -eq 0 ]
	run_id="$output"

	run "$SCRIPTS/benchmark.sh" savings "$run_id"
	[ "$status" -eq 0 ]
	[ "$(awk -F, 'NR == 2 { print $10 }' "$BENCHMARK_OUT/runs/$run_id/results.csv")" = 'passed' ]
	[ "$(wc -l <"$BENCHMARK_OUT/runs/$run_id/audio-inventory.csv" | tr -d ' ')" -eq 1 ]
	[ "$(<"$BENCHMARK_OUT/runs/$run_id/audio-inventory.csv")" = 'source_path,track_index,codec,channels,channel_layout,language,bit_rate,duration_seconds,audio_bytes,audio_bytes_method' ]
}

# Catches the public finalist mode selecting an uncommitted setting, copying a
# scratch file under an ambiguous name, or losing exact run/sample confirmation.
@test "finalist mode re-encodes one named sample and copies the validated full title" {
	prepare_execution_run
	yq -i -o=json '.qualityPanel[0].id = "hdr10-grain-goodfellas"' "$BENCHMARK_SAMPLES_FILE"
	prepare_quality_upstream hdr10 provisional 22 '[22,24,26]'
	set_chosen_record avc final 24
	unset BENCHMARK_IDENTITY_FIXTURE
	export BENCHMARK_RUNNING_IMAGE="$BENCHMARK_DISPATCH_IMAGE"
	export BENCHMARK_I915_VERSION='fixture-i915'
	export BENCHMARK_VPL_VERSION='fixture-vpl'
	run_id='20260802T121500Z-deadbeef'
	export ENCODE_BENCHMARK_FINALIST_CONFIRM="copy:encode-benchmark:$run_id:hdr10-grain-goodfellas"

	run "$SCRIPTS/benchmark.sh" finalist "$run_id" hdr10-grain-goodfellas
	[ "$status" -eq 0 ]
	[ "$output" = "$run_id" ]
	[ -f "$BENCHMARK_OUT/runs/$run_id/encodes/hdr10-grain-goodfellas-qsv-gq22.mkv" ]
	run jq -e --arg run "$QUALITY_RUN_ID" '
		.selectedSettings == [{cohort:"hdr10",globalQuality:22,qualityRunId:$run}]
	' "$BENCHMARK_OUT/runs/$run_id/manifest.json"
	[ "$status" -eq 0 ]
	[ "$(find "$BENCHMARK_OUT/runs/$run_id/encodes" -type f | wc -l | tr -d ' ')" -eq 1 ]
	[ "$(find "$BENCHMARK_SCRATCH" -type f | wc -l | tr -d ' ')" -eq 0 ]
}

# Catches finalist execution reaching source hashing or run creation from a
# stale upstream record, a non-provisional state, or the wrong cohort title.
@test "finalist runtime verifies provisional state title and upstream before measured work" {
	prepare_execution_run
	yq -i -o=json '.qualityPanel[0].id = "hdr10-grain-goodfellas"' "$BENCHMARK_SAMPLES_FILE"
	prepare_quality_upstream hdr10 provisional 22 '[22,24,26]'
	run_id='20260815T150000Z-cccccccc'
	export ENCODE_BENCHMARK_FINALIST_CONFIRM="copy:encode-benchmark:$run_id:hdr10-grain-goodfellas"
	: >"$BENCHMARK_COMMAND_LOG"

	yq -i -o=json '.chosenSettings.hdr10.qualityResultsSha256 = ("sha256:" + ("d" * 64))' "$BENCHMARK_SAMPLES_FILE"
	run "$SCRIPTS/benchmark.sh" finalist "$run_id" hdr10-grain-goodfellas
	[ "$status" -ne 0 ]
	[ ! -e "$BENCHMARK_OUT/runs/$run_id" ]
	! rg -q '^sha256sum .*source' "$BENCHMARK_COMMAND_LOG"

	prepare_quality_upstream hdr10 provisional 22 '[22,24,26]'
	export ENCODE_BENCHMARK_FINALIST_CONFIRM="copy:encode-benchmark:$run_id:sample-hdr"
	run "$SCRIPTS/benchmark.sh" finalist "$run_id" sample-hdr
	[ "$status" -ne 0 ]
	[ ! -e "$BENCHMARK_OUT/runs/$run_id" ]

	prepare_quality_upstream hdr10 final 22 '[22,24,26]'
	export ENCODE_BENCHMARK_FINALIST_CONFIRM="copy:encode-benchmark:$run_id:hdr10-grain-goodfellas"
	run "$SCRIPTS/benchmark.sh" finalist "$run_id" hdr10-grain-goodfellas
	[ "$status" -ne 0 ]
	[ ! -e "$BENCHMARK_OUT/runs/$run_id" ]
}

# Catches a Job entering its first production encode with stale source bytes.
# The synthetic assigned-node proof runs first, but it must not touch the title.
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

prepare_contention_samples() {
	prepare_execution_run
	source_size="$(wc -c <"$source_media" | tr -d ' ')"
	source_sha="$(sha256sum "$source_media" | awk '{print $1}')"
	runtime="$(jq -c '.runtime' "$BENCHMARK_SAMPLES_FILE")"
	strategy="$(strategy_contract)"
	jq -n \
		--arg path "$source_media" \
		--argjson size "$source_size" \
		--arg sha "$source_sha" \
		--argjson runtime "$runtime" \
		--argjson strategy "$strategy" \
		'def title($id; $cohort; $w; $h):
			{id: $id, cohort: $cohort, path: $path, sizeBytes: $size, sha256: $sha,
			 width: $w, height: $h, clips: {detail: "00:17:23.456"}};
		{
			schemaVersion: 2,
			strategy: $strategy,
			runtime: $runtime,
			savingsSeed: 20260802,
			qualityPanel: [
				title("a-4k-hdr"; "hdr10"; 3840; 2160),
				title("b-1080-avc"; "avc"; 1920; 1080),
				title("c-1080-vc1"; "vc1"; 1920; 1080)
			],
			savingsPanel: [],
			chosenSettings: {
				avc: {}, vc1: {}, hdr10: {}
			}
		}' >"$BENCHMARK_SAMPLES_FILE"
	prepare_quality_upstream avc final 24 '[24,26,28]'
	prepare_quality_upstream vc1 final 26 '[26,28,30]'
	prepare_quality_upstream hdr10 final 22 '[22,24,26]'
}

# Catches contention workers sharing one results file, persisting full-title
# output, or omitting worker/attempt-scoped wall-time evidence.
@test "contention worker discards output and publishes a separate attempt CSV fragment" {
	prepare_contention_samples
	unset BENCHMARK_IDENTITY_FIXTURE
	export BENCHMARK_RUNNING_IMAGE="$BENCHMARK_DISPATCH_IMAGE"
	export BENCHMARK_I915_VERSION='fixture-i915'
	export BENCHMARK_VPL_VERSION='fixture-vpl'
	run_id='20260802T121500Z-deadbeef'
	run "$SCRIPTS/benchmark.sh" contention "$run_id" a worker-1 a-4k-hdr
	[ "$status" -eq 0 ]
	[ "$output" = "$run_id" ]
	fragment="$BENCHMARK_OUT/runs/$run_id/contention-a-worker-1-attempt-1.csv"
	[ -f "$fragment" ]
	run jq -e --arg run "$QUALITY_RUN_ID" '
		.selectedSettings == [{cohort:"hdr10",globalQuality:22,qualityRunId:$run}]
	' "$BENCHMARK_OUT/runs/$run_id/manifest.json"
	[ "$status" -eq 0 ]
	[ "$(wc -l <"$fragment" | tr -d ' ')" -eq 2 ]
	run python3 - "$fragment" <<'PYTHON'
import csv
import json
import sys

with open(sys.argv[1], newline="", encoding="utf-8") as stream:
    rows = list(csv.DictReader(stream))
print(json.dumps(rows, sort_keys=True, separators=(",", ":")))
PYTHON
	[ "$status" -eq 0 ]
	run jq -e '
		length == 1 and .[0].run_id == "20260802T121500Z-deadbeef" and
		.[0].case == "a" and .[0].worker_id == "worker-1" and
		.[0].sample_id == "a-4k-hdr" and .[0].cohort == "hdr10" and
		.[0].setting == "22" and .[0].attempt == "1" and
		(.[0].wall_seconds | tonumber) >= 0 and
		.[0].output_disposition == "discarded"
	' <<<"$output"
	[ "$status" -eq 0 ]
	[ ! -e "$BENCHMARK_OUT/runs/$run_id/results.csv" ]
	[ "$(find "$BENCHMARK_SCRATCH" -type f | wc -l | tr -d ' ')" -eq 0 ]

	run "$SCRIPTS/benchmark.sh" contention "$run_id" a worker-1 a-4k-hdr
	[ "$status" -eq 0 ]
	[ -f "$BENCHMARK_OUT/runs/$run_id/contention-a-worker-1-attempt-2.csv" ]
}

# Catches a failed fragment publication leaving a full-title encode or staged
# evidence behind for a retry to misinterpret as durable worker output.
@test "contention cleans scratch and staged evidence when fragment publication fails" {
	prepare_contention_samples
	failure_bin="$BATS_TEST_TMPDIR/contention-failure-bin"
	mkdir -p "$failure_bin"
	cat >"$failure_bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination="${!#}"
if [[ "$destination" == */contention-a-worker-1-attempt-1.csv ]]; then
	exit 91
fi
exec /bin/mv "$@"
EOF
	chmod +x "$failure_bin/mv"
	export PATH="$failure_bin:$PATH"
	run_id='20260802T121500Z-deadbeef'

	run "$SCRIPTS/benchmark.sh" contention "$run_id" a worker-1 a-4k-hdr
	[ "$status" -eq 91 ]
	[ ! -e "$BENCHMARK_OUT/runs/$run_id/contention-a-worker-1-attempt-1.csv" ]
	[ "$(find "$BENCHMARK_OUT/runs/$run_id" -maxdepth 1 -name '.contention-*' | wc -l | tr -d ' ')" -eq 0 ]
	[ "$(find "$BENCHMARK_SCRATCH" -type f | wc -l | tr -d ' ')" -eq 0 ]
}

# Catches direct runtime invocation bypassing dispatch sample selection or
# mutating the run tree before case eligibility and chosen settings are proven.
@test "contention refuses wrong case samples and missing settings before run creation" {
	prepare_contention_samples
	run_id='20260802T121500Z-deadbeef'
	run "$SCRIPTS/benchmark.sh" contention "$run_id" a worker-1 b-1080-avc
	[ "$status" -ne 0 ]
	[ "$output" = 'contention case a requires an eligible 3840x2160 HDR10 quality sample' ]
	[ ! -e "$BENCHMARK_OUT/runs/$run_id" ]

	yq -i -o=json 'del(.chosenSettings.avc)' "$BENCHMARK_SAMPLES_FILE"
	run "$SCRIPTS/benchmark.sh" contention "$run_id" b worker-1 b-1080-avc
	[ "$status" -ne 0 ]
	[ "$output" = 'no final setting for cohort: avc' ]
	[ ! -e "$BENCHMARK_OUT/runs/$run_id" ]

	run "$SCRIPTS/benchmark.sh" contention "$run_id" b '../worker' b-1080-avc
	[ "$status" -eq 64 ]
	[ "$output" = 'invalid contention worker id: ../worker' ]
	[ ! -e "$BENCHMARK_OUT/runs/$run_id" ]
}

# Catches a direct worker bypassing dispatch and relying on cohort alone for
# the 4K/1080p contention contract before it creates immutable run state.
@test "contention runtime rejects missing or wrong exact sample resolution" {
	prepare_contention_samples
	run_id='20260802T121500Z-deadbeef'
	yq -i -o=json '.qualityPanel[0].width = 1920' "$BENCHMARK_SAMPLES_FILE"
	run "$SCRIPTS/benchmark.sh" contention "$run_id" a worker-1 a-4k-hdr
	[ "$status" -eq 65 ]
	[ "$output" = 'contention case a requires an eligible 3840x2160 HDR10 quality sample' ]
	[ ! -e "$BENCHMARK_OUT/runs/$run_id" ]

	prepare_contention_samples
	yq -i -o=json 'del(.qualityPanel[1].height)' "$BENCHMARK_SAMPLES_FILE"
	run "$SCRIPTS/benchmark.sh" contention "$run_id" b worker-1 b-1080-avc
	[ "$status" -eq 65 ]
	[ "$output" = 'contention case b requires an eligible 1920x1080 non-DV quality sample' ]
	[ ! -e "$BENCHMARK_OUT/runs/$run_id" ]
}

@test "finalist publication rejects symlink escape and rolls back when durable append fails" {
	prepare_execution_run
	prepare_quality_upstream avc provisional 22 '[22,24,26]'
	run_id='20260802T120000Z-aaaaaaaa'
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	mkdir -p "$run_dir"
	finalist_row="$BATS_TEST_TMPDIR/finalist-safe.json"
	jq '.panel = "finalist" | .clip_id = "full" | .sample_id = "avc-grain-memento"' \
		"$FIXTURES/metrics/variant-passed.json" >"$finalist_row"
	export ENCODE_BENCHMARK_FINALIST_CONFIRM="copy:encode-benchmark:$run_id:avc-grain-memento"

	outside="$BATS_TEST_TMPDIR/outside"
	mkdir -p "$outside"
	ln -s "$outside" "$run_dir/encodes"
	scratch_output="$BENCHMARK_SCRATCH/finalist-symlink.mkv"
	printf '%s' 'must stay confined' >"$scratch_output"
	run "$SCRIPTS/benchmark.sh" _test record-result "$run_id" "$finalist_row" "$scratch_output"
	[ "$status" -ne 0 ]
	[ ! -e "$outside/avc-grain-memento-qsv-gq22.mkv" ]
	[ ! -e "$scratch_output" ]
	rm "$run_dir/encodes"

	export BENCHMARK_TEST_FAIL_RESULT_APPEND=1
	printf '%s' 'new finalist' >"$scratch_output"
	run "$SCRIPTS/benchmark.sh" _test record-result "$run_id" "$finalist_row" "$scratch_output"
	[ "$status" -ne 0 ]
	[ ! -e "$run_dir/encodes/avc-grain-memento-qsv-gq22.mkv" ]
	[ ! -e "$scratch_output" ]
	[ "$(wc -l <"$run_dir/results.csv" | tr -d ' ')" -eq 1 ]

	printf '%s' 'prior finalist' >"$run_dir/encodes/avc-grain-memento-qsv-gq22.mkv"
	printf '%s' 'replacement finalist' >"$scratch_output"
	run "$SCRIPTS/benchmark.sh" _test record-result "$run_id" "$finalist_row" "$scratch_output"
	[ "$status" -ne 0 ]
	[ "$(<"$run_dir/encodes/avc-grain-memento-qsv-gq22.mkv")" = 'prior finalist' ]
	[ ! -e "$scratch_output" ]
}

# Catches a failed staged-to-final rename leaving the new staged bytes behind,
# losing the prior finalist, or discarding the only recoverable backup when the
# restoration itself cannot complete.
@test "finalist promotion failure removes staging and verifies prior restoration" {
	prepare_execution_run
	prepare_quality_upstream avc provisional 22 '[22,24,26]'
	run_id='20260802T120000Z-aaaaaaaa'
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	mkdir -p "$run_dir/encodes"
	finalist_row="$BATS_TEST_TMPDIR/finalist-promotion.json"
	jq '.panel = "finalist" | .clip_id = "full" | .sample_id = "avc-grain-memento"' \
		"$FIXTURES/metrics/variant-passed.json" >"$finalist_row"
	export ENCODE_BENCHMARK_FINALIST_CONFIRM="copy:encode-benchmark:$run_id:avc-grain-memento"

	mv_stub="$BATS_TEST_TMPDIR/promotion-bin"
	mkdir -p "$mv_stub"
	cat >"$mv_stub/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source_path=''
destination=''
for argument in "$@"; do
	[[ "$argument" == '--' ]] && continue
	source_path="$destination"
	destination="$argument"
done
if [[ "$source_path" == *.tmp.mkv && "$destination" == *.mkv ]]; then
	exit 74
fi
if [[ "${FAIL_FINALIST_RESTORE:-0}" == '1' && "$source_path" == *.restore-*.mkv ]]; then
	exit 74
fi
exec /bin/mv "$@"
EOF
	cat >"$mv_stub/cp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source_path=''
destination=''
for argument in "$@"; do
	[[ "$argument" == '--' ]] && continue
	source_path="$destination"
	destination="$argument"
done
if [[ "${FAIL_FINALIST_RESTORE_COPY:-0}" == '1' && "$source_path" == *.backup.mkv &&
	"$destination" == *.restore*.mkv ]]; then
	printf '%s' 'partial restore bytes' >"$destination"
	exit 74
fi
exec /bin/cp "$@"
EOF
	chmod +x "$mv_stub/mv" "$mv_stub/cp"
	export PATH="$mv_stub:$PATH"

	destination="$run_dir/encodes/avc-grain-memento-qsv-gq22.mkv"
	scratch_output="$BENCHMARK_SCRATCH/finalist-promotion.mkv"
	printf '%s' 'prior finalist' >"$destination"
	printf '%s' 'replacement finalist' >"$scratch_output"
	run "$SCRIPTS/benchmark.sh" _test record-result "$run_id" "$finalist_row" "$scratch_output"
	[ "$status" -ne 0 ]
	[ "$(<"$destination")" = 'prior finalist' ]
	[ ! -e "$scratch_output" ]
	[ "$(find "$run_dir/encodes" -type f -name '*.tmp.mkv' | wc -l | tr -d ' ')" -eq 0 ]
	[ "$(find "$run_dir/encodes" -type f -name '*.backup.mkv' | wc -l | tr -d ' ')" -eq 0 ]

	export FAIL_FINALIST_RESTORE=1
	printf '%s' 'replacement finalist' >"$scratch_output"
	run "$SCRIPTS/benchmark.sh" _test record-result "$run_id" "$finalist_row" "$scratch_output"
	[ "$status" -ne 0 ]
	[[ "$output" == *'finalist backup restoration failed; retained:'* ]]
	[ ! -e "$destination" ]
	[ "$(find "$run_dir/encodes" -type f -name '*.backup.mkv' | wc -l | tr -d ' ')" -eq 1 ]
	[ "$(<"$(find "$run_dir/encodes" -type f -name '*.backup.mkv')")" = 'prior finalist' ]

	# A retry must recover the retained prior finalist before it attempts another
	# promotion. Otherwise the retry can delete the only recoverable copy.
	unset FAIL_FINALIST_RESTORE
	printf '%s' 'second replacement finalist' >"$scratch_output"
	run "$SCRIPTS/benchmark.sh" _test record-result "$run_id" "$finalist_row" "$scratch_output"
	[ "$status" -ne 0 ]
	[ "$(<"$destination")" = 'prior finalist' ]
	[ "$(find "$run_dir/encodes" -type f -name '*.backup.mkv' | wc -l | tr -d ' ')" -eq 0 ]

	# A failed backup copy may write a partial restore stage. That stage must be
	# removed while the complete backup remains available for recovery.
	export FAIL_FINALIST_RESTORE_COPY=1
	printf '%s' 'third replacement finalist' >"$scratch_output"
	run "$SCRIPTS/benchmark.sh" _test record-result "$run_id" "$finalist_row" "$scratch_output"
	[ "$status" -ne 0 ]
	[ ! -e "$destination" ]
	[ "$(find "$run_dir/encodes" -type f -name '*.backup.mkv' | wc -l | tr -d ' ')" -eq 1 ]
	[ "$(<"$(find "$run_dir/encodes" -type f -name '*.backup.mkv')")" = 'prior finalist' ]
	[ "$(find "$run_dir/encodes" -type f -name '*.restore*.mkv' | wc -l | tr -d ' ')" -eq 0 ]
}

# Catches a result fixture with valid local metrics publishing after its
# committed quality evidence has changed since finalist run preparation.
@test "finalist publication rechecks strategy and upstream identity before copy" {
	prepare_execution_run
	prepare_quality_upstream avc provisional 22 '[22,24,26]'
	run_id='20260815T150000Z-cccccccc'
	run_dir="$BENCHMARK_OUT/runs/$run_id"
	mkdir -p "$run_dir"
	finalist_row="$BATS_TEST_TMPDIR/finalist-stale-upstream.json"
	jq '.panel = "finalist" | .clip_id = "full" | .sample_id = "avc-grain-memento" | .cohort = "avc"' \
		"$FIXTURES/metrics/variant-passed.json" >"$finalist_row"
	scratch_output="$BENCHMARK_SCRATCH/finalist-stale-upstream.mkv"
	printf '%s' 'must not publish' >"$scratch_output"
	export ENCODE_BENCHMARK_FINALIST_CONFIRM="copy:encode-benchmark:$run_id:avc-grain-memento"
	printf '%s\n' 'changed quality evidence' >>"$BENCHMARK_OUT/runs/$QUALITY_RUN_ID/results.csv"

	run "$SCRIPTS/benchmark.sh" _test record-result "$run_id" "$finalist_row" "$scratch_output"
	[ "$status" -ne 0 ]
	[ ! -e "$run_dir/encodes/avc-grain-memento-qsv-gq22.mkv" ]
	[ ! -e "$run_dir/results.csv" ]
}

# Catches findings silently mixing unnamed runs or copying raw credential and
# path fields into the Markdown artifact instead of using an allowlisted summary.
@test "findings combines explicitly named run inputs and excludes credentials" {
	export BENCHMARK_SAMPLES_FILE="$BATS_TEST_TMPDIR/findings-samples.json"
	yq -r '.data."samples.json"' "$BATS_TEST_DIRNAME/../app/samples.yaml" >"$BENCHMARK_SAMPLES_FILE"
	target='20260802T120000Z-cccccccc'
	quality='20260802T120000Z-aaaaaaaa'
	savings='20260802T120000Z-bbbbbbbb'
	worker_1='20260802T120000Z-11111111'
	worker_2='20260802T120000Z-22222222'
	mkdir -p "$BENCHMARK_OUT/runs/$target" "$BENCHMARK_OUT/runs/$quality" "$BENCHMARK_OUT/runs/$savings" \
		"$BENCHMARK_OUT/runs/$worker_1" "$BENCHMARK_OUT/runs/$worker_2"
	cp "$GOLDEN/results.csv" "$BENCHMARK_OUT/runs/$quality/results.csv"
	cat >"$BENCHMARK_OUT/runs/$quality/x265-comparisons.jsonl" <<'EOF'
{"status":"bracketed","lower_crf":24,"upper_crf":22,"matched_bit_rate":6000,"premium_percent":12.5,"sample_id":"sample-avc","clip_id":"detail","qsv_setting":"22"}
{"status":"unbracketed","sample_id":"sample-hdr","clip_id":"grain","qsv_setting":"24"}
EOF
	results="$BENCHMARK_OUT/runs/$savings/results.csv"
	printf '%s\n' 'run_id,panel,sample_id,cohort,source_sha256,clip_id,encoder,requested_setting,selected_rate_control,status,attempt,input_bytes,output_bytes,reduction_percent,input_bit_rate,output_bit_rate,wall_seconds,encode_fps,encode_speed,vmaf_harmonic_mean,vmaf_1pct_low,ssim,gpu_busy_percent,qsv_proof,validation_codec,validation_duration,validation_resolution,validation_frame_rate,validation_bit_depth,validation_hdr,validation_audio_tracks,validation_subtitle_tracks,validation_chapters,validation_failures,log_path,output_disposition,strategy_id,qsv_initialization,video_busy_nanoseconds' >"$results"
	for reduction in 10 20 30 40 50 60 70 80; do
		printf '%s\n' "$savings,savings,sample-$reduction,avc,bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,full,qsv,22,ICQ,passed,1,1000,600,$reduction,8000,4800,10,30,1,,,,50,passed,passed,passed,passed,passed,passed,passed,passed,passed,passed,,logs/sample.log,discarded,qsv-hevc-icq-v1,passed,800000000" >>"$results"
	done
	contention_header='run_id,case,worker_id,sample_id,cohort,setting,status,attempt,wall_seconds,qsv_proof,validation_failures,output_disposition'
	printf '%s\n' "$contention_header" \
		'"20260802T120000Z-11111111","b","worker-1","sample-avc","avc","24","passed","1","120.500000","passed","","discarded"' \
		>"$BENCHMARK_OUT/runs/$worker_1/contention-b-worker-1-attempt-1.csv"
	printf '%s\n' "$contention_header" \
		'"20260802T120000Z-22222222","b","worker-2","sample-vc1","vc1","26","passed","1","130.250000","passed","","discarded"' \
		>"$BENCHMARK_OUT/runs/$worker_2/contention-b-worker-2-attempt-1.csv"
	cat >"$BENCHMARK_OUT/runs/$target/findings-inputs.json" <<EOF
{"qualityRunId":"$quality","savingsRunId":"$savings","contentionFile":"contention.json","contentionFragments":[{"runId":"$worker_1","file":"contention-b-worker-1-attempt-1.csv"},{"runId":"$worker_2","file":"contention-b-worker-2-attempt-1.csv"}],"plexToken":"must-not-leak"}
EOF
	cat >"$BENCHMARK_OUT/runs/$target/contention.json" <<'EOF'
{"baselineStartLatencySeconds":1.2,"bufferingCount":0,"startLatencySeconds":2.1,"seekToResumeSeconds":3.2,"nasUplinkMbps":10000,"measuredThroughputMbps":812,"plexToken":"also-must-not-leak","sourcePath":"/media/Secret Movie.mkv"}
EOF

	run "$SCRIPTS/benchmark.sh" findings "$target"
	[ "$status" -eq 0 ]
	[ "$output" = "$target" ]
	findings="$BENCHMARK_OUT/runs/$target/findings.md"
	[ -f "$findings" ]
	run rg -F '| avc | 45.000000 | 25.000000 | 65.000000 | 40.000000 | GO |' "$findings"
	[ "$status" -eq 0 ]
	run rg -F "Quality run: \`$quality\`" "$findings"
	[ "$status" -eq 0 ]
	run rg -F "Savings run: \`$savings\`" "$findings"
	[ "$status" -eq 0 ]
	run rg -F '| sample-avc | detail | 22 | bracketed | 12.500000 | QSV preferred |' "$findings"
	[ "$status" -eq 0 ]
	run rg -F '| sample-hdr | grain | 24 | unbracketed |  | No verdict |' "$findings"
	[ "$status" -eq 0 ]
	run rg -F "| $worker_1 | b | worker-1 | sample-avc | avc | 24 | passed | 120.500000 |" "$findings"
	[ "$status" -eq 0 ]
	run rg -F "| $worker_2 | b | worker-2 | sample-vc1 | vc1 | 26 | passed | 130.250000 |" "$findings"
	[ "$status" -eq 0 ]
	run rg -n 'must-not-leak|Secret Movie|plexToken|sourcePath' "$findings"
	[ "$status" -eq 1 ]
}

@test "findings rejects malicious values in allowed contention fields" {
	target='20260802T120000Z-dddddddd'
	quality='20260802T120000Z-aaaaaaaa'
	savings='20260802T120000Z-bbbbbbbb'
	worker='20260802T120000Z-11111111'
	mkdir -p "$BENCHMARK_OUT/runs/$target" "$BENCHMARK_OUT/runs/$quality" "$BENCHMARK_OUT/runs/$savings" "$BENCHMARK_OUT/runs/$worker"
	cp "$GOLDEN/results.csv" "$BENCHMARK_OUT/runs/$quality/results.csv"
	cp "$GOLDEN/results.csv" "$BENCHMARK_OUT/runs/$savings/results.csv"
	printf '%s\n' '{"status":"unbracketed","sample_id":"sample-avc","clip_id":"detail","qsv_setting":"22"}' \
		>"$BENCHMARK_OUT/runs/$quality/x265-comparisons.jsonl"
	printf '%s\n' \
		'run_id,case,worker_id,sample_id,cohort,setting,status,attempt,wall_seconds,qsv_proof,validation_failures,output_disposition' \
		'"20260802T120000Z-11111111","a","worker-1","sample-hdr","hdr10","22","passed","1","120.500000","passed","","discarded"' \
		>"$BENCHMARK_OUT/runs/$worker/contention-a-worker-1-attempt-1.csv"
	cat >"$BENCHMARK_OUT/runs/$target/findings-inputs.json" <<EOF
{"qualityRunId":"$quality","savingsRunId":"$savings","contentionFile":"contention.json","contentionFragments":[{"runId":"$worker","file":"contention-a-worker-1-attempt-1.csv"}]}
EOF
	cat >"$BENCHMARK_OUT/runs/$target/contention.json" <<'EOF'
{"baselineStartLatencySeconds":"1\n## injected","bufferingCount":0,"startLatencySeconds":2.1,"seekToResumeSeconds":3.2,"nasUplinkMbps":10000,"measuredThroughputMbps":812}
EOF
	run "$SCRIPTS/benchmark.sh" findings "$target"
	[ "$status" -ne 0 ]
	[ ! -e "$BENCHMARK_OUT/runs/$target/findings.md" ]
}

# Catches summing container estimates instead of packet bytes or merging audio
# stream indices during the full-title savings pass.
@test "full-title audio inventory sums ffprobe packets per stream" {
	inventory_path="$BATS_TEST_TMPDIR/audio-inventory.csv"
	run "$SCRIPTS/benchmark.sh" _test audio-inventory \
		"$FIXTURES/logs/audio-packets.log" "$FIXTURES/metrics/probe-source.json" "$inventory_path"
	[ "$status" -eq 0 ]
	run python3 - "$inventory_path" <<'PYTHON'
import csv
import json
import sys

with open(sys.argv[1], newline="", encoding="utf-8") as stream:
    rows = list(csv.DictReader(stream))
print(json.dumps(rows, sort_keys=True, separators=(",", ":")))
PYTHON
	[ "$status" -eq 0 ]
	[ "$output" = '[{"audio_bytes":"150","audio_bytes_method":"packet-counted","bit_rate":"","channel_layout":"7.1","channels":"8","codec":"truehd","duration_seconds":"90","language":"eng","source_path":"/media/source.mkv","track_index":"1"},{"audio_bytes":"40","audio_bytes_method":"packet-counted","bit_rate":"640000","channel_layout":"5.1(side)","channels":"6","codec":"ac3","duration_seconds":"90","language":"eng","source_path":"/media/source.mkv","track_index":"2"}]' ]
}

# Catches a probe that stops at the first absent tool. Each missing command
# reported late costs a full operator dispatch cycle, so the capability run must
# name the whole gap at once.
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

	for key in requiredCommands optionalCommands; do
		run "$SCRIPTS/benchmark.sh" _test declared-commands "$inner" "$key"
		[ "$status" -eq 0 ]
		jq_list="$(jq -r ".runtime.$key[]" "$inner")"
		[ -n "$jq_list" ]
		[ "$output" = "$jq_list" ]
	done
}

# Catches the substitute inventory silently disappearing or turning fatal. It is
# report-only: an absent optional command must never fail the probe, and the
# report must survive a required-command failure, which is exactly when the
# operator needs to know what can replace the missing tool.
@test "substitute inventory is reported alongside a required-command failure" {
	create_capability_tools
	write_capability_samples '' benchmark-absent-required
	export BENCHMARK_DISPATCH_IMAGE='docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	export NODE_NAME='talos-03'

	run "$SCRIPTS/benchmark.sh" capabilities
	[ "$status" -eq 1 ]
	[[ "$output" == *'runtime image is missing required commands: benchmark-absent-required'* ]]
	[[ "$output" == *'runtime image substitute inventory:'* ]]
	[[ "$output" == *'present='* ]]
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
