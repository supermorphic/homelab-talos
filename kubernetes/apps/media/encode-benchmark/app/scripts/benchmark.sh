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
runs_root="$benchmark_out/runs"
samples_file="${BENCHMARK_SAMPLES_FILE:-/config/samples.json}"
test_mode="${BENCHMARK_TEST_MODE:-0}"
running_image_file='/provenance/image.json'
running_image_wait_seconds=600
diagnostic_terminal_max_bytes="$CONTRACT_DIAGNOSTIC_TERMINAL_MAX_BYTES"
diagnostic_terminal_reason_count_limit="$CONTRACT_DIAGNOSTIC_TERMINAL_REASON_COUNT_LIMIT"
diagnostic_terminal_reason_length_limit="$CONTRACT_DIAGNOSTIC_TERMINAL_REASON_LENGTH_LIMIT"
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
if [[ "$test_mode" == '1' ]]; then
	running_image_file="${BENCHMARK_RUNNING_IMAGE_FILE:-$running_image_file}"
	running_image_wait_seconds="${BENCHMARK_RUNNING_IMAGE_WAIT_SECONDS:-$running_image_wait_seconds}"
	diagnostic_terminal_max_bytes="${BENCHMARK_TERMINATION_LOG_MAX_BYTES:-$diagnostic_terminal_max_bytes}"
else
	for override in BENCHMARK_RUNNING_IMAGE_FILE BENCHMARK_RUNNING_IMAGE_WAIT_SECONDS BENCHMARK_RUNNING_IMAGE BENCHMARK_TERMINATION_LOG_PATH BENCHMARK_TERMINATION_LOG_MAX_BYTES; do
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
[[ "$diagnostic_terminal_max_bytes" =~ ^[0-9]+$ && "$diagnostic_terminal_max_bytes" -gt 0 && "$diagnostic_terminal_max_bytes" -lt 4096 ]] || {
	echo 'termination log byte limit must be a positive integer below 4096' >&2
	exit 64
}
if [[ "$test_mode" != '1' ]]; then
	for test_hook in \
		BENCHMARK_TEST_SOURCE_PROBE BENCHMARK_TEST_TITLE_SOURCE_PROBE BENCHMARK_TEST_OUTPUT_PROBE \
		BENCHMARK_TEST_FDINFO_FIXTURE BENCHMARK_TEST_INVALID_OUTPUT_MATCH \
		BENCHMARK_TEST_INVALID_OUTPUT_PROBE BENCHMARK_TEST_FAIL_RESULT_APPEND \
		BENCHMARK_TEST_QUALITY_EVIDENCE_COMPETITOR_SETTING \
		BENCHMARK_TEST_QUALITY_EVIDENCE_COMPETITOR_FILE \
		BENCHMARK_TEST_FAIL_AUDIO_INVENTORY_WRITE \
		BENCHMARK_DIAGNOSTIC_MISSING_TOOL BENCHMARK_DIAGNOSTIC_FFPROBE_FIELDS \
		BENCHMARK_DIAGNOSTIC_INCOMPLETE_WINDOW BENCHMARK_DIAGNOSTIC_MISSING_METRIC \
		BENCHMARK_DIAGNOSTIC_DRIFT_SOURCE BENCHMARK_DIAGNOSTIC_DRIFT_IMAGE_FILE \
		BENCHMARK_DIAGNOSTIC_FAIL_ENCODE BENCHMARK_DIAGNOSTIC_FAIL_DECODE \
		BENCHMARK_DIAGNOSTIC_PUBLISH_FAILURE; do
		if [[ -v "$test_hook" ]]; then
			echo 'BENCHMARK_TEST_* hooks require BENCHMARK_TEST_MODE=1' >&2
			exit 64
		fi
	done
