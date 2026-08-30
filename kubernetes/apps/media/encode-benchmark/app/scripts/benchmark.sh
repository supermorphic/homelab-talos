#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_directory/contract.sh"
# shellcheck disable=SC1091
source "$script_directory/quality-evidence.sh"
benchmark_out="${BENCHMARK_OUT:-/out}"
scratch_root="${BENCHMARK_SCRATCH:-/scratch}"
samples_file="${BENCHMARK_SAMPLES_FILE:-/config/samples.json}"
test_mode="${BENCHMARK_TEST_MODE:-0}"
running_image_file='/provenance/image.json'
running_image_wait_seconds=600
results_header='run_id,panel,sample_id,cohort,source_sha256,clip_id,encoder,requested_setting,selected_rate_control,status,attempt,input_bytes,output_bytes,reduction_percent,input_bit_rate,output_bit_rate,wall_seconds,encode_fps,encode_speed,vmaf_harmonic_mean,vmaf_1pct_low,ssim,gpu_busy_percent,qsv_proof,validation_codec,validation_duration,validation_resolution,validation_frame_rate,validation_bit_depth,validation_hdr,validation_audio_tracks,validation_subtitle_tracks,validation_chapters,validation_failures,log_path,output_disposition,strategy_id,qsv_initialization,video_busy_nanoseconds,quality_evidence_path,quality_evidence_sha256'

if [[ "$test_mode" != '1' && -n "${BENCHMARK_OUT+x}" ]]; then
	echo 'BENCHMARK_OUT requires BENCHMARK_TEST_MODE=1' >&2
	exit 64
fi
if [[ "$test_mode" != '1' && -n "${BENCHMARK_SCRATCH+x}" ]]; then
	echo 'BENCHMARK_SCRATCH requires BENCHMARK_TEST_MODE=1' >&2
	exit 64
fi
if [[ "$test_mode" != '1' && -n "${BENCHMARK_SAMPLES_FILE+x}" ]]; then
	echo 'BENCHMARK_SAMPLES_FILE requires BENCHMARK_TEST_MODE=1' >&2
	exit 64
fi
if [[ "$test_mode" != '1' && -n "${BENCHMARK_TEST_QUALITY_PLAN_FILE+x}" ]]; then
	echo 'BENCHMARK_TEST_QUALITY_PLAN_FILE requires BENCHMARK_TEST_MODE=1' >&2
	exit 64
fi
if [[ "$test_mode" == '1' ]]; then
	running_image_file="${BENCHMARK_RUNNING_IMAGE_FILE:-$running_image_file}"
	running_image_wait_seconds="${BENCHMARK_RUNNING_IMAGE_WAIT_SECONDS:-$running_image_wait_seconds}"
else
	for override in BENCHMARK_RUNNING_IMAGE_FILE BENCHMARK_RUNNING_IMAGE_WAIT_SECONDS BENCHMARK_RUNNING_IMAGE; do
		if [[ -v "$override" ]]; then
			echo "$override requires BENCHMARK_TEST_MODE=1" >&2
			exit 64
		fi
	done
fi
[[ "$running_image_wait_seconds" =~ ^[0-9]+$ ]] || {
	echo 'running image evidence wait must be a non-negative integer' >&2
	exit 64
}
if [[ "$test_mode" != '1' ]]; then
	for test_hook in \
		BENCHMARK_TEST_SOURCE_PROBE BENCHMARK_TEST_OUTPUT_PROBE \
		BENCHMARK_TEST_FDINFO_FIXTURE BENCHMARK_TEST_INVALID_OUTPUT_MATCH \
		BENCHMARK_TEST_INVALID_OUTPUT_PROBE BENCHMARK_TEST_FAIL_RESULT_APPEND \
		BENCHMARK_TEST_QUALITY_EVIDENCE_COMPETITOR_SETTING \
		BENCHMARK_TEST_QUALITY_EVIDENCE_COMPETITOR_FILE; do
		if [[ -v "$test_hook" ]]; then
			echo 'BENCHMARK_TEST_* hooks require BENCHMARK_TEST_MODE=1' >&2
			exit 64
		fi
	done
fi
usage() {
	echo 'usage: benchmark.sh capabilities | quality [run-id]' >&2
	exit 64
}

validate_run_id() {
	local run_id="$1"
	contract_is_run_id "$run_id" || {
		echo "invalid run id: $run_id" >&2
		return 64
	}
}