fi
usage() {
	echo 'usage: benchmark.sh capabilities | diagnostics [run-id] | quality [run-id] | x265 <run-id> <sample-id> | savings <run-id> | finalist <run-id> <sample-id> | contention <run-id> <a|b|c|d> <worker-id> <sample-id> | findings <run-id>' >&2
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
	local source="$1"
	local timestamp="$2"
	local clip="$3"
	local qsv_output="$4"
	local x265_output="$5"
	local vmaf_log="$6"
	local gq="$7"
	local crf="$8"
	local -a clip_command qsv_command x265_command vmaf_command ssim_command psnr_command
	local clip_json qsv_json x265_json vmaf_json ssim_json psnr_json

	clip_command=(ffmpeg -nostdin -v error -ss "$timestamp" -i "$source" -t 90 -map 0 -c copy "$clip")
	qsv_command=(
		ffmpeg -nostdin -v verbose -init_hw_device qsv=hw:/dev/dri/renderD128
		-filter_hw_device hw -i "$clip" -map 0 -c:v hevc_qsv -preset veryslow
		-global_quality "$gq" -look_ahead 0 -extbrc 0 -c:a copy -c:s copy
		-map_metadata 0 -map_chapters 0 "$qsv_output"
	)
	x265_command=(
		ffmpeg -nostdin -v verbose -i "$clip" -map 0 -c:v libx265 -preset slow -crf "$crf"
		-c:a copy -c:s copy -map_metadata 0 -map_chapters 0 "$x265_output"
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
	x265_json="$(array_json "${x265_command[@]}")"
	vmaf_json="$(array_json "${vmaf_command[@]}")"
	ssim_json="$(array_json "${ssim_command[@]}")"
	psnr_json="$(array_json "${psnr_command[@]}")"
	jq -n -c \
		--argjson clip "$clip_json" \
		--argjson qsv "$qsv_json" \
		--argjson x265 "$x265_json" \
		--argjson vmaf "$vmaf_json" \
		--argjson ssim "$ssim_json" \
		--argjson psnr "$psnr_json" \
		'{clip: $clip, qsv: $qsv, x265: $x265, vmaf: $vmaf, ssim: $ssim, psnr: $psnr}'
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

median_slice() {
	local start="$1"
	local length="$2"
	shift 2
	local -a values=("$@")
	local middle
	if ((length == 1)); then
		printf '%.6f\n' "${values[$start]}"
	elif ((length % 2 == 1)); then
		middle=$((start + length / 2))
		printf '%.6f\n' "${values[$middle]}"
	else
		middle=$((start + length / 2))
		awk -v a="${values[$((middle - 1))]}" -v b="${values[$middle]}" \
			'BEGIN { printf "%.6f\n", (a + b) / 2 }'
	fi
}

savings_stats() {
	local fixture="$1"
	local -a values
	local count median half q1 q3 iqr verdict upper_start
	mapfile -t values < <(jq -e -r '
		if (.reductionPercent | type) != "array" or (.reductionPercent | length) == 0 or
			([.reductionPercent[] | numbers] | length) != (.reductionPercent | length)
		then error("invalid savings distribution")
		else .reductionPercent[]
		end
	' "$fixture" | sort -n)
	count="${#values[@]}"
	median="$(median_slice 0 "$count" "${values[@]}")"
	if ((count == 1)); then
		q1="$median"
		q3="$median"
	else
		half=$((count / 2))
		q1="$(median_slice 0 "$half" "${values[@]}")"
		if ((count % 2 == 1)); then
			upper_start=$((half + 1))
		else
			upper_start="$half"
		fi
		q3="$(median_slice "$upper_start" "$half" "${values[@]}")"
	fi
	iqr="$(awk -v lower="$q1" -v upper="$q3" 'BEGIN { printf "%.6f", upper - lower }')"
	verdict="$(awk -v value="$median" 'BEGIN {
		if (value >= 25) print "GO"
		else if (value >= 15) print "MARGINAL"
		else print "NO-GO"
	}')"
	printf '{"count":%s,"median":%s,"q1":%s,"q3":%s,"iqr":%s,"verdict":"%s"}\n' \
		"$count" "$median" "$q1" "$q3" "$iqr" "$verdict"
}

x265_match() {
	local fixture="$1"
	local qsv_vmaf qsv_bit_rate point_count index v1 b1 crf1 v2 b2 crf2
	local matched premium lower_crf upper_crf
	local -a points
	qsv_vmaf="$(jq -e -r '.qsvVmaf | numbers' "$fixture")"
	qsv_bit_rate="$(jq -e -r '.qsvBitRate | numbers | select(. > 0)' "$fixture")"
	mapfile -t points < <(jq -e -r '
		if (.points | type) != "array" or
			([.points[] | select(
				(.crf | type) == "number" and (.vmaf | type) == "number" and
				(.bitRate | type) == "number" and .bitRate > 0
			)] | length) != (.points | length)
		then error("invalid x265 measurements")
		else .points | sort_by(.crf)[] | [.vmaf, .bitRate, .crf] | @tsv
		end
	' "$fixture")
	point_count="${#points[@]}"
	if ((point_count == 0)); then
		printf '%s\n' '{"status":"unbracketed"}'
		return
	fi
	for ((index = 0; index < point_count; index += 1)); do
		IFS=$'\t' read -r v1 b1 crf1 <<<"${points[$index]}"
		if awk -v q="$qsv_vmaf" -v v="$v1" 'BEGIN { exit !(q == v) }'; then
			matched="$(awk -v value="$b1" 'BEGIN { printf "%.6f", value }')"
			premium="$(awk -v q="$qsv_bit_rate" -v matched="$matched" \
				'BEGIN { printf "%.6f", (q - matched) * 100 / matched }')"
			printf '{"status":"bracketed","lower_crf":%s,"upper_crf":%s,"matched_bit_rate":%s,"premium_percent":%s}\n' \
				"$crf1" "$crf1" "$matched" "$premium"
			return
		fi
		((index + 1 < point_count)) || continue
		IFS=$'\t' read -r v2 b2 crf2 <<<"${points[$((index + 1))]}"
		if awk -v q="$qsv_vmaf" -v first="$v1" -v second="$v2" \
			'BEGIN { exit !((first <= q && q <= second) || (second <= q && q <= first)) }'; then
			matched="$(awk -v q="$qsv_vmaf" -v v1="$v1" -v b1="$b1" -v v2="$v2" -v b2="$b2" '
				BEGIN {
					if (v1 == v2) printf "%.6f", b1
					else printf "%.6f", b1 + (q - v1) * (b2 - b1) / (v2 - v1)
				}
			')"
			premium="$(awk -v q="$qsv_bit_rate" -v matched="$matched" \
				'BEGIN { printf "%.6f", (q - matched) * 100 / matched }')"
			if awk -v first="$v1" -v second="$v2" 'BEGIN { exit !(first <= second) }'; then
				lower_crf="$crf1"
				upper_crf="$crf2"
			else
				lower_crf="$crf2"
				upper_crf="$crf1"
			fi
			printf '{"status":"bracketed","lower_crf":%s,"upper_crf":%s,"matched_bit_rate":%s,"premium_percent":%s}\n' \
				"$lower_crf" "$upper_crf" "$matched" "$premium"
			return
		fi
	done
	printf '%s\n' '{"status":"unbracketed"}'
}

x265_next() {
	local fixture="$1"
	local qsv_vmaf minimum_vmaf maximum_vmaf next point_count
	local attempted_min attempted_max
	qsv_vmaf="$(jq -e -r '.qsvVmaf | numbers' "$fixture")"
	jq -e '
		(.points | type) == "array" and
		((.attemptedCrfs // [.points[].crf]) | type) == "array" and
		((.points | length) == 0 or ((.attemptedCrfs // [.points[].crf]) | length) > 0) and
		all((.attemptedCrfs // [.points[].crf])[]; type == "number" and floor == . and . >= 10 and . <= 34) and
		all(.points[]; (.crf | type) == "number" and (.vmaf | type) == "number" and
			(.bitRate | type) == "number" and .bitRate > 0)
	' "$fixture" >/dev/null
	point_count="$(jq -r '.points | length' "$fixture")"
	if ((point_count == 0)); then
		printf '%s\n' '{"status":"unbracketed"}'
		return
	fi
	minimum_vmaf="$(jq -e -r '[.points[].vmaf] | min' "$fixture")"
	maximum_vmaf="$(jq -e -r '[.points[].vmaf] | max' "$fixture")"
	attempted_min="$(jq -e -r '[((.attemptedCrfs // [.points[].crf])[])] | min' "$fixture")"
	attempted_max="$(jq -e -r '[((.attemptedCrfs // [.points[].crf])[])] | max' "$fixture")"
	if awk -v q="$qsv_vmaf" -v low="$minimum_vmaf" -v high="$maximum_vmaf" \
		'BEGIN { exit !(low <= q && q <= high) }'; then
		printf '%s\n' '{"status":"bracketed"}'
	elif awk -v q="$qsv_vmaf" -v high="$maximum_vmaf" 'BEGIN { exit !(q > high) }'; then
		next=$((attempted_min - 2))
		if ((next < 10)); then
			printf '%s\n' '{"status":"unbracketed"}'
		else
			printf '{"status":"extend","next_crf":%s}\n' "$next"
		fi
	else
		next=$((attempted_max + 2))
		if ((next > 34)); then
			printf '%s\n' '{"status":"unbracketed"}'
		else
			printf '{"status":"extend","next_crf":%s}\n' "$next"
		fi
	fi
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
	local hdr_source_probe="${5:-$source_probe}"
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
	hdr="$(passed_or_failed jq -e -n --slurpfile source "$hdr_source_probe" --slurpfile output "$output_probe" '
		($source[0].hdrFormat | type) == "string" and ($output[0].hdrFormat | type) == "string" and
		($source[0].colorPrimaries | type) == "string" and ($output[0].colorPrimaries | type) == "string" and
		($source[0].colorTransfer | type) == "string" and ($output[0].colorTransfer | type) == "string" and
		($source[0].colorSpace | type) == "string" and ($output[0].colorSpace | type) == "string" and
		$source[0].hdrFormat == $output[0].hdrFormat and
		$source[0].colorPrimaries == $output[0].colorPrimaries and
		$source[0].colorTransfer == $output[0].colorTransfer and
		$source[0].colorSpace == $output[0].colorSpace and
		($source[0].masteringDisplay // "") == ($output[0].masteringDisplay // "") and
		($source[0].maxCLL // "") == ($output[0].maxCLL // "")
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

diagnostic_hdr_normalize() {
	local evidence="$1"
	jq -e -c '
		def exact_keys($keys): type == "object" and ((keys | sort) == ($keys | sort));
		def gcd($a; $b):
			if $b == 0 then $a else gcd($b; ($a % $b)) end;
		def rational:
			exact_keys(["denominator", "numerator"]) and
			(.numerator | type == "number" and floor == . and . >= 0) and
			(.denominator | type == "number" and floor == . and . > 0);
		def reduced_rational:
			(gcd(.numerator; .denominator)) as $divisor |
			{
				numerator: (.numerator / $divisor),
				denominator: (.denominator / $divisor)
			};
		def chromaticity:
			exact_keys(["x", "y"]) and (.x | rational) and (.y | rational);
		def mastering_display:
			exact_keys(["displayPrimaries", "luminance", "whitePoint"]) and
			(.displayPrimaries | exact_keys(["blue", "green", "red"]) and
				(.red | chromaticity) and (.green | chromaticity) and (.blue | chromaticity)) and
			(.whitePoint | chromaticity) and
			(.luminance | exact_keys(["max", "min"]) and (.min | rational) and (.max | rational));
		def hdr_metadata:
			exact_keys(["masteringDisplay", "maxCLL", "maxFALL"]) and
			(.masteringDisplay | mastering_display) and
			(.maxCLL | rational) and
			(.maxFALL | rational);
		def normalize_metadata:
			{
				masteringDisplay: {
					displayPrimaries: {
						red: {
							x: (.masteringDisplay.displayPrimaries.red.x | reduced_rational),
							y: (.masteringDisplay.displayPrimaries.red.y | reduced_rational)
						},
						green: {
							x: (.masteringDisplay.displayPrimaries.green.x | reduced_rational),
							y: (.masteringDisplay.displayPrimaries.green.y | reduced_rational)
						},
						blue: {
							x: (.masteringDisplay.displayPrimaries.blue.x | reduced_rational),
							y: (.masteringDisplay.displayPrimaries.blue.y | reduced_rational)
						}
					},
					whitePoint: {
						x: (.masteringDisplay.whitePoint.x | reduced_rational),
						y: (.masteringDisplay.whitePoint.y | reduced_rational)
					},
					luminance: {
						min: (.masteringDisplay.luminance.min | reduced_rational),
						max: (.masteringDisplay.luminance.max | reduced_rational)
					}
				},
				maxCLL: (.maxCLL | reduced_rational),
				maxFALL: (.maxFALL | reduced_rational)
			};
		def oracle:
			(
				(exact_keys(["metadata", "status"]) and .status == "ok" and (.metadata | hdr_metadata)) or
				(exact_keys(["status"]) and (.status == "null" or .status == "absent" or .status == "malformed"))
			);
		def normalize_oracle:
			if .status == "ok" then
				{status: "ok", metadata: (.metadata | normalize_metadata)}
			else
				{status}
			end;
		def oracle_pair:
			exact_keys(["decoded", "trace"]) and (.decoded | oracle) and (.trace | oracle);
		def authoritative_pair($null_reason; $absent_reason; $malformed_reason):
			(.decoded | normalize_oracle) as $decoded |
			(.trace | normalize_oracle) as $trace |
			if ($decoded.status == "ok" and $trace.status == "ok") then
				if $decoded.metadata == $trace.metadata then
					{status: "ok", metadata: $decoded.metadata}
				else
					{status: "unresolved", reasons: ["decoded-trace-disagreement"]}
				end
			elif ($decoded.status == "null" or $trace.status == "null") then
				{status: "unresolved", reasons: [$null_reason]}
			elif ($decoded.status == "absent" or $trace.status == "absent") then
				{status: "unresolved", reasons: [$absent_reason]}
			else
				{status: "unresolved", reasons: [$malformed_reason]}
			end;
		def source_windows:
			exact_keys(["beginning", "detail", "end"]) and
			(.beginning | oracle_pair) and
			(.detail | oracle_pair) and
			(.end | oracle_pair);
		if
			exact_keys(["clip", "encoded", "schemaVersion", "source"]) and
			.schemaVersion == 1 and
			(.source | exact_keys(["streamProbe", "windows"]) and
				(.streamProbe | oracle) and
				(.windows | source_windows)) and
			(.clip | oracle_pair) and
			(.encoded | oracle_pair)
		then
			{
				schemaVersion: 1,
				source: {
					streamProbe: (.source.streamProbe | normalize_oracle),
					windows: {
						beginning: {
							decoded: (.source.windows.beginning.decoded | normalize_oracle),
							trace: (.source.windows.beginning.trace | normalize_oracle),
							authoritative: (.source.windows.beginning | authoritative_pair(
								"source-window-null"; "source-window-absent"; "source-window-malformed"
							))
						},
						detail: {
							decoded: (.source.windows.detail.decoded | normalize_oracle),
							trace: (.source.windows.detail.trace | normalize_oracle),
							authoritative: (.source.windows.detail | authoritative_pair(
								"source-window-null"; "source-window-absent"; "source-window-malformed"
							))
						},
						end: {
							decoded: (.source.windows.end.decoded | normalize_oracle),
							trace: (.source.windows.end.trace | normalize_oracle),
							authoritative: (.source.windows.end | authoritative_pair(
								"source-window-null"; "source-window-absent"; "source-window-malformed"
							))
						}
					}
				},
				clip: {
					decoded: (.clip.decoded | normalize_oracle),
					trace: (.clip.trace | normalize_oracle),
					authoritative: (.clip | authoritative_pair(
						"clip-window-null"; "clip-window-absent"; "clip-window-malformed"
					))
				},
				encoded: {
					decoded: (.encoded.decoded | normalize_oracle),
					trace: (.encoded.trace | normalize_oracle),
					authoritative: (.encoded | authoritative_pair(
						"encoded-window-null"; "encoded-window-absent"; "encoded-window-malformed"
					))
				}
			} as $normalized |
			($normalized.source.windows | [.beginning.authoritative, .detail.authoritative, .end.authoritative]) as $windows |
			$normalized |
			.source.authoritative =
				if any($windows[]; .status != "ok") then
					($windows | map(select(.status != "ok"))[0])
				elif ([ $windows[].metadata ] | unique | length) != 1 then
					{status: "unresolved", reasons: ["source-window-conflict"]}
				else
					{status: "ok", metadata: $windows[0].metadata}
				end
		else
			error("invalid diagnostic hdr evidence")
		end
	' "$evidence"
}

diagnostic_vmaf_classify() {
	local evidence="$1"
	jq -e -c -L "$script_directory" 'include "diagnostic-contract"; diagnostic_vmaf_classify' "$evidence"
}

diagnostic_hdr_classify() {
	local evidence="$1" normalized
	normalized="$(diagnostic_hdr_normalize "$evidence")" || return $?
	jq -e -c -L "$script_directory" 'include "diagnostic-contract"; diagnostic_hdr_classify_normalized' <<<"$normalized"
}

diagnostic_publish_json() {
	local destination="$1" document="$2" directory staged
	if [[ "$test_mode" == '1' && "${BENCHMARK_DIAGNOSTIC_PUBLISH_FAILURE:-}" == 'summary' &&
		"$(basename "$destination")" == 'diagnostic-summary.json' ]]; then
		return 65
	fi
	directory="$(dirname "$destination")"
	mkdir -p "$directory"
	staged="$(mktemp "$directory/.diagnostic-json.XXXXXX")" || return
	if ! jq -e -S -c . <<<"$document" >"$staged"; then
		rm -f -- "$staged"
		return 65
	fi
	mv -f -- "$staged" "$destination"
	chmod 0444 "$destination"
}

diagnostic_invalidate_identity_evidence() {
	local diagnostic_root="$1" vmaf_entries="$2" hdr_entries="$3"
	local entries='[]' entry relative evidence updated
	while IFS= read -r entry; do
		[[ -n "$entry" ]] || continue
		relative="$(jq -e -r '.evidence | strings' <<<"$entry")" || return 65
		evidence="$diagnostic_root/$relative"
		updated="$(jq -e -c '
			.status = "harness-blocked" |
			.reason = "post-run-identity-drift" |
			.settings |= map(.status = "harness-blocked" | .reason = "post-run-identity-drift") |
			.classification = {
				schemaVersion:1, classification:"unresolved", reasons:["post-run-identity-drift"]
			}
		' "$evidence")" || return
		diagnostic_publish_json "$evidence" "$updated" || return
		entry="$(jq -c '
			.status = "harness-blocked" | .classification = "unresolved" | .reasons = ["post-run-identity-drift"]
		' <<<"$entry")" || return
		entries="$(jq -c --argjson entry "$entry" '. + [$entry]' <<<"$entries")" || return
	done < <(jq -c '.[]' <<<"$vmaf_entries")
	vmaf_entries="$entries"
	entries='[]'
	while IFS= read -r entry; do
		[[ -n "$entry" ]] || continue
		relative="$(jq -e -r '.evidence | strings' <<<"$entry")" || return 65
		evidence="$diagnostic_root/$relative"
		updated="$(jq -e -c '
			.status = "harness-blocked" |
			.reason = "post-run-identity-drift" |
			.classification = {
				schemaVersion:1, classification:"unresolved-oracle", reasons:["post-run-identity-drift"]
			}
		' "$evidence")" || return
		diagnostic_publish_json "$evidence" "$updated" || return
		entry="$(jq -c '
			.status = "harness-blocked" | .classification = "unresolved-oracle" | .reasons = ["post-run-identity-drift"]
		' <<<"$entry")" || return
		entries="$(jq -c --argjson entry "$entry" '. + [$entry]' <<<"$entries")" || return
	done < <(jq -c '.[]' <<<"$hdr_entries")
	jq -n -c --argjson vmaf "$vmaf_entries" --argjson hdr "$entries" '{vmaf:$vmaf,hdr:$hdr}'
}

diagnostic_status_merge() {
	local first="$1" second="$2"
	if [[ "$first" == 'failed' || "$second" == 'failed' ]]; then
		printf '%s\n' 'failed'
	elif [[ "$first" == 'harness-blocked' || "$second" == 'harness-blocked' ]]; then
		printf '%s\n' 'harness-blocked'
	else
		printf '%s\n' 'complete'
	fi
}

diagnostic_terminal_vmaf_reasons_json() {
	contract_diagnostics_terminal_vmaf_reason_classes_json | jq -c 'keys | sort'
}

diagnostic_terminal_hdr_reasons_json() {
	contract_diagnostics_terminal_hdr_reason_classes_json | jq -c 'keys | sort'
}

diagnostic_terminal_reason_allowed() {
	local allowed="$1" reason="$2"
	jq -e --arg reason "$reason" 'index($reason) != null' <<<"$allowed" >/dev/null
}

diagnostic_termination_log_path() {
	if [[ -n "${BENCHMARK_TERMINATION_LOG_PATH:-}" ]]; then
		[[ "$test_mode" == '1' ]] || {
			echo 'BENCHMARK_TERMINATION_LOG_PATH requires BENCHMARK_TEST_MODE=1' >&2
			return 64
		}
		printf '%s\n' "$BENCHMARK_TERMINATION_LOG_PATH"
	elif [[ "$test_mode" == '1' ]]; then
		printf '%s\n' "$scratch_root/diagnostic-termination-log.json"
	else
		printf '%s\n' '/dev/termination-log'
	fi
}

diagnostic_summary_reason_error() {
	local summary="$1" vmaf_reason_classes hdr_reason_classes
	vmaf_reason_classes="$(contract_diagnostics_terminal_vmaf_reason_classes_json)" || return
	hdr_reason_classes="$(contract_diagnostics_terminal_hdr_reason_classes_json)" || return
	jq -r \
		--argjson vmaf_reason_classes "$vmaf_reason_classes" \
		--argjson hdr_reason_classes "$hdr_reason_classes" \
		--argjson reason_length_limit "$diagnostic_terminal_reason_length_limit" '
		def vmaf_reasons: [(try .vmaf.entries[]?.reasons[]? catch empty)];
		def hdr_reasons: [(try .hdr.entries[]?.reasons[]? catch empty)];
		if ((vmaf_reasons + hdr_reasons) |
			any(.[]; type == "string" and length > $reason_length_limit)) then
			"reason-too-long"
		elif (vmaf_reasons | any(.[]; . as $reason |
			($reason | type) == "string" and ($vmaf_reason_classes[$reason] | type) != "array")) or
			(hdr_reasons | any(.[]; . as $reason |
				($reason | type) == "string" and ($hdr_reason_classes[$reason] | type) != "array")) then
			"unknown-reason"
		else "" end
	' <<<"$summary"
}

diagnostic_terminal_payload() {
	local status="$1" run_id="${2:-}" summary="${3:-}" reason_code="${4:-incomplete-or-failed-evidence}"
	local artifact='null' artifact_location='' allowed_vmaf allowed_hdr vmaf_reason_classes hdr_reason_classes summary_reason validation_reason payload
	case "$status" in
	complete | harness-blocked | failed) ;;
	*)
		echo 'diagnostic terminal status is invalid' >&2
		return 65
		;;
	esac
	[[ -z "$run_id" ]] || validate_run_id "$run_id" >/dev/null
	if [[ -n "$run_id" ]]; then
		artifact_location="/out/runs/$run_id/diagnostics"
		artifact="$(jq -n --arg value "/out/runs/$run_id/diagnostics" '$value')"
	fi
	allowed_vmaf="$(diagnostic_terminal_vmaf_reasons_json)"
	allowed_hdr="$(diagnostic_terminal_hdr_reasons_json)"
	vmaf_reason_classes="$(contract_diagnostics_terminal_vmaf_reason_classes_json)"
	hdr_reason_classes="$(contract_diagnostics_terminal_hdr_reason_classes_json)"
	if [[ -z "$summary" ]]; then
		diagnostic_terminal_reason_allowed "$allowed_vmaf" "$reason_code" || {
			echo 'diagnostic VMAF terminal reason is invalid' >&2
			return 65
		}
		diagnostic_terminal_reason_allowed "$allowed_hdr" "$reason_code" || {
			echo 'diagnostic HDR terminal reason is invalid' >&2
			return 65
		}
		payload="$(jq -n -c --arg strategy "$CONTRACT_STRATEGY_ID" --arg status "$status" \
			--arg run "$run_id" --arg reason "$reason_code" --argjson artifact "$artifact" '{
			schemaVersion:1,
			strategyId:$strategy,
			mode:"diagnostics",
			status:$status,
			runId:(if $run == "" then null else $run end),
			artifactLocation:$artifact,
			vmaf:{
				total:5,
				"encoder-output-defect":0,
				"temporal-alignment-defect":0,
				unresolved:5,
				"vmaf-measurement-defect":0,
				reasons:[$reason]
			},
			hdr:{
				total:3,
				"clip-boundary-defect":0,
				"encoder-output-defect":0,
				preserved:0,
				"source-probe-defect":0,
				"unresolved-oracle":3,
				reasons:[$reason]
			}
		}')" || return 65
	else
		summary_reason="$(diagnostic_summary_reason_error "$summary")" || return 65
		if [[ -n "$summary_reason" ]]; then
			printf 'terminal-summary-schema-error:%s\n' "$summary_reason" >&2
			return 65
		fi
		jq -e --arg strategy "$CONTRACT_STRATEGY_ID" --arg status "$status" --arg run "$run_id" \
			--argjson allowed_vmaf "$allowed_vmaf" --argjson allowed_hdr "$allowed_hdr" \
			--argjson vmaf_reason_classes "$vmaf_reason_classes" \
			--argjson hdr_reason_classes "$hdr_reason_classes" \
			--argjson reason_count_limit "$diagnostic_terminal_reason_count_limit" \
			--argjson reason_length_limit "$diagnostic_terminal_reason_length_limit" '
			def valid_vmaf_entry:
				. as $entry |
				type == "object" and
				(keys | sort) == ["classification","clipId","evidence","reasons","sampleId","status"] and
				(.status == "complete" or .status == "harness-blocked" or .status == "failed") and
				(.classification == "encoder-output-defect" or .classification == "temporal-alignment-defect" or
				 .classification == "unresolved" or .classification == "vmaf-measurement-defect") and
				(.reasons | type == "array" and length >= 1 and length <= $reason_count_limit and
					all(.[]; . as $reason | ($reason | type) == "string" and ($reason | length) > 0 and
						($reason | length) <= $reason_length_limit and ($allowed_vmaf | index($reason)) != null)) and
				($entry.reasons | all(.[]; . as $reason | ($vmaf_reason_classes[$reason] // []) | index($entry.classification) != null));
			def valid_hdr_entry:
				. as $entry |
				type == "object" and
				(keys | sort) == ["classification","evidence","reasons","sampleId","status"] and
				(.status == "complete" or .status == "harness-blocked" or .status == "failed") and
				(.classification == "clip-boundary-defect" or .classification == "encoder-output-defect" or
				 .classification == "preserved" or .classification == "source-probe-defect" or
				 .classification == "unresolved-oracle") and
				(.reasons | type == "array" and length >= 1 and length <= $reason_count_limit and
					all(.[]; . as $reason | ($reason | type) == "string" and ($reason | length) > 0 and
						($reason | length) <= $reason_length_limit and ($allowed_hdr | index($reason)) != null)) and
				($entry.reasons | all(.[]; . as $reason | ($hdr_reason_classes[$reason] // []) | index($entry.classification) != null));
			type == "object" and
			(keys | sort) == ["hdr","mode","runId","schemaVersion","status","strategyId","vmaf"] and
			.schemaVersion == 1 and .strategyId == $strategy and
			.mode == "diagnostics" and .status == $status and .runId == $run and
			(.vmaf | type == "object" and (keys | sort) == ["entries","total"] and .total == 5 and
				(.entries | type == "array" and length == 5 and all(.[]; valid_vmaf_entry))) and
			(.hdr | type == "object" and (keys | sort) == ["entries","total"] and .total == 3 and
				(.entries | type == "array" and length == 3 and all(.[]; valid_hdr_entry)))
		' <<<"$summary" >/dev/null || return 65
		payload="$(jq -n -c --arg strategy "$CONTRACT_STRATEGY_ID" --arg status "$status" \
			--arg run "$run_id" --argjson artifact "$artifact" --argjson summary "$summary" '
			def reason_list($entries):
				[$entries[]?.reasons[]?] | unique | sort;
			def vmaf_counts($entries):
				{
					total: 5,
					"encoder-output-defect": ([$entries[] | select(.classification == "encoder-output-defect")] | length),
					"temporal-alignment-defect": ([$entries[] | select(.classification == "temporal-alignment-defect")] | length),
					unresolved: ([$entries[] | select(.classification == "unresolved")] | length),
					"vmaf-measurement-defect": ([$entries[] | select(.classification == "vmaf-measurement-defect")] | length),
					reasons: reason_list($entries)
				};
			def hdr_counts($entries):
				{
					total: 3,
					"clip-boundary-defect": ([$entries[] | select(.classification == "clip-boundary-defect")] | length),
					"encoder-output-defect": ([$entries[] | select(.classification == "encoder-output-defect")] | length),
					preserved: ([$entries[] | select(.classification == "preserved")] | length),
					"source-probe-defect": ([$entries[] | select(.classification == "source-probe-defect")] | length),
					"unresolved-oracle": ([$entries[] | select(.classification == "unresolved-oracle")] | length),
					reasons: reason_list($entries)
				};
			{
				schemaVersion:1,
				strategyId:$strategy,
				mode:"diagnostics",
				status:$status,
				runId:(if $run == "" then null else $run end),
				artifactLocation:$artifact,
				vmaf:(vmaf_counts($summary.vmaf.entries)),
				hdr:(hdr_counts($summary.hdr.entries))
			}
		')" || return 65
	fi
	validation_reason="$(contract_diagnostics_terminal_schema_reason "$payload" "$run_id" "$status" "$artifact_location")" || return 65
	[[ -z "$validation_reason" ]] || return 65
	printf '%s\n' "$payload"
}

diagnostic_emit_terminal() {
	local payload="$1" canonical canonical_bytes path
	path="$(diagnostic_termination_log_path)" || return
	canonical="$(jq -e -S -c . <<<"$payload")" || return 65
	canonical_bytes="$(contract_diagnostics_terminal_byte_count "$canonical")" || return 65
	((canonical_bytes <= diagnostic_terminal_max_bytes)) || {
		echo 'diagnostic terminal payload exceeds byte limit' >&2
		return 65
	}
	mkdir -p "$(dirname "$path")"
	printf '%s' "$canonical" >"$path" || return
	printf '%s\n' "$canonical"
}

diagnostic_terminal() {
	local status="$1" run_id="${2:-}" summary="${3:-}" reason_code="${4:-incomplete-or-failed-evidence}" payload
	payload="$(diagnostic_terminal_payload "$status" "$run_id" "$summary" "$reason_code")" || return
	diagnostic_emit_terminal "$payload"
}

reject_diagnostics_resume_run_id() {
	local requested_mode="$1" run_id="$2" manifest stored_mode
	[[ -n "$run_id" ]] || return 0
	validate_run_id "$run_id" || return
	manifest="$runs_root/$run_id/manifest.json"
	[[ -f "$manifest" && ! -L "$manifest" ]] || return 0
	stored_mode="$(jq -e -r '.mode | select(type == "string")' "$manifest" 2>/dev/null || true)"
	[[ "$stored_mode" != 'diagnostics' ]] || {
		printf 'identity mismatch: mode (stored=diagnostics, current=%s)\n' "$requested_mode" >&2
		return 65
	}
}

diagnostic_command_clip() {
	array_json ffmpeg -nostdin -v error -ss "$1" -i '<source-title>' -t 90 \
		-map 0:v:0 -c copy '<source-clip>'
}

diagnostic_command_encode() {
	array_json ffmpeg -nostdin -v verbose -init_hw_device qsv=hw:/dev/dri/renderD128 \
		-filter_hw_device hw -i '<source-clip>' -map 0 -c:v hevc_qsv -preset veryslow \
		-global_quality "$1" -look_ahead 0 -extbrc 0 -c:a copy -c:s copy \
		-map_metadata 0 -map_chapters 0 '<encoded-output>'
}

diagnostic_command_decode() {
	array_json ffmpeg -nostdin -v error -i '<encoded-output>' -map 0:v:0 -f null -
}

diagnostic_command_vmaf_frame() {
	array_json ffprobe -v error -select_streams v:0 -read_intervals '0%+90' \
		-show_streams -show_format -show_frames \
		-show_entries 'stream=start_time,duration,time_base,avg_frame_rate:format=start_time,duration:frame=best_effort_timestamp_time,pkt_duration_time,duration_time,key_frame,pict_type' \
		-of json "$1"
}

diagnostic_command_vmaf_current() {
	array_json ffmpeg -nostdin -v error -i '<encoded-output>' -i '<source-clip>' -lavfi \
		'[0:v][1:v]libvmaf=model=version=vmaf_4k_v0.6.1:log_fmt=json:log_path=<current-vmaf.json>' -f null -
}

diagnostic_command_vmaf_reset() {
	array_json ffmpeg -nostdin -v error -i '<encoded-output>' -i '<source-clip>' -filter_complex \
		'[0:v]setpts=PTS-STARTPTS[distorted];[1:v]setpts=PTS-STARTPTS[reference];[distorted][reference]libvmaf=model=version=vmaf_4k_v0.6.1:log_fmt=json:log_path=<reset-vmaf.json>' -f null -
}

diagnostic_command_offset_metric() {
	local metric="$1" observed="$2" encoded="$3" metrics_token filter
	case "$metric" in
	ssim) metrics_token='<ssim-metrics>' ;;
	psnr) metrics_token='<psnr-metrics>' ;;
	*) return 64 ;;
	esac
	filter="[0:v]select=eq(n\\,$observed),setpts=PTS-STARTPTS[source];[1:v]select=eq(n\\,$encoded),setpts=PTS-STARTPTS[encoded];[source][encoded]$metric=stats_file=$metrics_token"
	array_json ffmpeg -nostdin -v error -i '<source-clip>' -i '<encoded-output>' \
		-filter_complex "$filter" -f null -
}

diagnostic_command_hdr_stream() {
	array_json ffprobe -v error -select_streams v:0 -read_intervals '0%+10' \
		-show_streams -show_entries stream_side_data -of json '<source-title>'
}

diagnostic_command_hdr_frame() {
	array_json ffprobe -v error -select_streams v:0 -read_intervals "$2%+10" \
		-show_frames -show_entries frame=side_data_list -of json "$1"
}

diagnostic_command_hdr_trace() {
	array_json ffmpeg -nostdin -v verbose -ss "$2" -i "$1" -t 10 \
		-map 0:v:0 -c:v copy -bsf:v trace_headers -f null -
}

diagnostic_append_command_identity() {
	jq -c --arg command "$2" '. + [$command]' <<<"$1"
}

diagnostic_encoder_command_identities() {
	local commands='[]' sample_id clip_id observed timestamp offset encoded command token start
	while IFS=$'\t' read -r sample_id clip_id observed timestamp; do
		for command in \
			"$(diagnostic_command_clip "$timestamp")" \
			"$(diagnostic_command_vmaf_frame '<source-clip>')" \
			"$(diagnostic_command_vmaf_frame '<encoded-output>')" \
			"$(diagnostic_command_encode 16)" \
			"$(diagnostic_command_encode 30)" \
			"$(diagnostic_command_decode)" \
			"$(diagnostic_command_vmaf_current)" \
			"$(diagnostic_command_vmaf_reset)"; do
			commands="$(diagnostic_append_command_identity "$commands" "$command")" || return
		done
		for offset in -2 -1 0 1 2; do
			encoded=$((observed + offset))
			for command in \
				"$(diagnostic_command_offset_metric ssim "$observed" "$encoded")" \
				"$(diagnostic_command_offset_metric psnr "$observed" "$encoded")"; do
				commands="$(diagnostic_append_command_identity "$commands" "$command")" || return
			done
		done
	done < <(jq -r '. as $root | .diagnostics.vmafPanel[] as $entry |
		($root.qualityPanel[] | select(.id == $entry.sampleId)) as $sample |
		[$entry.sampleId,$entry.clipId,$entry.observedFrameIndex,$sample.clips[$entry.clipId]] | @tsv' "$samples_file")

	while IFS=$'\t' read -r sample_id clip_id timestamp; do
		for command in \
			"$(diagnostic_command_clip "$timestamp")" \
			"$(diagnostic_command_encode 16)" \
			"$(diagnostic_command_decode)" \
			"$(diagnostic_command_hdr_stream)"; do
			commands="$(diagnostic_append_command_identity "$commands" "$command")" || return
		done
		while IFS=$'\t' read -r token start; do
			for command in \
				"$(diagnostic_command_hdr_frame "$token" "$start")" \
				"$(diagnostic_command_hdr_trace "$token" "$start")"; do
				commands="$(diagnostic_append_command_identity "$commands" "$command")" || return
			done
		done <<EOF
<source-title>	0
<source-title>	$timestamp
<source-title>	<end-start>
<source-clip>	$timestamp
<encoded-output>	$timestamp
EOF
	done < <(jq -r '. as $root | .diagnostics.hdrPanel[] as $entry |
		($root.qualityPanel[] | select(.id == $entry.sampleId)) as $sample |
		[$entry.sampleId,$entry.clipId,$sample.clips[$entry.clipId]] | @tsv' "$samples_file")
	jq -c 'unique' <<<"$commands"
}

diagnostic_preflight() {
	local panel_samples="$1" filters bitstream_filters source frame_probe vmaf_probe_log vmaf_version
	filters="$(ffmpeg -nostdin -hide_banner -filters)" || return
	for filter in libvmaf ssim psnr; do
		awk -v required="$filter" '$2 == required { found = 1 } END { exit !found }' <<<"$filters" || {
			echo "$filter filter is unavailable for diagnostics" >&2
			return 2
		}
	done
	bitstream_filters="$(ffmpeg -nostdin -hide_banner -bsfs)" || return
	awk '$1 == "trace_headers" { found = 1 } END { exit !found }' <<<"$bitstream_filters" || {
		echo 'trace_headers bitstream filter is unavailable for diagnostics' >&2
		return 2
	}
	source="$(jq -e -r '.[0].path | strings' <<<"$panel_samples")" || return 65
	frame_probe="$(ffprobe -v error -select_streams v:0 -read_intervals '0%+1' \
		-show_frames \
		-show_entries 'frame=best_effort_timestamp_time,pkt_duration_time,duration_time,key_frame,pict_type' \
		-of json "$source")" || {
		echo 'ffprobe diagnostic frame preflight failed' >&2
		return 2
	}
	jq -e '
		(.frames | type) == "array" and (.frames | length) > 0 and
		(.frames[0].best_effort_timestamp_time | type) == "string" and
		((.frames[0].pkt_duration_time // .frames[0].duration_time) | type) == "string" and
		(.frames[0].key_frame == 0 or .frames[0].key_frame == 1) and
		(.frames[0].pict_type == "I" or .frames[0].pict_type == "P" or .frames[0].pict_type == "B")
	' <<<"$frame_probe" >/dev/null || {
		echo 'ffprobe required diagnostic frame fields are unavailable' >&2
		return 2
	}
	vmaf_probe_log="$(mktemp "${TMPDIR:-/tmp}/encode-benchmark-vmaf.XXXXXX")" || return
	if ! ffmpeg -nostdin -v error \
		-f lavfi -i 'color=size=1920x1080:rate=1:duration=1' \
		-f lavfi -i 'color=size=1920x1080:rate=1:duration=1' \
		-lavfi "[0:v][1:v]libvmaf=model=version=vmaf_4k_v0.6.1:log_fmt=json:log_path=$vmaf_probe_log:n_threads=1" \
		-frames:v 1 -f null - >/dev/null 2>&1; then
		rm -f -- "$vmaf_probe_log"
		echo 'libvmaf runtime probe failed for diagnostics' >&2
		return 2
	fi
	vmaf_version="$(jq -e -r '
		.version | strings | select(test("^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$"))
	' "$vmaf_probe_log")" || {
		rm -f -- "$vmaf_probe_log"
		echo 'libvmaf runtime version is unavailable for diagnostics' >&2
		return 2
	}
	rm -f -- "$vmaf_probe_log"
	BENCHMARK_VMAF_VERSION="$vmaf_version"
	export BENCHMARK_VMAF_VERSION
}

diagnostic_assigned_node_capability_gate() {
	local node_name="${NODE_NAME:-}" passing_nodes kernel ffmpeg_version
	[[ "$node_name" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || {
		echo 'diagnostic assigned-node capability identity is unavailable' >&2
		return 65
	}
	passing_nodes="$(contract_passing_diagnostic_nodes "$samples_file")" || return
	grep -Fqx -- "$node_name" <<<"$passing_nodes" || {
		echo 'diagnostic assigned node lacks committed passing ICQ capability evidence' >&2
		return 65
	}
	kernel="$(uname -r)"
	[[ "$kernel" =~ ^[A-Za-z0-9._+:~-]+$ ]] || {
		echo 'diagnostic assigned-node i915 identity is unavailable' >&2
		return 65
	}
	ffmpeg_version="$(ffmpeg -nostdin -version | awk 'NR == 1 { print $3 }')" || return
	[[ "$ffmpeg_version" =~ ^[A-Za-z0-9._+:-]+$ ]] || {
		echo 'diagnostic assigned-node QSV identity is unavailable' >&2
		return 65
	}
	BENCHMARK_I915_VERSION="driver=i915;kernel=$kernel"
	BENCHMARK_VPL_VERSION="backend=qsv;ffmpeg=$ffmpeg_version"
	export BENCHMARK_I915_VERSION BENCHMARK_VPL_VERSION
}

diagnostic_capability_proof() {
	local source="$1" filters bitstream_filters frame_probe
	filters="$(ffmpeg -nostdin -hide_banner -filters 2>/dev/null || true)"
	bitstream_filters="$(ffmpeg -nostdin -hide_banner -bsfs 2>/dev/null || true)"
	frame_probe="$(ffprobe -v error -select_streams v:0 -read_intervals '0%+1' -show_frames \
		-show_entries 'frame=best_effort_timestamp_time,pkt_duration_time,duration_time,key_frame,pict_type' -of json "$source" 2>/dev/null || true)"
	jq -n -c --arg filters "$filters" --arg bsfs "$bitstream_filters" --argjson frames "${frame_probe:-null}" '
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
			keyFrame:(if ($frames.frames | type == "array" and length > 0 and ($frames.frames[0].key_frame == 0 or $frames.frames[0].key_frame == 1)) then "passed" else "failed" end),
			pictType:(if ($frames.frames | type == "array" and length > 0 and ($frames.frames[0].pict_type == "I" or $frames.frames[0].pict_type == "P" or $frames.frames[0].pict_type == "B")) then "passed" else "failed" end)
		}
	'
}

diagnostic_identity_json() {
	"$script_directory/probe.sh" diagnostic-identity "$1"
}

diagnostic_vmaf_window() {
	local metrics="$1" first="$2" last="$3"
	[[ -f "$metrics" && ! -L "$metrics" ]] || return 66
	jq -e -c --argjson first "$first" --argjson last "$last" '
		if
			(.frames | type) == "array" and
			([.frames[] | select(
				(.frameNum | type) == "number" and (.frameNum | floor) == .frameNum and
				.frameNum >= $first and .frameNum <= $last and
				(.metrics.vmaf | type) == "number"
			)] | length) == 5 and
			([.frames[] | select(.frameNum >= $first and .frameNum <= $last) | .frameNum] | sort) ==
				[range($first; $last + 1)]
		then
			[.frames[] | select(.frameNum >= $first and .frameNum <= $last) |
				{frameIndex:.frameNum,vmaf:.metrics.vmaf}] | sort_by(.frameIndex)
		else error("missing diagnostic VMAF metrics") end
	' "$metrics"
}

diagnostic_metric_value() {
	local metric="$1" file="$2" value
	[[ -f "$file" && ! -L "$file" ]] || return 66
	case "$metric" in
	ssim)
		value="$(sed -n -E 's/^.*All:([0-9]+([.][0-9]+)?).*$/\1/p' "$file" | tail -n 1)"
		;;
	psnr)
		value="$(sed -n -E 's/^.*psnr_avg:(inf|[0-9]+([.][0-9]+)?).*$/\1/p' "$file" | tail -n 1)"
		if [[ "$value" == 'inf' ]]; then
			printf '%s\n' '{"kind":"positive-infinity"}'
			return
		fi
		[[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 65
		jq -n -c --argjson value "$value" '{kind:"finite",value:$value}'
		return
		;;
	*) return 64 ;;
	esac
	[[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 65
	printf '%s\n' "$value"
}

diagnostic_vmaf_setting() {
	local sample_id="$1" clip_id="$2" observed="$3" setting="$4" source_clip="$5"
	local output="$6" scratch="$7" source_identity="$8" source_window="$9" preparation_reason="${10:-}"
	local first=$((observed - 2)) last=$((observed + 2)) status='complete' reason=''
	local encode_log="$scratch/encode-$setting.log" fdinfo_log="$scratch/fdinfo-$setting.log"
	local current_metrics="$scratch/current-target-$observed-$setting.json"
	local reset_metrics="$scratch/reset-target-$observed-$setting.json"
	local encode_status=0 decode_status=0 output_identity='null' output_window='null'
	local current_window='[]' reset_window='[]' current_target=0 reset_target=0
	local offsets='[]' offset encoded_index metric_file metric_value offset_json
	local encode_command decode_command output_frame_command current_command reset_command ssim_command psnr_command
	local current_filter reset_filter ssim_filter psnr_filter classifier_input timeline
	local ssim_json psnr_json
	mkdir -p "$scratch"

	encode_command="$(diagnostic_command_encode "$setting")"
	decode_command="$(diagnostic_command_decode)"
	output_frame_command="$(diagnostic_command_vmaf_frame '<encoded-output>')"
	current_command="$(diagnostic_command_vmaf_current)"
	reset_command="$(diagnostic_command_vmaf_reset)"

	if [[ -n "$preparation_reason" ]]; then
		status='harness-blocked'
		reason="$preparation_reason"
	elif [[ ! -f "$source_clip" || "$source_identity" == 'null' || "$source_window" == 'null' ]]; then
		status='harness-blocked'
		reason='source-panel-preparation-aborted'
	else
		set +e
		run_qsv_encode "$source_clip" "$output" "$setting" "$encode_log" "$fdinfo_log"
		encode_status=$?
		set -e
	fi
	if [[ "$status" == 'complete' && "$encode_status" -ne 0 ]]; then
		status='failed'
		reason='encode-failed'
	elif [[ "$status" == 'complete' ]] && ! ffmpeg -nostdin -v error -i "$output" -map 0:v:0 -f null - >/dev/null 2>&1; then
		decode_status=1
		status='failed'
		reason='decode-failed'
	fi

	if [[ "$status" == 'complete' ]]; then
		output_identity="$(diagnostic_identity_json "$output")" || {
			status='harness-blocked'
			reason='output-identity-unavailable'
			output_identity='null'
		}
	fi
	if [[ "$status" == 'complete' ]]; then
		output_window="$("$script_directory/probe.sh" diagnostic-window "$output" 0 90 "$first" "$last")" || {
			status='harness-blocked'
			reason='incomplete-output-frame-window'
			output_window='null'
		}
	fi
	if [[ "$status" == 'complete' ]]; then
		current_filter="[0:v][1:v]libvmaf=model=version=vmaf_4k_v0.6.1:log_fmt=json:log_path=$current_metrics"
		if ! ffmpeg -nostdin -v error -i "$output" -i "$source_clip" -lavfi "$current_filter" -f null - >/dev/null 2>&1 ||
			! current_window="$(diagnostic_vmaf_window "$current_metrics" "$first" "$last")"; then
			status='harness-blocked'
			reason='missing-current-vmaf'
			current_window='[]'
		else
			current_target="$(jq -e -r --argjson target "$observed" '.[] | select(.frameIndex == $target) | .vmaf' <<<"$current_window")"
		fi
	fi
	if [[ "$status" == 'complete' ]]; then
		reset_filter="[0:v]setpts=PTS-STARTPTS[distorted];[1:v]setpts=PTS-STARTPTS[reference];[distorted][reference]libvmaf=model=version=vmaf_4k_v0.6.1:log_fmt=json:log_path=$reset_metrics"
		if ! ffmpeg -nostdin -v error -i "$output" -i "$source_clip" -filter_complex "$reset_filter" -f null - >/dev/null 2>&1 ||
			! reset_window="$(diagnostic_vmaf_window "$reset_metrics" "$first" "$last")"; then
			status='harness-blocked'
			reason='missing-reset-vmaf'
			reset_window='[]'
		else
			reset_target="$(jq -e -r --argjson target "$observed" '.[] | select(.frameIndex == $target) | .vmaf' <<<"$reset_window")"
		fi
	fi

	for offset in -2 -1 0 1 2; do
		encoded_index=$((observed + offset))
		metric_file="$scratch/ssim-target-$observed-offset-$offset-setting-$setting.log"
		ssim_filter="[0:v]select=eq(n\\,$observed),setpts=PTS-STARTPTS[source];[1:v]select=eq(n\\,$encoded_index),setpts=PTS-STARTPTS[encoded];[source][encoded]ssim=stats_file=$metric_file"
		ssim_command="$(diagnostic_command_offset_metric ssim "$observed" "$encoded_index")"
		metric_value='null'
		if [[ "$status" == 'complete' ]]; then
			if ffmpeg -nostdin -v error -i "$source_clip" -i "$output" -filter_complex "$ssim_filter" -f null - >/dev/null 2>&1 &&
				metric_value="$(diagnostic_metric_value ssim "$metric_file")"; then :; else
				status='harness-blocked'
				reason='missing-ssim-metric'
				metric_value='null'
			fi
		fi
		ssim_json="$(jq -n -c --argjson command "$ssim_command" --argjson value "$metric_value" \
			'{command:$command,value:$value}')"

		metric_file="$scratch/psnr-target-$observed-offset-$offset-setting-$setting.log"
		psnr_filter="[0:v]select=eq(n\\,$observed),setpts=PTS-STARTPTS[source];[1:v]select=eq(n\\,$encoded_index),setpts=PTS-STARTPTS[encoded];[source][encoded]psnr=stats_file=$metric_file"
		psnr_command="$(diagnostic_command_offset_metric psnr "$observed" "$encoded_index")"
		metric_value='null'
		if [[ "$status" == 'complete' ]]; then
			if ffmpeg -nostdin -v error -i "$source_clip" -i "$output" -filter_complex "$psnr_filter" -f null - >/dev/null 2>&1 &&
				metric_value="$(diagnostic_metric_value psnr "$metric_file")"; then :; else
				status='harness-blocked'
				reason='missing-psnr-metric'
				metric_value='null'
			fi
		fi
		psnr_json="$(jq -n -c --argjson command "$psnr_command" --argjson value "$metric_value" \
			'{command:$command,value:$value}')"
		offset_json="$(jq -n -c --argjson offset "$offset" --argjson source "$observed" \
			--argjson encoded "$encoded_index" --argjson ssim "$ssim_json" --argjson psnr "$psnr_json" '{
			offset:$offset,sourceFrameIndex:$source,encodedFrameIndex:$encoded,ssim:$ssim,psnr:$psnr
		}')"
		offsets="$(jq -c --argjson value "$offset_json" '. + [$value]' <<<"$offsets")"
	done
	timeline='{"zeroOffsetAligned":false,"discontinuity":null}'
	if [[ "$status" == 'complete' ]]; then
		timeline="$(jq -n -c -L "$script_directory" --argjson source "$source_window" --argjson output "$output_window" \
			--argjson offsets "$offsets" --argjson observed "$observed" '
			include "diagnostic-contract";
			[$offsets[] | {offset,ssim:.ssim.value,psnr:.psnr.value}] as $values |
			diagnostic_vmaf_timeline($source; $output; $values; $observed)
		')" || {
			status='harness-blocked'
			reason='timeline-evidence-invalid'
			timeline='{"zeroOffsetAligned":false,"discontinuity":null}'
		}
	fi

	classifier_input="$(jq -n -c --argjson quality "$setting" --arg status "$status" \
		--argjson current "$current_target" --argjson reset "$reset_target" --argjson offsets "$offsets" \
		--argjson timeline "$timeline" --argjson source_window "$source_window" '{
		globalQuality:$quality,
		completeEvidence:($status == "complete"),
		currentTargetVmaf:$current,
		resetTargetVmaf:$reset,
		sourceWindow:{status:(if $status == "failed" then "decode-error" else ($source_window.sourceWindow.status // "discontinuity") end)},
		timeline:$timeline,
		offsets:[$offsets[] | {offset,ssim:.ssim.value,psnr:.psnr.value}]
	}')"
	jq -n -c --argjson quality "$setting" --arg status "$status" --arg reason "$reason" \
		--argjson source_identity "$source_identity" --argjson output_identity "$output_identity" \
		--argjson source_window "$source_window" --argjson output_window "$output_window" \
		--argjson encode "$encode_command" --argjson decode "$decode_command" \
		--argjson output_frame_command "$output_frame_command" \
		--argjson current_command "$current_command" --argjson reset_command "$reset_command" \
		--argjson current_window "$current_window" --argjson reset_window "$reset_window" \
		--argjson offsets "$offsets" --argjson timeline "$timeline" --argjson classifier "$classifier_input" '{
		globalQuality:$quality,status:$status,reason:(if $reason == "" then null else $reason end),
		sourceIdentity:$source_identity,outputIdentity:$output_identity,
		sourceFrameWindow:$source_window,outputFrameWindow:$output_window,
		commands:{encode:$encode,decode:$decode,outputFrameProbe:$output_frame_command,
			vmafCurrent:$current_command,vmafReset:$reset_command},
		vmaf:{current:$current_window,reset:$reset_window},offsets:$offsets,timeline:$timeline,
		classifierInput:$classifier
	}'
}

diagnostic_hdr_pair() {
	local media="$1" token="$2" start="$3" duration="$4"
	local recorded_start="${5:-$start}"
	local decoded='null' trace='null' status='complete' reason=''
	local decoded_command trace_command
	decoded_command="$(diagnostic_command_hdr_frame "<$token>" "$recorded_start")"
	trace_command="$(diagnostic_command_hdr_trace "<$token>" "$recorded_start")"
	decoded="$("$script_directory/probe.sh" diagnostic-hdr-frame "$media" "$start" "$duration")" || {
		status='harness-blocked'
		reason='decoded-frame-oracle-failed'
		decoded='{"status":"malformed"}'
	}
	trace="$("$script_directory/probe.sh" diagnostic-hdr-trace "$media" "$start" "$duration")" || {
		status='harness-blocked'
		reason='trace-headers-oracle-failed'
		trace='{"status":"malformed"}'
	}
	jq -n -c --arg start "$recorded_start" --argjson duration "$duration" --arg status "$status" --arg reason "$reason" \
		--argjson decoded "$decoded" --argjson trace "$trace" \
		--argjson decoded_command "$decoded_command" --argjson trace_command "$trace_command" '{
		start:$start,durationSeconds:$duration,status:$status,
		reason:(if $reason == "" then null else $reason end),
		decoded:{command:$decoded_command,oracle:$decoded},
		trace:{command:$trace_command,oracle:$trace}
	}'
}

diagnostic_hdr_evidence() {
	local sample_id="$1" source="$2" clip_id="$3" timestamp="$4" clip="$5" output="$6" scratch="$7"
	local clip_ready="${8:-1}" prepared_source_identity="${9-}" prepared_clip_identity="${10-}" preparation_reason="${11:-}"
	local status='complete' reason='' encode_status=0 title_probe duration end_start
	local source_identity='null' clip_identity='null' output_identity='null' stream_oracle='null'
	local beginning detail ending clip_pair encoded_pair source_windows classifier_file normalized='null' classification
	local encode_command decode_command clip_command stream_command
	clip_command="$(diagnostic_command_clip "$timestamp")"
	encode_command="$(diagnostic_command_encode 16)"
	decode_command="$(diagnostic_command_decode)"
	stream_command="$(diagnostic_command_hdr_stream)"

	if [[ -n "$prepared_source_identity" ]]; then
		source_identity="$prepared_source_identity"
	else
		source_identity="$(diagnostic_identity_json "$source")" || {
			status='harness-blocked'
			reason='source-identity-unavailable'
			source_identity='null'
		}
	fi
	if [[ "$clip_ready" != '1' ]]; then
		status='harness-blocked'
		reason="${preparation_reason:-source-panel-preparation-aborted}"
		beginning="$(jq -n -c --arg reason "$reason" '{start:"0",durationSeconds:10,status:"harness-blocked",reason:$reason,decoded:{command:[],oracle:{status:"malformed"}},trace:{command:[],oracle:{status:"malformed"}}}')"
		detail="$(jq -n -c --arg start "$timestamp" --arg reason "$reason" '{start:$start,durationSeconds:10,status:"harness-blocked",reason:$reason,decoded:{command:[],oracle:{status:"malformed"}},trace:{command:[],oracle:{status:"malformed"}}}')"
		ending="$(jq -n -c --arg reason "$reason" '{start:"<end-start>",durationSeconds:10,status:"harness-blocked",reason:$reason,decoded:{command:[],oracle:{status:"malformed"}},trace:{command:[],oracle:{status:"malformed"}}}')"
		clip_pair="$detail"
		encoded_pair="$detail"
		jq -n -c --arg strategy "$CONTRACT_STRATEGY_ID" --arg sample "$sample_id" --arg clip_id "$clip_id" \
			--arg status "$status" --arg reason "$reason" --argjson source_identity "$source_identity" \
			--argjson clip_identity "$prepared_clip_identity" --argjson beginning "$beginning" --argjson detail "$detail" \
			--argjson ending "$ending" --argjson clip_pair "$clip_pair" --argjson encoded_pair "$encoded_pair" \
			--argjson clip_command "$clip_command" --argjson encode "$encode_command" --argjson decode "$decode_command" '
			{
				schemaVersion:1,strategyId:$strategy,sampleId:$sample,clipId:$clip_id,globalQuality:16,
				status:$status,reason:$reason,commands:{clip:$clip_command,encode:$encode,decode:$decode},
				source:{identity:$source_identity,streamProbe:{command:[],oracle:{status:"malformed"}},windows:{beginning:$beginning,detail:$detail,end:$ending}},
				clip:($clip_pair + {identity:$clip_identity}),
				encoded:($encoded_pair + {identity:null}),
				normalizedOracle:null,
				classification:{schemaVersion:1,classification:"unresolved-oracle",reasons:[$reason]}
			}'
		return
	elif [[ -n "$prepared_clip_identity" ]]; then
		clip_identity="$prepared_clip_identity"
	else
		clip_identity="$(diagnostic_identity_json "$clip")" || {
			status='harness-blocked'
			reason='clip-identity-unavailable'
			clip_identity='null'
		}
	fi
	if ! title_probe="$(probe_media title "$source")" ||
		! duration="$(jq -e -r '.durationSeconds | numbers | select(. >= 10)' <<<"$title_probe")"; then
		status='harness-blocked'
		reason='source-duration-unavailable'
		duration=10
	fi
	end_start="$(awk -v duration="$duration" 'BEGIN { value = duration - 10; if (value < 0) value = 0; printf "%.6f", value }')"
	stream_oracle="$("$script_directory/probe.sh" diagnostic-hdr-stream "$source" 0 10)" || {
		status='harness-blocked'
		reason='source-stream-oracle-failed'
		stream_oracle='{"status":"malformed"}'
	}
	beginning="$(diagnostic_hdr_pair "$source" source-title 0 10)"
	detail="$(diagnostic_hdr_pair "$source" source-title "$timestamp" 10)"
	ending="$(diagnostic_hdr_pair "$source" source-title "$end_start" 10 '<end-start>')"
	clip_pair="$(diagnostic_hdr_pair "$clip" source-clip 0 10 "$timestamp")"
	for pair in "$beginning" "$detail" "$ending" "$clip_pair"; do
		status="$(diagnostic_status_merge "$status" "$(jq -r '.status' <<<"$pair")")"
	done

	if [[ "$clip_ready" != '1' ]]; then
		encoded_pair="$(jq -n -c --arg start "$timestamp" --arg reason "$reason" '{start:$start,durationSeconds:10,status:"harness-blocked",reason:$reason,decoded:{command:[],oracle:{status:"malformed"}},trace:{command:[],oracle:{status:"malformed"}}}')"
	else
		set +e
		run_qsv_encode "$clip" "$output" 16 "$scratch/encode.log" "$scratch/fdinfo.log"
		encode_status=$?
		set -e
	fi
	if [[ "$clip_ready" == '1' && "$encode_status" -ne 0 ]]; then
		status='failed'
		reason='encode-failed'
	elif [[ "$clip_ready" == '1' ]] && ! ffmpeg -nostdin -v error -i "$output" -map 0:v:0 -f null - >/dev/null 2>&1; then
		status='failed'
		reason='decode-failed'
	elif [[ "$clip_ready" == '1' ]]; then
		output_identity="$(diagnostic_identity_json "$output")" || {
			status='harness-blocked'
			reason='output-identity-unavailable'
			output_identity='null'
		}
	fi
	if [[ "$status" == 'failed' ]]; then
		encoded_pair="$(jq -n -c --arg start "$timestamp" '{start:$start,durationSeconds:10,status:"failed",reason:"encoded-output-unavailable",decoded:{command:[],oracle:{status:"malformed"}},trace:{command:[],oracle:{status:"malformed"}}}')"
	elif [[ "$clip_ready" == '1' ]]; then
		encoded_pair="$(diagnostic_hdr_pair "$output" encoded-output 0 10 "$timestamp")"
		status="$(diagnostic_status_merge "$status" "$(jq -r '.status' <<<"$encoded_pair")")"
	fi

	source_windows="$(jq -n -c --argjson beginning "$beginning" --argjson detail "$detail" --argjson ending "$ending" \
		'{beginning:$beginning,detail:$detail,end:$ending}')"
	classifier_file="$scratch/hdr-classifier.json"
	jq -n -c --argjson stream "$stream_oracle" --argjson windows "$source_windows" \
		--argjson clip "$clip_pair" --argjson encoded "$encoded_pair" '{
		schemaVersion:1,
		source:{streamProbe:$stream,windows:($windows | with_entries(.value = {decoded:.value.decoded.oracle,trace:.value.trace.oracle}))},
		clip:{decoded:$clip.decoded.oracle,trace:$clip.trace.oracle},
		encoded:{decoded:$encoded.decoded.oracle,trace:$encoded.trace.oracle}
	}' >"$classifier_file"
	if [[ "$status" == 'complete' ]]; then
		normalized="$(diagnostic_hdr_normalize "$classifier_file")" || {
			status='harness-blocked'
			reason='HDR-oracle-normalization-failed'
			normalized='null'
		}
	fi
	if [[ "$status" == 'complete' ]] && jq -e '
		[
			.source.authoritative.reasons[]?,
			.source.windows[].authoritative.reasons[]?,
			.clip.authoritative.reasons[]?,
			.encoded.authoritative.reasons[]?
		] | any(. == "decoded-trace-disagreement" or . == "source-window-conflict")
	' <<<"$normalized" >/dev/null; then
		status='harness-blocked'
		reason='conflicting-HDR-oracle'
	fi
	if [[ "$status" == 'complete' ]]; then
		classification="$(diagnostic_hdr_classify "$classifier_file")" || {
			status='harness-blocked'
			reason='HDR-classification-failed'
			classification='{"schemaVersion":1,"classification":"unresolved-oracle","reasons":["classification-failed"]}'
		}
	else
		classification='{"schemaVersion":1,"classification":"unresolved-oracle","reasons":["incomplete-or-failed-evidence"]}'
	fi
	jq -n -c --arg strategy "$CONTRACT_STRATEGY_ID" --arg sample "$sample_id" --arg clip_id "$clip_id" \
		--arg status "$status" --arg reason "$reason" --argjson source_identity "$source_identity" \
		--argjson clip_identity "$clip_identity" --argjson output_identity "$output_identity" \
		--argjson clip_command "$clip_command" --argjson encode "$encode_command" --argjson decode "$decode_command" \
		--argjson stream_command "$stream_command" --argjson stream "$stream_oracle" \
		--argjson windows "$source_windows" --argjson clip_pair "$clip_pair" --argjson encoded_pair "$encoded_pair" \
		--argjson normalized "$normalized" --argjson classification "$classification" '{
		schemaVersion:1,strategyId:$strategy,sampleId:$sample,clipId:$clip_id,globalQuality:16,
		status:$status,reason:(if $reason == "" then null else $reason end),
		commands:{clip:$clip_command,encode:$encode,decode:$decode},
		source:{identity:$source_identity,streamProbe:{command:$stream_command,oracle:$stream},windows:$windows},
		clip:($clip_pair + {identity:$clip_identity}),
		encoded:($encoded_pair + {identity:$output_identity}),
		normalizedOracle:$normalized,classification:$classification
	}'
}

diagnostic_prepare_inputs() {
	local run_scratch="$1" sample_id clip_id observed sample source timestamp title_scratch clip
	local source_identity source_window clip_identity status reason preparations='[]'
	while IFS=$'\t' read -r sample_id clip_id observed; do
		sample="$(jq -e -c --arg sample "$sample_id" '.qualityPanel[] | select(.id == $sample)' "$samples_file")" || return
		source="$(jq -r '.path' <<<"$sample")"
		timestamp="$(jq -e -r --arg clip "$clip_id" '.clips[$clip] | strings' <<<"$sample")" || return
		title_scratch="$run_scratch/vmaf-$sample_id-$clip_id"
		clip="$title_scratch/diagnostic-vmaf-$sample_id-$clip_id-frame-$observed-source.mkv"
		mkdir -p "$title_scratch"
		status='complete'
		reason=''
		source_identity='null'
		source_window='null'
		if ! ffmpeg -nostdin -v error -ss "$timestamp" -i "$source" -t 90 -map 0:v:0 -c copy "$clip" >/dev/null 2>&1; then
			status='harness-blocked'
			reason='source-clip-create-failed'
		fi
		if [[ "$status" == 'complete' ]]; then
			source_identity="$(diagnostic_identity_json "$clip")" || {
				status='harness-blocked'
				reason='source-clip-identity-unavailable'
				source_identity='null'
			}
		fi
		if [[ "$status" == 'complete' ]]; then
			source_window="$("$script_directory/probe.sh" diagnostic-window "$clip" 0 90 "$((observed - 2))" "$((observed + 2))")" || {
				status='harness-blocked'
				reason='source-frame-window-unavailable'
				source_window='null'
			}
		fi
		preparations="$(jq -c --arg panel vmaf --arg sample "$sample_id" --arg clip_id "$clip_id" \
			--arg source "$source" --arg timestamp "$timestamp" --arg path "$clip" --arg scratch "$title_scratch" \
			--arg status "$status" --arg reason "$reason" --argjson observed "$observed" \
			--argjson identity "$source_identity" --argjson window "$source_window" '. + [{panel:$panel,sampleId:$sample,clipId:$clip_id,observedFrameIndex:$observed,source:$source,timestamp:$timestamp,path:$path,scratch:$scratch,sourceIdentity:$identity,sourceFrameWindow:$window,status:$status,reason:(if $reason == "" then null else $reason end)}]' <<<"$preparations")" || return
	done < <(jq -r '.diagnostics.vmafPanel[] | [.sampleId,.clipId,.observedFrameIndex] | @tsv' "$samples_file")

	while IFS=$'\t' read -r sample_id clip_id; do
		sample="$(jq -e -c --arg sample "$sample_id" '.qualityPanel[] | select(.id == $sample)' "$samples_file")" || return
		source="$(jq -r '.path' <<<"$sample")"
		timestamp="$(jq -e -r --arg clip "$clip_id" '.clips[$clip] | strings' <<<"$sample")" || return
		title_scratch="$run_scratch/hdr-$sample_id"
		clip="$title_scratch/diagnostic-hdr-$sample_id-source.mkv"
		mkdir -p "$title_scratch"
		status='complete'
		reason=''
		source_identity='null'
		clip_identity='null'
		if ! ffmpeg -nostdin -v error -ss "$timestamp" -i "$source" -t 90 -map 0:v:0 -c copy "$clip" >/dev/null 2>&1; then
			status='harness-blocked'
			reason='source-clip-create-failed'
		fi
		if [[ "$status" == 'complete' ]]; then
			source_identity="$(diagnostic_identity_json "$source")" || {
				status='harness-blocked'
				reason='source-clip-identity-unavailable'
				source_identity='null'
			}
		fi
		if [[ "$status" == 'complete' ]]; then
			clip_identity="$(diagnostic_identity_json "$clip")" || {
				status='harness-blocked'
				reason='source-clip-identity-unavailable'
				clip_identity='null'
			}
		fi
		preparations="$(jq -c --arg panel hdr --arg sample "$sample_id" --arg clip_id "$clip_id" \
			--arg source "$source" --arg timestamp "$timestamp" --arg path "$clip" --arg scratch "$title_scratch" \
			--arg status "$status" --arg reason "$reason" --argjson source_identity "$source_identity" \
			--argjson clip_identity "$clip_identity" '. + [{panel:$panel,sampleId:$sample,clipId:$clip_id,source:$source,timestamp:$timestamp,path:$path,scratch:$scratch,sourceIdentity:$source_identity,clipIdentity:$clip_identity,status:$status,reason:(if $reason == "" then null else $reason end)}]' <<<"$preparations")" || return
	done < <(jq -r '.diagnostics.hdrPanel[] | [.sampleId,.clipId] | @tsv' "$samples_file")
	printf '%s\n' "$preparations"
}

diagnostics_mode() {
	local explicit_run_id="${1:-}" panel_samples run_id='' run_directory diagnostic_root run_scratch manifest_temp
	local overall_status='complete' sample_id clip_id observed timestamp source clip output
	local sample source_identity source_window clip_identity clip_command source_frame_command settings setting setting_json evidence classifier_file classification
	local entry_status summary vmaf_entries='[]' hdr_entries='[]' title_scratch evidence_path clip_ready
	local preparations preparation preparation_reason
	local post_identity_valid=1 invalidated_entries
	if [[ -n "$explicit_run_id" ]]; then
		"$script_directory/runmeta.sh" diagnostic-precheck "$explicit_run_id" || return
	fi
	panel_samples="$(jq -c '. as $root | [.qualityPanel[]? | select(.id as $sample_id |
		([$root.diagnostics.vmafPanel[].sampleId, $root.diagnostics.hdrPanel[].sampleId] | index($sample_id) != null))]' "$samples_file")" || return
	if ! require_running_image_evidence; then
		diagnostic_terminal harness-blocked "$explicit_run_id" '' running-image-evidence-rejected
		return 2
	fi
	if ! diagnostic_assigned_node_capability_gate; then
		diagnostic_terminal harness-blocked "$explicit_run_id" '' assigned-node-capability-rejected
		return 2
	fi
	if ! runtime_pre_encode_gate "$panel_samples"; then
		diagnostic_terminal harness-blocked "$explicit_run_id" '' runtime-pre-encode-gate-rejected
		return 2
	fi
	if ! diagnostic_preflight "$panel_samples"; then
		diagnostic_terminal harness-blocked "$explicit_run_id" '' diagnostic-preflight-rejected
		return 2
	fi
	BENCHMARK_ENCODER_COMMANDS_JSON="$(encoder_commands_for_mode diagnostics)"
	export BENCHMARK_ENCODER_COMMANDS_JSON
	if [[ -n "$explicit_run_id" ]]; then
		run_id="$("$script_directory/runmeta.sh" create diagnostics "$explicit_run_id")" || {
			diagnostic_terminal harness-blocked "$explicit_run_id" '' runmeta-create-failed
			return 2
		}
	else
		run_id="$("$script_directory/runmeta.sh" create diagnostics)" || return
	fi
	run_directory="$benchmark_out/runs/$run_id"
	diagnostic_root="$run_directory/diagnostics"
	run_scratch="$scratch_root/$run_id"
	mkdir -p "$diagnostic_root/vmaf" "$diagnostic_root/hdr" "$run_scratch"
	manifest_temp="$(mktemp "$diagnostic_root/.manifest.XXXXXX")" || return
	cp -- "$run_directory/manifest.json" "$manifest_temp"
	mv -f -- "$manifest_temp" "$diagnostic_root/manifest.json"
	chmod 0444 "$diagnostic_root/manifest.json"

	preparations="$(diagnostic_prepare_inputs "$run_scratch")" || return

	while IFS= read -r preparation; do
		[[ -n "$preparation" ]] || continue
		sample_id="$(jq -r '.sampleId' <<<"$preparation")"
		clip_id="$(jq -r '.clipId' <<<"$preparation")"
		observed="$(jq -r '.observedFrameIndex' <<<"$preparation")"
		timestamp="$(jq -r '.timestamp' <<<"$preparation")"
		clip="$(jq -r '.path' <<<"$preparation")"
		title_scratch="$(jq -r '.scratch' <<<"$preparation")"
		source_identity="$(jq -c '.sourceIdentity' <<<"$preparation")"
		source_window="$(jq -c '.sourceFrameWindow' <<<"$preparation")"
		clip_command="$(diagnostic_command_clip "$timestamp")"
		source_frame_command="$(diagnostic_command_vmaf_frame '<source-clip>')"
		entry_status='complete'
		preparation_reason="$(jq -r '.reason // empty' <<<"$preparation")"
		if [[ -n "$preparation_reason" ]]; then
			entry_status='harness-blocked'
		fi
		settings='[]'
		for setting in 16 30; do
			output="$title_scratch/diagnostic-vmaf-$sample_id-$clip_id-frame-$observed-qsv-$setting.mkv"
			mkdir -p "$title_scratch/setting-$setting"
			setting_json="$(diagnostic_vmaf_setting "$sample_id" "$clip_id" "$observed" "$setting" \
				"$clip" "$output" "$title_scratch/setting-$setting" "$source_identity" "$source_window" "$preparation_reason")"
			settings="$(jq -c --argjson value "$setting_json" '. + [$value]' <<<"$settings")"
			entry_status="$(diagnostic_status_merge "$entry_status" "$(jq -r '.status' <<<"$setting_json")")"
		done
		classifier_file="$title_scratch/classifier.json"
		jq -n -c --arg sample "$sample_id" --arg clip "$clip_id" --argjson observed "$observed" \
			--argjson settings "$settings" '{schemaVersion:1,sampleId:$sample,clipId:$clip,
			observedFrameIndex:$observed,settings:[$settings[].classifierInput]}' >"$classifier_file"
		if [[ -n "$preparation_reason" ]]; then
			classification="$(jq -n -c --arg reason "$preparation_reason" \
				'{schemaVersion:1,classification:"unresolved",reasons:[$reason]}')" || return
		else
			classification="$(diagnostic_vmaf_classify "$classifier_file")" || {
				entry_status='harness-blocked'
				classification='{"schemaVersion":1,"classification":"unresolved","reasons":["classification-failed"]}'
			}
		fi
		evidence="$(jq -n -c --arg strategy "$CONTRACT_STRATEGY_ID" --arg sample "$sample_id" --arg clip "$clip_id" \
			--argjson observed "$observed" --arg status "$entry_status" --argjson clip_command "$clip_command" \
			--argjson source_frame_command "$source_frame_command" \
			--argjson source_identity "$source_identity" --argjson source_window "$source_window" \
			--argjson settings "$settings" --argjson classification "$classification" '{
			schemaVersion:1,strategyId:$strategy,sampleId:$sample,clipId:$clip,
			observedFrameIndex:$observed,status:$status,
			sourceClip:{command:$clip_command,frameProbeCommand:$source_frame_command,
				identity:$source_identity,frameWindow:$source_window},
			settings:[$settings[] | del(.classifierInput)],classification:$classification
		}')"
		evidence_path="$diagnostic_root/vmaf/$sample_id/$clip_id/evidence.json"
		diagnostic_publish_json "$evidence_path" "$evidence" || return
		vmaf_entries="$(jq -c --arg sample "$sample_id" --arg clip "$clip_id" --arg status "$entry_status" \
			--arg classification "$(jq -r '.classification' <<<"$classification")" \
			--argjson reasons "$(jq -c '.reasons' <<<"$classification")" \
			--arg evidence "vmaf/$sample_id/$clip_id/evidence.json" \
			'. + [{sampleId:$sample,clipId:$clip,status:$status,classification:$classification,reasons:$reasons,evidence:$evidence}]' <<<"$vmaf_entries")"
		overall_status="$(diagnostic_status_merge "$overall_status" "$entry_status")"
	done < <(jq -c '.[] | select(.panel == "vmaf")' <<<"$preparations")

	while IFS= read -r preparation; do
		[[ -n "$preparation" ]] || continue
		sample_id="$(jq -r '.sampleId' <<<"$preparation")"
		clip_id="$(jq -r '.clipId' <<<"$preparation")"
		source="$(jq -r '.source' <<<"$preparation")"
		timestamp="$(jq -r '.timestamp' <<<"$preparation")"
		clip="$(jq -r '.path' <<<"$preparation")"
		title_scratch="$(jq -r '.scratch' <<<"$preparation")"
		source_identity="$(jq -c '.sourceIdentity' <<<"$preparation")"
		clip_identity="$(jq -c '.clipIdentity' <<<"$preparation")"
		output="$title_scratch/diagnostic-hdr-$sample_id-qsv-16.mkv"
		clip_ready=1
		preparation_reason="$(jq -r '.reason // empty' <<<"$preparation")"
		if [[ -n "$preparation_reason" ]]; then
			clip_ready=0
		fi
		evidence="$(diagnostic_hdr_evidence "$sample_id" "$source" "$clip_id" "$timestamp" "$clip" "$output" "$title_scratch" "$clip_ready" "$source_identity" "$clip_identity" "$preparation_reason")"
		entry_status="$(jq -r '.status' <<<"$evidence")"
		evidence_path="$diagnostic_root/hdr/$sample_id/evidence.json"
		diagnostic_publish_json "$evidence_path" "$evidence" || return
		hdr_entries="$(jq -c --arg sample "$sample_id" --arg status "$entry_status" \
			--arg classification "$(jq -r '.classification.classification' <<<"$evidence")" \
			--argjson reasons "$(jq -c '.classification.reasons' <<<"$evidence")" \
			--arg evidence "hdr/$sample_id/evidence.json" \
			'. + [{sampleId:$sample,status:$status,classification:$classification,reasons:$reasons,evidence:$evidence}]' <<<"$hdr_entries")"
		overall_status="$(diagnostic_status_merge "$overall_status" "$entry_status")"
	done < <(jq -c '.[] | select(.panel == "hdr")' <<<"$preparations")

	if ! runtime_pre_encode_gate "$panel_samples" >/dev/null 2>&1; then
		post_identity_valid=0
	fi
	if ! require_running_image_evidence >/dev/null 2>&1; then
		post_identity_valid=0
	fi
	if ((post_identity_valid == 0)); then
		invalidated_entries="$(diagnostic_invalidate_identity_evidence \
			"$diagnostic_root" "$vmaf_entries" "$hdr_entries")" || return
		vmaf_entries="$(jq -e -c '.vmaf' <<<"$invalidated_entries")" || return
		hdr_entries="$(jq -e -c '.hdr' <<<"$invalidated_entries")" || return
		overall_status='harness-blocked'
	fi
	summary="$(jq -n -c --arg strategy "$CONTRACT_STRATEGY_ID" --arg run "$run_id" --arg status "$overall_status" \
		--argjson vmaf "$vmaf_entries" --argjson hdr "$hdr_entries" '{
		schemaVersion:1,strategyId:$strategy,mode:"diagnostics",runId:$run,status:$status,
		vmaf:{total:5,entries:$vmaf},hdr:{total:3,entries:$hdr}
	}')"
	diagnostic_publish_json "$diagnostic_root/diagnostic-summary.json" "$summary" || return
	rm -rf -- "$run_scratch"
	diagnostic_terminal "$overall_status" "$run_id" "$summary" || return
	return 0
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
	local lock_directory lock_owned=0 expected_digest actual_digest competitor
	evidence_directory="$run_directory/quality-evidence"
	evidence_base="$sample_id-$clip_id-qsv-$setting-attempt-$attempt"
	relative="quality-evidence/$evidence_base.json"
	destination="$run_directory/$relative"
	lock_directory="$evidence_directory/.$evidence_base.publish.lock"
	trap '
		if [[ -n "$staged" ]]; then rm -f -- "$staged"; fi
		if ((lock_owned)); then rmdir -- "$lock_directory" 2>/dev/null || true; fi
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
	# mkdir is the atomic ownership operation for this exact attempt. All
	# publishers must own it before inspecting or installing the destination.
	mkdir -- "$lock_directory" || return 65
	# shellcheck disable=SC2034 # Read by the EXIT trap.
	lock_owned=1
	[[ -d "$lock_directory" && ! -L "$lock_directory" ]] || return 65
	[[ "$(cd -P "$lock_directory" && pwd)" == "$(cd -P "$evidence_directory" && pwd)/.${evidence_base}.publish.lock" ]] || return 65
	if [[ "$test_mode" == '1' &&
		"${BENCHMARK_TEST_QUALITY_EVIDENCE_COMPETITOR_SETTING:-}" == "$setting" &&
		-n "${BENCHMARK_TEST_QUALITY_EVIDENCE_COMPETITOR_FILE:-}" ]]; then
		competitor="$BENCHMARK_TEST_QUALITY_EVIDENCE_COMPETITOR_FILE"
		[[ -f "$competitor" && ! -L "$competitor" ]] || return 65
		if [[ ! -e "$destination" && ! -L "$destination" ]]; then
			cp -- "$competitor" "$destination" || return 65
		fi
	fi
	if [[ -e "$destination" || -L "$destination" ]]; then
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
	else
		mv -- "$staged" "$destination" || return 65
		staged=''
		[[ -f "$destination" && ! -L "$destination" ]] || return 65
		[[ "$(realpath "$destination")" == "$(cd -P "$run_directory" && pwd)/$relative" ]] || return 65
		digest="sha256:$(sha256sum "$destination" | awk 'NR == 1 { print $1 }')"
		[[ "$digest" == "$expected_digest" ]] || return 65
		quality_evidence_document_matches "$destination" "$run_id" "$sample_id" "$cohort" \
			"$source_sha" "$clip_id" "$setting" \
			"$(jq -r '.harmonicMean' <<<"$vmaf")" "$(jq -r '.onePercentLow' <<<"$vmaf")" \
			"$ssim" "$validation_hdr" || return 65
	fi
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
	local status attempt disposition='discarded' confirmation destination
	local expected_finalist chosen
	local encodes_directory='' staged_destination='' backup_destination='' prior_digest='' published=0 had_prior=0
	local append_status=0 completed_status=0 columns_text out_physical runs_physical run_physical encodes_physical
	local promotion_status=0 rollback_status=0
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
	[[ "$panel" == 'quality' || "$panel" == 'x265' || "$panel" == 'savings' || "$panel" == 'finalist' ]] || return 65
	[[ "$encoder" == 'qsv' || "$encoder" == 'x265' ]] || return 65
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
	if [[ "$encoder" == 'x265' ]] &&
		[[ "$qsv_initialization" != 'not-applicable' || "$video_busy_nanoseconds" != '0' ]]; then
		echo 'x265 result must use not-applicable QSV evidence' >&2
		return 65
	fi
	if [[ "$panel" == 'finalist' ]]; then
		confirmation="copy:encode-benchmark:$run_id:$sample_id"
		if [[ "${ENCODE_BENCHMARK_FINALIST_CONFIRM:-}" != "$confirmation" ]]; then
			echo "missing finalist confirmation for $run_id/$sample_id" >&2
			return 64
		fi
		expected_finalist="$(contract_expected_finalist "$cohort")" || return
		[[ "$sample_id" == "$expected_finalist" ]] || {
			echo "finalist sample does not match cohort: $cohort" >&2
			return 65
		}
		prepare_chosen_upstream "$cohort" provisional || return
		chosen="$(contract_chosen_record "$samples_file" "$cohort" provisional)" || return 65
		[[ "$setting" == "$(jq -r '.globalQuality' <<<"$chosen")" ]] || {
			echo "finalist result setting does not match chosen setting for cohort: $cohort" >&2
			return 65
		}
	fi
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

	if [[ "$panel" == 'finalist' ]]; then
		if [[ "$status" == 'passed' ]]; then
			disposition='copied'
		fi
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
	if [[ "$panel" == 'finalist' && "$status" == 'passed' ]]; then
		[[ -f "$scratch_output" && ! -L "$scratch_output" ]] || {
			echo 'validated finalist scratch output is not a regular file' >&2
			return 66
		}
		encodes_directory="$run_directory/encodes"
		if [[ -e "$encodes_directory" || -L "$encodes_directory" ]]; then
			[[ -d "$encodes_directory" && ! -L "$encodes_directory" ]] || {
				echo 'finalist encodes directory is not a confined directory' >&2
				return 65
			}
		else
			mkdir -- "$encodes_directory"
		fi
		encodes_physical="$(cd -P "$encodes_directory" && pwd)"
		[[ "$encodes_physical" == "$run_physical/encodes" ]] || {
			echo 'finalist encodes directory escapes the run' >&2
			return 65
		}
		destination="$encodes_directory/$sample_id-$encoder-gq$setting.mkv"
		[[ ! -L "$destination" && (! -e "$destination" || -f "$destination") ]] || {
			echo 'finalist destination is not a regular file' >&2
			return 65
		}
		staged_destination="$encodes_directory/.$sample_id-$encoder-gq$setting-attempt-$attempt.tmp.mkv"
		backup_destination="$encodes_directory/.$sample_id-$encoder-gq$setting-attempt-$attempt.backup.mkv"
		rm -f -- "$staged_destination"
		if [[ -e "$backup_destination" || -L "$backup_destination" ]]; then
			[[ -f "$backup_destination" && ! -L "$backup_destination" ]] || {
				echo "finalist retained backup is not a regular file: $backup_destination" >&2
				return 74
			}
			[[ ! -e "$destination" ]] || {
				echo "finalist recovery is ambiguous; retained backup: $backup_destination" >&2
				return 74
			}
			prior_digest="sha256:$(sha256sum "$backup_destination" | awk '{print $1}')"
			restore_finalist_backup "$backup_destination" "$destination" "$prior_digest" || return
		fi
		cp -- "$scratch_output" "$staged_destination" || return
		if [[ -e "$destination" ]]; then
			prior_digest="sha256:$(sha256sum "$destination" | awk '{print $1}')"
			mv -- "$destination" "$backup_destination" || {
				rm -f -- "$staged_destination"
				return 74
			}
			had_prior=1
		fi
		mv -- "$staged_destination" "$destination" || promotion_status=$?
		if ((promotion_status != 0)); then
			rm -f -- "$staged_destination" || true
			if ((had_prior)) && ! restore_finalist_backup "$backup_destination" "$destination" "$prior_digest"; then
				return 74
			fi
			return "$promotion_status"
		fi
		published=1
	fi
	if [[ "$test_mode" == '1' && "${BENCHMARK_TEST_FAIL_RESULT_APPEND:-0}" == '1' ]]; then
		append_status=74
	else
		(
			IFS=,
			printf '%s\n' "${columns[*]}"
		) >>"$results" || append_status=$?
	fi
	if ((append_status != 0)); then
		if ((published)); then
			if ! rm -f -- "$destination"; then
				echo "finalist rollback could not remove replacement; retained backup: $backup_destination" >&2
				rollback_status=74
			elif ((had_prior)) &&
				! restore_finalist_backup "$backup_destination" "$destination" "$prior_digest"; then
				rollback_status=74
			fi
		fi
		if [[ -n "$staged_destination" ]]; then rm -f -- "$staged_destination"; fi
		if [[ -n "$backup_destination" && "$rollback_status" == '0' ]]; then
			rm -f -- "$backup_destination"
		fi
		if ((rollback_status != 0)); then return "$rollback_status"; fi
		return "$append_status"
	fi
	if [[ -n "$backup_destination" ]]; then rm -f -- "$backup_destination"; fi
	printf '{"status":"%s","attempt":%s,"output_disposition":"%s"}\n' \
		"$status" "$attempt" "$disposition"
}

restore_finalist_backup() {
	local backup="$1" destination="$2" expected_digest="$3" restored_digest
	local restore_staged="${backup%.backup.mkv}.restore-stage.mkv"
	[[ -f "$backup" && ! -L "$backup" ]] || {
		echo "finalist backup restoration failed; retained: $backup" >&2
		return 74
	}
	rm -f -- "$restore_staged"
	if ! cp -- "$backup" "$restore_staged"; then
		rm -f -- "$restore_staged" || true
		echo "finalist backup restoration failed; retained: $backup" >&2
		return 74
	fi
	restored_digest="sha256:$(sha256sum "$restore_staged" | awk '{print $1}')"
	if [[ "$restored_digest" != "$expected_digest" ]]; then
		rm -f -- "$restore_staged"
		echo "finalist backup restoration failed; retained: $backup" >&2
		return 74
	fi
	if ! mv -- "$restore_staged" "$destination"; then
		rm -f -- "$restore_staged"
		echo "finalist backup restoration failed; retained: $backup" >&2
		return 74
	fi
	restored_digest="sha256:$(sha256sum "$destination" | awk '{print $1}')"
	if [[ "$restored_digest" != "$expected_digest" ]]; then
		rm -f -- "$destination"
		echo "finalist backup restoration failed; retained: $backup" >&2
		return 74
	fi
	if ! rm -f -- "$backup"; then
		echo "finalist backup restoration failed; retained: $backup" >&2
		return 74
	fi
}

record_result() {
	local run_id="$1" fixture="$2" scratch_output="$3" status=0
	record_result_inner "$run_id" "$fixture" "$scratch_output" || status=$?
	rm -f -- "$scratch_output"
	return "$status"
}

filter_audio_inventory() {
	local input="$1" header="$2" source_path="$3"
	BENCHMARK_INVENTORY_SOURCE_VALUE="$source_path" awk -v expected_header="$header" '
		function fail() {
			failure = 65
			exit failure
		}
		function reset_record() {
			delete fields
			field_count = 0
			field = ""
			at_field_start = 1
			in_quotes = 0
			closed_quote = 0
			raw_record = ""
			record_active = 0
		}
		function finish_field() {
			fields[++field_count] = field
			field = ""
			at_field_start = 1
			closed_quote = 0
		}
		function finish_record(   key) {
			finish_field()
			record_count += 1
			if (record_count == 1) {
				if (raw_record != expected_header || field_count != 10) fail()
				print raw_record
			} else {
				if (field_count != 10 || fields[1] == "" || fields[2] !~ /^[0-9]+$/) fail()
				if (fields[1] != ENVIRON["BENCHMARK_INVENTORY_SOURCE_VALUE"]) {
					key = fields[1] SUBSEP fields[2]
					if (key in seen) fail()
					seen[key] = 1
					print raw_record
				}
			}
			reset_record()
		}
		BEGIN { reset_record() }
		{
			if (record_active) raw_record = raw_record ORS $0
			else raw_record = $0
			record_active = 1
			line = $0
			for (position = 1; position <= length(line); position += 1) {
				character = substr(line, position, 1)
				if (in_quotes) {
					if (character == "\"") {
						if (substr(line, position + 1, 1) == "\"") {
							field = field "\""
							position += 1
						} else {
							in_quotes = 0
							closed_quote = 1
						}
					} else {
						field = field character
					}
				} else if (closed_quote) {
					if (character != ",") fail()
					finish_field()
				} else if (at_field_start && character == "\"") {
					in_quotes = 1
					at_field_start = 0
				} else if (character == ",") {
					finish_field()
				} else {
					if (character == "\"") fail()
					field = field character
					at_field_start = 0
				}
			}
			if (in_quotes) {
				field = field ORS
				next
			}
			finish_record()
		}
		END {
			if (failure) exit failure
			if (in_quotes || record_active || record_count == 0) exit 65
		}
	' "$input"
}

append_audio_inventory() {
	local packets="$1"
	local probe="$2"
	local output="$3"
	local header='source_path,track_index,codec,channels,channel_layout,language,bit_rate,duration_seconds,audio_bytes,audio_bytes_method'
	local sums track index bytes staged tracks_json line source_path track_count position
	declare -A packet_bytes=()
	if [[ -e "$output" || -L "$output" ]]; then
		[[ -f "$output" && ! -L "$output" ]] || return 65
	fi
	sums="$(awk -F, '
		NF == 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { bytes[$1] += $2; seen[$1] = 1; next }
		{ exit 65 }
		END { for (stream in seen) printf "%s\t%.0f\n", stream, bytes[stream] }
	' "$packets")" || return
	while IFS=$'\t' read -r index bytes; do
		[[ -n "$index" ]] || continue
		packet_bytes[$index]="$bytes"
	done <<<"$sums"
	tracks_json="$(jq -e -c '
		if (.path | type) != "string" or (.audioTracks | type) != "array" or
			any(.audioTracks[]; (.index | type) != "number" or (.index | floor) != .index or
				(.codec | type) != "string" or (.channels | type) != "number" or
				(.channelLayout | type) != "string" or (.language | type) != "string" or
				((.bitRate | type) != "number" and (.bitRate | type) != "null") or
				(.durationSeconds | type) != "number") or
			([.audioTracks[].index] | unique | length) != (.audioTracks | length)
		then error("invalid audio inventory probe") else .audioTracks end
	' "$probe")" || return
	source_path="$(jq -e -r '.path | strings' "$probe")" || return
	track_count="$(jq -e -r 'length' <<<"$tracks_json")" || return
	staged="$output.$$.tmp"
	rm -f -- "$staged" || return 74
	if [[ -e "$output" ]]; then
		filter_audio_inventory "$output" "$header" "$source_path" >"$staged" || {
			rm -f -- "$staged" || true
			return 65
		}
	else
		printf '%s\n' "$header" >"$staged" || {
			rm -f -- "$staged" || true
			return 74
		}
	fi
	if [[ "$test_mode" == '1' && "${BENCHMARK_TEST_FAIL_AUDIO_INVENTORY_WRITE:-0}" == '1' ]]; then
		rm -f -- "$staged" || true
		return 74
	fi
	for ((position = 0; position < track_count; position += 1)); do
		track="$(jq -e -c --argjson position "$position" '.[$position]' <<<"$tracks_json")" || {
			rm -f -- "$staged" || true
			return 65
		}
		index="$(jq -e -r '.index' <<<"$track")" || {
			rm -f -- "$staged" || true
			return 65
		}
		bytes="${packet_bytes[$index]:-0}"
		line="$(jq -r \
			--argjson bytes "$bytes" \
			--arg source_path "$source_path" '
			[
				$source_path, .index, .codec, .channels, .channelLayout, .language,
				.bitRate,
				(if (.durationSeconds | floor) == .durationSeconds then (.durationSeconds | floor) else .durationSeconds end),
				$bytes, "packet-counted"
			] | @csv
		' <<<"$track")" || {
			rm -f -- "$staged"
			return 65
		}
		printf '%s\n' "$line" >>"$staged" || {
			rm -f -- "$staged" || true
			return 74
		}
	done
	mv -f -- "$staged" "$output" || {
		rm -f -- "$staged" || true
		return 74
	}
}

# Report every declared command the runtime image is missing, not just the first.
# A probe that stops at one missing tool costs an operator a full dispatch cycle
# per gap, which is how an undeclared python3 reached a live census Job.
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
	local encoders filters uid configured_image configured_digest dispatch_image node_name
	local missing candidate present absent proof_json proof_exit
	local -a required_commands=() optional_commands=()
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
		# Report-only inventory of substitutes, emitted on the diagnostic path
		# only: the success path's stdout is a strict JSON contract. When a
		# required command is absent the next question is always "what can
		# replace it", and answering that from the same run is what keeps a gap
		# from costing one dispatch cycle per candidate.
		mapfile -t optional_commands < <(read_declared_commands "$samples_file" optionalCommands)
		if ((${#optional_commands[@]} > 0)); then
			present=''
			absent=''
			for candidate in "${optional_commands[@]}"; do
				if command -v "$candidate" >/dev/null 2>&1; then
					present+="${present:+,}$candidate"
				else
					absent+="${absent:+,}$candidate"
				fi
			done
			echo "runtime image substitute inventory: present=${present:-none} absent=${absent:-none}" >&2
		fi
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
	filters="$(ffmpeg -nostdin -hide_banner -filters)"
	grep -q -F 'hevc_qsv' <<<"$encoders" || return 1
	grep -q -F 'libvmaf' <<<"$filters" || return 1
	grep -q -F 'libx265' <<<"$encoders" || return 1
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
			hevcQsv: true, libx265: true,
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
	if [[ "$test_mode" == '1' && "$role" == 'title' && -n "${BENCHMARK_TEST_TITLE_SOURCE_PROBE:-}" ]]; then
		jq -c . "$BENCHMARK_TEST_TITLE_SOURCE_PROBE"
	elif [[ "$test_mode" == '1' && "$role" == 'source' && -n "${BENCHMARK_TEST_SOURCE_PROBE:-}" ]]; then
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
	local execution_class="${2:-gpu}"
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
	if [[ "$execution_class" == 'gpu' ]]; then
		grep -q -F 'hevc_qsv' <<<"$encoders" || {
			echo 'hevc_qsv encoder is unavailable' >&2
			return 1
		}
	else
		[[ "$execution_class" == 'cpu' ]] || return 64
		grep -q -F 'libx265' <<<"$encoders" || {
			echo 'libx265 encoder is unavailable' >&2
			return 1
		}
	fi
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
	diagnostic_capabilities="$(diagnostic_capability_proof "$source")" || diagnostic_capabilities='{}'

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

run_x265_encode() {
	local input="$1"
	local output="$2"
	local setting="$3"
	local encode_log="$4"
	ffmpeg -nostdin -v verbose -i "$input" -map 0 -c:v libx265 -preset slow -crf "$setting" \
		-c:a copy -c:s copy -map_metadata 0 -map_chapters 0 "$output" >"$encode_log" 2>&1
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
	local busy_log="${15}" still_prefix="${16:-}" attempt="${17}" row_fixture="${18}"
	local run_directory logs_directory evidence_base source_probe_file output_probe_file validation_file
	local vmaf_file ssim_file psnr_file source_probe validation metrics value height='0'
	local input_bytes='0' output_bytes='0' duration='0' input_rate='0' output_rate='0'
	local reduction='0.000000' fps='0.000000' speed='0.000000' vmaf_harmonic=''
	local vmaf_low='' ssim='' psnr='' gpu_busy='' qsv_status='not-applicable' selected='CRF'
	local qsv_initialization='not-applicable' video_busy_nanoseconds='0' strategy_id="$CONTRACT_STRATEGY_ID"
	local validation_failures validation_codec validation_duration validation_resolution
	local validation_frame_rate validation_bit_depth validation_hdr validation_audio
	local validation_subtitle validation_chapters decode_status=1 proof_json progress
	local hdr_source_probe_file="${19:-}"
	local quality_source_path="${20:-}" quality_source_timestamp="${21:-}"
	local quality_vmaf='null' quality_hdr='null' quality_evidence_ref=''
	local quality_evidence_path='' quality_evidence_sha256='' quality_evidence_ready=1

	run_directory="$benchmark_out/runs/$run_id"
	logs_directory="$run_directory/logs"
	evidence_base="$sample_id-$clip_id-$encoder-$setting-attempt-$attempt"
	mkdir -p "$logs_directory"
	source_probe_file="$logs_directory/$evidence_base-source-probe.json"
	[[ -n "$hdr_source_probe_file" ]] || hdr_source_probe_file="$source_probe_file"
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
			if ! validation="$(validate_probes "$source_probe_file" "$output_probe_file" "$scope" "$decode_status" "$hdr_source_probe_file" 2>/dev/null)"; then
				validation="$(failed_validation validation-parse)"
			fi
		else
			validation="$(failed_validation output-probe)"
		fi
		if [[ "$panel" == 'quality' || "$panel" == 'x265' ]]; then
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
		if [[ -n "$still_prefix" ]] &&
			! "$script_directory/stills.sh" "$reference" "$output" '00:00:00.000' "$still_prefix"; then
			validation="$(add_validation_failure "$validation" stills)"
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
	local mode="$1"
	local commands='[]' setting
	local -a settings
	if [[ "$mode" == 'quality' ]]; then
		commands="$(jq -n -c '["ffmpeg -nostdin -v error -ss <timestamp> -i <source> -t 90 -map 0 -c copy <clip>"]')"
		read -r -a settings <<<"$CONTRACT_ICQ_SETTINGS"
	elif [[ "$mode" == 'diagnostics' ]]; then
		commands="$(diagnostic_encoder_command_identities)" || return
	elif [[ "$mode" == 'x265' ]]; then
		commands="$(jq -n -c '["ffmpeg -nostdin -v error -ss <timestamp> -i <source> -t 90 -map 0 -c copy <clip>"]')"
		for ((setting = 10; setting <= 34; setting += 2)); do
			commands="$(jq -c --arg command \
				"ffmpeg -nostdin -v verbose -i <input> -map 0 -c:v libx265 -preset slow -crf $setting -c:a copy -c:s copy -map_metadata 0 -map_chapters 0 <output>" \
				'. + [$command]' <<<"$commands")"
		done
	else
		if [[ "$mode" == 'finalist' ]]; then
			mapfile -t settings < <(jq -r '.chosenSettings[]? | select(.state == "provisional") | .globalQuality' "$samples_file" | sort -nu)
		else
			mapfile -t settings < <(jq -r '.chosenSettings[]? | select(.state == "final") | .globalQuality' "$samples_file" | sort -nu)
		fi
	fi
	for setting in "${settings[@]}"; do
		contract_is_icq_setting "$samples_file" "$setting" || continue
		commands="$(jq -c --arg command \
			"ffmpeg -nostdin -v verbose -init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw -i <input> -map 0 -c:v hevc_qsv -preset veryslow -global_quality $setting -look_ahead 0 -extbrc 0 -c:a copy -c:s copy -map_metadata 0 -map_chapters 0 <output>" \
			'. + [$command]' <<<"$commands")"
	done
	printf '%s\n' "$commands"
}

encode_one_variant() {
	local run_id="$1" panel="$2" sample_id="$3" cohort="$4" sha="$5" clip_id="$6"
	local encoder="$7" setting="$8" input="$9" scope="${10}" still_prefix="${11:-}"
	local disposition="${12:-record}" run_directory results attempt evidence_base
	local hdr_source_probe_file="${13:-}" quality_source_path="${14:-}" quality_source_timestamp="${15:-}"
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
	if [[ "$encoder" == 'qsv' ]]; then
		run_qsv_encode "$input" "$output" "$setting" "$encode_log" "$busy_log" || status=$?
	else
		: >"$busy_log"
		run_x265_encode "$input" "$output" "$setting" "$encode_log" || status=$?
	fi
	end="$(now_nanoseconds)"
	wall="$(awk -v start="$start" -v end="$end" 'BEGIN { printf "%.6f", (end - start) / 1000000000 }')"
	process_variant "$run_id" "$panel" "$sample_id" "$cohort" "$sha" "$clip_id" \
		"$encoder" "$setting" "$input" "$output" "$scope" "$status" "$wall" \
		"$encode_log" "$busy_log" "$still_prefix" "$attempt" "$row_fixture" "$hdr_source_probe_file" \
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

append_comparison_once() {
	local output="$1" comparison="$2" quality_run="$3" x265_run="$4" sample_id="$5"
	local clip_id="$6" setting="$7" allowed_clips="$8" staged
	staged="$output.$$.tmp"
	rm -f -- "$staged"
	jq -e -n --argjson row "$comparison" --arg strategy "$CONTRACT_STRATEGY_ID" \
		--arg quality "$quality_run" --arg x265 "$x265_run" --arg sample "$sample_id" \
		--arg clip "$clip_id" --argjson setting "$setting" --argjson clips "$allowed_clips" '
		def bounded_crf:
			type == "number" and floor == . and . >= 10 and . <= 34 and . % 2 == 0;
		def valid_row:
			type == "object" and
			keys == ["clipId","lowerCrf","matchedBitRate","premiumPercent","qsvSetting",
				"qualityRunId","sampleId","status","strategyId","upperCrf","x265RunId"] and
			.strategyId == $strategy and .qualityRunId == $quality and .x265RunId == $x265 and
			.sampleId == $sample and (.clipId as $value | $clips | index($value) != null) and
			.qsvSetting == $setting and
			if .status == "bracketed" then
				(.lowerCrf | bounded_crf) and (.upperCrf | bounded_crf) and
				(.matchedBitRate | type == "number" and . > 0) and
				(.premiumPercent | type == "number")
			elif .status == "unbracketed" then
				.lowerCrf == null and .upperCrf == null and .matchedBitRate == null and .premiumPercent == null
			else false end;
		($clips | type == "array" and length == 3 and all(.[]; type == "string")) and
		($row | valid_row) and $row.clipId == $clip
	' >/dev/null || return 65
	if [[ -e "$output" || -L "$output" ]]; then
		[[ -f "$output" && ! -L "$output" ]] || return 65
		jq -e -s --arg strategy "$CONTRACT_STRATEGY_ID" --arg quality "$quality_run" \
			--arg x265 "$x265_run" --arg sample "$sample_id" --argjson setting "$setting" \
			--argjson clips "$allowed_clips" '
			def bounded_crf:
				type == "number" and floor == . and . >= 10 and . <= 34 and . % 2 == 0;
			def valid_row:
				type == "object" and
				keys == ["clipId","lowerCrf","matchedBitRate","premiumPercent","qsvSetting",
					"qualityRunId","sampleId","status","strategyId","upperCrf","x265RunId"] and
				.strategyId == $strategy and .qualityRunId == $quality and .x265RunId == $x265 and
				.sampleId == $sample and (.clipId as $value | $clips | index($value) != null) and
				.qsvSetting == $setting and
				if .status == "bracketed" then
					(.lowerCrf | bounded_crf) and (.upperCrf | bounded_crf) and
					(.matchedBitRate | type == "number" and . > 0) and
					(.premiumPercent | type == "number")
				elif .status == "unbracketed" then
					.lowerCrf == null and .upperCrf == null and .matchedBitRate == null and .premiumPercent == null
				else false end;
			length as $count |
			all(.[]; valid_row) and
			([.[] | [.sampleId,.clipId,.qsvSetting] | @json] | unique | length) == $count
		' "$output" >/dev/null || return 65
		jq -c --arg sample "$sample_id" --arg clip "$clip_id" --argjson setting "$setting" '
			select(.sampleId != $sample or .clipId != $clip or .qsvSetting != $setting)
		' "$output" >"$staged" || {
			rm -f -- "$staged"
			return 65
		}
	else
		: >"$staged"
	fi
	printf '%s\n' "$comparison" >>"$staged" || {
		rm -f -- "$staged"
		return 74
	}
	mv -f -- "$staged" "$output"
}

rank_quality_candidates() {
	local results="$1" candidate_samples="$2" run_id="$3"
	local run_directory artifact staged rows expected settings expected_keys digest candidates
	local probe_source probe_clip durable_status diagnostic_status
	if [[ ! -v CONTRACT_ICQ_SETTINGS ]]; then
		contract_load "$candidate_samples" || return
	fi
	set +e
	diagnostic_results_input_rejected "$results"
	diagnostic_status=$?
	set -e
	if [[ "$diagnostic_status" == '65' ]]; then
		return 65
	elif [[ "$diagnostic_status" != '1' && "$diagnostic_status" != '66' ]]; then
		return "$diagnostic_status"
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
				reduction_percent: $columns[13], vmaf_harmonic_mean: $columns[19],
				vmaf_1pct_low: $columns[20], ssim: $columns[21], qsv_proof: $columns[23],
				validation_codec: $columns[24], validation_duration: $columns[25],
				validation_resolution: $columns[26], validation_frame_rate: $columns[27],
				validation_bit_depth: $columns[28], validation_hdr: $columns[29],
				validation_audio_tracks: $columns[30], validation_subtitle_tracks: $columns[31],
				validation_chapters: $columns[32], validation_failures: $columns[33],
				strategy_id: $columns[36], qsv_initialization: $columns[37],
				video_busy_nanoseconds: $columns[38]
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
	probe_source="$(jq -e -r '.[0].source_sha256 | strings' <<<"$expected")" || return 65
	probe_clip="$(jq -e -r '.[0].clip_id | strings' <<<"$expected")" || return 65
	set +e
	"$script_directory/runmeta.sh" completed "$run_id" "quality|$probe_source|$probe_clip|qsv|16" >/dev/null
	durable_status=$?
	set -e
	[[ "$durable_status" == '0' || "$durable_status" == '1' ]] || return "$durable_status"
	expected_keys="$(jq -r '[.[] | [.cohort, .sample_id, .source_sha256, .clip_id] | join("|")] | join("\u001c")' <<<"$expected")"
	awk -F, -v run_id="$run_id" -v settings="$CONTRACT_ICQ_SETTINGS" -v expected="$expected_keys" '
		BEGIN {
			count = split(expected, values, "\034")
			for (item = 1; item <= count; item++) known[values[item]] = 1
		}
		NR > 1 {
			key = $4 "|" $3 "|" $5 "|" $6
			if ($1 != run_id || $2 != "quality" || $7 != "qsv" || $8 !~ /^[0-9]+$/ ||
				index(" " settings " ", " " $8 " ") == 0 ||
				!(key in known)) exit 65
		}
	' "$results" || {
		echo 'invalid quality results row' >&2
		return 65
	}
	digest="$(sha256sum "$results" | awk '{print $1}')"
	[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 65
	candidates="$(jq -n -c \
		--arg run_id "$run_id" --arg strategy "$CONTRACT_STRATEGY_ID" \
		--arg digest "sha256:$digest" \
		--argjson schema "$CONTRACT_RESULTS_SCHEMA" \
		--slurpfile rows_input <(printf '%s\n' "$rows") \
		--slurpfile expected_input <(printf '%s\n' "$expected") \
		--slurpfile settings_input <(printf '%s\n' "$settings") '
		($rows_input[0]) as $rows |
		($expected_input[0]) as $expected |
		($settings_input[0]) as $settings |
		def numeric_at_least($minimum):
			(tonumber?) as $number |
			$number != null and ($number == $number) and ($number != infinite) and $number >= $minimum;
		def numeric: numeric_at_least(-infinite);
		def median:
			sort as $values | ($values | length) as $count |
			if ($count % 2) == 1 then $values[($count / 2 | floor)]
			else (($values[($count / 2 - 1 | floor)] + $values[($count / 2 | floor)]) / 2)
			end;
		def objective_passes:
			.status == "passed" and .selected_rate_control == "ICQ" and
			.qsv_proof == "passed" and .qsv_initialization == "passed" and
			(.video_busy_nanoseconds | test("^[0-9]+$") and tonumber > 0) and
			(.validation_codec == "passed" and .validation_duration == "passed" and
			 .validation_resolution == "passed" and .validation_frame_rate == "passed" and
			 .validation_bit_depth == "passed" and .validation_hdr == "passed" and
			 .validation_audio_tracks == "passed" and .validation_subtitle_tracks == "passed" and
			 .validation_chapters == "passed") and .validation_failures == "" and
			(.vmaf_harmonic_mean | numeric_at_least(95)) and
			(.vmaf_1pct_low | numeric_at_least(90)) and
			(.reduction_percent | numeric) and .strategy_id == $strategy;
		def expected_keys: map([.sample_id, .clip_id]) | sort;
		{
			schemaVersion: 1, strategyId: $strategy, qualityRunId: $run_id,
			resultsSchemaVersion: $schema, resultsSha256: $digest,
			cohorts: (reduce ["avc", "vc1", "hdr10"][] as $cohort ({};
				($expected | map(select(.cohort == $cohort))) as $cohort_expected |
				([ $settings[] as $setting |
					([ $rows[] | select(
						.run_id == $run_id and .panel == "quality" and .cohort == $cohort and
						.encoder == "qsv" and .requested_setting == ($setting | tostring)
					)] ) as $group |
					select(($cohort_expected | length) > 0 and
						($group | length) == ($cohort_expected | length) and
						($group | map([.sample_id, .clip_id]) | sort) == ($cohort_expected | expected_keys) and
						($group | all(objective_passes))) |
					{globalQuality: $setting, medianReductionPercent: ($group | map(.reduction_percent | tonumber) | median)}
				] | sort_by(-.medianReductionPercent, .globalQuality)) as $eligible |
				.[$cohort] = if ($eligible | length) > 0 then {
					status: "eligible", expectedClipCount: ($cohort_expected | length), candidates: $eligible
				} else {
					status: "no-go", expectedClipCount: ($cohort_expected | length), candidates: [],
					reason: "no-objective-candidate"
				} end
			))
		}
	')" || return 65
	staged="$(mktemp "$run_directory/.quality-candidates.XXXXXX")" || return
	if ! jq -e . <<<"$candidates" >"$staged"; then
		rm -f -- "$staged"
		return 65
	fi
	mv -f -- "$staged" "$artifact"
}

prepare_chosen_upstream() {
	local cohort="$1" required_state="$2" record quality_run quality_directory manifest results candidates
	local actual_results_digest actual_candidates_digest actual_manifest_digest expected_header upstream selected
	local manifest_identity created_at identity_suffix
	local out_physical runs_physical quality_physical
	record="$(contract_chosen_record "$samples_file" "$cohort" "$required_state")" || {
		echo "chosen setting for $cohort is not authorized for state: $required_state" >&2
		return 65
	}
	quality_run="$(jq -r '.qualityRunId' <<<"$record")"
	quality_directory="$benchmark_out/runs/$quality_run"
	manifest="$quality_directory/manifest.json"
	results="$quality_directory/results.csv"
	candidates="$quality_directory/quality-candidates.json"
	[[ -d "$benchmark_out" && ! -L "$benchmark_out" &&
		-d "$benchmark_out/runs" && ! -L "$benchmark_out/runs" &&
		-d "$quality_directory" && ! -L "$quality_directory" &&
		-f "$manifest" && ! -L "$manifest" && -f "$results" && ! -L "$results" &&
		-f "$candidates" && ! -L "$candidates" ]] || {
		echo "chosen setting upstream evidence is unavailable for cohort: $cohort" >&2
		return 66
	}
	out_physical="$(cd -P "$benchmark_out" && pwd)"
	runs_physical="$(cd -P "$benchmark_out/runs" && pwd)"
	quality_physical="$(cd -P "$quality_directory" && pwd)"
	[[ "$runs_physical" == "$out_physical/runs" && "$quality_physical" == "$runs_physical/$quality_run" ]] || {
		echo "chosen setting upstream evidence escapes the output hierarchy for cohort: $cohort" >&2
		return 65
	}
	manifest_identity="$(jq -e -c 'if type == "object" and has("createdAt") then del(.createdAt)
		else error("invalid quality manifest") end' "$manifest")" || {
		echo "chosen setting quality manifest identity is invalid for cohort: $cohort" >&2
		return 65
	}
	jq -e '.mode == "quality"' <<<"$manifest_identity" >/dev/null || {
		echo "chosen setting quality manifest identity is invalid for cohort: $cohort" >&2
		return 65
	}
	manifest_identity="$(contract_normalize_run_identity "$manifest_identity" quality)" || {
		echo "chosen setting quality manifest identity is invalid for cohort: $cohort" >&2
		return 65
	}
	created_at="$(jq -e -r '.createdAt | strings' "$manifest")" || return 65
	contract_is_compact_utc_timestamp "$created_at" || {
		echo "chosen setting quality manifest timestamp is invalid for cohort: $cohort" >&2
		return 65
	}
	[[ "$created_at" == "${quality_run%-*}" ]] || {
		echo "chosen setting quality manifest timestamp does not match run for cohort: $cohort" >&2
		return 65
	}
	identity_suffix="$(printf '%s\n' "$manifest_identity" | sha256sum | awk '{print substr($1, 1, 8)}')"
	[[ "$identity_suffix" == "${quality_run##*-}" ]] || {
		echo "chosen setting quality manifest identity does not match run for cohort: $cohort" >&2
		return 65
	}
	IFS= read -r expected_header <"$results" || true
	[[ "$expected_header" == "$results_header" ]] || {
		echo "chosen setting quality results schema is invalid for cohort: $cohort" >&2
		return 65
	}
	awk -F, -v run="$quality_run" -v strategy="$CONTRACT_STRATEGY_ID" '
		NR > 1 {
			rows += 1
			if (NF != 41 || $1 != run || $2 != "quality" || $37 != strategy) exit 65
		}
		END {if (rows < 1) exit 65}
	' "$results" || {
		echo "chosen setting quality results identity is invalid for cohort: $cohort" >&2
		return 65
	}
	actual_results_digest="sha256:$(sha256sum "$results" | awk '{print $1}')"
	actual_candidates_digest="sha256:$(sha256sum "$candidates" | awk '{print $1}')"
	actual_manifest_digest="sha256:$(sha256sum "$manifest" | awk '{print $1}')"
	[[ "$actual_results_digest" == "$(jq -r '.qualityResultsSha256' <<<"$record")" &&
	"$actual_candidates_digest" == "$(jq -r '.candidateEvidenceSha256' <<<"$record")" ]] || {
		echo "chosen setting upstream digest is stale for cohort: $cohort" >&2
		return 65
	}
	jq -e --arg cohort "$cohort" --arg run "$quality_run" --arg strategy "$CONTRACT_STRATEGY_ID" \
		--arg digest "$actual_results_digest" --argjson schema "$CONTRACT_RESULTS_SCHEMA" \
		--argjson record "$record" '
		.schemaVersion == 1 and .strategyId == $strategy and .qualityRunId == $run and
		.resultsSchemaVersion == $schema and .resultsSha256 == $digest and
		(.cohorts | type == "object") and
		(.cohorts[$cohort] | type == "object" and .status == "eligible" and
			(.candidates | type == "array" and length >= 1 and length <= 8 and
				all(.[];
					(type == "object" and keys == ["globalQuality","medianReductionPercent"] and
					 (.globalQuality | type == "number" and floor == .) and
					 (.globalQuality as $value | [16,18,20,22,24,26,28,30] | index($value) != null) and
					 (.medianReductionPercent | type == "number"))) and
				([.[].globalQuality] | unique | length) == length)) and
		(.cohorts[$cohort].candidates | map(.globalQuality)) as $ranked |
		($record.rejectedSettings | map(.globalQuality)) as $rejected |
		$rejected == $ranked[0:($rejected | length)] and
		if $record.state == "rejected" then
			($rejected | length) == ($ranked | length) and $record.globalQuality == $ranked[-1]
		else
			($rejected | length) < ($ranked | length) and
			$record.globalQuality == $ranked[($rejected | length)]
		end
	' "$candidates" >/dev/null || {
		echo "chosen setting rejected history is not the ranked candidate prefix for cohort: $cohort" >&2
		return 65
	}
	upstream="$(jq -n -c --arg cohort "$cohort" --argjson chosen "$record" \
		--arg manifest "$actual_manifest_digest" --arg results "$actual_results_digest" \
		--arg candidates "$actual_candidates_digest" '{
			cohort:$cohort, chosenSetting:$chosen, qualityManifestSha256:$manifest,
			qualityResultsSha256:$results, candidateEvidenceSha256:$candidates
		}')"
	selected="$(jq -n -c --arg cohort "$cohort" --argjson chosen "$record" \
		'[{cohort:$cohort,globalQuality:$chosen.globalQuality,qualityRunId:$chosen.qualityRunId}]')"
	BENCHMARK_UPSTREAM_IDENTITY_JSON="$upstream"
	BENCHMARK_SELECTED_SETTINGS_JSON="$selected"
	export BENCHMARK_UPSTREAM_IDENTITY_JSON BENCHMARK_SELECTED_SETTINGS_JSON
}

quality_mode() {
	local explicit_run_id="${1:-}" run_id run_directory run_scratch sample sample_id cohort
	local source sha detection title_probe_file clip_id timestamp clip
	local setting rank_status
	local panel_samples
	local -a qsv_settings
	read -r -a qsv_settings <<<"$CONTRACT_ICQ_SETTINGS"
	reject_diagnostics_resume_run_id quality "$explicit_run_id" || return
	assigned_node_capability_gate || return
	panel_samples="$(jq -c '[.qualityPanel[]?]' "$samples_file")"
	runtime_pre_encode_gate "$panel_samples" || return
	BENCHMARK_ENCODER_COMMANDS_JSON="$(encoder_commands_for_mode quality)"
	export BENCHMARK_ENCODER_COMMANDS_JSON
	if [[ -n "$explicit_run_id" ]]; then
		run_id="$("$script_directory/runmeta.sh" create quality "$explicit_run_id")"
	else
		run_id="$("$script_directory/runmeta.sh" create quality)"
	fi
	run_directory="$benchmark_out/runs/$run_id"
	run_scratch="$scratch_root/$run_id"
	mkdir -p "$run_directory/logs" "$run_directory/stills" "$run_scratch"
	while IFS= read -r sample; do
		sample_id="$(jq -r '.id' <<<"$sample")"
		cohort="$(jq -r '.cohort' <<<"$sample")"
		source="$(jq -r '.path' <<<"$sample")"
		sha="$(jq -r '.sha256' <<<"$sample")"
		detection="$(jq -r '.detectionOnly // false' <<<"$sample")"
		if [[ "$detection" == 'true' || "$cohort" == 'dolby-vision' ]]; then
			printf '%s,%s,detection-only\n' "$sample_id" "$cohort" >>"$run_directory/skips.csv"
			continue
		fi
		title_probe_file="$run_directory/logs/$sample_id-title-source-probe.json"
		if ! probe_media title "$source" >"$title_probe_file" 2>/dev/null; then
			printf '%s\n' '{}' >"$title_probe_file"
		fi
		while IFS=$'\t' read -r clip_id timestamp; do
			clip="$run_scratch/$sample_id-$clip_id-source.mkv"
			ffmpeg -nostdin -v error -ss "$timestamp" -i "$source" -t 90 -map 0 -c copy "$clip"
			for setting in "${qsv_settings[@]}"; do
				if row_is_complete "$run_id" quality "$sha" "$clip_id" qsv "$setting"; then continue; fi
				encode_one_variant "$run_id" quality "$sample_id" "$cohort" "$sha" "$clip_id" \
					qsv "$setting" "$clip" clip \
					"$run_directory/stills/$sample_id-$clip_id-qsv-$setting" record "$title_probe_file" \
					"$source" "$timestamp" >/dev/null
			done
			rm -f -- "$clip"
		done < <(jq -r '.clips | to_entries[] | [.key, .value] | @tsv' <<<"$sample")
	done < <(jq -c '.qualityPanel[]?' "$samples_file")
	rank_quality_candidates "$run_directory/results.csv" "$samples_file" "$run_id" || rank_status=$?
	rm -rf -- "$run_scratch"
	((${rank_status:-0} == 0)) || return "$rank_status"
	if [[ -n "${BENCHMARK_DISPATCH_CORRELATION_ID:-}" ]]; then
		jq -n -c --arg dispatch "$BENCHMARK_DISPATCH_CORRELATION_ID" --arg runtime "$run_id" \
			--arg strategy "$CONTRACT_STRATEGY_ID" '{
				schemaVersion:1, strategyId:$strategy, status:"complete",
				dispatchId:$dispatch, runtimeRunId:$runtime,
				artifactLocation:("/out/runs/" + $runtime)
			}'
	else
		printf '%s\n' "$run_id"
	fi
}

quality_target_for_clip() {
	local quality_run="$1" sample_id="$2" cohort="$3" source_sha="$4" clip_id="$5" setting="$6"
	local results="$benchmark_out/runs/$quality_run/results.csv"
	awk -F, -v run="$quality_run" -v sample="$sample_id" -v cohort="$cohort" -v sha="$source_sha" \
		-v clip="$clip_id" -v setting="$setting" -v strategy="$CONTRACT_STRATEGY_ID" '
		NR > 1 && NF == 41 && $1 == run && $2 == "quality" && $3 == sample &&
			$4 == cohort && $5 == sha && $6 == clip && $7 == "qsv" && $8 == setting &&
			$9 == "ICQ" && $10 == "passed" && $16 ~ /^[0-9]+([.][0-9]+)?$/ && $16 + 0 > 0 &&
			$20 ~ /^[0-9]+([.][0-9]+)?$/ && $24 == "passed" &&
			$25 == "passed" && $26 == "passed" && $27 == "passed" && $28 == "passed" &&
			$29 == "passed" && $30 == "passed" && $31 == "passed" && $32 == "passed" &&
			$33 == "passed" && $34 == "" && $37 == strategy && $38 == "passed" &&
			$39 ~ /^[0-9]+$/ && $39 + 0 > 0 {
			count += 1
			vmaf = $20
			bit_rate = $16
		}
		END {
			if (count != 1) exit 65
			printf "{\"qsvVmaf\":%s,\"qsvBitRate\":%s}\n", vmaf, bit_rate
		}
	' "$results" || {
		echo "selected ICQ quality result is missing or invalid: $sample_id/$clip_id" >&2
		return 65
	}
}

x265_curve_fixture() {
	local results="$1" run_id="$2" sample_id="$3" source_sha="$4" clip_id="$5" target="$6"
	local points attempted
	points="$(awk -F, -v run="$run_id" -v sample="$sample_id" -v sha="$source_sha" -v clip="$clip_id" \
		-v strategy="$CONTRACT_STRATEGY_ID" '
		NR > 1 && NF == 41 && $1 == run && $2 == "x265" && $3 == sample && $5 == sha && $6 == clip &&
			$7 == "x265" && $8 ~ /^[0-9]+$/ && $8 >= 10 && $8 <= 34 && $8 % 2 == 0 &&
			$9 == "CRF" && $10 == "passed" && $16 ~ /^[0-9]+([.][0-9]+)?$/ && $16 + 0 > 0 &&
			$20 ~ /^[0-9]+([.][0-9]+)?$/ && $21 ~ /^[0-9]+([.][0-9]+)?$/ && $22 == "" && $23 == "" &&
			$24 == "not-applicable" && $25 == "passed" && $26 == "passed" && $27 == "passed" &&
			$28 == "passed" && $29 == "passed" && $30 == "passed" && $31 == "passed" &&
			$32 == "passed" && $33 == "passed" && $34 == "" && $36 == "discarded" && $37 == strategy &&
			$38 == "not-applicable" && $39 == "0" {
			printf "{\"crf\":%s,\"vmaf\":%s,\"bitRate\":%s}\n", $8, $20, $16
		}
	' "$results" | jq -s -c '.')" || return
	attempted="$(awk -F, -v run="$run_id" -v sample="$sample_id" -v sha="$source_sha" -v clip="$clip_id" \
		-v strategy="$CONTRACT_STRATEGY_ID" '
		NR > 1 && NF == 41 && $1 == run && $2 == "x265" && $3 == sample && $5 == sha && $6 == clip &&
			$7 == "x265" && $8 ~ /^[0-9]+$/ && $8 >= 10 && $8 <= 34 && $8 % 2 == 0 &&
			$9 == "CRF" && $37 == strategy && $38 == "not-applicable" && $39 == "0" {print $8}
	' "$results" | sort -nu | jq -R -s -c 'split("\n") | map(select(length > 0) | tonumber)')" || return
	jq -n -c --argjson target "$target" --argjson points "$points" --argjson attempted "$attempted" \
		'$target + {points:$points,attemptedCrfs:$attempted}'
}

x265_mode() (
	local requested_run_id="$1" requested_sample_id="$2" sample sample_count cohort source sha setting
	local quality_run panel_samples run_id run_directory run_scratch results comparisons title_probe_file
	local clip_id timestamp clip crf next_json action target curve curve_file match comparison completed_status allowed_clips
	local -a initial_crfs
	trap 'if [[ -n "${run_scratch:-}" ]]; then rm -rf -- "$run_scratch"; fi' EXIT
	validate_run_id "$requested_run_id" || return
	validate_sample_id "$requested_sample_id" || return
	reject_diagnostics_resume_run_id x265 "$requested_run_id" || return
	case "$requested_sample_id" in
	avc-grain-memento | hdr10-grain-goodfellas) ;;
	*)
		echo "sample is not an x265 reference: $requested_sample_id" >&2
		return 65
		;;
	esac
	sample="$(SAMPLE_ID="$requested_sample_id" jq -c \
		'.qualityPanel[]? | select(.id == env.SAMPLE_ID and .x265Reference == true and
			(.detectionOnly // false) == false and (.cohort == "avc" or .cohort == "hdr10"))' \
		"$samples_file")"
	sample_count="$(wc -l <<<"$sample" | tr -d ' ')"
	[[ -n "$sample" && "$sample_count" == '1' ]] || {
		echo "sample is not an x265 reference: $requested_sample_id" >&2
		return 65
	}
	cohort="$(jq -r '.cohort' <<<"$sample")"
	prepare_chosen_upstream "$cohort" final || return
	setting="$(jq -r '.chosenSetting.globalQuality' <<<"$BENCHMARK_UPSTREAM_IDENTITY_JSON")"
	quality_run="$(jq -r '.chosenSetting.qualityRunId' <<<"$BENCHMARK_UPSTREAM_IDENTITY_JSON")"
	panel_samples="$(jq -n -c --argjson sample "$sample" '[$sample]')"
	runtime_pre_encode_gate "$panel_samples" cpu || return
	BENCHMARK_EXECUTION_CLASS=cpu
	BENCHMARK_X265_SAMPLE_ID="$requested_sample_id"
	BENCHMARK_ENCODER_COMMANDS_JSON="$(encoder_commands_for_mode x265)"
	export BENCHMARK_EXECUTION_CLASS BENCHMARK_X265_SAMPLE_ID BENCHMARK_ENCODER_COMMANDS_JSON
	run_id="$("$script_directory/runmeta.sh" create x265 "$requested_run_id")" || return
	run_directory="$benchmark_out/runs/$run_id"
	run_scratch="$scratch_root/$run_id"
	results="$run_directory/results.csv"
	comparisons="$run_directory/x265-comparisons.jsonl"
	mkdir -p "$run_directory/logs" "$run_scratch"
	ensure_results_file "$results"
	source="$(jq -r '.path' <<<"$sample")"
	sha="$(jq -r '.sha256' <<<"$sample")"
	allowed_clips="$(jq -c '.clips | keys' <<<"$sample")" || return
	title_probe_file="$run_directory/logs/$requested_sample_id-title-source-probe.json"
	if ! probe_media title "$source" >"$title_probe_file" 2>/dev/null; then
		printf '%s\n' '{}' >"$title_probe_file"
	fi
	mapfile -t initial_crfs < <(jq -r '.strategy.x265.initialCrfs[]' "$samples_file")
	while IFS=$'\t' read -r clip_id timestamp; do
		target="$(quality_target_for_clip "$quality_run" "$requested_sample_id" "$cohort" "$sha" "$clip_id" "$setting")" || return
		clip="$run_scratch/$requested_sample_id-$clip_id-source.mkv"
		curve_file="$run_scratch/$requested_sample_id-$clip_id-curve.json"
		ffmpeg -nostdin -v error -ss "$timestamp" -i "$source" -t 90 -map 0 -c copy "$clip"
		for crf in "${initial_crfs[@]}"; do
			completed_status=0
			row_is_complete "$run_id" x265 "$sha" "$clip_id" x265 "$crf" || completed_status=$?
			case "$completed_status" in
			0) continue ;;
			1)
				encode_one_variant "$run_id" x265 "$requested_sample_id" "$cohort" "$sha" "$clip_id" \
					x265 "$crf" "$clip" clip '' record "$title_probe_file" >/dev/null
				;;
			*) return "$completed_status" ;;
			esac
		done
		while :; do
			curve="$(x265_curve_fixture "$results" "$run_id" "$requested_sample_id" "$sha" "$clip_id" "$target")" || return
			printf '%s\n' "$curve" >"$curve_file"
			next_json="$(x265_next "$curve_file")" || return
			action="$(jq -r '.status' <<<"$next_json")"
			[[ "$action" == 'extend' ]] || break
			crf="$(jq -r '.next_crf' <<<"$next_json")"
			completed_status=0
			row_is_complete "$run_id" x265 "$sha" "$clip_id" x265 "$crf" || completed_status=$?
			if ((completed_status == 1)); then
				encode_one_variant "$run_id" x265 "$requested_sample_id" "$cohort" "$sha" "$clip_id" \
					x265 "$crf" "$clip" clip '' record "$title_probe_file" >/dev/null
			elif ((completed_status != 0)); then return "$completed_status"; fi
		done
		curve="$(x265_curve_fixture "$results" "$run_id" "$requested_sample_id" "$sha" "$clip_id" "$target")" || return
		printf '%s\n' "$curve" >"$curve_file"
		match="$(x265_match "$curve_file")" || return
		comparison="$(jq -n -c --arg strategy "$CONTRACT_STRATEGY_ID" --arg quality "$quality_run" \
			--arg x265 "$run_id" --arg sample "$requested_sample_id" --arg clip "$clip_id" \
			--argjson setting "$setting" --argjson matched "$match" '{
				strategyId:$strategy,qualityRunId:$quality,x265RunId:$x265,sampleId:$sample,
				clipId:$clip,qsvSetting:$setting,status:$matched.status,
				lowerCrf:($matched.lower_crf // null),upperCrf:($matched.upper_crf // null),
				matchedBitRate:($matched.matched_bit_rate // null),premiumPercent:($matched.premium_percent // null)
			}')" || return
		append_comparison_once "$comparisons" "$comparison" "$quality_run" "$run_id" \
			"$requested_sample_id" "$clip_id" "$setting" "$allowed_clips" || return
		rm -f -- "$clip" "$curve_file"
	done < <(jq -r '.clips | to_entries[] | [.key, .value] | @tsv' <<<"$sample")
	printf '%s\n' "$run_id"
)

savings_mode() {
	local requested_run_id="$1" run_id run_directory run_scratch sample sample_id cohort
	local source sha setting packets probe_file detection prepared row_fixture output
	local failed_row inventory_status
	local panel_samples final_cohorts panel_cohorts cohort_name selected_record selected_state
	local upstream_map='{}' selected_settings='[]' cohort_applicability='{}' final_records='{}' artifact_staged
	final_cohorts='[]'
	reject_diagnostics_resume_run_id savings "$requested_run_id" || return
	panel_cohorts="$(jq -e -c '[.savingsPanel[]?.cohort | select(. == "avc" or . == "vc1" or . == "hdr10")] | unique' "$samples_file")" || return 65
	for cohort_name in avc vc1 hdr10; do
		selected_state=''
		if jq -e --arg cohort "$cohort_name" '
			.chosenSettings[$cohort] | type == "object" and .state == "final"
		' "$samples_file" >/dev/null; then
			selected_record="$(contract_chosen_record "$samples_file" "$cohort_name" final)" || {
				echo "claimed final chosen setting is malformed for cohort: $cohort_name" >&2
				return 65
			}
			[[ "$(jq -r --arg cohort "$cohort_name" 'index($cohort) != null' <<<"$panel_cohorts")" == 'true' ]] || {
				echo "savings panel omits final cohort: $cohort_name" >&2
				return 65
			}
			selected_state='final'
		else
			selected_record="$(contract_chosen_record "$samples_file" "$cohort_name" 2>/dev/null || true)"
		fi
		if [[ -z "$selected_record" ]]; then
			cohort_applicability="$(jq -c --arg cohort "$cohort_name" \
				'. + {($cohort):{status:"not-applicable",reason:"no-final-setting"}}' \
				<<<"$cohort_applicability")"
			continue
		fi
		[[ "${selected_state:-}" == 'final' ]] || selected_state="$(jq -r '.state' <<<"$selected_record")"
		case "$selected_state" in
		final)
			final_cohorts="$(jq -c --arg cohort "$cohort_name" '. + [$cohort]' <<<"$final_cohorts")"
			final_records="$(jq -c --arg cohort "$cohort_name" --argjson record "$selected_record" \
				'. + {($cohort):$record}' <<<"$final_records")"
			cohort_applicability="$(jq -c --arg cohort "$cohort_name" \
				--argjson quality "$(jq '.globalQuality' <<<"$selected_record")" \
				'. + {($cohort):{status:"measured",globalQuality:$quality}}' \
				<<<"$cohort_applicability")"
			;;
		rejected)
			cohort_applicability="$(jq -c --arg cohort "$cohort_name" \
				'. + {($cohort):{status:"not-applicable",reason:"visual-no-go"}}' \
				<<<"$cohort_applicability")"
			;;
		provisional)
			cohort_applicability="$(jq -c --arg cohort "$cohort_name" \
				'. + {($cohort):{status:"not-applicable",reason:"visual-pending"}}' \
				<<<"$cohort_applicability")"
			;;
		*)
			echo "chosen setting has an invalid state for cohort: $cohort_name" >&2
			return 65
			;;
		esac
	done
	[[ "$(jq -r 'length' <<<"$final_cohorts")" -gt 0 ]] || {
		echo 'no final chosen setting authorizes savings' >&2
		return 65
	}
	while IFS= read -r cohort_name; do
		selected_record="$(jq -e -c --arg cohort "$cohort_name" '.[$cohort]' <<<"$final_records")" || return 65
		prepare_chosen_upstream "$cohort_name" final || return
		upstream_map="$(jq -c --arg cohort "$cohort_name" --argjson identity "$BENCHMARK_UPSTREAM_IDENTITY_JSON" \
			'. + {($cohort):$identity}' <<<"$upstream_map")"
		selected_settings="$(jq -c --argjson selected "$BENCHMARK_SELECTED_SETTINGS_JSON" '. + $selected' \
			<<<"$selected_settings")"
	done < <(jq -r '.[]' <<<"$final_cohorts")
	BENCHMARK_UPSTREAM_IDENTITY_JSON="$(jq -n -c --argjson chosen "$upstream_map" '{chosenSettings:$chosen}')"
	BENCHMARK_SELECTED_SETTINGS_JSON="$selected_settings"
	BENCHMARK_SAVINGS_COHORTS_JSON="$final_cohorts"
	export BENCHMARK_UPSTREAM_IDENTITY_JSON BENCHMARK_SELECTED_SETTINGS_JSON BENCHMARK_SAVINGS_COHORTS_JSON
	assigned_node_capability_gate || return
	panel_samples="$(jq -c --argjson cohorts "$final_cohorts" '[.savingsPanel[]? | select(.cohort as $cohort | ($cohorts | index($cohort)) != null)]' "$samples_file")"
	runtime_pre_encode_gate "$panel_samples" || return
	BENCHMARK_ENCODER_COMMANDS_JSON="$(encoder_commands_for_mode savings)"
	export BENCHMARK_ENCODER_COMMANDS_JSON
	run_id="$("$script_directory/runmeta.sh" create savings "$requested_run_id")"
	run_directory="$benchmark_out/runs/$run_id"
	run_scratch="$scratch_root/$run_id"
	artifact_staged="$(mktemp "$run_directory/.savings-cohorts.XXXXXX")" || return
	if ! jq -n -S -c --arg run_id "$run_id" --arg strategy "$CONTRACT_STRATEGY_ID" \
		--argjson cohorts "$cohort_applicability" \
		'{schemaVersion:1,strategyId:$strategy,runId:$run_id,cohorts:$cohorts}' >"$artifact_staged"; then
		rm -f -- "$artifact_staged"
		return 65
	fi
	mv -f -- "$artifact_staged" "$run_directory/savings-cohorts.json"
	mkdir -p "$run_directory/logs" "$run_scratch"
	while IFS= read -r sample; do
		sample_id="$(jq -r '.id' <<<"$sample")"
		cohort="$(jq -r '.cohort' <<<"$sample")"
		source="$(jq -r '.path' <<<"$sample")"
		sha="$(jq -r '.sha256' <<<"$sample")"
		detection="$(jq -r '.detectionOnly // false' <<<"$sample")"
		if [[ "$detection" == 'true' || "$cohort" == 'dolby-vision' ]]; then
			printf '%s,%s,detection-only\n' "$sample_id" "$cohort" >>"$run_directory/skips.csv"
			continue
		fi
		setting="$(contract_chosen_record "$samples_file" "$cohort" final | jq -r '.globalQuality // ""')" || continue
		contract_is_icq_setting "$samples_file" "$setting" || continue
		if row_is_complete "$run_id" savings "$sha" full qsv "$setting"; then continue; fi
		prepared="$(encode_one_variant "$run_id" savings "$sample_id" "$cohort" "$sha" full \
			qsv "$setting" "$source" full '' defer)"
		IFS='|' read -r row_fixture output <<<"$prepared"
		packets="$run_scratch/$sample_id-audio-packets.csv"
		probe_file="$run_scratch/$sample_id-source-probe.json"
		inventory_status=0
		ffprobe -show_packets -select_streams a -show_entries packet=stream_index,size \
			-of csv=p=0 "$source" >"$packets" || inventory_status=$?
		if ((inventory_status == 0)); then
			probe_media source "$source" >"$probe_file" 2>/dev/null || inventory_status=$?
		fi
		if ((inventory_status == 0)); then
			append_audio_inventory "$packets" "$probe_file" "$run_directory/audio-inventory.csv" || inventory_status=$?
		fi
		if ((inventory_status != 0)); then
			failed_row="$row_fixture.inventory-failed"
			jq -c '
				.encode_status = "1" |
				.validation_codec = "failed" | .validation_duration = "failed" |
				.validation_resolution = "failed" | .validation_frame_rate = "failed" |
				.validation_bit_depth = "failed" | .validation_hdr = "failed" |
				.validation_audio_tracks = "failed" | .validation_subtitle_tracks = "failed" |
				.validation_chapters = "failed" |
				.validation_failures = ((.validation_failures + ";audio-inventory") | ltrimstr(";"))
			' "$row_fixture" >"$failed_row"
			mv -f -- "$failed_row" "$row_fixture"
		fi
		record_result "$run_id" "$row_fixture" "$output" >/dev/null
		rm -f -- "$row_fixture" "$packets" "$probe_file"
	done < <(jq -c '.savingsPanel[]?' "$samples_file")
	rm -rf -- "$run_scratch"
	printf '%s\n' "$run_id"
}