validate_sample_id() {
	local sample_id="$1"
	[[ "$sample_id" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || {
		echo "invalid sample id: $sample_id" >&2
		return 64
	}
}

array_json() {
	jq -n -c '$ARGS.positional' --args -- "$@"
}

build_commands() {
	local source="$1" timestamp="$2" clip="$3" qsv_output="$4" vmaf_log="$5" gq="$6"
	local -a clip_command qsv_command vmaf_command ssim_command psnr_command
	local clip_json qsv_json vmaf_json ssim_json psnr_json

	clip_command=(ffmpeg -nostdin -v error -ss "$timestamp" -i "$source" -t 90 -map 0 -c copy "$clip")
	qsv_command=(
		ffmpeg -nostdin -v verbose -init_hw_device qsv=hw:/dev/dri/renderD128
		-filter_hw_device hw -i "$clip" -map 0 -c:v hevc_qsv -preset veryslow
		-global_quality "$gq" -look_ahead 0 -extbrc 0 -c:a copy -c:s copy
		-map_metadata 0 -map_chapters 0 "$qsv_output"
	)
	vmaf_command=(
		ffmpeg -nostdin -v error -i "$qsv_output" -i "$clip" -lavfi
		"[0:v][1:v]libvmaf=model=version=vmaf_4k_v0.6.1:log_fmt=json:log_path=$vmaf_log"
		-f null -
	)
	ssim_command=(
		ffmpeg -nostdin -v info -i "$qsv_output" -i "$clip" -lavfi '[0:v][1:v]ssim'
		-f null -
	)
	psnr_command=(
		ffmpeg -nostdin -v info -i "$qsv_output" -i "$clip" -lavfi '[0:v][1:v]psnr'
		-f null -
	)
	clip_json="$(array_json "${clip_command[@]}")"
	qsv_json="$(array_json "${qsv_command[@]}")"
	vmaf_json="$(array_json "${vmaf_command[@]}")"
	ssim_json="$(array_json "${ssim_command[@]}")"
	psnr_json="$(array_json "${psnr_command[@]}")"
	jq -n -c --argjson clip "$clip_json" --argjson qsv "$qsv_json" \
		--argjson vmaf "$vmaf_json" --argjson ssim "$ssim_json" --argjson psnr "$psnr_json" \
		'{clip:$clip,qsv:$qsv,vmaf:$vmaf,ssim:$ssim,psnr:$psnr}'
}

quality_work_plan() {
	local plan_override="${BENCHMARK_TEST_QUALITY_PLAN_FILE:-}"
	if [[ -n "$plan_override" ]]; then
		[[ "$test_mode" == '1' ]] || {
			echo 'BENCHMARK_TEST_QUALITY_PLAN_FILE requires BENCHMARK_TEST_MODE=1' >&2
			return 64
		}
		[[ -f "$plan_override" && ! -L "$plan_override" ]] || {
			echo 'quality plan fixture is not a regular file' >&2
			return 66
		}
		while IFS= read -r row; do
			printf '%s\n' "$row"
		done <"$plan_override"
		return
	fi

	jq -e -c --arg settings "$CONTRACT_ICQ_SETTINGS" '
		($settings | split(" ") | map(tonumber)) as $settings |
		.qualityPanel[]? |
		select((.detectionOnly // false) != true and .cohort != "dolby-vision") as $sample |
		$sample.clips | to_entries[] as $clip |
		$settings[] as $setting |
		{
			sampleId: $sample.id,
			cohort: $sample.cohort,
			sourcePath: $sample.path,
			sourceSha256: $sample.sha256,
			clipId: $clip.key,
			timestamp: $clip.value,
			encoder: "qsv",
			requestedSetting: $setting
		}
	' "$samples_file"
}
vmaf_stats() {
	local metrics="$1"
	local -a scores
	local count harmonic low_count low_mean
	[[ -f "$metrics" ]] || {
		echo 'VMAF metrics file not found' >&2
		return 66
	}
	mapfile -t scores < <(jq -e -r '
		if (.frames | type) != "array" or (.frames | length) == 0 or
			([.frames[] | .metrics.vmaf | numbers] | length) != (.frames | length)
		then error("invalid VMAF frames")
		else .frames[].metrics.vmaf
		end
	' "$metrics")
	count="${#scores[@]}"
	harmonic="$(printf '%s\n' "${scores[@]}" | awk '
		BEGIN { sum = 0; count = 0 }
		{
			score = $1
			if (score < 0.000001) score = 0.000001
			sum += 1 / score
			count += 1
		}
		END { printf "%.6f", count / sum }
	')"
	low_count=$(((count + 99) / 100))
	low_mean="$(printf '%s\n' "${scores[@]}" | sort -n | head -n "$low_count" | awk '
		{ sum += $1; count += 1 }
		END { printf "%.6f", sum / count }
	')"
	printf '{"frame_count":%s,"harmonic_mean":%s,"one_percent_low":%s}\n' \
		"$count" "$harmonic" "$low_mean"
}

drm_fdinfo_metrics() {
	local fixture="$1"
	awk '
		function block_error(value) {
			if (reason == "") reason = value
		}
		function finish_snapshot() {
			if (!snapshot) return
			if (!driver_seen) block_error("missing-driver")
			if (!video_seen) block_error("missing-video-counter")
			if (reason != "") return
			if (!first_seen) {
				first_seen = 1
				first_time = timestamp
				last_time = timestamp
				first_video = video
				maximum_video = video
				capacity_value = capacity
			} else {
				last_time = timestamp
				if (video > maximum_video) maximum_video = video
				if (capacity != capacity_value) block_error("changed-video-capacity")
			}
		}
		function start_snapshot(value) {
			finish_snapshot()
			snapshot = 1
			timestamp = value
			driver_seen = 0
			video_seen = 0
			capacity = 1
		}
		/^[0-9]+$/ {
			start_snapshot($1)
			next
		}
		$1 == "drm-driver:" {
			if (!snapshot || NF != 2) {
				block_error("malformed-driver")
				next
			}
			driver_seen = 1
			driver = $2
			if ($2 != "i915") block_error("wrong-driver")
			next
		}
		$1 == "drm-engine-video:" {
			if (!snapshot || NF != 3 || $2 !~ /^[0-9]+$/ || $3 != "ns") {
				block_error("malformed-video-counter")
				next
			}
			video_seen = 1
			video = $2
			next
		}
		$1 == "drm-engine-capacity-video:" {
			if (!snapshot || NF != 2 || $2 !~ /^[0-9]+$/ || $2 <= 0) {
				block_error("invalid-video-capacity")
				next
			}
			capacity = $2
			next
		}
		END {
			finish_snapshot()
			if (!snapshot && reason == "") reason = "missing-snapshots"
			if (!first_seen && reason == "") reason = "missing-video-counter"
			if (reason != "") {
				printf "{\"status\":\"harness-blocked\",\"driver\":\"%s\",\"video_busy_nanoseconds\":0,\"video_busy_percent\":0.000000,\"reason\":\"%s\"}\n", driver, reason
				exit
			}
			delta = maximum_video - first_video
			elapsed = last_time - first_time
			percent = (elapsed > 0 ? delta * 100 / elapsed / capacity_value : 0)
			printf "{\"status\":\"available\",\"driver\":\"%s\",\"video_busy_nanoseconds\":%.0f,\"video_busy_percent\":%.6f,\"reason\":\"\"}\n", driver, delta, percent
		}
	' "$fixture"
}

qsv_proof() {
	local encode_status="$1"
	local encode_log="$2"
	local fdinfo_log="$3"
	local height="$4"
	local selected='unknown' initialization='failed' binding='harness-blocked'
	local render_node='' fps='0.000000' speed='0.000000'
	local driver gpu delta telemetry metrics reasons='' proof='passed' value blocked=0
	if [[ "$encode_status" == '0' ]] &&
		! grep -q -E 'Device creation failed|Failed to initiali[sz]e|Error creating a MFX session' "$encode_log"; then
		initialization='passed'
	fi
	value="$(grep -i -E 'Using .*ratecontrol method|Runtime selected ratecontrol method:' "$encode_log" |
		grep -o -i -E 'LA[_-]?ICQ|CQP|ICQ|CBR|VBR|AVBR|QVBR' | tail -n 1 || true)"
	case "${value^^}" in
	LA_ICQ | LA-ICQ | LAICQ) selected='rejected' ;;
	CQP | ICQ | CBR | VBR | AVBR | QVBR) selected="${value^^}" ;;
	esac
	value="$(grep -o -E 'fps=[[:space:]]*[0-9]+([.][0-9]+)?' "$encode_log" | tail -n 1 | sed 's/fps=[[:space:]]*//' || true)"
	[[ -z "$value" ]] || fps="$(awk -v value="$value" 'BEGIN { printf "%.6f", value }')"
	value="$(grep -o -E 'speed=[[:space:]]*[0-9]+([.][0-9]+)?x' "$encode_log" | tail -n 1 | sed 's/speed=[[:space:]]*//; s/x$//' || true)"
	[[ -z "$value" ]] || speed="$(awk -v value="$value" 'BEGIN { printf "%.6f", value }')"
	value="$(grep -E '^render-node: /dev/dri/renderD[0-9]+$' "$fdinfo_log" | tail -n 1 || true)"
	if [[ "$value" == 'render-node: /dev/dri/renderD128' ]]; then
		render_node='/dev/dri/renderD128'
		binding='passed'
	elif [[ -n "$value" ]]; then
		render_node="${value#render-node: }"
		binding='failed'
	fi
	metrics="$(drm_fdinfo_metrics "$fdinfo_log")"
	telemetry="$(jq -r '.status' <<<"$metrics")"
	driver="$(jq -r '.driver' <<<"$metrics")"
	delta="$(jq -r '.video_busy_nanoseconds' <<<"$metrics")"
	gpu="$(awk -v value="$(jq -r '.video_busy_percent' <<<"$metrics")" \
		'BEGIN { printf "%.6f", value }')"

	if [[ "$initialization" != 'passed' ]]; then
		reasons='initialization'
	fi
	if [[ "$binding" != 'passed' ]]; then
		reasons="${reasons:+$reasons;}binding"
		[[ "$binding" == 'harness-blocked' ]] && blocked=1
	fi
	if [[ "$selected" == 'unknown' ]]; then
		reasons="${reasons:+$reasons;}rate-control"
		[[ "$initialization" == 'passed' ]] && blocked=1
	elif [[ "$selected" != 'ICQ' ]]; then
		reasons="${reasons:+$reasons;}rate-control"
	fi
	if [[ "$telemetry" != 'available' ]]; then
		reasons="${reasons:+$reasons;}telemetry"
		blocked=1
	elif ! awk -v delta="$delta" 'BEGIN { exit !(delta > 0) }'; then
		reasons="${reasons:+$reasons;}telemetry"
	fi
	if ! awk -v value="$speed" 'BEGIN { exit !(value > 0) }'; then
		reasons="${reasons:+$reasons;}progress"
	fi
	if [[ "$initialization" != 'passed' ]]; then
		proof='failed'
	elif ((blocked)); then
		proof='harness-blocked'
	elif [[ -n "$reasons" ]]; then
		proof='failed'
	fi
	jq -n -c \
		--arg selected "$selected" --arg initialization "$initialization" \
		--arg binding "$binding" --arg render_node "$render_node" --arg driver "$driver" \
		--argjson busy "$delta" --argjson fps "$fps" --argjson speed "$speed" \
		--argjson gpu "$gpu" --arg proof "$proof" --arg reasons "$reasons" '{
			selected_rate_control: $selected, initialization: $initialization,
			binding: $binding, render_node: $render_node, drm_driver: $driver,
			video_busy_nanoseconds: $busy, encode_fps: $fps, encode_speed: $speed,
			gpu_busy_percent: $gpu, qsv_proof: $proof, suspect_reasons: $reasons
		}'
}

passed_or_failed() {
	if "$@" >/dev/null; then
		printf '%s\n' 'passed'
	else
		printf '%s\n' 'failed'
	fi
}

normalized_rational() {
	local value="$1" numerator denominator divisor a b remainder
	[[ "$value" =~ ^([0-9]{1,10})/([0-9]{1,10})$ ]] || return 1
	numerator="${BASH_REMATCH[1]}"
	denominator="${BASH_REMATCH[2]}"
	((10#$numerator > 0 && 10#$denominator > 0 && 10#$numerator <= 2147483647 && 10#$denominator <= 2147483647)) || return 1
	a=$((10#$numerator))
	b=$((10#$denominator))
	while ((b != 0)); do
		remainder=$((a % b))
		a="$b"
		b="$remainder"
	done
	divisor="$a"
	printf '%s/%s\n' "$((10#$numerator / divisor))" "$((10#$denominator / divisor))"
}

validate_probes() {
	local source_probe="$1"
	local output_probe="$2"
	local scope="$3"
	local decode_status="$4"
	local tolerance source_duration='0' output_duration='0' duration_difference='0'
	local codec duration resolution frame_rate bit_depth hdr audio subtitle chapters
	local failures='' source_frame output_frame source_base output_base
	[[ "$scope" == 'clip' || "$scope" == 'full' ]] || return 64
	if [[ "$scope" == 'clip' ]]; then tolerance='1.0'; else tolerance='2.0'; fi
	source_base="$(passed_or_failed jq -e '
		(.durationSeconds | type) == "number" and
		(.videoCodec | type) == "string" and
		(.width | type) == "number" and (.width | floor) == .width and .width > 0 and
		(.height | type) == "number" and (.height | floor) == .height and .height > 0 and
		(.frameRate | type) == "string" and
		(.bitDepth | type) == "number" and (.bitDepth | floor) == .bitDepth and .bitDepth > 0 and
		(.hdrFormat | type) == "string" and (.colorPrimaries | type) == "string" and
		(.colorTransfer | type) == "string" and (.colorSpace | type) == "string" and
		has("masteringDisplay") and (.masteringDisplay | type) as $md | ($md == "object" or $md == "null") and
		has("maxCLL") and (.maxCLL | type) as $cll | ($cll == "object" or $cll == "null") and
		(.audioTrackCount | type) == "number" and (.audioTrackCount | floor) == .audioTrackCount and .audioTrackCount >= 0 and
		(.subtitleCount | type) == "number" and (.subtitleCount | floor) == .subtitleCount and .subtitleCount >= 0 and
		(.chapterCount | type) == "number" and (.chapterCount | floor) == .chapterCount and .chapterCount >= 0
	' "$source_probe")"
	output_base="$(passed_or_failed jq -e '
		(.durationSeconds | type) == "number" and
		(.videoCodec | type) == "string" and
		(.width | type) == "number" and (.width | floor) == .width and .width > 0 and
		(.height | type) == "number" and (.height | floor) == .height and .height > 0 and
		(.frameRate | type) == "string" and
		(.bitDepth | type) == "number" and (.bitDepth | floor) == .bitDepth and .bitDepth > 0 and
		(.hdrFormat | type) == "string" and (.colorPrimaries | type) == "string" and
		(.colorTransfer | type) == "string" and (.colorSpace | type) == "string" and
		has("masteringDisplay") and (.masteringDisplay | type) as $md | ($md == "object" or $md == "null") and
		has("maxCLL") and (.maxCLL | type) as $cll | ($cll == "object" or $cll == "null") and
		(.audioTrackCount | type) == "number" and (.audioTrackCount | floor) == .audioTrackCount and .audioTrackCount >= 0 and
		(.subtitleCount | type) == "number" and (.subtitleCount | floor) == .subtitleCount and .subtitleCount >= 0 and
		(.chapterCount | type) == "number" and (.chapterCount | floor) == .chapterCount and .chapterCount >= 0
	' "$output_probe")"
	if [[ "$source_base" == 'passed' && "$output_base" == 'passed' ]]; then
		source_duration="$(jq -r '.durationSeconds' "$source_probe")"
		output_duration="$(jq -r '.durationSeconds' "$output_probe")"
		duration_difference="$(awk -v source="$source_duration" -v output="$output_duration" '
			BEGIN { difference = source - output; if (difference < 0) difference = -difference; print difference }
		')"
	fi

	codec="$(passed_or_failed jq -e '(.videoCodec | type) == "string" and .videoCodec == "hevc"' "$output_probe")"
	if [[ "$source_base" == 'passed' && "$output_base" == 'passed' ]]; then
		duration="$(passed_or_failed awk -v difference="$duration_difference" -v tolerance="$tolerance" \
			'BEGIN { exit !(difference <= tolerance) }')"
	else
		duration='failed'
	fi
	resolution="$(passed_or_failed jq -e -n --slurpfile source "$source_probe" --slurpfile output "$output_probe" \
		'($source[0].width | type) == "number" and ($output[0].width | type) == "number" and
		 ($source[0].height | type) == "number" and ($output[0].height | type) == "number" and
		 $source[0].width == $output[0].width and $source[0].height == $output[0].height')"
	frame_rate='failed'
	if source_frame="$(normalized_rational "$(jq -r '.frameRate // empty' "$source_probe")")" &&
		output_frame="$(normalized_rational "$(jq -r '.frameRate // empty' "$output_probe")")" &&
		[[ "$source_frame" == "$output_frame" ]]; then
		frame_rate='passed'
	fi
	bit_depth="$(passed_or_failed jq -e -n --slurpfile source "$source_probe" --slurpfile output "$output_probe" '
		($source[0].bitDepth | type) == "number" and ($output[0].bitDepth | type) == "number" and
		$source[0].bitDepth == $output[0].bitDepth and
		(if $source[0].hdrFormat == "hdr10" then $output[0].bitDepth == 10 else true end)
	')"
	hdr="$(passed_or_failed jq -e -n --slurpfile source "$source_probe" --slurpfile output "$output_probe" '
		($source[0].hdrFormat | type) == "string" and ($output[0].hdrFormat | type) == "string" and
		($source[0].colorPrimaries | type) == "string" and ($output[0].colorPrimaries | type) == "string" and
		($source[0].colorTransfer | type) == "string" and ($output[0].colorTransfer | type) == "string" and
		($source[0].colorSpace | type) == "string" and ($output[0].colorSpace | type) == "string" and
		$source[0].hdrFormat == $output[0].hdrFormat and
		$source[0].colorPrimaries == $output[0].colorPrimaries and
		$source[0].colorTransfer == $output[0].colorTransfer and
		$source[0].colorSpace == $output[0].colorSpace
	')"
	audio="$(passed_or_failed jq -e -n --slurpfile source "$source_probe" --slurpfile output "$output_probe" \
		'($source[0].audioTrackCount | type) == "number" and ($output[0].audioTrackCount | type) == "number" and $source[0].audioTrackCount == $output[0].audioTrackCount')"
	subtitle="$(passed_or_failed jq -e -n --slurpfile source "$source_probe" --slurpfile output "$output_probe" \
		'($source[0].subtitleCount | type) == "number" and ($output[0].subtitleCount | type) == "number" and $source[0].subtitleCount == $output[0].subtitleCount')"
	chapters="$(passed_or_failed jq -e -n --slurpfile source "$source_probe" --slurpfile output "$output_probe" \
		'($source[0].chapterCount | type) == "number" and ($output[0].chapterCount | type) == "number" and $source[0].chapterCount == $output[0].chapterCount')"

	if [[ "$decode_status" != '0' ]]; then failures='decode'; fi
	for field in \
		"codec:$codec" "duration:$duration" "resolution:$resolution" \
		"frame-rate:$frame_rate" "bit-depth:$bit_depth" "hdr:$hdr" \
		"audio-tracks:$audio" "subtitle-tracks:$subtitle" "chapters:$chapters"; do
		name="${field%%:*}"
		value="${field#*:}"
		if [[ "$value" != 'passed' ]]; then
			failures="${failures:+$failures;}$name"
		fi
	done
	jq -n -c \
		--arg codec "$codec" --arg duration "$duration" --arg resolution "$resolution" \
		--arg frame_rate "$frame_rate" --arg bit_depth "$bit_depth" --arg hdr "$hdr" \
		--arg audio "$audio" --arg subtitle "$subtitle" --arg chapters "$chapters" \
		--arg failures "$failures" '{
			validation_codec: $codec,
			validation_duration: $duration,
			validation_resolution: $resolution,
			validation_frame_rate: $frame_rate,
			validation_bit_depth: $bit_depth,
			validation_hdr: $hdr,
			validation_audio_tracks: $audio,
			validation_subtitle_tracks: $subtitle,
			validation_chapters: $chapters,
			validation_failures: $failures
		}'
}

ensure_results_file() {
	local results="$1"
	local existing_header
	if [[ ! -e "$results" ]]; then
		printf '%s\n' "$results_header" >"$results"
		return
	fi
	[[ -f "$results" && ! -L "$results" ]] || {
		echo 'results path is not a regular file' >&2
		return 65
	}
	IFS= read -r existing_header <"$results" || true
	[[ "$existing_header" == "$results_header" ]] || {
		echo 'invalid results CSV header' >&2
		return 65
	}
}

result_attempt() {
	local results="$1"
	local panel="$2" sha="$3" clip="$4" encoder="$5" setting="$6"
	awk -F, -v panel="$panel" -v sha="$sha" -v clip="$clip" -v encoder="$encoder" -v setting="$setting" '
		NR > 1 && $2 == panel && $5 == sha && $6 == clip && $7 == encoder && $8 == setting {
			if (($11 + 0) > maximum) maximum = $11 + 0
		}
		END { print maximum + 1 }
	' "$results"
}

safe_csv_field() {
	local value="$1"
	[[ "$value" != *','* && "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *'"'* ]]
}

quality_evidence_document_matches() {
	local document="$1" run_id="$2" sample_id="$3" cohort="$4" source_sha="$5"
	local clip_id="$6" setting="$7" vmaf_harmonic="$8" vmaf_low="$9" ssim="${10}"
	local validation_hdr="${11}"
	[[ -f "$document" && ! -L "$document" ]] || return 66
	jq -e \
		--arg run "$run_id" --arg sample "$sample_id" --arg cohort "$cohort" \
		--arg source_sha "$source_sha" --arg clip "$clip_id" --argjson setting "$setting" \
		--arg vmaf_harmonic "$vmaf_harmonic" --arg vmaf_low "$vmaf_low" \
		--arg ssim "$ssim" --arg validation_hdr "$validation_hdr" \
		--arg strategy "$CONTRACT_STRATEGY_ID" --argjson schema "$CONTRACT_QUALITY_EVIDENCE_SCHEMA" '
		def exact_keys($wanted): type == "object" and ((keys | sort) == ($wanted | sort));
		def finite_number: type == "number" and isfinite;
		def nonnegative_integer: finite_number and floor == . and . >= 0;
		def excluded_frame:
			exact_keys(["frameIndex","vmaf"]) and
			(.frameIndex | nonnegative_integer) and .vmaf == 0;
		exact_keys(["clipId","cohort","globalQuality","hdr","psnr","runId","sampleId",
			"schemaVersion","sourceSha256","ssim","strategyId","vmaf"]) and
		.schemaVersion == $schema and .strategyId == $strategy and .runId == $run and
		.sampleId == $sample and .cohort == $cohort and .sourceSha256 == $source_sha and
		.clipId == $clip and .globalQuality == $setting and
		(.ssim | finite_number) and .ssim == ($ssim | tonumber) and
		(.psnr | finite_number) and
		(.vmaf |
			exact_keys(["evaluatedFrameCount","excludedFrames","harmonicMean","onePercentLow","rawFrameCount"]) and
			(.rawFrameCount | nonnegative_integer and . > 0) and
			(.evaluatedFrameCount | nonnegative_integer and . > 0) and
			(.excludedFrames | type == "array" and length <= 1 and all(.[]; excluded_frame)) and
			.evaluatedFrameCount == (.rawFrameCount - (.excludedFrames | length)) and
			(.harmonicMean | finite_number) and .harmonicMean == ($vmaf_harmonic | tonumber) and
			(.onePercentLow | finite_number) and .onePercentLow == ($vmaf_low | tonumber)) and
		(if $cohort == "hdr10" then
			(.hdr |
				exact_keys(["classification","normalizedOracle","reasons"]) and
				(.classification as $classification |
					["preserved","source-oracle-defect","clip-boundary-defect","encoder-output-defect"] |
					index($classification)) != null and
				(.reasons | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)) and
				(.normalizedOracle | type == "object")) and
			(if $validation_hdr == "passed" then .hdr.classification == "preserved" else true end)
		else .hdr == null end)
	' "$document" >/dev/null
}

publish_quality_evidence() (
	local run_directory="$1" run_id="$2" sample_id="$3" cohort="$4" source_sha="$5"
	local clip_id="$6" setting="$7" attempt="$8" vmaf="$9" ssim="${10}" psnr="${11}"
	local hdr="${12}" validation_hdr="${13}"
	local evidence_directory evidence_base relative destination staged='' digest document
	local expected_digest actual_digest competitor
	evidence_directory="$run_directory/quality-evidence"
	evidence_base="$sample_id-$clip_id-qsv-$setting-attempt-$attempt"
	relative="quality-evidence/$evidence_base.json"
	destination="$run_directory/$relative"
	trap '
		if [[ -n "$staged" ]]; then rm -f -- "$staged"; fi
	' EXIT
	[[ "$sample_id" =~ ^[a-z0-9][a-z0-9._-]*$ && "$clip_id" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || return 65
	if [[ -e "$evidence_directory" || -L "$evidence_directory" ]]; then
		[[ -d "$evidence_directory" && ! -L "$evidence_directory" ]] || return 65
	else
		mkdir -- "$evidence_directory" || return
	fi
	[[ "$(cd -P "$evidence_directory" && pwd)" == "$(cd -P "$run_directory" && pwd)/quality-evidence" ]] || return 65
	document="$(jq -S -c -n \
		--arg run "$run_id" --arg sample "$sample_id" --arg cohort "$cohort" \
		--arg source_sha "$source_sha" --arg clip "$clip_id" --argjson setting "$setting" \
		--arg strategy "$CONTRACT_STRATEGY_ID" --argjson schema "$CONTRACT_QUALITY_EVIDENCE_SCHEMA" \
		--argjson vmaf "$vmaf" --argjson ssim "$ssim" --argjson psnr "$psnr" --argjson hdr "$hdr" '{
			clipId:$clip,cohort:$cohort,globalQuality:$setting,hdr:$hdr,psnr:$psnr,
			runId:$run,sampleId:$sample,schemaVersion:$schema,sourceSha256:$source_sha,
			ssim:$ssim,strategyId:$strategy,vmaf:$vmaf
		}')" || return 65
	staged="$(mktemp "$evidence_directory/.$evidence_base.tmp.XXXXXX")" || return
	if ! printf '%s\n' "$document" >"$staged" || ! chmod 0600 "$staged" ||
		! quality_evidence_document_matches "$staged" "$run_id" "$sample_id" "$cohort" \
			"$source_sha" "$clip_id" "$setting" \
			"$(jq -r '.harmonicMean' <<<"$vmaf")" "$(jq -r '.onePercentLow' <<<"$vmaf")" \
			"$ssim" "$validation_hdr"; then
		return 65
	fi
	expected_digest="sha256:$(sha256sum "$staged" | awk 'NR == 1 { print $1 }')"
	[[ "$expected_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || return 65
	if [[ "$test_mode" == '1' &&
		"${BENCHMARK_TEST_QUALITY_EVIDENCE_COMPETITOR_SETTING:-}" == "$setting" &&
		-n "${BENCHMARK_TEST_QUALITY_EVIDENCE_COMPETITOR_FILE:-}" ]]; then
		competitor="$BENCHMARK_TEST_QUALITY_EVIDENCE_COMPETITOR_FILE"
		[[ -f "$competitor" && ! -L "$competitor" ]] || return 65
		if [[ ! -e "$destination" && ! -L "$destination" ]]; then
			cp -- "$competitor" "$destination" || return 65
		fi
	fi
	# A hard link publishes the already complete same-filesystem inode only when
	# the destination does not exist. It cannot replace a concurrent publisher.
	if ln -T -- "$staged" "$destination" 2>/dev/null; then
		rm -f -- "$staged" || return 65
		staged=''
	else
		[[ -e "$destination" || -L "$destination" ]] || return 65
	fi
	[[ -f "$destination" && ! -L "$destination" ]] || return 65
	[[ "$(realpath "$destination")" == "$(cd -P "$run_directory" && pwd)/$relative" ]] || return 65
	actual_digest="sha256:$(sha256sum "$destination" | awk 'NR == 1 { print $1 }')"
	[[ "$actual_digest" == "$expected_digest" ]] || return 65
	quality_evidence_document_matches "$destination" "$run_id" "$sample_id" "$cohort" \
		"$source_sha" "$clip_id" "$setting" \
		"$(jq -r '.harmonicMean' <<<"$vmaf")" "$(jq -r '.onePercentLow' <<<"$vmaf")" \
		"$ssim" "$validation_hdr" || return 65
	chmod 0600 "$destination" || return 65
	digest="$actual_digest"
	printf '%s\t%s\n' "$relative" "$digest"
)

validate_quality_evidence_reference() {
	local run_directory="$1" run_id="$2" sample_id="$3" cohort="$4" source_sha="$5"
	local clip_id="$6" setting="$7" attempt="$8" evidence_path="$9" evidence_digest="${10}"
	local fixture="${11}" expected_path evidence_file actual_digest
	expected_path="quality-evidence/$sample_id-$clip_id-qsv-$setting-attempt-$attempt.json"
	[[ "$evidence_path" == "$expected_path" && "$evidence_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || return 65
	evidence_file="$run_directory/$evidence_path"
	[[ -f "$evidence_file" && ! -L "$evidence_file" ]] || return 65
	[[ "$(realpath "$evidence_file")" == "$(cd -P "$run_directory" && pwd)/$evidence_path" ]] || return 65
	actual_digest="sha256:$(sha256sum "$evidence_file" | awk 'NR == 1 { print $1 }')"
	[[ "$actual_digest" == "$evidence_digest" ]] || return 65
	quality_evidence_document_matches "$evidence_file" "$run_id" "$sample_id" "$cohort" \
		"$source_sha" "$clip_id" "$setting" \
		"$(jq -r '.vmaf_harmonic_mean' "$fixture")" "$(jq -r '.vmaf_1pct_low' "$fixture")" \
		"$(jq -r '.ssim' "$fixture")" "$(jq -r '.validation_hdr' "$fixture")"
}

record_result_inner() {
	local run_id="$1"
	local fixture="$2"
	local scratch_output="$3"
	local run_directory results panel sample_id cohort source_sha clip encoder setting
	local selected strategy qsv_initialization video_busy_nanoseconds quality_evidence_path quality_evidence_sha256
	local status attempt disposition='discarded'
	local append_status=0 completed_status=0 columns_text out_physical runs_physical run_physical
	local -a columns
	if [[ ! -v CONTRACT_STRATEGY_ID ]]; then
		contract_load "$samples_file" || return
	fi
	validate_run_id "$run_id" || return
	[[ -f "$fixture" ]] || return 66
	run_directory="$benchmark_out/runs/$run_id"
	[[ -d "$run_directory" && ! -L "$run_directory" ]] || {
		echo "run directory not found: $run_id" >&2
		return 66
	}
	[[ -d "$benchmark_out" && ! -L "$benchmark_out" &&
		-d "$benchmark_out/runs" && ! -L "$benchmark_out/runs" ]] || {
		echo 'benchmark output hierarchy is not confined' >&2
		return 65
	}
	out_physical="$(cd -P "$benchmark_out" && pwd)"
	runs_physical="$(cd -P "$benchmark_out/runs" && pwd)"
	run_physical="$(cd -P "$run_directory" && pwd)"
	[[ "$runs_physical" == "$out_physical/runs" && "$run_physical" == "$runs_physical/$run_id" ]] || {
		echo 'run directory escapes the benchmark output hierarchy' >&2
		return 65
	}
	panel="$(jq -e -r '.panel | strings' "$fixture")" || return 65
	sample_id="$(jq -e -r '.sample_id | strings' "$fixture")" || return 65
	cohort="$(jq -e -r '.cohort | strings' "$fixture")" || return 65
	source_sha="$(jq -e -r '.source_sha256 | strings' "$fixture")" || return 65
	clip="$(jq -e -r '.clip_id | strings' "$fixture")" || return 65
	encoder="$(jq -e -r '.encoder | strings' "$fixture")" || return 65
	setting="$(jq -e -r '.requested_setting | strings' "$fixture")" || return 65
	selected="$(jq -e -r '.selected_rate_control | strings' "$fixture")" || return 65
	strategy="$(jq -e -r '.strategy_id | strings' "$fixture")" || return 65
	qsv_initialization="$(jq -e -r '.qsv_initialization | strings' "$fixture")" || return 65
	video_busy_nanoseconds="$(jq -e -r '.video_busy_nanoseconds | strings' "$fixture")" || return 65
	quality_evidence_path="$(jq -e -r '(.quality_evidence_path // "") | strings' "$fixture")" || return 65
	quality_evidence_sha256="$(jq -e -r '(.quality_evidence_sha256 // "") | strings' "$fixture")" || return 65
	validate_sample_id "$sample_id" || return
	[[ "$panel" == 'quality' && "$encoder" == 'qsv' ]] || return 65
	[[ "$setting" =~ ^[0-9]+$ ]] || return 65
	if [[ "$encoder" == 'qsv' ]]; then
		contract_is_icq_setting "$samples_file" "$setting" || {
			echo 'QSV result setting is not an ICQ candidate' >&2
			return 65
		}
	fi
	[[ "$source_sha" =~ ^[0-9a-f]{64}$ ]] || return 65
	[[ "$strategy" == "$CONTRACT_STRATEGY_ID" ]] || {
		echo 'result fixture strategy does not match contract' >&2
		return 65
	}
	results="$run_directory/results.csv"
	ensure_results_file "$results" || return
	row_is_complete "$run_id" "$panel" "$source_sha" "$clip" "$encoder" "$setting" || completed_status=$?
	if ((completed_status != 0 && completed_status != 1)); then return "$completed_status"; fi
	if ((completed_status == 0)); then
		attempt=$(("$(result_attempt "$results" "$panel" "$source_sha" "$clip" "$encoder" "$setting")" - 1))
		printf '{"status":"skipped","attempt":%s,"output_disposition":"not-created"}\n' "$attempt"
		return
	fi
	attempt="$(result_attempt "$results" "$panel" "$source_sha" "$clip" "$encoder" "$setting")"
	if [[ "$panel" == 'quality' ]]; then
		if ! validate_quality_evidence_reference "$run_directory" "$run_id" "$sample_id" "$cohort" \
			"$source_sha" "$clip" "$setting" "$attempt" "$quality_evidence_path" \
			"$quality_evidence_sha256" "$fixture"; then
			echo 'quality result evidence is missing or invalid' >&2
			return 65
		fi
	elif [[ -n "$quality_evidence_path" || -n "$quality_evidence_sha256" ]]; then
		echo 'non-quality result must not reference quality evidence' >&2
		return 65
	fi
	status='passed'
	if [[ "$(jq -r '.encode_status // 0' "$fixture")" != '0' ]]; then
		status='failed'
	elif [[ -n "$(jq -r '.validation_failures' "$fixture")" ]]; then
		status='invalid'
	elif [[ "$encoder" == 'qsv' ]] &&
		[[ "$selected" != 'ICQ' || "$(jq -r '.qsv_proof' "$fixture")" != 'passed' ||
		"$qsv_initialization" != 'passed' || ! "$video_busy_nanoseconds" =~ ^[0-9]+$ ||
		"$video_busy_nanoseconds" -le 0 ]]; then
		status='invalid'
	fi

	columns_text="$(jq -e -r '
		[
			.panel, .sample_id, .cohort, .source_sha256, .clip_id, .encoder,
			.requested_setting, .selected_rate_control,
			.input_bytes, .output_bytes, .reduction_percent,
			.input_bit_rate, .output_bit_rate, .wall_seconds, .encode_fps,
			.encode_speed, .vmaf_harmonic_mean, .vmaf_1pct_low, .ssim,
			.gpu_busy_percent, .qsv_proof, .validation_codec,
			.validation_duration, .validation_resolution,
			.validation_frame_rate, .validation_bit_depth, .validation_hdr,
			.validation_audio_tracks, .validation_subtitle_tracks,
			.validation_chapters, .validation_failures, .log_path,
			.strategy_id, .qsv_initialization, .video_busy_nanoseconds
		] | if length == 35 and all(.[]; type == "string")
		then .[] else error("invalid result fixture") end
	' "$fixture")" || return 65
	mapfile -t columns <<<"$columns_text"
	((${#columns[@]} == 35)) || return 65
	columns=(
		"$run_id" "${columns[0]}" "${columns[1]}" "${columns[2]}" "${columns[3]}"
		"${columns[4]}" "${columns[5]}" "${columns[6]}" "${columns[7]}" "$status"
		"$attempt" "${columns[@]:8:24}" "$disposition" "${columns[@]:32:3}"
		"$quality_evidence_path" "$quality_evidence_sha256"
	)
	for value in "${columns[@]}"; do
		safe_csv_field "$value" || {
			echo 'result contains an unsafe CSV field' >&2
			return 65
		}
	done
	if [[ "$test_mode" == '1' && "${BENCHMARK_TEST_FAIL_RESULT_APPEND:-0}" == '1' ]]; then
		append_status=74
	else
		(
			IFS=,
			printf '%s\n' "${columns[*]}"
		) >>"$results" || append_status=$?
	fi
	if ((append_status != 0)); then
		return "$append_status"
	fi
	printf '{"status":"%s","attempt":%s,"output_disposition":"%s"}\n' \
		"$status" "$attempt" "$disposition"
}

record_result() {
	local run_id="$1" fixture="$2" scratch_output="$3" status=0
	record_result_inner "$run_id" "$fixture" "$scratch_output" || status=$?
	rm -f -- "$scratch_output"
	return "$status"
}

# Report every declared command the runtime image is missing, not just the first.
# A probe that stops at one missing tool costs an operator a full dispatch cycle
# per gap, which is how an undeclared command reached a live Job.
missing_declared_commands() {
	local candidate
	local -a missing=()
	for candidate in "$@"; do
		command -v "$candidate" >/dev/null 2>&1 || missing+=("$candidate")
	done
	((${#missing[@]} == 0)) || printf '%s\n' "${missing[*]}"
}

# Read the declaration using only shell builtins. Parsing this with jq would make
# the probe depend on a tool it exists to test for: a first live capability run
# reported only "yq rg" and could not enumerate the rest of the gap, costing the
# dispatch cycle this whole check is meant to save. The offline contracts assert
# this parse against jq's on the same file.
read_declared_commands() {
	local file="$1" key="${2:-requiredCommands}" line in_block=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" =~ ^[[:space:]]*\"$key\":[[:space:]]*\[[[:space:]]*$ ]]; then
			in_block=1
			continue
		fi
		((in_block)) || continue
		if [[ "$line" =~ ^[[:space:]]*\"([A-Za-z0-9_.-]+)\",?[[:space:]]*$ ]]; then
			printf '%s\n' "${BASH_REMATCH[1]}"
		else
			break
		fi
	done <"$file"
}

normalize_running_image_id() {
	local image_id="$1" stripped
	stripped="${image_id#docker-pullable://}"
	stripped="${stripped#containerd://}"
	[[ "$stripped" =~ ^([^@[:space:]]+@)?sha256:[0-9a-f]{64}$ ]] || return 65
	printf '%s\n' "$stripped"
}

require_running_image_evidence() {
	local configured_image dispatched_image configured_digest dispatched_digest
	local evidence normalized_image_id running_digest deadline
	if [[ "$test_mode" == '1' && ! -v BENCHMARK_RUNNING_IMAGE_FILE && -z "${BENCHMARK_RUNNING_IMAGE:-}" ]]; then
		return 0
	fi
	configured_image="$(jq -e -r '.runtime.image | strings | select(test("^[^@[:space:]]+@sha256:[0-9a-f]{64}$"))' \
		"$samples_file")" || {
		echo 'configured runtime image is missing or mutable' >&2
		return 65
	}
	dispatched_image="${BENCHMARK_DISPATCH_IMAGE:-}"
	[[ "$dispatched_image" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]] || {
		echo 'dispatched runtime image is missing or mutable' >&2
		return 65
	}
	configured_digest="${configured_image##*@}"
	dispatched_digest="${dispatched_image##*@}"
	[[ "$configured_image" == "$dispatched_image" && "$configured_digest" == "$dispatched_digest" ]] || {
		echo 'configured and dispatched runtime images do not match' >&2
		return 65
	}
	if [[ "$test_mode" == '1' && -n "${BENCHMARK_RUNNING_IMAGE:-}" && ! -f "$running_image_file" ]]; then
		normalized_image_id="$(normalize_running_image_id "$BENCHMARK_RUNNING_IMAGE")" || return 65
		running_digest="${normalized_image_id##*@}"
		[[ "$running_digest" == "$configured_digest" ]] || return 65
		BENCHMARK_RUNNING_IMAGE="$normalized_image_id"
		export BENCHMARK_RUNNING_IMAGE
		return
	fi
	deadline=$((SECONDS + running_image_wait_seconds))
	while [[ ! -f "$running_image_file" ]]; do
		if ((SECONDS >= deadline)); then
			echo 'timed out waiting for running image evidence' >&2
			return 70
		fi
		sleep 1
	done
	evidence="$(jq -e -c \
		--arg configured "$configured_image" --arg dispatched "$dispatched_image" '
		select(type == "object" and keys == ["configuredImage","dispatchedImage","imageId"] and
			.configuredImage == $configured and .dispatchedImage == $dispatched and
			(.imageId | type == "string"))
	' "$running_image_file")" || {
		echo 'running image evidence is malformed or inconsistent' >&2
		return 65
	}
	normalized_image_id="$(normalize_running_image_id "$(jq -r '.imageId' <<<"$evidence")")" || {
		echo 'running image evidence is malformed or inconsistent' >&2
		return 65
	}
	running_digest="${normalized_image_id##*@}"
	[[ "$running_digest" == "$configured_digest" && "$running_digest" == "$dispatched_digest" ]] || {
		echo 'running image evidence is malformed or inconsistent' >&2
		return 65
	}
	BENCHMARK_RUNNING_IMAGE="$normalized_image_id"
	export BENCHMARK_RUNNING_IMAGE
	printf 'running_image_evidence=accepted image_id=%s\n' "$normalized_image_id" >&2
}

capabilities() (
	local capability_directory source encode_log fdinfo_log ffmpeg_version ffprobe_version
	local encoders uid configured_image configured_digest dispatch_image node_name
	local missing proof_json proof_exit
	local -a required_commands=()
	# Every check below is written in terms of jq, grep or ffmpeg, so the command
	# surface must be established before any of them runs; otherwise the probe
	# dies as "command not found" and reports nothing.
	mapfile -t required_commands < <(read_declared_commands "$samples_file")
	((${#required_commands[@]} > 0)) || {
		echo 'runtime requiredCommands declaration is missing or empty' >&2
		return 65
	}
	missing="$(missing_declared_commands "${required_commands[@]}")"
	[[ -z "$missing" ]] || {
		echo "runtime image is missing required commands: $missing" >&2
		return 1
	}
	configured_image="$(jq -e -r '.runtime.image' "$samples_file")" || {
		echo 'configured runtime image is missing' >&2
		return 65
	}
	[[ "$configured_image" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]] || {
		echo 'configured runtime image must use an immutable sha256 digest' >&2
		return 65
	}
	dispatch_image="${BENCHMARK_DISPATCH_IMAGE:-}"
	[[ "$dispatch_image" == "$configured_image" ]] || {
		echo 'runtime image identity does not match dispatched source' >&2
		return 65
	}
	configured_digest="${configured_image##*@}"
	node_name="${NODE_NAME:-}"
	[[ "$node_name" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || {
		echo 'capability node name is missing or malformed' >&2
		return 65
	}
	encoders="$(ffmpeg -nostdin -hide_banner -encoders)"
	grep -q -F 'hevc_qsv' <<<"$encoders" || return 1
	uid="$(id -u)"
	[[ "$uid" == '568' ]] || return 1
	mkdir -p "$scratch_root"
	capability_directory="$(mktemp -d "$scratch_root/capabilities.XXXXXX")"
	trap 'rm -rf -- "$capability_directory"' EXIT
	source="$capability_directory/source.mkv"
	encode_log="$capability_directory/qsv.log"
	fdinfo_log="$capability_directory/drm-fdinfo.log"
	ffmpeg -nostdin -v error -f lavfi -i 'testsrc2=size=1920x1080:rate=30' -t 5 \
		-pix_fmt yuv420p "$source"
	set +e
	proof_json="$(capability_proof "$encode_log" "$fdinfo_log")"
	proof_exit=$?
	set -e
	ffmpeg_version="$(ffmpeg -nostdin -version | awk 'NR == 1 { print $3 }')"
	ffprobe_version="$(ffprobe -version | awk 'NR == 1 { print $3 }')"
	jq -n -c \
		--arg ffmpeg "$ffmpeg_version" \
		--arg ffprobe "$ffprobe_version" \
		--arg node "$node_name" \
		--arg configured_image "$configured_image" \
		--arg configured_digest "$configured_digest" \
		--argjson uid "$uid" \
		--argjson proof "$proof_json" '$proof + {
			status: $proof.proofStatus, uid: $uid,
			hevcQsv: true,
			ffmpegVersion: $ffmpeg, ffprobeVersion: $ffprobe,
			nodeName: $node, configuredImage: $configured_image,
			configuredImageDigest: $configured_digest
		}'
	return "$proof_exit"
)

assigned_node_capability_gate() {
	local evidence driver ffmpeg_version kernel
	evidence="$(capabilities)" || return
	driver="$(jq -e -r '
		select(.status == "passed" and .proofStatus == "passed") |
		.drmDriver | strings | select(. == "i915")
	' <<<"$evidence")" || {
		echo 'assigned-node i915 identity is unavailable' >&2
		return 65
	}
	ffmpeg_version="$(jq -e -r '
		.ffmpegVersion | strings |
		select(test("^[A-Za-z0-9._+:-]+$"))
	' <<<"$evidence")" || {
		echo 'assigned-node VPL identity is unavailable' >&2
		return 65
	}
	kernel="$(uname -r)"
	[[ "$kernel" =~ ^[A-Za-z0-9._+:~-]+$ ]] || {
		echo 'assigned-node i915 identity is unavailable' >&2
		return 65
	}
	BENCHMARK_I915_VERSION="driver=$driver;kernel=$kernel"
	BENCHMARK_VPL_VERSION="backend=qsv;ffmpeg=$ffmpeg_version"
	export BENCHMARK_I915_VERSION BENCHMARK_VPL_VERSION
}

probe_media() {
	local role="$1"
	local path="$2"
	if [[ "$test_mode" == '1' && "$role" == 'source' && -n "${BENCHMARK_TEST_SOURCE_PROBE:-}" ]]; then
		jq -c . "$BENCHMARK_TEST_SOURCE_PROBE"
	elif [[ "$test_mode" == '1' && "$role" == 'output' &&
		-n "${BENCHMARK_TEST_INVALID_OUTPUT_MATCH:-}" &&
		"$path" =~ ${BENCHMARK_TEST_INVALID_OUTPUT_MATCH} ]]; then
		jq -c . "$BENCHMARK_TEST_INVALID_OUTPUT_PROBE"
	elif [[ "$test_mode" == '1' && "$role" == 'output' && -n "${BENCHMARK_TEST_OUTPUT_PROBE:-}" ]]; then
		jq -c . "$BENCHMARK_TEST_OUTPUT_PROBE"
	else
		"$script_directory/probe.sh" "$path"
	fi
}

file_size() {
	local path="$1"
	local size
	if size="$(stat -c '%s' "$path" 2>/dev/null)"; then
		printf '%s\n' "$size"
	else
		stat -f '%z' "$path"
	fi
}

runtime_pre_encode_gate() {
	local samples_json="$1"
	local configured_image dispatch_image sample sample_id source expected_size actual_size
	local expected_sha actual_sha encoders filters write_probe
	configured_image="$(jq -e -r '.runtime.image' "$samples_file")" || {
		echo 'configured runtime image is missing' >&2
		return 65
	}
	[[ "$configured_image" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]] || {
		echo 'configured runtime image must use an immutable sha256 digest' >&2
		return 65
	}
	dispatch_image="${BENCHMARK_DISPATCH_IMAGE:-}"
	if [[ "$test_mode" != '1' && "$dispatch_image" != "$configured_image" ]]; then
		echo 'runtime image identity does not match dispatched source' >&2
		return 65
	fi
	[[ -d "$benchmark_out" && ! -L "$benchmark_out" ]] || {
		echo 'benchmark output mount is unavailable' >&2
		return 66
	}
	write_probe="$(mktemp "$benchmark_out/.write-probe.XXXXXX")" || {
		echo 'benchmark output mount is not writable' >&2
		return 73
	}
	rm -f -- "$write_probe" || {
		echo 'benchmark output write probe could not be removed' >&2
		return 73
	}
	while IFS= read -r sample; do
		[[ -n "$sample" ]] || continue
		sample_id="$(jq -e -r '.id | strings | select(test("^[a-z0-9][a-z0-9._-]*$"))' <<<"$sample")" || return 65
		source="$(jq -e -r '.path | strings' <<<"$sample")" || return 65
		expected_size="$(jq -e -r '.sizeBytes | numbers | select(. > 0 and floor == .)' <<<"$sample")" || return 65
		expected_sha="$(jq -e -r '.sha256 | strings | select(test("^[0-9a-f]{64}$"))' <<<"$sample")" || return 65
		if [[ "$test_mode" != '1' && ! "$source" =~ ^/media/.+ ]]; then
			echo "sample path is outside /media: $sample_id" >&2
			return 65
		fi
		[[ -f "$source" && -r "$source" ]] || {
			echo "sample is not readable: $sample_id" >&2
			return 66
		}
		actual_size="$(file_size "$source")" || return
		[[ "$actual_size" == "$expected_size" ]] || {
			echo "sample size mismatch: $sample_id" >&2
			return 65
		}
		actual_sha="$(sha256sum "$source" | awk 'NR == 1 { value = $1; sub(/^\\/, "", value); print value }')"
		[[ "$actual_sha" == "$expected_sha" ]] || {
			echo "sample hash mismatch: $sample_id" >&2
			return 65
		}
	done < <(jq -c '.[]' <<<"$samples_json")
	encoders="$(ffmpeg -nostdin -hide_banner -encoders)" || return
	filters="$(ffmpeg -nostdin -hide_banner -filters)" || return
	grep -q -F 'hevc_qsv' <<<"$encoders" || {
		echo 'hevc_qsv encoder is unavailable' >&2
		return 1
	}
	grep -q -F 'libvmaf' <<<"$filters" || {
		echo 'libvmaf filter is unavailable' >&2
		return 1
	}
}

now_nanoseconds() {
	local value
	value="$(date '+%s%N')"
	if [[ "$value" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$value"
	else
		awk -v seconds="$(date '+%s')" 'BEGIN { printf "%.0f\n", seconds * 1000000000 }'
	fi
}

sample_drm_fdinfo() {
	local ffmpeg_pid="$1"
	local render_node="$2"
	local output="$3"
	local timestamp fd_path target fdinfo binding_recorded=0
	local -a fd_paths
	: >"$output"
	while kill -0 "$ffmpeg_pid" 2>/dev/null; do
		shopt -s nullglob
		fd_paths=(/proc/"$ffmpeg_pid"/fd/*)
		shopt -u nullglob
		for fd_path in "${fd_paths[@]}"; do
			[[ "${fd_path##*/}" =~ ^[0-9]+$ ]] || continue
			target="$(realpath "$fd_path" 2>/dev/null || true)"
			[[ "$target" == "$render_node" ]] || continue
			fdinfo="/proc/$ffmpeg_pid/fdinfo/${fd_path##*/}"
			[[ -r "$fdinfo" ]] || continue
			if ((binding_recorded == 0)); then
				printf 'render-node: %s\n\n' "$target" >>"$output"
				binding_recorded=1
			fi
			timestamp="$(now_nanoseconds)"
			{
				printf '%s\n' "$timestamp"
				awk '$1 == "drm-driver:" || $1 == "drm-engine-video:" ||
					$1 == "drm-engine-capacity-video:" { print }' "$fdinfo"
				printf '\n'
			} >>"$output"
			break
		done
		sleep 1
	done
}

run_qsv_initialization() {
	local log="$1"
	local status
	if ffmpeg -nostdin -v verbose \
		-init_hw_device qsv=hw:/dev/dri/renderD128 \
		-filter_hw_device hw \
		-f lavfi -i 'nullsrc=size=16x16:rate=1' \
		-frames:v 1 -f null - >"$log" 2>&1; then
		status=0
	else
		status=$?
	fi
	if ((status != 0)) || grep -q -E \
		'Device creation failed|Failed to initiali[sz]e|Error creating a MFX session' "$log"; then
		return 1
	fi
}

run_qsv_encode() {
	local input="$1"
	local output="$2"
	local setting="$3"
	local encode_log="$4"
	local fdinfo_log="$5"
	local ffmpeg_pid sampler_pid status
	if [[ "$test_mode" == '1' && -n "${BENCHMARK_TEST_FDINFO_FIXTURE:-}" ]]; then
		cp "$BENCHMARK_TEST_FDINFO_FIXTURE" "$fdinfo_log"
		ffmpeg -nostdin -v verbose -init_hw_device qsv=hw:/dev/dri/renderD128 \
			-filter_hw_device hw -i "$input" -map 0 -c:v hevc_qsv -preset veryslow \
			-global_quality "$setting" -look_ahead 0 -extbrc 0 \
			-c:a copy -c:s copy -map_metadata 0 -map_chapters 0 "$output" >"$encode_log" 2>&1
		return
	fi
	ffmpeg -nostdin -v verbose -init_hw_device qsv=hw:/dev/dri/renderD128 \
		-filter_hw_device hw -i "$input" -map 0 -c:v hevc_qsv -preset veryslow \
		-global_quality "$setting" -look_ahead 0 -extbrc 0 \
		-c:a copy -c:s copy -map_metadata 0 -map_chapters 0 "$output" >"$encode_log" 2>&1 &
	ffmpeg_pid=$!
	sample_drm_fdinfo "$ffmpeg_pid" '/dev/dri/renderD128' "$fdinfo_log" &
	sampler_pid=$!
	set +e
	wait "$ffmpeg_pid"
	status=$?
	wait "$sampler_pid"
	set -e
	return "$status"
}

quality_capability_proof() {
	local source="$1" filters bitstream_filters frame_probe
	filters="$(ffmpeg -nostdin -hide_banner -filters 2>/dev/null || true)"
	bitstream_filters="$(ffmpeg -nostdin -hide_banner -bsfs 2>/dev/null || true)"
	frame_probe="$(ffprobe -v error -select_streams v:0 -read_intervals '0%+1' -show_frames \
		-show_entries 'frame=best_effort_timestamp_time,pkt_duration_time,duration_time,key_frame,pict_type' \
		-of json "$source" 2>/dev/null || true)"
	jq -n -c --arg filters "$filters" --arg bsfs "$bitstream_filters" \
		--argjson frames "${frame_probe:-null}" '
		def filter($name): ($filters | split("\n") | any(. | split(" ") | map(select(length > 0)) | .[1] == $name));
		def frame_field($name): ($frames.frames | type == "array" and length > 0 and
			($frames.frames[0][$name] | type) == "string");
		{
			traceHeaders:(if ($bsfs | split("\n") | any(. == "trace_headers")) then "passed" else "failed" end),
			libvmaf:(if filter("libvmaf") then "passed" else "failed" end),
			ssim:(if filter("ssim") then "passed" else "failed" end),
			psnr:(if filter("psnr") then "passed" else "failed" end),
			bestEffortTimestampTime:(if frame_field("best_effort_timestamp_time") then "passed" else "failed" end),
			packetDurationTime:(if (frame_field("pkt_duration_time") or frame_field("duration_time")) then "passed" else "failed" end),
			keyFrame:(if ($frames.frames | type == "array" and length > 0 and
				($frames.frames[0].key_frame == 0 or $frames.frames[0].key_frame == 1)) then "passed" else "failed" end),
			pictType:(if ($frames.frames | type == "array" and length > 0 and
				($frames.frames[0].pict_type == "I" or $frames.frames[0].pict_type == "P" or
				 $frames.frames[0].pict_type == "B")) then "passed" else "failed" end)
		}
	'
}

capability_proof() {
	local encode_log="$1"
	local fdinfo_log="$2"
	local capability_directory source encoded initialization_log proof_json metrics_json
	local initialization_status=1 encode_status=1 decode='failed' vmaf='failed'
	local proof_status='passed' reasons=''
	local initialization selected binding render_node driver telemetry delta percent fps speed telemetry_reason diagnostic_capabilities
	local -a settings
	capability_directory="$(dirname "$encode_log")"
	source="$capability_directory/source.mkv"
	encoded="$capability_directory/qsv.mkv"
	initialization_log="$capability_directory/qsv-init.log"
	: >"$fdinfo_log"
	read -r -a settings <<<"$CONTRACT_ICQ_SETTINGS"

	set +e
	run_qsv_initialization "$initialization_log"
	initialization_status=$?
	if ((initialization_status == 0)); then
		run_qsv_encode "$source" "$encoded" "${settings[0]}" "$encode_log" "$fdinfo_log"
		encode_status=$?
	else
		: >"$encode_log"
		encode_status="$initialization_status"
	fi
	set -e
	proof_json="$(qsv_proof "$encode_status" "$encode_log" "$fdinfo_log" 0)"
	metrics_json="$(drm_fdinfo_metrics "$fdinfo_log")"
	initialization="$(jq -r '.initialization' <<<"$proof_json")"
	selected="$(jq -r '.selected_rate_control' <<<"$proof_json")"
	binding="$(jq -r '.binding' <<<"$proof_json")"
	render_node="$(jq -r '.render_node' <<<"$proof_json")"
	driver="$(jq -r '.drm_driver' <<<"$proof_json")"
	fps="$(jq -r '.encode_fps' <<<"$proof_json")"
	speed="$(jq -r '.encode_speed' <<<"$proof_json")"
	telemetry="$(jq -r '.status' <<<"$metrics_json")"
	delta="$(jq -r '.video_busy_nanoseconds' <<<"$metrics_json")"
	percent="$(jq -r '.video_busy_percent' <<<"$metrics_json")"
	telemetry_reason="$(jq -r '.reason' <<<"$metrics_json")"

	if ((encode_status == 0)) && ffmpeg -nostdin -v error -i "$encoded" -map 0:v:0 -f null - \
		>/dev/null 2>&1; then
		decode='passed'
	fi
	if ((encode_status == 0)) && ffmpeg -nostdin -v error -i "$encoded" -i "$source" -lavfi \
		'[0:v][1:v]libvmaf=model=version=vmaf_4k_v0.6.1' -f null - >/dev/null 2>&1; then
		vmaf='passed'
	fi
	diagnostic_capabilities="$(quality_capability_proof "$source")" || diagnostic_capabilities='{}'

	[[ "$initialization" == 'passed' ]] || reasons='initialization'
	if [[ "$binding" != 'passed' ]]; then
		reasons="${reasons:+$reasons;}binding"
		[[ "$binding" == 'harness-blocked' ]] && proof_status='harness-blocked'
	fi
	if [[ "$selected" == 'unknown' ]]; then
		reasons="${reasons:+$reasons;}rate-control"
		[[ "$initialization" == 'passed' ]] && proof_status='harness-blocked'
	elif [[ "$selected" != 'ICQ' ]]; then
		reasons="${reasons:+$reasons;}rate-control"
	fi
	if [[ "$telemetry" == 'available' ]]; then
		awk -v value="$delta" 'BEGIN { exit !(value > 0) }' ||
			reasons="${reasons:+$reasons;}telemetry"
	else
		reasons="${reasons:+$reasons;}telemetry"
		proof_status='harness-blocked'
	fi
	awk -v value="$speed" 'BEGIN { exit !(value > 0) }' ||
		reasons="${reasons:+$reasons;}progress"
	[[ "$decode" == 'passed' ]] || reasons="${reasons:+$reasons;}decode"
	[[ "$vmaf" == 'passed' ]] || reasons="${reasons:+$reasons;}vmaf"
	jq -e '
		type == "object" and
		keys == ["bestEffortTimestampTime","keyFrame","libvmaf","packetDurationTime","pictType","psnr","ssim","traceHeaders"] and
		all(.[]; . == "passed")
	' <<<"$diagnostic_capabilities" >/dev/null 2>&1 ||
		reasons="${reasons:+$reasons;}quality-capabilities"
	if [[ "$initialization" != 'passed' ]]; then
		proof_status='failed'
	elif [[ "$proof_status" != 'harness-blocked' && -n "$reasons" ]]; then
		proof_status='failed'
	fi

	jq -n -c \
		--arg strategy "$CONTRACT_STRATEGY_ID" \
		--argjson schema "$CONTRACT_CAPABILITY_SCHEMA" \
		--arg initialization "$initialization" \
		--arg initialization_reason '' \
		--arg render_node "$render_node" \
		--arg driver "$driver" \
		--arg selected "$selected" \
		--arg telemetry "$telemetry" \
		--arg telemetry_reason "$telemetry_reason" \
		--argjson delta "$delta" \
		--argjson percent "$percent" \
		--argjson fps "$fps" \
		--argjson speed "$speed" \
		--arg decode "$decode" \
		--arg vmaf "$vmaf" \
		--arg proof_status "$proof_status" \
		--arg reasons "$reasons" --argjson diagnostic_capabilities "$diagnostic_capabilities" '{
			strategyId: $strategy,
			proofSchemaVersion: $schema,
			initialization: $initialization,
			initializationReason: $initialization_reason,
			renderNode: $render_node,
			drmDriver: $driver,
			selectedRateControl: $selected,
			telemetryStatus: $telemetry,
			telemetryReason: $telemetry_reason,
			videoBusyNanoseconds: $delta,
			videoBusyPercent: $percent,
			encodeFps: $fps,
			encodeSpeed: $speed,
			decode: $decode,
			vmaf: $vmaf,
			diagnosticCapabilities: $diagnostic_capabilities,
			proofStatus: $proof_status,
			proofReasons: $reasons
		}'
	case "$proof_status" in
	passed) return 0 ;;
	failed) return 1 ;;
	*) return 2 ;;
	esac
}

encoder_progress() {
	local encode_log="$1"
	local fps speed value
	fps='0.000000'
	speed='0.000000'
	value="$(grep -o -E 'fps=[[:space:]]*[0-9]+([.][0-9]+)?' "$encode_log" | tail -n 1 | sed 's/fps=[[:space:]]*//' || true)"
	[[ -z "$value" ]] || fps="$(awk -v value="$value" 'BEGIN { printf "%.6f", value }')"
	value="$(grep -o -E 'speed=[[:space:]]*[0-9]+([.][0-9]+)?x' "$encode_log" | tail -n 1 | sed 's/speed=[[:space:]]*//; s/x$//' || true)"
	[[ -z "$value" ]] || speed="$(awk -v value="$value" 'BEGIN { printf "%.6f", value }')"
	printf '%s|%s\n' "$fps" "$speed"
}

failed_validation() {
	local reason="$1"
	jq -n -c --arg reason "$reason" '{
		validation_codec:"failed", validation_duration:"failed",
		validation_resolution:"failed", validation_frame_rate:"failed",
		validation_bit_depth:"failed", validation_hdr:"failed",
		validation_audio_tracks:"failed", validation_subtitle_tracks:"failed",
		validation_chapters:"failed", validation_failures:$reason
	}'
}

add_validation_failure() {
	local validation="$1" reason="$2"
	jq -c --arg reason "$reason" '
		.validation_failures = ((.validation_failures + ";" + $reason) | ltrimstr(";"))
	' <<<"$validation"
}

process_variant() {
	local run_id="$1" panel="$2" sample_id="$3" cohort="$4" source_sha="$5"
	local clip_id="$6" encoder="$7" setting="$8" reference="$9" output="${10}"
	local scope="${11}" encode_status="${12}" wall_seconds="${13}" encode_log="${14}"
	local busy_log="${15}" attempt="${16}" row_fixture="${17}"
	local run_directory logs_directory evidence_base source_probe_file output_probe_file validation_file
	local vmaf_file ssim_file psnr_file source_probe validation metrics value height='0'
	local input_bytes='0' output_bytes='0' duration='0' input_rate='0' output_rate='0'
	local reduction='0.000000' fps='0.000000' speed='0.000000' vmaf_harmonic=''
	local vmaf_low='' ssim='' psnr='' gpu_busy='' qsv_status='not-applicable' selected='CRF'
	local qsv_initialization='not-applicable' video_busy_nanoseconds='0' strategy_id="$CONTRACT_STRATEGY_ID"
	local validation_failures validation_codec validation_duration validation_resolution
	local validation_frame_rate validation_bit_depth validation_hdr validation_audio
	local validation_subtitle validation_chapters decode_status=1 proof_json progress
	local quality_source_path="${18:-}" quality_source_timestamp="${19:-}"
	local quality_vmaf='null' quality_hdr='null' quality_evidence_ref=''
	local quality_evidence_path='' quality_evidence_sha256='' quality_evidence_ready=1

	run_directory="$benchmark_out/runs/$run_id"
	logs_directory="$run_directory/logs"
	evidence_base="$sample_id-$clip_id-$encoder-$setting-attempt-$attempt"
	mkdir -p "$logs_directory"
	source_probe_file="$logs_directory/$evidence_base-source-probe.json"
	output_probe_file="$logs_directory/$evidence_base-output-probe.json"
	validation_file="$logs_directory/$evidence_base-validation.json"
	vmaf_file="$logs_directory/$evidence_base-vmaf.json"
	ssim_file="$logs_directory/$evidence_base-ssim.log"
	psnr_file="$logs_directory/$evidence_base-psnr.log"
	validation="$(failed_validation encode)"

	if probe_media source "$reference" >"$source_probe_file" 2>&1 &&
		source_probe="$(jq -e -c . "$source_probe_file" 2>/dev/null)"; then
		duration="$(jq -r 'if (.durationSeconds | type) == "number" then .durationSeconds else 0 end' <<<"$source_probe")"
		height="$(jq -r 'if (.height | type) == "number" then .height else 0 end' <<<"$source_probe")"
	else
		source_probe='{}'
		validation="$(failed_validation source-probe)"
	fi
	if value="$(file_size "$reference" 2>/dev/null)"; then input_bytes="$value"; fi
	input_rate="$(awk -v bytes="$input_bytes" -v seconds="$duration" \
		'BEGIN { if (seconds > 0) printf "%.0f", bytes * 8 / seconds; else print 0 }')"

	if [[ "$encode_status" == '0' && -f "$output" && ! -L "$output" ]]; then
		if value="$(file_size "$output" 2>/dev/null)"; then output_bytes="$value"; fi
		output_rate="$(awk -v bytes="$output_bytes" -v seconds="$duration" \
			'BEGIN { if (seconds > 0) printf "%.0f", bytes * 8 / seconds; else print 0 }')"
		reduction="$(awk -v input="$input_bytes" -v output="$output_bytes" \
			'BEGIN { if (input > 0) printf "%.6f", (input - output) * 100 / input; else print "0.000000" }')"
		if ffmpeg -nostdin -v error -i "$output" -map 0:v:0 -f null -; then decode_status=0; fi
		if [[ "$source_probe" != '{}' ]] && probe_media output "$output" >"$output_probe_file" 2>&1 &&
			jq -e . "$output_probe_file" >/dev/null 2>&1; then
			if ! validation="$(validate_probes "$source_probe_file" "$output_probe_file" "$scope" "$decode_status" 2>/dev/null)"; then
				validation="$(failed_validation validation-parse)"
			fi
		else
			validation="$(failed_validation output-probe)"
		fi
		if [[ "$panel" == 'quality' ]]; then
			if ffmpeg -nostdin -v error -i "$output" -i "$reference" -lavfi \
				"[0:v][1:v]libvmaf=model=version=vmaf_4k_v0.6.1:log_fmt=json:log_path=$vmaf_file" \
				-f null - &&
				if [[ "$panel" == 'quality' ]]; then
					metrics="$(quality_vmaf_stats "$vmaf_file" "$samples_file" "$sample_id" "$clip_id" 2>/dev/null)" &&
						vmaf_harmonic="$(jq -e -r '.harmonicMean | numbers' <<<"$metrics" 2>/dev/null)" &&
						vmaf_low="$(jq -e -r '.onePercentLow | numbers' <<<"$metrics" 2>/dev/null)" &&
						quality_vmaf="$metrics"
				else
					metrics="$(vmaf_stats "$vmaf_file" 2>/dev/null)" &&
						vmaf_harmonic="$(jq -e -r '.harmonic_mean | numbers' <<<"$metrics" 2>/dev/null)" &&
						vmaf_low="$(jq -e -r '.one_percent_low | numbers' <<<"$metrics" 2>/dev/null)"
				fi; then
				:
			else
				vmaf_harmonic=''
				vmaf_low=''
				validation="$(add_validation_failure "$validation" vmaf)"
				[[ "$panel" != 'quality' ]] || quality_evidence_ready=0
			fi
			if [[ "$panel" == 'quality' ]]; then
				if ffmpeg -nostdin -v info -i "$output" -i "$reference" -lavfi '[0:v][1:v]ssim' \
					-f null - >"$ssim_file" 2>&1 &&
					value="$(quality_parse_metric ssim "$ssim_file")"; then
					ssim="$value"
				else
					ssim=''
					validation="$(add_validation_failure "$validation" ssim)"
					quality_evidence_ready=0
				fi
				if ffmpeg -nostdin -v info -i "$output" -i "$reference" -lavfi '[0:v][1:v]psnr' \
					-f null - >"$psnr_file" 2>&1 &&
					value="$(quality_parse_metric psnr "$psnr_file")"; then
					psnr="$value"
				else
					psnr=''
					validation="$(add_validation_failure "$validation" psnr)"
					quality_evidence_ready=0
				fi
				if [[ "$cohort" == 'hdr10' ]]; then
					if [[ -n "$quality_source_path" && -n "$quality_source_timestamp" ]] &&
						quality_hdr="$(quality_hdr_evidence "$quality_source_path" "$quality_source_timestamp" \
							"$reference" "$output" 2>/dev/null)"; then
						if [[ "$(jq -r '.classification' <<<"$quality_hdr")" == 'preserved' ]]; then
							validation="$(jq -c '.validation_hdr = "passed"' <<<"$validation")"
						else
							validation="$(jq -c '.validation_hdr = "failed"' <<<"$validation")"
							validation="$(add_validation_failure "$validation" hdr)"
						fi
					else
						quality_hdr='null'
						quality_evidence_ready=0
					fi
				elif [[ -z "$quality_source_path" || -z "$quality_source_timestamp" ]]; then
					quality_evidence_ready=0
				fi
			fi
		fi
	fi
	if [[ "$encoder" == 'qsv' ]]; then
		if proof_json="$(qsv_proof "$encode_status" "$encode_log" "$busy_log" "$height" 2>/dev/null)" &&
			jq -e . <<<"$proof_json" >/dev/null 2>&1; then
			selected="$(jq -r '.selected_rate_control' <<<"$proof_json")"
			qsv_initialization="$(jq -r '.initialization' <<<"$proof_json")"
			fps="$(jq -r '.encode_fps' <<<"$proof_json")"
			speed="$(jq -r '.encode_speed' <<<"$proof_json")"
			gpu_busy="$(jq -r '.gpu_busy_percent' <<<"$proof_json")"
			qsv_status="$(jq -r '.qsv_proof' <<<"$proof_json")"
			if metrics="$(drm_fdinfo_metrics "$busy_log" 2>/dev/null)" &&
				video_busy_nanoseconds="$(jq -e -r '.video_busy_nanoseconds | numbers | floor' <<<"$metrics" 2>/dev/null)"; then
				:
			else
				video_busy_nanoseconds='0'
			fi
		else
			selected='unknown'
			qsv_initialization='failed'
			qsv_status='suspect'
			validation="$(add_validation_failure "$validation" qsv-proof)"
			printf '%s\n' "$validation" >"$validation_file"
		fi
	else
		if progress="$(encoder_progress "$encode_log" 2>/dev/null)"; then
			IFS='|' read -r fps speed <<<"$progress"
		fi
	fi
	if [[ "$panel" == 'quality' && "$quality_evidence_ready" == '0' ]]; then
		validation="$(add_validation_failure "$validation" quality-evidence)"
	fi
	printf '%s\n' "$validation" >"$validation_file"

	validation_codec="$(jq -r '.validation_codec // "failed"' <<<"$validation")"
	validation_duration="$(jq -r '.validation_duration // "failed"' <<<"$validation")"
	validation_resolution="$(jq -r '.validation_resolution // "failed"' <<<"$validation")"
	validation_frame_rate="$(jq -r '.validation_frame_rate // "failed"' <<<"$validation")"
	validation_bit_depth="$(jq -r '.validation_bit_depth // "failed"' <<<"$validation")"
	validation_hdr="$(jq -r '.validation_hdr // "failed"' <<<"$validation")"
	validation_audio="$(jq -r '.validation_audio_tracks // "failed"' <<<"$validation")"
	validation_subtitle="$(jq -r '.validation_subtitle_tracks // "failed"' <<<"$validation")"
	validation_chapters="$(jq -r '.validation_chapters // "failed"' <<<"$validation")"
	validation_failures="$(jq -r '.validation_failures // "processing"' <<<"$validation")"
	if [[ "$panel" == 'quality' && "$quality_evidence_ready" == '1' ]]; then
		if quality_evidence_ref="$(publish_quality_evidence "$run_directory" "$run_id" "$sample_id" \
			"$cohort" "$source_sha" "$clip_id" "$setting" "$attempt" "$quality_vmaf" \
			"$ssim" "$psnr" "$quality_hdr" "$validation_hdr")"; then
			IFS=$'\t' read -r quality_evidence_path quality_evidence_sha256 <<<"$quality_evidence_ref"
		else
			validation="$(add_validation_failure "$validation" quality-evidence)"
			printf '%s\n' "$validation" >"$validation_file"
			validation_failures="$(jq -r '.validation_failures // "quality-evidence"' <<<"$validation")"
			quality_evidence_ready=0
		fi
	fi

	jq -n -c \
		--arg panel "$panel" --arg sample_id "$sample_id" --arg cohort "$cohort" \
		--arg source_sha "$source_sha" --arg clip_id "$clip_id" --arg encoder "$encoder" \
		--arg setting "$setting" --arg selected "$selected" --arg encode_status "$encode_status" \
		--arg input_bytes "$input_bytes" --arg output_bytes "$output_bytes" \
		--arg reduction "$reduction" --arg input_rate "$input_rate" --arg output_rate "$output_rate" \
		--arg wall "$wall_seconds" --arg fps "$fps" --arg speed "$speed" \
		--arg vmaf_harmonic "$vmaf_harmonic" --arg vmaf_low "$vmaf_low" --arg ssim "$ssim" \
		--arg gpu "$gpu_busy" --arg qsv "$qsv_status" --arg codec "$validation_codec" \
		--arg duration "$validation_duration" --arg resolution "$validation_resolution" \
		--arg frame_rate "$validation_frame_rate" --arg bit_depth "$validation_bit_depth" \
		--arg hdr "$validation_hdr" --arg audio "$validation_audio" \
		--arg subtitle "$validation_subtitle" --arg chapters "$validation_chapters" \
		--arg failures "$validation_failures" --arg log_path "logs/${encode_log##*/}" \
		--arg strategy_id "$strategy_id" --arg qsv_initialization "$qsv_initialization" \
		--arg video_busy_nanoseconds "$video_busy_nanoseconds" \
		--arg quality_evidence_path "$quality_evidence_path" \
		--arg quality_evidence_sha256 "$quality_evidence_sha256" '{
			panel: $panel, sample_id: $sample_id, cohort: $cohort, source_sha256: $source_sha,
			clip_id: $clip_id, encoder: $encoder, requested_setting: $setting,
			selected_rate_control: $selected, encode_status: $encode_status,
			input_bytes: $input_bytes, output_bytes: $output_bytes,
			reduction_percent: $reduction, input_bit_rate: $input_rate,
			output_bit_rate: $output_rate, wall_seconds: $wall, encode_fps: $fps,
			encode_speed: $speed, vmaf_harmonic_mean: $vmaf_harmonic,
			vmaf_1pct_low: $vmaf_low, ssim: $ssim, gpu_busy_percent: $gpu,
			qsv_proof: $qsv, validation_codec: $codec,
			validation_duration: $duration, validation_resolution: $resolution,
			validation_frame_rate: $frame_rate, validation_bit_depth: $bit_depth,
			validation_hdr: $hdr, validation_audio_tracks: $audio,
			validation_subtitle_tracks: $subtitle, validation_chapters: $chapters,
			validation_failures: $failures, log_path: $log_path,
			strategy_id: $strategy_id, qsv_initialization: $qsv_initialization,
			video_busy_nanoseconds: $video_busy_nanoseconds,
			quality_evidence_path: $quality_evidence_path,
			quality_evidence_sha256: $quality_evidence_sha256
		}' >"$row_fixture"
}

row_is_complete() {
	local run_id="$1" panel="$2" sha="$3" clip="$4" encoder="$5" setting="$6"
	local status
	set +e
	"$script_directory/runmeta.sh" completed "$run_id" "$panel|$sha|$clip|$encoder|$setting" >/dev/null
	status=$?
	set -e
	if [[ "$status" == '0' ]]; then return 0; fi
	if [[ "$status" == '1' ]]; then return 1; fi
	return "$status"
}

encoder_commands_for_mode() {
	local mode="$1" commands setting
	local -a settings
	[[ "$mode" == 'quality' ]] || return 64
	commands="$(jq -n -c '["ffmpeg -nostdin -v error -ss <timestamp> -i <source> -t 90 -map 0 -c copy <clip>"]')"
	read -r -a settings <<<"$CONTRACT_ICQ_SETTINGS"
	for setting in "${settings[@]}"; do
		commands="$(jq -c --arg command \
			"ffmpeg -nostdin -v verbose -init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw -i <input> -map 0 -c:v hevc_qsv -preset veryslow -global_quality $setting -look_ahead 0 -extbrc 0 -c:a copy -c:s copy -map_metadata 0 -map_chapters 0 <output>" \
			'. + [$command]' <<<"$commands")"
	done
	printf '%s\n' "$commands"
}

encode_one_variant() {
	local run_id="$1" panel="$2" sample_id="$3" cohort="$4" sha="$5" clip_id="$6"
	local encoder="$7" setting="$8" input="$9" scope="${10}"
	local disposition="${11:-record}" run_directory results attempt evidence_base
	local quality_source_path="${12:-}" quality_source_timestamp="${13:-}"
	local output encode_log busy_log row_fixture start end wall status=0 record_status=0
	run_directory="$benchmark_out/runs/$run_id"
	results="$run_directory/results.csv"
	ensure_results_file "$results"
	attempt="$(result_attempt "$results" "$panel" "$sha" "$clip_id" "$encoder" "$setting")"
	evidence_base="$sample_id-$clip_id-$encoder-$setting-attempt-$attempt"
	output="$scratch_root/$run_id/$evidence_base.mkv"
	encode_log="$run_directory/logs/$evidence_base.log"
	busy_log="$run_directory/logs/$evidence_base-busy.log"
	row_fixture="$scratch_root/$run_id/$evidence_base-row.json"
	start="$(now_nanoseconds)"
	[[ "$encoder" == 'qsv' ]] || return 65
	run_qsv_encode "$input" "$output" "$setting" "$encode_log" "$busy_log" || status=$?
	end="$(now_nanoseconds)"
	wall="$(awk -v start="$start" -v end="$end" 'BEGIN { printf "%.6f", (end - start) / 1000000000 }')"
	process_variant "$run_id" "$panel" "$sample_id" "$cohort" "$sha" "$clip_id" \
		"$encoder" "$setting" "$input" "$output" "$scope" "$status" "$wall" \
		"$encode_log" "$busy_log" "$attempt" "$row_fixture" \
		"$quality_source_path" "$quality_source_timestamp"
	if [[ "$panel" == 'quality' ]] &&
		! jq -e '(.quality_evidence_path | length) > 0 and (.quality_evidence_sha256 | length) > 0' \
			"$row_fixture" >/dev/null; then
		rm -f -- "$row_fixture" "$output"
		return 0
	fi
	if [[ "$disposition" == 'defer' ]]; then
		printf '%s|%s\n' "$row_fixture" "$output"
		return
	fi
	record_result "$run_id" "$row_fixture" "$output" || record_status=$?
	rm -f -- "$row_fixture"
	return "$record_status"
}

quality_ranking_descriptor_identity() {
	local path="$1" descriptor="$2" directory="$3"
	local identity directory_device descriptor_identity path_device path_inode_size
	[[ -f "$path" && ! -L "$path" && -f "$descriptor" ]] || return 65
	if [[ "$path" -ef "$descriptor" ]]; then
		if identity="$(LC_ALL=C stat -Lc '%d:%i:%s' -- "$path" 2>/dev/null)"; then
			[[ "$identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ && "$path" -ef "$descriptor" ]] || return 65
			printf 'gnu:%s\n' "$identity"
			return
		fi
		identity="$(LC_ALL=C stat -f '%d:%i:%z' "$path" 2>/dev/null)" || return 65
		[[ "$identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ && "$path" -ef "$descriptor" ]] || return 65
		printf 'bsd:%s\n' "$identity"
		return
	fi

	# macOS exposes an opened regular file through the synthetic /dev/fd
	# filesystem, so Bash -ef sees a different device. Bind the inode namespace
	# to the already-confined parent device, then compare descriptor inode/size.
	[[ "$(uname -s)" == 'Darwin' ]] || return 65
	identity="$(LC_ALL=C stat -f '%d:%i:%z' "$path" 2>/dev/null)" || return 65
	directory_device="$(LC_ALL=C stat -f '%d' "$directory" 2>/dev/null)" || return 65
	descriptor_identity="$(LC_ALL=C stat -f '%i:%z' "$descriptor" 2>/dev/null)" || return 65
	[[ "$identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ && "$directory_device" =~ ^[0-9]+$ &&
		"$descriptor_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 65
	path_device="${identity%%:*}"
	path_inode_size="${identity#*:}"
	[[ "$path_device" == "$directory_device" && "$path_inode_size" == "$descriptor_identity" &&
		-f "$path" && ! -L "$path" && -f "$descriptor" ]] || return 65
	printf 'darwin:%s\n' "$identity"
}

quality_evidence_for_ranking() (
	local run_directory="$1" run_id="$2" sample_id="$3" cohort="$4" source_sha="$5"
	local clip_id="$6" setting="$7" attempt="$8" evidence_path="$9" evidence_digest="${10}"
	local evidence_directory evidence_file expected_path actual_digest run_physical
	local evidence_fd current_fd evidence_fd_path current_fd_path opened_identity
	local current_identity current_digest evidence_snapshot projection
	expected_path="quality-evidence/$sample_id-$clip_id-qsv-$setting-attempt-$attempt.json"
	[[ "$sample_id" =~ ^[a-z0-9][a-z0-9._-]*$ && "$clip_id" =~ ^[a-z0-9][a-z0-9._-]*$ &&
		"$evidence_path" == "$expected_path" && "$evidence_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || return 65
	evidence_directory="$run_directory/quality-evidence"
	[[ -d "$evidence_directory" && ! -L "$evidence_directory" ]] || return 65
	run_physical="$(cd -P "$run_directory" && pwd)" || return 65
	[[ "$(cd -P "$evidence_directory" && pwd)" == "$run_physical/quality-evidence" ]] || return 65
	evidence_file="$run_directory/$evidence_path"
	[[ -f "$evidence_file" && ! -L "$evidence_file" ]] || return 65
	[[ "$(realpath "$evidence_file")" == "$run_physical/$evidence_path" ]] || return 65

	# Open the canonical file directly and tie its descriptor to the confined
	# pathname. Base64 keeps every byte, including trailing newlines and NULs,
	# intact while the digest and parser consume one in-memory snapshot.
	exec {evidence_fd}<"$evidence_file" || return 65
	evidence_fd_path="/dev/fd/$evidence_fd"
	opened_identity="$(quality_ranking_descriptor_identity \
		"$evidence_file" "$evidence_fd_path" "$evidence_directory")" || return 65
	[[ -f "$evidence_file" && ! -L "$evidence_file" &&
		"$(realpath "$evidence_file")" == "$run_physical/$evidence_path" ]] || return 65
	evidence_snapshot="$(base64 <&"$evidence_fd")" || return 65
	actual_digest="sha256:$(printf '%s' "$evidence_snapshot" | base64 --decode |
		sha256sum | awk 'NR == 1 { print $1 }')"
	[[ "$actual_digest" == "$evidence_digest" ]] || return 65
	projection="$(printf '%s' "$evidence_snapshot" | base64 --decode | jq -e -c \
		--arg run "$run_id" --arg sample "$sample_id" --arg cohort "$cohort" \
		--arg source_sha "$source_sha" --arg clip "$clip_id" --argjson setting "$setting" \
		--arg strategy "$CONTRACT_STRATEGY_ID" --argjson schema "$CONTRACT_QUALITY_EVIDENCE_SCHEMA" '
		def exact_keys($wanted): type == "object" and ((keys | sort) == ($wanted | sort));
		def finite_number: type == "number" and isfinite;
		def nonnegative_integer: finite_number and floor == . and . >= 0;
		def excluded_frame:
			exact_keys(["frameIndex","vmaf"]) and
			(.frameIndex | nonnegative_integer) and .vmaf == 0;
		. as $document |
		exact_keys(["clipId","cohort","globalQuality","hdr","psnr","runId","sampleId",
			"schemaVersion","sourceSha256","ssim","strategyId","vmaf"]) and
		.schemaVersion == $schema and .strategyId == $strategy and .runId == $run and
		.sampleId == $sample and .cohort == $cohort and .sourceSha256 == $source_sha and
		.clipId == $clip and .globalQuality == $setting and
		(.ssim | finite_number) and (.psnr | finite_number) and
		(.vmaf |
			exact_keys(["evaluatedFrameCount","excludedFrames","harmonicMean","onePercentLow","rawFrameCount"]) and
			(.rawFrameCount | nonnegative_integer and . > 0) and
			(.evaluatedFrameCount | nonnegative_integer and . > 0) and
			(.excludedFrames | type == "array" and length <= 1 and all(.[]; excluded_frame)) and
			.evaluatedFrameCount == (.rawFrameCount - (.excludedFrames | length)) and
			(.harmonicMean | finite_number) and (.onePercentLow | finite_number)) and
		(if $cohort == "hdr10" then
			(.hdr |
				exact_keys(["classification","normalizedOracle","reasons"]) and
				(.classification as $classification |
					["preserved","source-oracle-defect","clip-boundary-defect","encoder-output-defect"] |
					index($classification)) != null and
				(.reasons | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)) and
				(.normalizedOracle | type == "object"))
		else .hdr == null end) |
		select(.) |
		{
			vmafHarmonicMean:$document.vmaf.harmonicMean,
			vmafOnePercentLow:$document.vmaf.onePercentLow,
			ssim:$document.ssim,
			psnr:$document.psnr,
			hdrClassification:($document.hdr.classification // null)
		}
	')" || return 65

	# The snapshot is valid only while the canonical path still names the same
	# regular inode with the authenticated digest. Reopen it after parsing and
	# repeat both inode and path checks around the final digest read.
	[[ -f "$evidence_file" && ! -L "$evidence_file" &&
		"$(realpath "$evidence_file")" == "$run_physical/$evidence_path" ]] || return 65
	exec {current_fd}<"$evidence_file" || return 65
	current_fd_path="/dev/fd/$current_fd"
	current_identity="$(quality_ranking_descriptor_identity \
		"$evidence_file" "$current_fd_path" "$evidence_directory")" || return 65
	[[ "$current_identity" == "$opened_identity" ]] || return 65
	current_digest="sha256:$(sha256sum <&"$current_fd" | awk 'NR == 1 { print $1 }')"
	current_identity="$(quality_ranking_descriptor_identity \
		"$evidence_file" "$current_fd_path" "$evidence_directory")" || return 65
	[[ "$current_digest" == "$evidence_digest" && "$current_identity" == "$opened_identity" &&
		-f "$evidence_file" && ! -L "$evidence_file" &&
		"$(realpath "$evidence_file")" == "$run_physical/$evidence_path" ]] || return 65
	jq -n -c --arg identity "$opened_identity" --argjson quality "$projection" \
		'{identity:$identity, quality:$quality}'
)

quality_ranking_binding_current() (
	local run_directory="$1" evidence_path="$2" evidence_digest="$3" expected_identity="$4"
	local run_physical evidence_directory evidence_file evidence_fd evidence_fd_path
	local current_identity current_digest
	[[ "$evidence_path" =~ ^quality-evidence/[a-z0-9][a-z0-9._-]*-[a-z0-9][a-z0-9._-]*-qsv-[0-9]+-attempt-[0-9]+\.json$ &&
		"$evidence_digest" =~ ^sha256:[0-9a-f]{64}$ && -n "$expected_identity" ]] || return 65
	run_physical="$(cd -P "$run_directory" && pwd)" || return 65
	evidence_directory="$run_directory/quality-evidence"
	[[ -d "$evidence_directory" && ! -L "$evidence_directory" &&
		"$(cd -P "$evidence_directory" && pwd)" == "$run_physical/quality-evidence" ]] || return 65
	evidence_file="$run_directory/$evidence_path"
	[[ -f "$evidence_file" && ! -L "$evidence_file" &&
		"$(realpath "$evidence_file")" == "$run_physical/$evidence_path" ]] || return 65
	exec {evidence_fd}<"$evidence_file" || return 65
	evidence_fd_path="/dev/fd/$evidence_fd"
	current_identity="$(quality_ranking_descriptor_identity \
		"$evidence_file" "$evidence_fd_path" "$evidence_directory")" || return 65
	[[ "$current_identity" == "$expected_identity" ]] || return 65
	current_digest="sha256:$(sha256sum <&"$evidence_fd" | awk 'NR == 1 { print $1 }')"
	current_identity="$(quality_ranking_descriptor_identity \
		"$evidence_file" "$evidence_fd_path" "$evidence_directory")" || return 65
	[[ "$current_digest" == "$evidence_digest" && "$current_identity" == "$expected_identity" &&
		"$(realpath "$evidence_file")" == "$run_physical/$evidence_path" ]] || return 65
)

quality_ranking_bindings_current() {
	local run_directory="$1" bindings="$2" binding
	while IFS= read -r binding; do
		quality_ranking_binding_current "$run_directory" \
			"$(jq -r '.path' <<<"$binding")" "$(jq -r '.digest' <<<"$binding")" \
			"$(jq -r '.identity' <<<"$binding")" || return 65
	done < <(jq -c '.[]' <<<"$bindings")
}

rank_quality_candidates() {
	local results="$1" candidate_samples="$2" run_id="$3"
	local run_directory artifact staged rows expected settings expected_keys digest candidates
	local authenticated_rows='[]' authenticated_bindings='[]' row evidence binding
	local maximum_binding_count binding_groups group_key
	if [[ ! -v CONTRACT_ICQ_SETTINGS ]]; then
		contract_load "$candidate_samples" || return
	fi
	validate_run_id "$run_id" || return
	ensure_results_file "$results" || return
	[[ -f "$candidate_samples" && ! -L "$candidate_samples" ]] || return 66
	run_directory="$(dirname "$results")"
	[[ -d "$run_directory" && ! -L "$run_directory" ]] || return 66
	[[ "$results" == "$benchmark_out/runs/$run_id/results.csv" ]] || return 65
	artifact="$run_directory/quality-candidates.json"
	[[ ! -e "$artifact" || (-f "$artifact" && ! -L "$artifact") ]] || return 65
	rows="$(jq -R -s --arg header "$results_header" '
		def lines_without_terminal_newline:
			if length > 0 and .[-1] == "" then .[:-1] else . end;
		(split("\n") | lines_without_terminal_newline) as $lines |
		if ($lines | length) < 1 or $lines[0] != $header then error("invalid results CSV header")
		elif any($lines[1:][]?; length == 0) then error("invalid empty results CSV row")
		else [
			$lines[1:][] | split(",") as $columns |
			if ($columns | length) != 41 then error("invalid results CSV row") else {
				run_id: $columns[0], panel: $columns[1], sample_id: $columns[2], cohort: $columns[3],
				source_sha256: $columns[4], clip_id: $columns[5], encoder: $columns[6],
				requested_setting: $columns[7], selected_rate_control: $columns[8], status: $columns[9],
				attempt: $columns[10],
				reduction_percent: $columns[13], qsv_proof: $columns[23],
				validation_codec: $columns[24], validation_duration: $columns[25],
				validation_resolution: $columns[26], validation_frame_rate: $columns[27],
				validation_bit_depth: $columns[28], validation_hdr: $columns[29],
				validation_audio_tracks: $columns[30], validation_subtitle_tracks: $columns[31],
				validation_chapters: $columns[32], validation_failures: $columns[33],
				strategy_id: $columns[36], qsv_initialization: $columns[37],
				video_busy_nanoseconds: $columns[38], quality_evidence_path: $columns[39],
				quality_evidence_sha256: $columns[40]
			} end
		] end
	' "$results")" || return 65
	expected="$(jq -e -c '
		[.qualityPanel[]? |
			select((.detectionOnly // false) != true and .cohort != "dolby-vision") |
			select((.cohort == "avc" or .cohort == "vc1" or .cohort == "hdr10") and
				(.id | type == "string" and length > 0) and (.clips | type == "object")) |
			. as $sample | $sample.clips | keys[] |
			{cohort: $sample.cohort, sample_id: $sample.id, source_sha256: $sample.sha256, clip_id: .}
		]
	' "$candidate_samples")" || return 65
	settings="$(jq -n -c --arg settings "$CONTRACT_ICQ_SETTINGS" '$settings | split(" ") | map(tonumber)')" || return
	maximum_binding_count="$(jq -n --argjson expected "$expected" --argjson settings "$settings" \
		'$expected | length * ($settings | length)')" || return 65
	[[ "$maximum_binding_count" =~ ^[0-9]+$ ]] || return 65
	binding_groups="$(jq -n -c \
		--argjson rows "$rows" --argjson expected "$expected" --argjson settings "$settings" '
		[ ["avc","vc1","hdr10"][] as $cohort | $settings[] as $setting |
			($expected | map(select(.cohort == $cohort)) | length) as $expected_count |
			select($expected_count > 0 and
				([$rows[] | select(.cohort == $cohort and
					.requested_setting == ($setting | tostring))] | length) == $expected_count) |
			($cohort + "|" + ($setting | tostring)) ]
	')" || return 65
	expected_keys="$(jq -r '[.[] | [.cohort, .sample_id, .source_sha256, .clip_id] | join("|")] | join("\u001c")' <<<"$expected")"
	awk -F, -v run_id="$run_id" -v settings="$CONTRACT_ICQ_SETTINGS" \
		-v strategy="$CONTRACT_STRATEGY_ID" -v expected="$expected_keys" '
		BEGIN {
			count = split(expected, values, "\034")
			for (item = 1; item <= count; item++) known[values[item]] = 1
		}
		NR > 1 {
			key = $4 "|" $3 "|" $5 "|" $6
			expected_evidence = "quality-evidence/" $3 "-" $6 "-qsv-" $8 "-attempt-" $11 ".json"
			if ($1 != run_id || $2 != "quality" || $7 != "qsv" || $8 !~ /^[0-9]+$/ ||
				index(" " settings " ", " " $8 " ") == 0 ||
				!(key in known) ||
				($10 != "passed" && $10 != "failed" && $10 != "invalid") ||
				$11 !~ /^[0-9]+$/ || $11 + 0 < 1 || $37 != strategy ||
				$40 != expected_evidence || $41 !~ /^sha256:[0-9a-f]{64}$/) exit 65
			if ($10 == "passed" && ($9 != "ICQ" || $38 != "passed" ||
				$39 !~ /^[0-9]+$/ || $39 + 0 <= 0)) exit 65
		}
	' "$results" || {
		echo 'invalid quality results row' >&2
		return 65
	}
	while IFS= read -r row; do
		if evidence="$(quality_evidence_for_ranking "$run_directory" "$run_id" \
			"$(jq -r '.sample_id' <<<"$row")" "$(jq -r '.cohort' <<<"$row")" \
			"$(jq -r '.source_sha256' <<<"$row")" "$(jq -r '.clip_id' <<<"$row")" \
			"$(jq -r '.requested_setting' <<<"$row")" "$(jq -r '.attempt' <<<"$row")" \
			"$(jq -r '.quality_evidence_path' <<<"$row")" \
			"$(jq -r '.quality_evidence_sha256' <<<"$row")" 2>/dev/null)"; then
			row="$(jq -c --argjson evidence "$evidence" \
				'. + {evidenceValid:true,quality:$evidence.quality,evidenceIdentity:$evidence.identity}' \
				<<<"$row")" || return 65
			group_key="$(jq -r '.cohort + "|" + .requested_setting' <<<"$row")" || return 65
			if jq -e --arg key "$group_key" 'index($key) != null' <<<"$binding_groups" >/dev/null; then
				binding="$(jq -c '{path:.quality_evidence_path,digest:.quality_evidence_sha256,
					identity:.evidenceIdentity}' <<<"$row")" || return 65
				authenticated_bindings="$(jq -c --argjson binding "$binding" \
					'. + [$binding]' <<<"$authenticated_bindings")" || return 65
			fi
		else
			row="$(jq -c '. + {evidenceValid:false}' <<<"$row")" || return 65
		fi
		authenticated_rows="$(jq -c --argjson row "$row" '. + [$row]' <<<"$authenticated_rows")" || return 65
	done < <(jq -c '.[]' <<<"$rows")
	rows="$authenticated_rows"
	[[ "$(jq 'length' <<<"$authenticated_bindings")" -le "$maximum_binding_count" ]] || return 65
	digest="$(sha256sum "$results" | awk '{print $1}')"
	[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 65
	candidates="$(jq -n -c \
		--arg run_id "$run_id" --arg strategy "$CONTRACT_STRATEGY_ID" \
		--arg digest "sha256:$digest" \
		--argjson schema "$CONTRACT_RESULTS_SCHEMA" \
		--argjson candidate_schema "$CONTRACT_QUALITY_CANDIDATES_SCHEMA" \
		--slurpfile rows_input <(printf '%s\n' "$rows") \
		--slurpfile expected_input <(printf '%s\n' "$expected") \
		--slurpfile settings_input <(printf '%s\n' "$settings") '
		($rows_input[0]) as $rows |
		($expected_input[0]) as $expected |
		($settings_input[0]) as $settings |
		def numeric: (tonumber?) as $number | $number != null and ($number | isfinite);
		def finite_number: type == "number" and isfinite;
		def median:
			sort as $values | ($values | length) as $count |
			if ($count % 2) == 1 then $values[($count / 2 | floor)]
			else (($values[($count / 2 - 1 | floor)] + $values[($count / 2 | floor)]) / 2)
			end;
		def objective_passes:
			.evidenceValid == true and .status == "passed" and .selected_rate_control == "ICQ" and
			.qsv_proof == "passed" and .qsv_initialization == "passed" and
			(.video_busy_nanoseconds | test("^[0-9]+$") and tonumber > 0) and
			(.validation_codec == "passed" and .validation_duration == "passed" and
			 .validation_resolution == "passed" and .validation_frame_rate == "passed" and
			 .validation_bit_depth == "passed" and .validation_hdr == "passed" and
			 .validation_audio_tracks == "passed" and .validation_subtitle_tracks == "passed" and
			 .validation_chapters == "passed") and .validation_failures == "" and
			(.quality.vmafHarmonicMean | finite_number and . >= 95) and
			(.quality.vmafOnePercentLow | finite_number and . >= 90) and
			(.quality.ssim | finite_number) and (.quality.psnr | finite_number) and
			(if .cohort == "hdr10" then .quality.hdrClassification == "preserved" else true end) and
			(.reduction_percent | numeric) and .strategy_id == $strategy;
		def expected_keys: map([.sample_id, .clip_id]) | sort;
		def group_for($cohort; $setting):
			[ $rows[] | select(
				.run_id == $run_id and .panel == "quality" and .cohort == $cohort and
				.encoder == "qsv" and .requested_setting == ($setting | tostring)
			) ];
		def complete_group($group; $cohort_expected):
			($cohort_expected | length) > 0 and
			($group | length) == ($cohort_expected | length) and
			($group | map([.sample_id, .clip_id]) | sort) == ($cohort_expected | expected_keys) and
			($group | all(.evidenceValid == true));
		{
			schemaVersion: $candidate_schema, strategyId: $strategy, qualityRunId: $run_id,
			resultsSchemaVersion: $schema, resultsSha256: $digest,
			cohorts: (reduce ["avc", "vc1", "hdr10"][] as $cohort ({};
				($expected | map(select(.cohort == $cohort))) as $cohort_expected |
				([ $settings[] as $setting |
					group_for($cohort; $setting) as $group |
					select(complete_group($group; $cohort_expected) and ($group | all(objective_passes))) |
					{globalQuality: $setting, medianReductionPercent: ($group | map(.reduction_percent | tonumber) | median)}
				] | sort_by(-.medianReductionPercent, .globalQuality)) as $eligible |
				([$settings[] as $setting |
					complete_group(group_for($cohort; $setting); $cohort_expected)] | all) as $complete |
				.[$cohort] = if ($eligible | length) > 0 then {
					status: "eligible", expectedClipCount: ($cohort_expected | length), candidates: $eligible
				} elif $complete then {
					status: "no-go", expectedClipCount: ($cohort_expected | length), candidates: [],
					reason: "no-objective-candidate"
				} else {
					status: "no-verdict", expectedClipCount: ($cohort_expected | length), candidates: [],
					reason: "incomplete-evidence"
				} end
			))
		}
	')" || return 65
	staged="$(mktemp "$run_directory/.quality-candidates.XXXXXX")" || return
	if ! jq -e . <<<"$candidates" >"$staged"; then
		rm -f -- "$staged"
		return 65
	fi
	if ! quality_ranking_bindings_current "$run_directory" "$authenticated_bindings"; then
		rm -f -- "$staged"
		return 65
	fi
	mv -f -- "$staged" "$artifact"
}

quality_mode() {
	local explicit_run_id="${1:-}" run_id run_directory run_scratch sample_id cohort
	local source sha clip_id timestamp clip encoder setting
	local rank_status quality_completion_cohorts panel_samples work_plan row fields active_clip=''
	assigned_node_capability_gate || return
	panel_samples="$(jq -c '[.qualityPanel[]?]' "$samples_file")"
	runtime_pre_encode_gate "$panel_samples" || return
	work_plan="$(quality_work_plan)" || return
	BENCHMARK_ENCODER_COMMANDS_JSON="$(encoder_commands_for_mode quality)"
	export BENCHMARK_ENCODER_COMMANDS_JSON
	if [[ -n "$explicit_run_id" ]]; then
		run_id="$("$script_directory/runmeta.sh" create quality "$explicit_run_id")"
	else
		run_id="$("$script_directory/runmeta.sh" create quality)"
	fi
	run_directory="$benchmark_out/runs/$run_id"
	run_scratch="$scratch_root/$run_id"
	mkdir -p "$run_directory/logs" "$run_scratch"
	while IFS= read -r row; do
		fields="$(jq -e -r '
			select(type == "object" and
				(keys | sort) == (["clipId","cohort","encoder","requestedSetting","sampleId",
					"sourcePath","sourceSha256","timestamp"] | sort)) |
			[.sampleId,.cohort,.sourcePath,.sourceSha256,.clipId,.timestamp,.encoder,
				(.requestedSetting | tostring)] | @tsv
		' <<<"$row")" || return 65
		IFS=$'\t' read -r sample_id cohort source sha clip_id timestamp encoder setting <<<"$fields"
		validate_sample_id "$sample_id" || return
		validate_sample_id "$clip_id" || return
		[[ "$encoder" == 'qsv' ]] || return 65
		contract_is_icq_setting "$samples_file" "$setting" || return 65
		if row_is_complete "$run_id" quality "$sha" "$clip_id" "$encoder" "$setting"; then continue; fi
		clip="$run_scratch/$sample_id-$clip_id-source.mkv"
		if [[ "$clip" != "$active_clip" ]]; then
			if [[ -n "$active_clip" ]]; then rm -f -- "$active_clip"; fi
			ffmpeg -nostdin -v error -ss "$timestamp" -i "$source" -t 90 -map 0 -c copy "$clip"
			active_clip="$clip"
		fi
		encode_one_variant "$run_id" quality "$sample_id" "$cohort" "$sha" "$clip_id" \
			"$encoder" "$setting" "$clip" clip record "$source" "$timestamp" >/dev/null
	done <<<"$work_plan"
	if [[ -n "$active_clip" ]]; then rm -f -- "$active_clip"; fi
	rank_quality_candidates "$run_directory/results.csv" "$samples_file" "$run_id" || rank_status=$?
	rm -rf -- "$run_scratch"
	((${rank_status:-0} == 0)) || return "$rank_status"
	if [[ -n "${BENCHMARK_DISPATCH_CORRELATION_ID:-}" ]]; then
		quality_completion_cohorts="$(jq -e -c '
			.cohorts | {
				avc:(.avc | {status,candidates:[.candidates[] | {globalQuality,medianReductionPercent}]}),
				vc1:(.vc1 | {status,candidates:[.candidates[] | {globalQuality,medianReductionPercent}]}),
				hdr10:(.hdr10 | {status,candidates:[.candidates[] | {globalQuality,medianReductionPercent}]})
			}
		' "$run_directory/quality-candidates.json")" || return 65
		jq -n -c --arg dispatch "$BENCHMARK_DISPATCH_CORRELATION_ID" --arg runtime "$run_id" \
			--arg strategy "$CONTRACT_STRATEGY_ID" --argjson cohorts "$quality_completion_cohorts" '{
				schemaVersion:2, strategyId:$strategy, status:"complete",
				dispatchId:$dispatch, runtimeRunId:$runtime,
				artifactLocation:("/out/runs/" + $runtime), cohorts:$cohorts
			}'
	else
		printf '%s\n' "$run_id"
	fi
}

test_dispatch() {
	[[ "$test_mode" == '1' ]] || {
		echo '_test requires BENCHMARK_TEST_MODE=1' >&2
		exit 64
	}
	(($# >= 1)) || usage
	local action="$1"
	shift
	case "$action" in
	running-image-evidence)
		(($# == 0)) || usage
		contract_load "$samples_file"
		require_running_image_evidence
		;;
	icq-settings)
		(($# == 0)) || usage
		contract_load "$samples_file"
		printf '%s\n' "$CONTRACT_ICQ_SETTINGS"
		;;
	icq-setting)
		(($# == 1)) || usage
		contract_load "$samples_file"
		contract_is_icq_setting "$samples_file" "$1"
		;;
	quality-work-plan)
		(($# == 0)) || usage
		contract_load "$samples_file"
		quality_work_plan
		;;
	encoder-commands)
		(($# == 1)) || usage
		contract_load "$samples_file"
		encoder_commands_for_mode "$1"
		;;
	results-header)
		(($# == 0)) || usage
		printf '%s\n' "$results_header"
		;;
	declared-commands)
		(($# >= 1 && $# <= 2)) || usage
		read_declared_commands "$@"
		;;
	commands)
		(($# == 6)) || usage
		build_commands "$@"
		;;
	vmaf-stats)
		(($# == 1)) || usage
		vmaf_stats "$1"
		;;
	drm-fdinfo-metrics)
		(($# == 1)) || usage
		drm_fdinfo_metrics "$1"
		;;
	qsv-proof)
		(($# == 4)) || usage
		qsv_proof "$@"
		;;
	validate-probes)
		(($# == 4)) || usage
		validate_probes "$@"
		;;
	record-result)
		(($# == 3)) || usage
		record_result "$@"
		;;
	rank-quality-candidates)
		(($# == 3)) || usage
		rank_quality_candidates "$@"
		;;
	*) usage ;;
	esac
}

(($# >= 1)) || usage
mode="$1"
shift
case "$mode" in
capabilities)
	(($# == 0)) || usage
	contract_load "$samples_file" || exit $?
	require_running_image_evidence || exit $?
	capabilities
	;;
_test) test_dispatch "$@" ;;
quality)
	(($# == 0 || $# == 1)) || usage
	contract_load "$samples_file" || exit $?
	require_running_image_evidence || exit $?
	quality_mode "${1:-}"
	;;
*) usage ;;
esac