finalist_mode() {
	local requested_run_id="$1" requested_sample_id="$2" run_id run_directory run_scratch
	local sample sample_id cohort source sha setting expected_confirmation expected_finalist chosen
	validate_run_id "$requested_run_id" || return
	validate_sample_id "$requested_sample_id" || return
	reject_diagnostics_resume_run_id finalist "$requested_run_id" || return
	expected_confirmation="copy:encode-benchmark:$requested_run_id:$requested_sample_id"
	[[ "${ENCODE_BENCHMARK_FINALIST_CONFIRM:-}" == "$expected_confirmation" ]] || {
		echo "missing finalist confirmation for $requested_run_id/$requested_sample_id" >&2
		return 64
	}
	sample="$(SAMPLE_ID="$requested_sample_id" jq -c \
		'.qualityPanel[]? | select(.id == env.SAMPLE_ID)' "$samples_file")"
	[[ -n "$sample" && "$(wc -l <<<"$sample" | tr -d ' ')" == '1' ]] || {
		echo "finalist sample not found or duplicated: $requested_sample_id" >&2
		return 66
	}
	cohort="$(jq -r '.cohort' <<<"$sample")"
	expected_finalist="$(contract_expected_finalist "$cohort")" || {
		echo "no finalist title for cohort: $cohort" >&2
		return 65
	}
	[[ "$requested_sample_id" == "$expected_finalist" ]] || {
		echo "finalist sample does not match cohort: $cohort" >&2
		return 65
	}
	chosen="$(contract_chosen_record "$samples_file" "$cohort" provisional)" || {
		echo "chosen setting for $cohort is not provisional" >&2
		return 65
	}
	prepare_chosen_upstream "$cohort" provisional || return
	setting="$(jq -r '.globalQuality' <<<"$chosen")"
	assigned_node_capability_gate || return
	runtime_pre_encode_gate "$(jq -n -c --argjson sample "$sample" '[$sample]')" || return
	BENCHMARK_ENCODER_COMMANDS_JSON="$(encoder_commands_for_mode finalist)"
	export BENCHMARK_ENCODER_COMMANDS_JSON
	run_id="$("$script_directory/runmeta.sh" create finalist "$requested_run_id")"
	run_directory="$benchmark_out/runs/$run_id"
	run_scratch="$scratch_root/$run_id"
	mkdir -p "$run_directory/logs" "$run_scratch"
	sample_id="$(jq -r '.id' <<<"$sample")"
	[[ "$cohort" != 'dolby-vision' && "$(jq -r '.detectionOnly // false' <<<"$sample")" != 'true' ]] || {
		echo 'Dolby Vision samples cannot be encoded' >&2
		return 65
	}
	source="$(jq -r '.path' <<<"$sample")"
	sha="$(jq -r '.sha256' <<<"$sample")"
	if ! row_is_complete "$run_id" finalist "$sha" full qsv "$setting"; then
		encode_one_variant "$run_id" finalist "$sample_id" "$cohort" "$sha" full \
			qsv "$setting" "$source" full '' >/dev/null
	fi
	rm -rf -- "$run_scratch"
	printf '%s\n' "$run_id"
}

validate_contention_resume_fragments() {
	local run_directory="$1" run_id="$2" expected_case="$3" expected_worker="$4"
	local expected_sample="$5" expected_cohort="$6" expected_setting="$7"
	local fragment header row fields fragment_case fragment_worker fragment_attempt
	for fragment in "$run_directory"/contention-*.csv; do
		[[ -e "$fragment" || -L "$fragment" ]] || continue
		[[ -f "$fragment" && ! -L "$fragment" ]] || {
			echo 'invalid prior contention fragment' >&2
			return 65
		}
		header="$(head -n 1 "$fragment")"
		[[ "$header" == 'run_id,case,worker_id,sample_id,cohort,setting,status,attempt,wall_seconds,qsv_proof,validation_failures,output_disposition,strategy_id' &&
			"$(wc -l <"$fragment" | tr -d ' ')" == '2' ]] || {
			echo 'invalid prior contention fragment' >&2
			return 65
		}
		row="$(tail -n 1 "$fragment")"
		fields="$(jq -R -e -c '
			split(",") | select(length == 13 and all(.[]; startswith("\"") and endswith("\""))) |
			map(.[1:-1])
		' <<<"$row")" || {
			echo 'invalid prior contention fragment' >&2
			return 65
		}
		jq -e --arg run "$run_id" --arg case "$expected_case" --arg worker "$expected_worker" \
			--arg sample "$expected_sample" --arg cohort "$expected_cohort" --arg setting "$expected_setting" '
			.[0] == $run and .[1] == $case and .[2] == $worker and .[3] == $sample and
			.[4] == $cohort and .[5] == $setting and (.[6] | test("^(passed|failed|invalid)$")) and
			(.[7] | test("^[1-9][0-9]*$")) and (.[8] | test("^[0-9]+([.][0-9]+)?$")) and
			(.[9] | test("^(passed|suspect)$")) and (.[10] | test("^[a-z0-9;-]*$")) and
			.[11] == "discarded" and .[12] == "qsv-hevc-icq-v1"
		' <<<"$fields" >/dev/null || {
			echo 'invalid prior contention fragment' >&2
			return 65
		}
		fragment_case="$(jq -r '.[1]' <<<"$fields")"
		fragment_worker="$(jq -r '.[2]' <<<"$fields")"
		fragment_attempt="$(jq -r '.[7]' <<<"$fields")"
		[[ "$(basename "$fragment")" == "contention-$fragment_case-$fragment_worker-attempt-$fragment_attempt.csv" ]] || {
			echo 'invalid prior contention fragment' >&2
			return 65
		}
	done
}

contention_mode() (
	local requested_run_id="$1" contention_case="$2" worker_id="$3" requested_sample_id="$4"
	local sample sample_id cohort setting run_id run_directory run_scratch attempt fragment staged playback_count
	local output encode_log busy_log row_fixture start end wall encode_status=0 status qsv failures resolution
	trap 'rm -f -- "${output:-}" "${row_fixture:-}" "${staged:-}" 2>/dev/null || true
		if [[ -n "${run_scratch:-}" ]]; then rm -rf -- "$run_scratch"; fi' EXIT
	validate_run_id "$requested_run_id" || return
	validate_sample_id "$requested_sample_id" || return
	reject_diagnostics_resume_run_id "contention-$contention_case" "$requested_run_id" || return
	[[ "$contention_case" =~ ^[a-d]$ ]] || {
		echo "invalid contention case: $contention_case" >&2
		return 64
	}
	[[ "$worker_id" =~ ^worker-[12]$ ]] || {
		echo "invalid contention worker id: $worker_id" >&2
		return 64
	}
	if [[ "$contention_case" == 'a' && "$worker_id" != 'worker-1' ]]; then
		echo 'contention case a permits only worker-1' >&2
		return 64
	fi
	sample="$(SAMPLE_ID="$requested_sample_id" jq -c \
		'.qualityPanel[]? | select(.id == env.SAMPLE_ID)' "$samples_file")"
	[[ -n "$sample" && "$(wc -l <<<"$sample" | tr -d ' ')" == '1' ]] || {
		echo "contention sample not found or duplicated: $requested_sample_id" >&2
		return 66
	}
	sample_id="$(jq -r '.id' <<<"$sample")"
	cohort="$(jq -r '.cohort' <<<"$sample")"
	resolution="$(jq -e -r '
		select((.width | type) == "number" and (.width | floor) == .width and
			(.height | type) == "number" and (.height | floor) == .height) |
		"\(.width)x\(.height)"
	' <<<"$sample" 2>/dev/null || true)"
	if [[ "$(jq -r '.detectionOnly // false' <<<"$sample")" == 'true' || "$cohort" == 'dolby-vision' ]]; then
		echo 'Dolby Vision samples cannot be encoded' >&2
		return 65
	fi
	if [[ "$contention_case" == 'a' && ("$cohort" != 'hdr10' || "$resolution" != '3840x2160') ]]; then
		echo 'contention case a requires an eligible 3840x2160 HDR10 quality sample' >&2
		return 65
	fi
	if [[ "$contention_case" != 'a' && (! "$cohort" =~ ^(avc|vc1)$ || "$resolution" != '1920x1080') ]]; then
		echo "contention case $contention_case requires an eligible 1920x1080 non-DV quality sample" >&2
		return 65
	fi
	[[ "${BENCHMARK_PLEX_CLIENT_DEVICE:-}" =~ ^[a-z0-9][a-z0-9._-]{0,62}$ ]] || {
		echo 'contention client device label is missing or invalid' >&2
		return 65
	}
	[[ "${BENCHMARK_PLAYBACK_SAMPLE_ID:-}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || {
		echo 'contention playback sample identity is missing or invalid' >&2
		return 65
	}
	playback_count="$(PLAYBACK_SAMPLE_ID="$BENCHMARK_PLAYBACK_SAMPLE_ID" jq -r '[.qualityPanel[]? | select(
		.id == env.PLAYBACK_SAMPLE_ID and .cohort == "hdr10" and .width == 3840 and .height == 2160 and
		(.detectionOnly // false) == false
	)] | length' "$samples_file")"
	[[ "$playback_count" == '1' ]] || {
		echo 'contention playback sample is not a committed 3840x2160 HDR10 non-DV quality title' >&2
		return 65
	}
	setting="$(contract_chosen_record "$samples_file" "$cohort" final | jq -r '.globalQuality // ""')" || {
		echo "no final setting for cohort: $cohort" >&2
		return 65
	}
	contract_is_icq_setting "$samples_file" "$setting" || {
		echo "no final setting for cohort: $cohort" >&2
		return 65
	}
	prepare_chosen_upstream "$cohort" final || return
	assigned_node_capability_gate || return
	runtime_pre_encode_gate "$(jq -n -c --argjson sample "$sample" '[$sample]')" || return
	# shellcheck disable=SC2030 # The exported worker identity is consumed by runmeta in this subshell.
	BENCHMARK_UPSTREAM_IDENTITY_JSON="$(jq -c \
		--arg client "$BENCHMARK_PLEX_CLIENT_DEVICE" \
		--arg playback "$BENCHMARK_PLAYBACK_SAMPLE_ID" \
		'. + {contention: {clientDevice: $client, playbackSampleId: $playback}}' \
		<<<"$BENCHMARK_UPSTREAM_IDENTITY_JSON")"
	export BENCHMARK_UPSTREAM_IDENTITY_JSON
	BENCHMARK_ENCODER_COMMANDS_JSON="$(encoder_commands_for_mode contention)"
	export BENCHMARK_ENCODER_COMMANDS_JSON
	run_id="$("$script_directory/runmeta.sh" create "contention-$contention_case" "$requested_run_id")"
	run_directory="$benchmark_out/runs/$run_id"
	validate_contention_resume_fragments "$run_directory" "$run_id" "$contention_case" "$worker_id" \
		"$sample_id" "$cohort" "$setting" || return
	run_scratch="$scratch_root/$run_id/$worker_id"
	mkdir -p "$run_directory/logs" "$run_scratch"
	attempt=1
	while [[ -e "$run_directory/contention-$contention_case-$worker_id-attempt-$attempt.csv" ||
		-L "$run_directory/contention-$contention_case-$worker_id-attempt-$attempt.csv" ]]; do
		((attempt += 1))
	done
	fragment="$run_directory/contention-$contention_case-$worker_id-attempt-$attempt.csv"
	output="$run_scratch/$sample_id-full-qsv-$setting-attempt-$attempt.mkv"
	encode_log="$run_directory/logs/$sample_id-contention-$contention_case-$worker_id-attempt-$attempt.log"
	busy_log="$run_directory/logs/$sample_id-contention-$contention_case-$worker_id-attempt-$attempt-busy.log"
	row_fixture="$run_scratch/$sample_id-contention-$contention_case-$worker_id-attempt-$attempt.json"
	start="$(now_nanoseconds)"
	run_qsv_encode "$(jq -r '.path' <<<"$sample")" "$output" "$setting" "$encode_log" "$busy_log" || encode_status=$?
	end="$(now_nanoseconds)"
	wall="$(awk -v start="$start" -v end="$end" 'BEGIN { printf "%.6f", (end - start) / 1000000000 }')"
	process_variant "$run_id" contention "$sample_id" "$cohort" "$(jq -r '.sha256' <<<"$sample")" \
		"full-$contention_case-$worker_id" qsv "$setting" "$(jq -r '.path' <<<"$sample")" "$output" \
		full "$encode_status" "$wall" "$encode_log" "$busy_log" '' "$attempt" "$row_fixture"
	status='passed'
	if [[ "$(jq -r '.encode_status' "$row_fixture")" != '0' ]]; then
		status='failed'
	elif [[ -n "$(jq -r '.validation_failures' "$row_fixture")" || "$(jq -r '.qsv_proof' "$row_fixture")" != 'passed' ]]; then
		status='invalid'
	fi
	qsv="$(jq -r '.qsv_proof' "$row_fixture")"
	failures="$(jq -r '.validation_failures' "$row_fixture")"
	staged="$(mktemp "$run_directory/.contention-$contention_case-$worker_id-attempt-$attempt.XXXXXX")"
	{
		printf '%s\n' 'run_id,case,worker_id,sample_id,cohort,setting,status,attempt,wall_seconds,qsv_proof,validation_failures,output_disposition,strategy_id'
		jq -r \
			--arg run_id "$run_id" --arg case "$contention_case" --arg worker "$worker_id" \
			--arg sample "$sample_id" --arg cohort "$cohort" --arg setting "$setting" \
			--arg status "$status" --arg attempt "$attempt" --arg wall "$wall" \
			--arg qsv "$qsv" --arg failures "$failures" \
			--arg strategy "$CONTRACT_STRATEGY_ID" \
			'[$run_id,$case,$worker,$sample,$cohort,$setting,$status,$attempt,$wall,$qsv,$failures,"discarded",$strategy] | @csv' \
			<<<'{}'
	} >"$staged"
	mv -- "$staged" "$fragment"
	staged=''
	printf '%s\n' "$run_id"
)

validate_contention_observations() {
	local evidence="$1" result
	[[ -f "$evidence" && ! -L "$evidence" ]] || return 66
	result="$(jq -e -c '
		def nas: . as $items | type == "array" and length == 180 and
			all(range(0; 180); . as $i | $items[$i] | type == "object" and
				.offsetSeconds == ($i * 5) and (.value | type == "number" and . >= 0));
		def baseline: type == "object" and keys == ["bufferingCount","bufferingDurationSeconds","durationSeconds","nasThroughputMbps","playbackMode","runId","seekToResumeSeconds","startLatencySeconds"] and
			(.runId | type == "string" and length > 0) and .durationSeconds == 900 and .playbackMode == "direct-play" and
			(.startLatencySeconds | type == "number" and . >= 0) and
			(.bufferingCount | type == "number" and floor == . and . >= 0) and
			(.bufferingDurationSeconds | type == "number" and . >= 0) and
			(.seekToResumeSeconds | type == "array" and length == 7 and all(.[]; type == "number" and . >= 0)) and
			(.nasThroughputMbps | nas);
		def expected_workers($case): if $case == "a" then ["worker-1"] else ["worker-1","worker-2"] end;
		def case_ok: . as $item | type == "object" and
			(.case | type == "string" and test("^[a-d]$")) and
			(.playbackMode == (if .case == "c" then "forced-transcode" else "direct-play" end)) and
			(.startLatencySeconds | type == "number" and . >= 0) and
			(.bufferingCount | type == "number" and floor == . and . >= 0) and
			(.bufferingDurationSeconds | type == "number" and . >= 0) and (.nasThroughputMbps | nas) and
			(.workerFragments | type == "array" and length == (expected_workers($item.case) | length) and
				all(.[]; type == "object" and keys == ["file","runId"] and
					(.runId | type == "string" and test("^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$")) and
					(.file | type == "string" and test("^contention-[a-d]-worker-[12]-attempt-[1-9][0-9]*[.]csv$"))) and
				([.[] | (.runId + "|" + .file)] | unique | length) == length and
				([.[].runId] | unique | length) == length and
				all(.[]; .file | test("^contention-" + $item.case + "-worker-[12]-attempt-[1-9][0-9]*[.]csv$")) and
				([.[] | .file | capture("^contention-[a-d]-(?<worker>worker-[12])-attempt-[1-9][0-9]*[.]csv$").worker] | sort) == expected_workers($item.case)) and
			(if .case == "d" then (.seekToResumeSeconds | type == "array" and length == 7 and all(.[]; type == "number" and . >= 0))
			 else (.seekToResumeSeconds | type == "array") end);
		if type != "object" or keys != ["baselines","cases","clientDevice","playbackSampleId","runId","schemaVersion","strategyId"] or
			.schemaVersion != 1 or .strategyId != "qsv-hevc-icq-v1" or
			(.runId | type != "string" or test("^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$") | not) or
			(.clientDevice | type != "string" or test("^[a-z0-9][a-z0-9._-]{0,62}$") | not) or
			(.playbackSampleId | type != "string" or test("^[a-z0-9][a-z0-9._-]*$") | not) or
			(.baselines | type != "array" or length != 3 or all(.[]; baseline) | not) or
			(.cases | type != "array" or length == 0 or all(.[]; case_ok) | not) or
			([.cases[].case] | unique | length != length)
		then error("invalid contention evidence")
		else . as $root |
			([$root.baselines[].startLatencySeconds] | max) as $max_start |
			([$root.baselines[].seekToResumeSeconds[]] | max) as $max_seek |
			([ $root.cases[] | select(.case != "d" and .bufferingCount != 0) | "case \(.case) buffering count \(.bufferingCount) must be zero" ] +
			 [ $root.cases[] | select(.case != "d" and .bufferingDurationSeconds != 0) | "case \(.case) buffering duration \(.bufferingDurationSeconds) must be zero" ] +
			 [ $root.cases[] | select(.startLatencySeconds > ($max_start + 2)) | "case \(.case) start latency \(.startLatencySeconds) exceeds baseline maximum plus 2 seconds \($max_start + 2)" ] +
			 [ $root.cases[] | select(.case == "d") | .seekToResumeSeconds | to_entries[] | select(.value > ($max_seek + 3)) | "case d seek \(.key + 1) latency \(.value) exceeds baseline maximum plus 3 seconds \($max_seek + 3)" ]) as $errors |
			{status: (if ($errors | length) == 0 then "passed" else "failed" end),
			 baselinesRetained: 3, baselineMaxStartLatencySeconds: $max_start,
			 baselineMaxSeekToResumeSeconds: $max_seek, failedEvents: $errors}
		end
	' "$evidence")" || return 65
	jq -c . <<<"$result"
}

validate_contention_worker_manifest() {
	local manifest="$1" contention_case="$2" fragment_fields="$3" client_device="$4" playback_sample="$5"
	local sample_id cohort setting expected_source manifest_identity created_at normalized node_name
	local expected_chosen expected_upstream expected_selected
	sample_id="$(jq -r '.[3]' <<<"$fragment_fields")"
	cohort="$(jq -r '.[4]' <<<"$fragment_fields")"
	setting="$(jq -r '.[5]' <<<"$fragment_fields")"
	expected_source="$(SAMPLE_ID="$sample_id" COHORT="$cohort" jq -e -c '
		[.qualityPanel[]? | select(.id == env.SAMPLE_ID and .cohort == env.COHORT)] |
		if length == 1 then .[0] | {path,sha256:("sha256:" + .sha256),size:.sizeBytes} else error("missing contention source") end
	' "$samples_file")" || return 65
	jq -e --arg mode "contention-$contention_case" '.mode == $mode' "$manifest" >/dev/null || return 65
	manifest_identity="$(jq -e -c '
		if type == "object" and has("createdAt") then del(.createdAt)
		else error("invalid contention worker manifest") end
	' "$manifest")" || return 65
	created_at="$(jq -e -r '.createdAt | strings' "$manifest")" || return 65
	contract_is_compact_utc_timestamp "$created_at" || return 65
	normalized="$(contract_normalize_run_identity "$manifest_identity" "contention-$contention_case")" || return 65
	expected_chosen="$(findings_chosen_identity "$cohort")" || return 65
	expected_upstream="$(jq -n -c --argjson chosen "$expected_chosen" --arg client "$client_device" \
		--arg playback "$playback_sample" '
		$chosen + {contention:{clientDevice:$client,playbackSampleId:$playback}}
	')" || return 65
	expected_selected="$(jq -n -c --arg cohort "$cohort" --argjson setting "$setting" \
		--arg quality "$(jq -r '.chosenSetting.qualityRunId' <<<"$expected_chosen")" '
		[{cohort:$cohort,globalQuality:$setting,qualityRunId:$quality}]
	')" || return 65
	jq -e --arg client "$client_device" --argjson source "$expected_source" \
		--argjson upstream "$expected_upstream" --argjson selected "$expected_selected" '
		.clientDevice == $client and
		.upstream == $upstream and .selectedSettings == $selected and
		.sources == [$source] and
		(.node.name | type == "string" and length > 0)
	' <<<"$normalized" >/dev/null || return 65
	node_name="$(jq -r '.node.name' <<<"$normalized")"
	if ! contract_passing_icq_nodes "$samples_file" | rg -qx -- "$node_name"; then
		return 65
	fi
	jq -n -c --arg case "$contention_case" --arg node "$node_name" '{case:$case,node:$node}'
}

validate_findings_inputs() {
	local inputs="$1"
	[[ -f "$inputs" && ! -L "$inputs" ]] || return 66
	jq -e -S -c '
		def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
		def compact_utc:
			type == "string" and test("^[0-9]{8}T[0-9]{6}Z$") and
			. as $original |
			(capture("^(?<year>[0-9]{4})(?<month>[0-9]{2})(?<day>[0-9]{2})T(?<hour>[0-9]{2})(?<minute>[0-9]{2})(?<second>[0-9]{2})Z$") |
				"\(.year)-\(.month)-\(.day)T\(.hour):\(.minute):\(.second)Z") as $iso |
			try (($iso | fromdateiso8601 | strftime("%Y%m%dT%H%M%SZ")) == $original) catch false;
		def run_id:
			type == "string" and test("^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$") and
			(split("-")[0] | compact_utc);
		def basename($suffix):
			type == "string" and test("^[a-zA-Z0-9][a-zA-Z0-9._-]*" + $suffix + "$");
		def quality:
			type == "object" and keys == ["candidatesSha256","resultsSha256","runId"] and
			(.runId | run_id) and (.resultsSha256 | digest) and (.candidatesSha256 | digest);
		def x265:
			type == "object" and keys == ["comparisonsSha256","runId","sampleId"] and
			(.runId | run_id) and (.sampleId == "avc-grain-memento" or .sampleId == "hdr10-grain-goodfellas") and
			(.comparisonsSha256 | digest);
		def savings:
			type == "object" and keys == ["cohortsSha256","resultsSha256","runId"] and
			(.runId | run_id) and (.resultsSha256 | digest) and (.cohortsSha256 | digest);
		def fragment:
			type == "object" and keys == ["file","runId","sha256"] and (.runId | run_id) and
			(.file | basename("[.]csv")) and (.sha256 | digest);
		def contention:
			type == "object" and keys == ["fragments","observationsFile","observationsSha256","runId"] and
			(.runId | run_id) and (.observationsFile | basename("[.]json")) and (.observationsSha256 | digest) and
			(.fragments | type == "array" and length <= 16 and all(.[]; fragment) and
				([.[] | (.runId + "|" + .file)] | unique | length) == length);
		if type == "object" and .mode? == "diagnostics" then error("diagnostics artifact")
		elif type == "object" and keys == ["contention","quality","savings","schemaVersion","strategyId","x265"] and
			.schemaVersion == 1 and .strategyId == "qsv-hevc-icq-v1" and (.quality | quality) and
			(.x265 | type == "array" and length <= 2 and all(.[]; x265) and
				([.[] | .sampleId] | unique | length) == length) and
			(.savings == null or (.savings | savings)) and
			(.contention == null or (.contention | contention))
		then . else error("invalid findings inputs") end
	' "$inputs" || return 65
}

findings_unsafe_artifact() {
	local path="$1"
	[[ -f "$path" && ! -L "$path" ]] || return 66
}

findings_sha256() {
	local path="$1"
	findings_unsafe_artifact "$path" || return
	printf 'sha256:%s\n' "$(sha256sum "$path" | awk 'NR == 1 { print $1 }')"
}

findings_validate_manifest() {
	local path="$1" run_id="$2" mode="$3" identity created_at
	findings_unsafe_artifact "$path" || return
	case "$mode" in
	quality | x265 | savings | contention-a | contention-b | contention-c | contention-d) ;;
	*) return 65 ;;
	esac
	identity="$(jq -e -S -c 'if type == "object" and has("createdAt") then del(.createdAt) else error("manifest") end' "$path")" || return 65
	jq -e '.mode != "diagnostics"' <<<"$identity" >/dev/null || return 65
	jq -e --arg mode "$mode" '.mode == $mode' <<<"$identity" >/dev/null || return 65
	identity="$(contract_normalize_run_identity "$identity" "$mode")" || return 65
	created_at="$(jq -e -r '.createdAt | strings' "$path")" || return 65
	contract_is_compact_utc_timestamp "$created_at" || return 65
	[[ "$created_at" == "${run_id%-*}" ]] || return 65
	printf '%s\n' "$identity"
}

diagnostic_results_input_rejected() {
	local path="$1"
	[[ -f "$path" && ! -L "$path" ]] || return 66
	jq -e '.mode? == "diagnostics"' "$path" >/dev/null 2>&1 || return 1
	return 65
}

findings_expected_sources() {
	local panel="$1" selector="${2:-[]}" selector_filter
	case "$panel" in
	quality)
		selector_filter='.qualityPanel[]?'
		;;
	x265)
		selector_filter='.qualityPanel[]? | select(.id == $selector[0])'
		;;
	savings)
		selector_filter='.savingsPanel[]? | select((.detectionOnly // false) != true and
			(.cohort as $cohort | $selector | index($cohort)) != null)'
		;;
	*) return 64 ;;
	esac
	jq -e -c --argjson selector "$selector" "[$selector_filter |
		{path,sha256:(\"sha256:\" + .sha256),size:.sizeBytes}] | sort_by(.path)" "$samples_file"
}

findings_chosen_identity() {
	local cohort="$1" record quality_run quality_directory manifest results candidates
	local manifest_digest results_digest candidates_digest
	record="$(contract_chosen_record "$samples_file" "$cohort" final)" || return 65
	quality_run="$(jq -r '.qualityRunId' <<<"$record")"
	quality_directory="$benchmark_out/runs/$quality_run"
	manifest="$quality_directory/manifest.json"
	results="$quality_directory/results.csv"
	candidates="$quality_directory/quality-candidates.json"
	findings_unsafe_artifact "$manifest" && findings_unsafe_artifact "$results" &&
		findings_unsafe_artifact "$candidates" || return 65
	manifest_digest="$(findings_sha256 "$manifest")" || return
	results_digest="$(findings_sha256 "$results")" || return
	candidates_digest="$(findings_sha256 "$candidates")" || return
	jq -e --arg results "$results_digest" --arg candidates "$candidates_digest" '
		.qualityResultsSha256 == $results and .candidateEvidenceSha256 == $candidates
	' <<<"$record" >/dev/null || return 65
	jq -n -c --arg cohort "$cohort" --argjson chosen "$record" --arg manifest "$manifest_digest" \
		--arg results "$results_digest" --arg candidates "$candidates_digest" '{
			cohort:$cohort,chosenSetting:$chosen,qualityManifestSha256:$manifest,
			qualityResultsSha256:$results,candidateEvidenceSha256:$candidates
		}'
}

findings_validate_quality_manifest() {
	local manifest="$1" expected_sources
	expected_sources="$(findings_expected_sources quality)" || return
	jq -e --argjson sources "$expected_sources" '
		.selectedSettings == [] and .upstream == {} and .sources == $sources
	' <<<"$manifest" >/dev/null
}

findings_validate_x265_manifest() {
	local manifest="$1" sample_id="$2" cohort="$3" setting="$4" expected_sources expected_upstream expected_selected
	expected_sources="$(findings_expected_sources x265 "$(jq -n -c --arg sample "$sample_id" '[$sample]')")" || return
	expected_upstream="$(findings_chosen_identity "$cohort")" || return
	expected_selected="$(jq -n -c --arg cohort "$cohort" --argjson setting "$setting" \
		--arg run "$(jq -r '.chosenSetting.qualityRunId' <<<"$expected_upstream")" \
		'[{cohort:$cohort,globalQuality:$setting,qualityRunId:$run}]')" || return
	jq -e --argjson sources "$expected_sources" --argjson upstream "$expected_upstream" \
		--argjson selected "$expected_selected" '
		.sources == $sources and .upstream == $upstream and .selectedSettings == $selected
	' <<<"$manifest" >/dev/null
}

findings_validate_savings_manifest() {
	local manifest="$1" final_cohorts="$2" cohort expected_sources expected_selected='[]' expected_upstream='{}' chosen
	expected_sources="$(findings_expected_sources savings "$final_cohorts")" || return
	while IFS= read -r cohort; do
		chosen="$(findings_chosen_identity "$cohort")" || return
		expected_selected="$(jq -c --arg cohort "$cohort" --argjson setting "$(jq '.chosenSetting.globalQuality' <<<"$chosen")" \
			--arg run "$(jq -r '.chosenSetting.qualityRunId' <<<"$chosen")" \
			'. + [{cohort:$cohort,globalQuality:$setting,qualityRunId:$run}] | sort_by(.cohort)' <<<"$expected_selected")" || return
		expected_upstream="$(jq -c --arg cohort "$cohort" --argjson chosen "$chosen" \
			'. + {($cohort):$chosen}' <<<"$expected_upstream")" || return
	done < <(jq -r '.[]' <<<"$final_cohorts")
	expected_upstream="$(jq -n -c --argjson chosen "$expected_upstream" '{chosenSettings:$chosen}')"
	jq -e --argjson sources "$expected_sources" --argjson upstream "$expected_upstream" \
		--argjson selected "$expected_selected" '
		.sources == $sources and .upstream == $upstream and .selectedSettings == $selected
	' <<<"$manifest" >/dev/null
}

findings_validate_results() {
	local path="$1" run_id="$2" panel="$3"
	findings_unsafe_artifact "$path" || return
	[[ "$(head -n 1 "$path")" == "$results_header" ]] || return 65
	awk -F, -v run="$run_id" -v panel="$panel" -v strategy="$CONTRACT_STRATEGY_ID" '
		NR > 1 { rows += 1; if (NF != 41 || $1 != run || $2 != panel || $37 != strategy) exit 65 }
		END { if (rows < 1) exit 65 }
	' "$path"
}

findings_results_json() {
	local path="$1"
	findings_unsafe_artifact "$path" || return
	jq -R -s -e -c --arg header "$results_header" '
		split("\n") | if .[-1] == "" then .[:-1] else . end |
		if length < 2 or .[0] != $header then error("invalid results CSV") else
			[.[1:][] |
				split(",") |
				if length != 41 then error("invalid results CSV row") else {
					run_id:.[0],panel:.[1],sample_id:.[2],cohort:.[3],source_sha256:.[4],
					clip_id:.[5],encoder:.[6],requested_setting:.[7],
					selected_rate_control:.[8],status:.[9],attempt:.[10],
					input_bytes:.[11],output_bytes:.[12],reduction_percent:.[13],
					input_bit_rate:.[14],output_bit_rate:.[15],wall_seconds:.[16],
					encode_fps:.[17],encode_speed:.[18],vmaf_harmonic_mean:.[19],
					vmaf_1pct_low:.[20],ssim:.[21],gpu_busy_percent:.[22],
					qsv_proof:.[23],validation_codec:.[24],validation_duration:.[25],
					validation_resolution:.[26],validation_frame_rate:.[27],
					validation_bit_depth:.[28],validation_hdr:.[29],
					validation_audio_tracks:.[30],validation_subtitle_tracks:.[31],
					validation_chapters:.[32],validation_failures:.[33],log_path:.[34],
					output_disposition:.[35],strategy_id:.[36],qsv_initialization:.[37],
					video_busy_nanoseconds:.[38]
				} end
			]
		end
	' "$path"
}

findings_validate_savings_results() {
	local path="$1" run_id="$2" rows expected
	rows="$(findings_results_json "$path")" || return 65
	expected="$(jq -e -c '
		. as $root |
		[.savingsPanel[]? |
			select((.detectionOnly // false) != true and .cohort != "dolby-vision" and
				$root.chosenSettings[.cohort].state == "final") |
			{sample_id:.id,cohort:.cohort,source_sha256:.sha256,clip_id:"full",
			 requested_setting:($root.chosenSettings[.cohort].globalQuality | tostring)}] |
		sort_by(.cohort,.sample_id)
	' "$samples_file")" || return 65
	jq -e --arg run "$run_id" --arg strategy "$CONTRACT_STRATEGY_ID" \
		--argjson expected "$expected" '
		def uint: test("^(0|[1-9][0-9]*)$");
		def positive_uint: test("^[1-9][0-9]*$");
		def decimal: test("^-?(0|[1-9][0-9]*)([.][0-9]+)?$");
		def positive_decimal: decimal and (tonumber > 0);
		def passed_validation:
			.validation_codec == "passed" and .validation_duration == "passed" and
			.validation_resolution == "passed" and .validation_frame_rate == "passed" and
			.validation_bit_depth == "passed" and .validation_hdr == "passed" and
			.validation_audio_tracks == "passed" and .validation_subtitle_tracks == "passed" and
			.validation_chapters == "passed" and .validation_failures == "";
		def valid:
			.run_id == $run and .panel == "savings" and .encoder == "qsv" and
			(.requested_setting | uint) and
			.selected_rate_control == "ICQ" and .status == "passed" and
			(.attempt | positive_uint) and (.input_bytes | positive_uint) and
			(.output_bytes | positive_uint) and (.reduction_percent | decimal) and
			(.input_bit_rate | positive_uint) and (.output_bit_rate | positive_uint) and
			(.wall_seconds | positive_decimal) and (.encode_fps | positive_decimal) and
			(.encode_speed | positive_decimal) and (.vmaf_harmonic_mean | decimal) and
			(.vmaf_1pct_low | decimal) and (.ssim | decimal) and
			(.gpu_busy_percent | decimal) and .qsv_proof == "passed" and
			passed_validation and
			(.log_path | test("^logs/[a-z0-9][a-z0-9.-]{0,191}[.]log$")) and
			.output_disposition == "discarded" and .strategy_id == $strategy and
			.qsv_initialization == "passed" and (.video_busy_nanoseconds | positive_uint);
		. as $rows |
		([$rows[] | {sample_id,cohort,source_sha256,clip_id,requested_setting}] |
			sort_by(.cohort,.sample_id)) == $expected and
		($rows | length) == ($expected | length) and
		all($rows[]; valid)
	' <<<"$rows" >/dev/null
}

findings_validate_quality_results() {
	local path="$1" run_id="$2" rows expected
	rows="$(findings_results_json "$path")" || return 65
	expected="$(jq -e -c '
		. as $root |
		[.qualityPanel[]? |
			select((.detectionOnly // false) != true and .cohort != "dolby-vision") |
			. as $sample | $root.chosenSettings[.cohort] as $chosen |
			select($chosen | type == "object") |
			.clips | keys[] as $clip |
			{sample_id:$sample.id,cohort:$sample.cohort,source_sha256:$sample.sha256,
			 clip_id:$clip,requested_setting:($chosen.globalQuality | tostring)}] |
		sort_by(.cohort,.sample_id,.clip_id)
	' "$samples_file")" || return 65
	jq -e --arg run "$run_id" --arg strategy "$CONTRACT_STRATEGY_ID" \
		--argjson expected "$expected" '
		def uint: test("^(0|[1-9][0-9]*)$");
		def positive_uint: test("^[1-9][0-9]*$");
		def decimal: test("^-?(0|[1-9][0-9]*)([.][0-9]+)?$");
		def positive_decimal: decimal and (tonumber > 0);
		def passed_validation:
			.validation_codec == "passed" and .validation_duration == "passed" and
			.validation_resolution == "passed" and .validation_frame_rate == "passed" and
			.validation_bit_depth == "passed" and .validation_hdr == "passed" and
			.validation_audio_tracks == "passed" and .validation_subtitle_tracks == "passed" and
			.validation_chapters == "passed" and .validation_failures == "";
		def valid:
			.run_id == $run and .panel == "quality" and .encoder == "qsv" and
			(.requested_setting | uint) and .selected_rate_control == "ICQ" and
			.status == "passed" and (.attempt | positive_uint) and
			(.input_bytes | positive_uint) and (.output_bytes | positive_uint) and
			(.reduction_percent | decimal) and (.input_bit_rate | positive_uint) and
			(.output_bit_rate | positive_uint) and (.wall_seconds | positive_decimal) and
			(.encode_fps | positive_decimal) and (.encode_speed | positive_decimal) and
			(.vmaf_harmonic_mean | decimal) and (.vmaf_1pct_low | decimal) and
			(.ssim | decimal) and (.gpu_busy_percent | decimal) and
			.qsv_proof == "passed" and passed_validation and
			(.log_path | test("^logs/[a-z0-9][a-z0-9.-]{0,191}[.]log$")) and
			.output_disposition == "discarded" and .strategy_id == $strategy and
			.qsv_initialization == "passed" and (.video_busy_nanoseconds | positive_uint);
		. as $rows |
		[$rows[] |
			. as $row |
			select(any($expected[]; .cohort == $row.cohort and
				.requested_setting == $row.requested_setting))] as $chosen |
		([$chosen[] | {sample_id,cohort,source_sha256,clip_id,requested_setting}] |
			sort_by(.cohort,.sample_id,.clip_id)) == $expected and
		($chosen | length) == ($expected | length) and all($chosen[]; valid)
	' <<<"$rows" >/dev/null
}

findings_markdown_escape() {
	jq -Rr 'gsub("(?<char>[`*_{}\\[\\]()<>])"; "\\\(.char)")'
}

# Findings accepts a failed contention *observation* as evidence, but not a
# failed worker encode. Every named fragment must be a completed ICQ encode
# whose output was discarded after successful validation.
findings_validate_contention_fragment() {
	local path="$1" run_id="$2" header row fields fragment_case fragment_worker fragment_attempt fragment_setting
	findings_unsafe_artifact "$path" || return
	header="$(head -n 1 "$path")"
	[[ "$header" == 'run_id,case,worker_id,sample_id,cohort,setting,status,attempt,wall_seconds,qsv_proof,validation_failures,output_disposition,strategy_id' &&
		"$(wc -l <"$path" | tr -d ' ')" == '2' ]] || return 65
	row="$(tail -n 1 "$path")"
	fields="$(jq -R -e -c '
		split(",") | select(length == 13 and all(.[]; startswith("\"") and endswith("\""))) |
		map(.[1:-1])
	' <<<"$row")" || return 65
	jq -e --arg run "$run_id" '
		.[0] == $run and
		(.[1] | test("^[a-d]$")) and
		(.[2] | test("^worker-[12]$")) and
		(.[3] | test("^(avc-grain-memento|vc1-fugitive|hdr10-grain-goodfellas)$")) and
		(.[4] | test("^(avc|vc1|hdr10)$")) and
		(.[5] | test("^[0-9]+$")) and
		.[6] == "passed" and
		(.[7] | test("^[1-9][0-9]*$")) and
		(.[8] | test("^[0-9]+([.][0-9]+)?$")) and
		.[9] == "passed" and .[10] == "" and
		.[11] == "discarded" and .[12] == "qsv-hevc-icq-v1"
	' <<<"$fields" >/dev/null || return 65
	fragment_setting="$(jq -r '.[5]' <<<"$fields")"
	contract_is_icq_setting "$samples_file" "$fragment_setting" || return 65
	fragment_case="$(jq -r '.[1]' <<<"$fields")"
	fragment_worker="$(jq -r '.[2]' <<<"$fields")"
	fragment_attempt="$(jq -r '.[7]' <<<"$fields")"
	[[ "$(basename "$path")" == "contention-$fragment_case-$fragment_worker-attempt-$fragment_attempt.csv" ]]
}

findings_required_contention_cases() {
	local hdr_final avc_final vc1_final required='[]'
	hdr_final="$(jq -r '.chosenSettings.hdr10.state == "final"' "$samples_file")"
	avc_final="$(jq -r '.chosenSettings.avc.state == "final"' "$samples_file")"
	vc1_final="$(jq -r '.chosenSettings.vc1.state == "final"' "$samples_file")"
	if [[ "$hdr_final" == true ]]; then
		required='["a"]'
	fi
	if [[ "$avc_final" == true && "$vc1_final" == true ]]; then
		required="$(jq -c '. + ["b","c","d"]' <<<"$required")"
	fi
	printf '%s\n' "$required"
}

findings_validate_evidence() {
	local run_id="$1" inputs="$2" quality_run quality_results quality_candidates quality_manifest
	local savings_run savings_results savings_cohorts savings_manifest x265_entry x265_run x265_file x265_manifest
	local contention_run contention_file contention_path fragment fragment_run fragment_file fragment_path fragment_manifest
	local contention_client_device contention_playback_sample fragment_observation_case fragment_fields
	local contention_node_bindings='[]' manifest_binding
	local findings_cohort findings_setting normalized_manifest final_cohorts required_contention_cases
	validate_findings_inputs "$inputs" >/dev/null || return 65
	quality_run="$(jq -r '.quality.runId' "$inputs")"
	quality_results="$benchmark_out/runs/$quality_run/results.csv"
	quality_candidates="$benchmark_out/runs/$quality_run/quality-candidates.json"
	quality_manifest="$benchmark_out/runs/$quality_run/manifest.json"
	normalized_manifest="$(findings_validate_manifest "$quality_manifest" "$quality_run" quality)" || return 65
	findings_validate_quality_manifest "$normalized_manifest" || return 65
	findings_validate_results "$quality_results" "$quality_run" quality || return 65
	findings_validate_quality_results "$quality_results" "$quality_run" || return 65
	[[ "$(findings_sha256 "$quality_results")" == "$(jq -r '.quality.resultsSha256' "$inputs")" &&
	"$(findings_sha256 "$quality_candidates")" == "$(jq -r '.quality.candidatesSha256' "$inputs")" ]] || return 65
	jq -e --arg run "$quality_run" --arg strategy "$CONTRACT_STRATEGY_ID" --arg digest "$(findings_sha256 "$quality_results")" \
		--argjson schema "$CONTRACT_RESULTS_SCHEMA" '
			type == "object" and .schemaVersion == 1 and .strategyId == $strategy and .qualityRunId == $run and
			.resultsSchemaVersion == $schema and .resultsSha256 == $digest and
			(.cohorts | type == "object" and keys == ["avc","hdr10","vc1"] and
			 all(.[]; type == "object" and (.status == "eligible" or .status == "no-go")))
		' "$quality_candidates" >/dev/null || return 65
	for findings_cohort in avc vc1 hdr10; do
		if jq -e --arg cohort "$findings_cohort" '.chosenSettings[$cohort]?.state == "final"' "$samples_file" >/dev/null; then
			findings_chosen_identity "$findings_cohort" >/dev/null || return 65
			jq -e --arg run "$quality_run" --arg results "$(jq -r '.quality.resultsSha256' "$inputs")" \
				--arg candidates "$(jq -r '.quality.candidatesSha256' "$inputs")" '
					.qualityRunId == $run and .qualityResultsSha256 == $results and .candidateEvidenceSha256 == $candidates
				' <<<"$(contract_chosen_record "$samples_file" "$findings_cohort" final)" >/dev/null || return 65
		fi
	done
	while IFS= read -r x265_entry; do
		x265_run="$(jq -r '.runId' <<<"$x265_entry")"
		x265_file="$benchmark_out/runs/$x265_run/x265-comparisons.jsonl"
		x265_manifest="$benchmark_out/runs/$x265_run/manifest.json"
		normalized_manifest="$(findings_validate_manifest "$x265_manifest" "$x265_run" x265)" || return 65
		[[ "$(findings_sha256 "$x265_file")" == "$(jq -r '.comparisonsSha256' <<<"$x265_entry")" ]] || return 65
		findings_cohort="$(if [[ "$(jq -r '.sampleId' <<<"$x265_entry")" == avc-grain-memento ]]; then printf avc; else printf hdr10; fi)"
		findings_setting="$(contract_chosen_record "$samples_file" "$findings_cohort" final | jq -r '.globalQuality')" || return 65
		findings_validate_x265_manifest "$normalized_manifest" "$(jq -r '.sampleId' <<<"$x265_entry")" \
			"$findings_cohort" "$findings_setting" || return 65
		jq -s -e --arg run "$x265_run" --arg quality "$quality_run" --arg sample "$(jq -r '.sampleId' <<<"$x265_entry")" \
			--arg strategy "$CONTRACT_STRATEGY_ID" --argjson setting "$findings_setting" '
				length == 3 and all(.[]; type == "object" and
					keys == ["clipId","lowerCrf","matchedBitRate","premiumPercent","qsvSetting","qualityRunId","sampleId","status","strategyId","upperCrf","x265RunId"] and
					.strategyId == $strategy and .qualityRunId == $quality and .x265RunId == $run and .sampleId == $sample and .qsvSetting == $setting and
					((.status == "unbracketed" and .lowerCrf == null and .upperCrf == null and .matchedBitRate == null and .premiumPercent == null) or
					 (.status == "bracketed" and (.lowerCrf | type == "number") and (.upperCrf | type == "number") and (.matchedBitRate | type == "number" and . > 0) and (.premiumPercent | type == "number"))))
			' "$x265_file" >/dev/null || return 65
	done < <(jq -c '.x265[]' "$inputs")
	if [[ "$(jq -r '.savings == null' "$inputs")" == 'false' ]]; then
		savings_run="$(jq -r '.savings.runId' "$inputs")"
		savings_results="$benchmark_out/runs/$savings_run/results.csv"
		savings_cohorts="$benchmark_out/runs/$savings_run/savings-cohorts.json"
		savings_manifest="$benchmark_out/runs/$savings_run/manifest.json"
		normalized_manifest="$(findings_validate_manifest "$savings_manifest" "$savings_run" savings)" || return 65
		findings_validate_results "$savings_results" "$savings_run" savings || return 65
		[[ "$(findings_sha256 "$savings_results")" == "$(jq -r '.savings.resultsSha256' "$inputs")" &&
		"$(findings_sha256 "$savings_cohorts")" == "$(jq -r '.savings.cohortsSha256' "$inputs")" ]] || return 65
		findings_validate_savings_results "$savings_results" "$savings_run" || return 65
		jq -e --arg run "$savings_run" --arg strategy "$CONTRACT_STRATEGY_ID" '
			type == "object" and keys == ["cohorts","runId","schemaVersion","strategyId"] and .schemaVersion == 1 and
			.strategyId == $strategy and .runId == $run and (.cohorts | type == "object" and keys == ["avc","hdr10","vc1"])
		' "$savings_cohorts" >/dev/null || return 65
		final_cohorts="$(jq -c '[.chosenSettings as $chosen | ["avc","vc1","hdr10"][] |
			select($chosen[.]?.state == "final")]' "$samples_file")" || return
		findings_validate_savings_manifest "$normalized_manifest" "$final_cohorts" || return 65
	fi
	required_contention_cases="$(findings_required_contention_cases)" || return 65
	if [[ "$(jq -r 'length' <<<"$required_contention_cases")" == '0' ]]; then
		[[ "$(jq -r '.contention == null' "$inputs")" == true ]] || return 65
	else
		[[ "$(jq -r '.contention != null' "$inputs")" == true ]] || return 65
	fi
	if [[ "$(jq -r '.contention == null' "$inputs")" == 'false' ]]; then
		contention_run="$(jq -r '.contention.runId' "$inputs")"
		contention_file="$(jq -r '.contention.observationsFile' "$inputs")"
		contention_path="$benchmark_out/runs/$contention_run/$contention_file"
		[[ "$(findings_sha256 "$contention_path")" == "$(jq -r '.contention.observationsSha256' "$inputs")" ]] || return 65
		validate_contention_observations "$contention_path" >/dev/null || return 65
		jq -e --arg run "$contention_run" --argjson required "$required_contention_cases" '
			.runId == $run and ([.cases[].case] | sort) == ($required | sort)
		' "$contention_path" >/dev/null || return 65
		contention_client_device="$(jq -r '.clientDevice' "$contention_path")"
		contention_playback_sample="$(jq -r '.playbackSampleId' "$contention_path")"
		jq -e --argjson fragments "$(jq -c '[.contention.fragments[] | {runId,file}]' "$inputs")" '
			([.cases[] | .workerFragments[]] | sort_by(.runId, .file)) == ($fragments | sort_by(.runId, .file))
		' "$contention_path" >/dev/null || return 65
		while IFS= read -r fragment; do
			fragment_run="$(jq -r '.runId' <<<"$fragment")"
			fragment_file="$(jq -r '.file' <<<"$fragment")"
			fragment_path="$benchmark_out/runs/$fragment_run/$fragment_file"
			[[ "$(findings_sha256 "$fragment_path")" == "$(jq -r '.sha256' <<<"$fragment")" ]] || return 65
			findings_validate_contention_fragment "$fragment_path" "$fragment_run" || return 65
			fragment_observation_case="$(jq -e -r --arg run "$fragment_run" --arg file "$fragment_file" '
				[.cases[] | select(any(.workerFragments[]?; .runId == $run and .file == $file)) | .case] |
				if length == 1 then .[0] else error("ambiguous contention fragment") end
			' "$contention_path")" || return 65
			fragment_fields="$(tail -n 1 "$fragment_path" | jq -R -e -c 'split(",") | map(.[1:-1])')" || return 65
			[[ "$(jq -r '.[1]' <<<"$fragment_fields")" == "$fragment_observation_case" ]] || return 65
			fragment_manifest="$benchmark_out/runs/$fragment_run/manifest.json"
			findings_validate_manifest "$fragment_manifest" "$fragment_run" "contention-$fragment_observation_case" || return 65
			manifest_binding="$(validate_contention_worker_manifest "$fragment_manifest" "$fragment_observation_case" "$fragment_fields" \
				"$contention_client_device" "$contention_playback_sample")" || return 65
			contention_node_bindings="$(jq -c --argjson binding "$manifest_binding" '. + [$binding]' <<<"$contention_node_bindings")"
		done < <(jq -c '.contention.fragments[]' "$inputs")
		jq -e 'group_by(.case) | all(.[]; if .[0].case == "a" then length == 1 else length == 2 and ([.[].node] | unique | length) == 2 end)' \
			<<<"$contention_node_bindings" >/dev/null || return 65
	fi
}

findings_conclusion() {
	local cohort="$1" objective="$2" state="$3" savings_verdict="$4" x265_verdict="$5"
	if [[ "$objective" == no-go || "$state" == rejected || "$savings_verdict" == NO-GO ]]; then
		printf '%s\n' 'NO-GO'
	elif [[ "$x265_verdict" == no-verdict ]]; then
		printf '%s\n' 'no-verdict'
	elif [[ "$savings_verdict" == MARGINAL ]]; then
		printf '%s\n' 'MARGINAL'
	elif [[ "$state" == final && "$savings_verdict" == GO && ("$cohort" == vc1 || "$x265_verdict" == admissible || "$x265_verdict" == not-applicable) ]]; then
		printf '%s\n' 'GO'
	else
		printf '%s\n' 'no-verdict'
	fi
}

findings_render_v1() {
	local run_id="$1" inputs="$2" quality_run savings_run='' savings_results='' savings_cohorts=''
	local final_cohorts contention_status='not applicable' findings_temp cohort
	local state objective setting quality_summary savings_summary='' savings_verdict='not applicable' x265_verdict='not applicable' conclusion
	local distribution stats contentions_present expected_x265 actual_x265 quality_rows capability_nodes
	contract_validate_chosen_settings "$samples_file" || return 65
	findings_validate_evidence "$run_id" "$inputs" || {
		echo 'findings upstream evidence is invalid or stale' >&2
		return 65
	}
	quality_run="$(jq -r '.quality.runId' "$inputs")"
	quality_rows="$(findings_results_json "$benchmark_out/runs/$quality_run/results.csv")" || return 65
	capability_nodes="$(contract_passing_icq_nodes "$samples_file" | awk '
		BEGIN { separator = "" }
		{ printf "%s%s", separator, $0; separator = ", " }
	')"
	[[ -n "$capability_nodes" ]] || capability_nodes='none'
	final_cohorts="$(jq -c '[.chosenSettings as $chosen | ["avc","vc1","hdr10"][] | select($chosen[.]?.state == "final")]' "$samples_file")"
	expected_x265="$(jq -c '[.[] | select(. == "avc" or . == "hdr10")]' <<<"$final_cohorts")"
	actual_x265="$(jq -c '[.x265[] | if .sampleId == "avc-grain-memento" then "avc" else "hdr10" end] | sort' "$inputs")"
	[[ "$actual_x265" == "$(jq -c 'sort' <<<"$expected_x265")" ]] || {
		echo 'x265 evidence does not match final cohort applicability' >&2
		return 65
	}
	if [[ "$(jq -r 'length' <<<"$final_cohorts")" -gt 0 ]]; then
		[[ "$(jq -r '.savings != null' "$inputs")" == true ]] || {
			echo 'final cohort is missing required savings evidence' >&2
			return 65
		}
		savings_run="$(jq -r '.savings.runId' "$inputs")"
		savings_results="$benchmark_out/runs/$savings_run/results.csv"
		savings_cohorts="$benchmark_out/runs/$savings_run/savings-cohorts.json"
		jq -e --argjson final "$final_cohorts" '
			.cohorts as $cohorts | all($final[]; . as $cohort | $cohorts[$cohort].status == "measured")
		' "$savings_cohorts" >/dev/null || {
			echo 'savings cohort applicability does not match final cohort state' >&2
			return 65
		}
	else
		[[ "$(jq -r '.savings == null' "$inputs")" == true ]] || return 65
	fi
	contentions_present="$(jq -r '.contention != null' "$inputs")"
	if [[ "$contentions_present" == true ]]; then
		contention_status="$(validate_contention_observations \
			"$benchmark_out/runs/$(jq -r '.contention.runId' "$inputs")/$(jq -r '.contention.observationsFile' "$inputs")" |
			jq -r '.status')"
	fi
	findings_temp="$benchmark_out/runs/$run_id/findings.md.tmp"
	{
		printf '# Encode benchmark findings\n\n'
		printf 'Evidence strategy: `qsv-hevc-icq-v1`  \nQuality run: `%s`\n\n' \
			"$(printf '%s' "$quality_run" | findings_markdown_escape)"
		for cohort in avc vc1 hdr10; do
			savings_summary=''
			savings_verdict='not applicable'
			state="$(jq -r --arg cohort "$cohort" '.chosenSettings[$cohort].state // "no-setting"' "$samples_file")"
			objective="$(jq -r --arg cohort "$cohort" '.cohorts[$cohort].status' "$benchmark_out/runs/$quality_run/quality-candidates.json")"
			setting="$(jq -r --arg cohort "$cohort" '.chosenSettings[$cohort].globalQuality // "no setting"' "$samples_file")"
			quality_summary="$(jq -r --arg cohort "$cohort" --arg setting "$setting" '
				[.[] | select(.cohort == $cohort and .requested_setting == $setting)] as $rows |
				if ($rows | length) == 0 then "not applicable" else
					"VMAF " + ([$rows[].vmaf_harmonic_mean | tonumber] | min | tostring) +
					"; SSIM " + ([$rows[].ssim | tonumber] | min | tostring) +
					"; output validation passed; speed " +
					([$rows[].encode_speed | tonumber] | min | tostring) +
					"; output bytes " + ([$rows[].output_bytes | tonumber] | add | tostring)
				end
			' <<<"$quality_rows")" || return 65
			x265_verdict='not applicable'
			if [[ "$cohort" == avc || "$cohort" == hdr10 ]]; then
				if [[ "$state" == final ]]; then
					x265_verdict="$(jq -r --arg cohort "$cohort" '
						[.x265[] | select((if .sampleId == "avc-grain-memento" then "avc" else "hdr10" end) == $cohort)] | .[0].runId
					' "$inputs" | while IFS= read -r xrun; do
						jq -s -r 'if any(.[]; .status == "unbracketed" or (.status == "bracketed" and .premiumPercent > 30)) then "no-verdict"
						elif all(.[]; .status == "bracketed" and .premiumPercent <= 30) then "admissible" else "no-verdict" end' \
							"$benchmark_out/runs/$xrun/x265-comparisons.jsonl"
					done)"
				fi
			fi
			if [[ -n "$savings_results" ]]; then
				distribution="$(awk -F, -v cohort="$cohort" 'NR > 1 && $2 == "savings" && $4 == cohort && $10 == "passed" && $37 == "qsv-hevc-icq-v1" { print $14 }' "$savings_results" | jq -R -s -c --arg cohort "$cohort" '{cohort:$cohort,reductionPercent:(split("\n") | map(select(length > 0) | tonumber))}')"
				if [[ "$(jq -r '.reductionPercent | length' <<<"$distribution")" -gt 0 ]]; then
					stats="$(savings_stats /dev/stdin <<<"$distribution")" || return
					savings_verdict="$(jq -r '.verdict' <<<"$stats")"
					savings_summary="$(jq -r '"median " + (.median|tostring) + "; Q1 " + (.q1|tostring) + "; Q3 " + (.q3|tostring) + "; IQR " + (.iqr|tostring)' <<<"$stats")"
				fi
			fi
			[[ -n "$savings_summary" ]] || savings_summary='not applicable'
			conclusion="$(findings_conclusion "$cohort" "$objective" "$state" "$savings_verdict" "$x265_verdict")"
			printf '## %s\n\n' "$(printf '%s' "$cohort" | findings_markdown_escape)"
			printf -- '- Capability node basis: %s\n- Objective quality verdict: %s\n- Crop/finalist visual verdict: %s\n- Final global_quality: %s\n- Quality evidence: %s\n- x265 premium verdict: %s\n- Savings: %s; verdict %s\n- Contention: %s\n- Conclusion: **%s**\n\n' \
				"$(printf '%s' "$capability_nodes" | findings_markdown_escape)" \
				"$(printf '%s' "$objective" | findings_markdown_escape)" \
				"$(printf '%s' "$state" | findings_markdown_escape)" \
				"$(printf '%s' "$setting" | findings_markdown_escape)" \
				"$(printf '%s' "$quality_summary" | findings_markdown_escape)" \
				"$(printf '%s' "$x265_verdict" | findings_markdown_escape)" \
				"$(printf '%s' "$savings_summary" | findings_markdown_escape)" \
				"$(printf '%s' "$savings_verdict" | findings_markdown_escape)" \
				"$(printf '%s' "$contention_status" | findings_markdown_escape)" \
				"$(printf '%s' "$conclusion" | findings_markdown_escape)"
		done
		if [[ "$contention_status" == failed ]]; then
			printf 'Processing window: required before benchmark encoding.\n'
		fi
	} >"$findings_temp"
	# The input and upstream artifacts can change while rendering. Recheck the
	# same exact evidence before the atomic publication point.
	findings_validate_evidence "$run_id" "$inputs" || {
		rm -f -- "$findings_temp"
		return 65
	}
	mv -f -- "$findings_temp" "$benchmark_out/runs/$run_id/findings.md"
	printf '%s\n' "$run_id"
}

findings_mode() {
	local run_id="$1" run_directory inputs
	local mounted_inputs inputs_digest upstream_identity created_run
	validate_run_id "$run_id" || return
	run_directory="$benchmark_out/runs/$run_id"
	mounted_inputs="${BENCHMARK_FINDINGS_INPUTS_FILE:-$run_directory/findings-inputs.json}"
	inputs="$mounted_inputs"
	[[ -f "$inputs" && ! -L "$inputs" ]] || {
		echo 'findings inputs not found' >&2
		return 66
	}
	validate_findings_inputs "$inputs" >/dev/null || return 65
	inputs_digest="$(findings_sha256 "$inputs")"
	upstream_identity="$(jq -c --arg digest "$inputs_digest" '{findingsInputsSha256:$digest,quality:.quality,x265:.x265,savings:.savings,contention:.contention}' "$inputs")" || return 65
	BENCHMARK_FINDINGS_INPUTS_SHA256="$inputs_digest"
	BENCHMARK_UPSTREAM_IDENTITY_JSON="$upstream_identity"
	export BENCHMARK_FINDINGS_INPUTS_SHA256 BENCHMARK_UPSTREAM_IDENTITY_JSON
	created_run="$("$script_directory/runmeta.sh" create findings "$run_id")" || return
	[[ "$created_run" == "$run_id" ]] || return 65
	if [[ "$mounted_inputs" != "$run_directory/findings-inputs.json" ]]; then
		cp -- "$mounted_inputs" "$run_directory/findings-inputs.json" || return
		chmod 0600 "$run_directory/findings-inputs.json" || return
	fi
	inputs="$run_directory/findings-inputs.json"
	findings_render_v1 "$run_id" "$inputs"
	return
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
	chosen-upstream)
		(($# == 2)) || usage
		contract_load "$samples_file"
		prepare_chosen_upstream "$1" "$2"
		# shellcheck disable=SC2031 # This test action reads a separately exported worker identity.
		jq -n -c --argjson upstream "$BENCHMARK_UPSTREAM_IDENTITY_JSON" \
			--argjson selected "$BENCHMARK_SELECTED_SETTINGS_JSON" \
			'{upstream:$upstream,selectedSettings:$selected}'
		;;
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
	results-header)
		(($# == 0)) || usage
		printf '%s\n' "$results_header"
		;;
	declared-commands)
		(($# >= 1 && $# <= 2)) || usage
		read_declared_commands "$@"
		;;
	commands)
		(($# == 8)) || usage
		build_commands "$@"
		;;
	vmaf-stats)
		(($# == 1)) || usage
		vmaf_stats "$1"
		;;
	diagnostic-vmaf-classify)
		(($# == 1)) || usage
		diagnostic_vmaf_classify "$1"
		;;
	diagnostic-metric-value)
		(($# == 2)) || usage
		diagnostic_metric_value "$1" "$2"
		;;
	diagnostic-hdr-normalize)
		(($# == 1)) || usage
		diagnostic_hdr_normalize "$1"
		;;
	diagnostic-hdr-classify)
		(($# == 1)) || usage
		diagnostic_hdr_classify "$1"
		;;
	savings-stats)
		(($# == 1)) || usage
		savings_stats "$1"
		;;
	x265-match)
		(($# == 1)) || usage
		x265_match "$1"
		;;
	x265-next)
		(($# == 1)) || usage
		x265_next "$1"
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
		(($# >= 4 && $# <= 5)) || usage
		validate_probes "$@"
		;;
	record-result)
		(($# == 3)) || usage
		record_result "$@"
		;;
	audio-inventory)
		(($# == 3)) || usage
		append_audio_inventory "$@"
		;;
	rank-quality-candidates)
		(($# == 3)) || usage
		rank_quality_candidates "$@"
		;;
	validate-contention-observations)
		(($# == 1)) || usage
		validate_contention_observations "$1"
		;;
	validate-findings-inputs)
		(($# == 1)) || usage
		validate_findings_inputs "$1"
		;;
	findings-fragment)
		(($# == 2)) || usage
		findings_validate_contention_fragment "$1" "$2"
		;;
	findings-manifest)
		(($# == 3)) || usage
		contract_load "$samples_file"
		findings_validate_manifest "$1" "$2" "$3"
		;;
	findings-conclusion)
		(($# == 5)) || usage
		findings_conclusion "$@"
		;;
	diagnostic-terminal)
		(($# == 3)) || usage
		contract_load "$samples_file"
		summary="$(jq -e -c . "$3")" || return 65
		diagnostic_terminal "$1" "$2" "$summary"
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
diagnostics)
	(($# == 0 || $# == 1)) || usage
	contract_load "$samples_file" || exit $?
	contract_require_diagnostics "$samples_file" || exit $?
	diagnostics_mode "${1:-}"
	;;
quality)
	(($# == 0 || $# == 1)) || usage
	contract_load "$samples_file" || exit $?
	require_running_image_evidence || exit $?
	quality_mode "${1:-}"
	;;
x265)
	(($# == 2)) || usage
	contract_load "$samples_file" || exit $?
	contract_validate_chosen_settings "$samples_file" || exit $?
	require_running_image_evidence || exit $?
	x265_mode "$1" "$2"
	;;
savings)
	(($# == 1)) || usage
	contract_load "$samples_file" || exit $?
	contract_validate_chosen_settings "$samples_file" || exit $?
	require_running_image_evidence || exit $?
	savings_mode "$1"
	;;
finalist)
	(($# == 2)) || usage
	contract_load "$samples_file" || exit $?
	contract_validate_chosen_settings "$samples_file" || exit $?
	require_running_image_evidence || exit $?
	finalist_mode "$1" "$2"
	;;
contention)
	(($# == 4)) || usage
	contract_load "$samples_file" || exit $?
	contract_validate_chosen_settings "$samples_file" || exit $?
	require_running_image_evidence || exit $?
	contention_mode "$1" "$2" "$3" "$4"
	;;
findings)
	(($# == 1)) || usage
	contract_load "$samples_file" || exit $?
	findings_mode "$1"
	;;
*) usage ;;
esac
