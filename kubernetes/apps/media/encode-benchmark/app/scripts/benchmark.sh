#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
benchmark_out="${BENCHMARK_OUT:-/out}"
scratch_root="${BENCHMARK_SCRATCH:-/scratch}"
samples_file="${BENCHMARK_SAMPLES_FILE:-/config/samples.json}"
test_mode="${BENCHMARK_TEST_MODE:-0}"
results_header='run_id,panel,sample_id,cohort,source_sha256,clip_id,encoder,requested_setting,selected_rate_control,status,attempt,input_bytes,output_bytes,reduction_percent,input_bit_rate,output_bit_rate,wall_seconds,encode_fps,encode_speed,vmaf_harmonic_mean,vmaf_1pct_low,ssim,gpu_busy_percent,qsv_proof,validation_codec,validation_duration,validation_resolution,validation_frame_rate,validation_bit_depth,validation_hdr,validation_audio_tracks,validation_subtitle_tracks,validation_chapters,validation_failures,log_path,output_disposition'

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
if [[ "$test_mode" != '1' ]]; then
	for test_hook in \
		BENCHMARK_TEST_SOURCE_PROBE BENCHMARK_TEST_OUTPUT_PROBE \
		BENCHMARK_TEST_FDINFO_FIXTURE BENCHMARK_TEST_INVALID_OUTPUT_MATCH \
		BENCHMARK_TEST_INVALID_OUTPUT_PROBE BENCHMARK_TEST_FAIL_RESULT_APPEND \
		BENCHMARK_TEST_FAIL_AUDIO_INVENTORY_WRITE; do
		if [[ -v "$test_hook" ]]; then
			echo 'BENCHMARK_TEST_* hooks require BENCHMARK_TEST_MODE=1' >&2
			exit 64
		fi
	done
fi

usage() {
	echo 'usage: benchmark.sh capabilities | quality [run-id] | savings <run-id> | finalist <run-id> <sample-id> | contention <run-id> <a|b|c|d> <worker-id> <sample-id> | findings <run-id>' >&2
	exit 64
}

validate_run_id() {
	local run_id="$1"
	[[ "$run_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]] || {
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
	local -a clip_command qsv_command x265_command vmaf_command ssim_command
	local clip_json qsv_json x265_json vmaf_json ssim_json

	clip_command=(ffmpeg -v error -ss "$timestamp" -i "$source" -t 90 -map 0 -c copy "$clip")
	qsv_command=(
		ffmpeg -v verbose -init_hw_device qsv=hw:/dev/dri/renderD128
		-filter_hw_device hw -i "$clip" -map 0 -c:v hevc_qsv -preset veryslow
		-global_quality "$gq" -look_ahead 1 -extbrc 1 -c:a copy -c:s copy
		-map_metadata 0 -map_chapters 0 "$qsv_output"
	)
	x265_command=(
		ffmpeg -v verbose -i "$clip" -map 0 -c:v libx265 -preset slow -crf "$crf"
		-c:a copy -c:s copy -map_metadata 0 -map_chapters 0 "$x265_output"
	)
	vmaf_command=(
		ffmpeg -v error -i "$qsv_output" -i "$clip" -lavfi
		"[0:v][1:v]libvmaf=model=version=vmaf_4k_v0.6.1:log_fmt=json:log_path=$vmaf_log"
		-f null -
	)
	ssim_command=(
		ffmpeg -v info -i "$qsv_output" -i "$clip" -lavfi '[0:v][1:v]ssim'
		-f null -
	)

	clip_json="$(array_json "${clip_command[@]}")"
	qsv_json="$(array_json "${qsv_command[@]}")"
	x265_json="$(array_json "${x265_command[@]}")"
	vmaf_json="$(array_json "${vmaf_command[@]}")"
	ssim_json="$(array_json "${ssim_command[@]}")"
	jq -n -c \
		--argjson clip "$clip_json" \
		--argjson qsv "$qsv_json" \
		--argjson x265 "$x265_json" \
		--argjson vmaf "$vmaf_json" \
		--argjson ssim "$ssim_json" \
		'{clip: $clip, qsv: $qsv, x265: $x265, vmaf: $vmaf, ssim: $ssim}'
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
	local matched premium
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
		else .points | sort_by(.vmaf, .crf)[] | [.vmaf, .bitRate, .crf] | @tsv
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
		if awk -v q="$qsv_vmaf" -v lower="$v1" -v upper="$v2" \
			'BEGIN { exit !(lower <= q && q <= upper) }'; then
			matched="$(awk -v q="$qsv_vmaf" -v v1="$v1" -v b1="$b1" -v v2="$v2" -v b2="$b2" '
				BEGIN {
					if (v1 == v2) printf "%.6f", b1
					else printf "%.6f", b1 + (q - v1) * (b2 - b1) / (v2 - v1)
				}
			')"
			premium="$(awk -v q="$qsv_bit_rate" -v matched="$matched" \
				'BEGIN { printf "%.6f", (q - matched) * 100 / matched }')"
			printf '{"status":"bracketed","lower_crf":%s,"upper_crf":%s,"matched_bit_rate":%s,"premium_percent":%s}\n' \
				"$crf1" "$crf2" "$matched" "$premium"
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
	local encode_log="$1"
	local fdinfo_log="$2"
	local height="$3"
	local selected='unknown' initialization='failed' fps='0.000000' speed='0.000000'
	local gpu delta telemetry metrics reasons='' proof='suspect' value
	if grep -q -E 'Successfully initiali[sz]ed the hardware device' "$encode_log" &&
		! grep -q -E 'Device creation failed|Failed to initiali[sz]e' "$encode_log"; then
		initialization='passed'
	fi
	value="$(grep -o -i -E 'LA[_-]?ICQ|CQP|ICQ|CBR|VBR|AVBR|QVBR' "$encode_log" | tail -n 1 || true)"
	case "${value^^}" in
	LA_ICQ | LA-ICQ | LAICQ) selected='LA-ICQ' ;;
	CQP | ICQ | CBR | VBR | AVBR | QVBR) selected="${value^^}" ;;
	esac
	value="$(grep -o -E 'fps=[[:space:]]*[0-9]+([.][0-9]+)?' "$encode_log" | tail -n 1 | sed 's/fps=[[:space:]]*//' || true)"
	[[ -z "$value" ]] || fps="$(awk -v value="$value" 'BEGIN { printf "%.6f", value }')"
	value="$(grep -o -E 'speed=[[:space:]]*[0-9]+([.][0-9]+)?x' "$encode_log" | tail -n 1 | sed 's/speed=[[:space:]]*//; s/x$//' || true)"
	[[ -z "$value" ]] || speed="$(awk -v value="$value" 'BEGIN { printf "%.6f", value }')"
	metrics="$(drm_fdinfo_metrics "$fdinfo_log")"
	telemetry="$(jq -r '.status' <<<"$metrics")"
	delta="$(jq -r '.video_busy_nanoseconds' <<<"$metrics")"
	gpu="$(awk -v value="$(jq -r '.video_busy_percent' <<<"$metrics")" \
		'BEGIN { printf "%.6f", value }')"

	if [[ "$initialization" != 'passed' ]]; then
		reasons='initialization'
	fi
	if [[ "$selected" != 'LA-ICQ' ]]; then
		reasons="${reasons:+$reasons;}rate-control"
	fi
	if [[ "$telemetry" != 'available' ]] || ! awk -v delta="$delta" 'BEGIN { exit !(delta > 0) }'; then
		reasons="${reasons:+$reasons;}telemetry"
	fi
	if ((height == 0)); then
		if ! awk -v value="$speed" 'BEGIN { exit !(value > 0) }'; then
			reasons="${reasons:+$reasons;}speed"
		fi
	elif ((height >= 2160)); then
		if ! awk -v value="$speed" 'BEGIN { exit !(value >= 0.5 && value <= 2.0) }'; then
			reasons="${reasons:+$reasons;}speed"
		fi
	elif ! awk -v value="$speed" 'BEGIN { exit !(value >= 2.0 && value <= 20.0) }'; then
		reasons="${reasons:+$reasons;}speed"
	fi
	[[ -n "$reasons" ]] || proof='passed'
	printf '{"selected_rate_control":"%s","initialization":"%s","encode_fps":%s,"encode_speed":%s,"gpu_busy_percent":%s,"qsv_proof":"%s","suspect_reasons":"%s"}\n' \
		"$selected" "$initialization" "$fps" "$speed" "$gpu" "$proof" "$reasons"
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

result_key_passed() {
	local results="$1"
	local panel="$2" sha="$3" clip="$4" encoder="$5" setting="$6"
	awk -F, -v panel="$panel" -v sha="$sha" -v clip="$clip" -v encoder="$encoder" -v setting="$setting" '
		NR > 1 && $2 == panel && $5 == sha && $6 == clip && $7 == encoder && $8 == setting && $10 == "passed" { found = 1 }
		END { exit !found }
	' "$results"
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

record_result_inner() {
	local run_id="$1"
	local fixture="$2"
	local scratch_output="$3"
	local run_directory results panel sample_id cohort source_sha clip encoder setting
	local selected status attempt disposition='discarded' confirmation destination
	local encodes_directory='' staged_destination='' backup_destination='' published=0 had_prior=0
	local append_status=0 columns_text out_physical runs_physical run_physical encodes_physical
	local -a columns
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
	validate_sample_id "$sample_id" || return
	[[ "$panel" == 'quality' || "$panel" == 'savings' || "$panel" == 'finalist' ]] || return 65
	[[ "$encoder" == 'qsv' || "$encoder" == 'x265' ]] || return 65
	[[ "$setting" =~ ^[0-9]+$ ]] || return 65
	[[ "$source_sha" =~ ^[0-9a-f]{64}$ ]] || return 65
	results="$run_directory/results.csv"
	ensure_results_file "$results" || return
	if result_key_passed "$results" "$panel" "$source_sha" "$clip" "$encoder" "$setting"; then
		attempt=$(("$(result_attempt "$results" "$panel" "$source_sha" "$clip" "$encoder" "$setting")" - 1))
		printf '{"status":"skipped","attempt":%s,"output_disposition":"not-created"}\n' "$attempt"
		return
	fi
	attempt="$(result_attempt "$results" "$panel" "$source_sha" "$clip" "$encoder" "$setting")"
	status='passed'
	if [[ "$(jq -r '.encode_status // 0' "$fixture")" != '0' ]]; then
		status='failed'
	elif [[ -n "$(jq -r '.validation_failures' "$fixture")" ]]; then
		status='invalid'
	elif [[ "$encoder" == 'qsv' ]] &&
		[[ "$selected" != 'LA-ICQ' || "$(jq -r '.qsv_proof' "$fixture")" != 'passed' ]]; then
		status='invalid'
	fi

	if [[ "$panel" == 'finalist' ]]; then
		confirmation="copy:encode-benchmark:$run_id:$sample_id"
		if [[ "${ENCODE_BENCHMARK_FINALIST_CONFIRM:-}" != "$confirmation" ]]; then
			echo "missing finalist confirmation for $run_id/$sample_id" >&2
			return 64
		fi
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
			.validation_chapters, .validation_failures, .log_path
		] | if length == 32 and all(.[]; type == "string")
		then .[] else error("invalid result fixture") end
	' "$fixture")" || return 65
	mapfile -t columns <<<"$columns_text"
	((${#columns[@]} == 32)) || return 65
	columns=(
		"$run_id" "${columns[0]}" "${columns[1]}" "${columns[2]}" "${columns[3]}"
		"${columns[4]}" "${columns[5]}" "${columns[6]}" "${columns[7]}" "$status"
		"$attempt" "${columns[@]:8}" "$disposition"
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
		rm -f -- "$staged_destination" "$backup_destination"
		cp -- "$scratch_output" "$staged_destination" || return
		if [[ -e "$destination" ]]; then
			mv -- "$destination" "$backup_destination" || {
				rm -f -- "$staged_destination"
				return 74
			}
			had_prior=1
		fi
		if ! mv -- "$staged_destination" "$destination"; then
			if ((had_prior)); then mv -- "$backup_destination" "$destination"; fi
			return 74
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
			rm -f -- "$destination"
			if ((had_prior)); then mv -- "$backup_destination" "$destination"; fi
		fi
		if [[ -n "$staged_destination" ]]; then rm -f -- "$staged_destination"; fi
		if [[ -n "$backup_destination" ]]; then rm -f -- "$backup_destination"; fi
		return "$append_status"
	fi
	if [[ -n "$backup_destination" ]]; then rm -f -- "$backup_destination"; fi
	printf '{"status":"%s","attempt":%s,"output_disposition":"%s"}\n' \
		"$status" "$attempt" "$disposition"
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
	encoders="$(ffmpeg -hide_banner -encoders)"
	filters="$(ffmpeg -hide_banner -filters)"
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
	ffmpeg -v error -nostdin -f lavfi -i 'testsrc2=size=1920x1080:rate=30' -t 5 \
		-pix_fmt yuv420p "$source"
	set +e
	proof_json="$(capability_proof "$encode_log" "$fdinfo_log")"
	proof_exit=$?
	set -e
	ffmpeg_version="$(ffmpeg -version | awk 'NR == 1 { print $3 }')"
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
	capabilities >/dev/null
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
	encoders="$(ffmpeg -hide_banner -encoders)" || return
	filters="$(ffmpeg -hide_banner -filters)" || return
	grep -q -F 'hevc_qsv' <<<"$encoders" || {
		echo 'hevc_qsv encoder is unavailable' >&2
		return 1
	}
	grep -q -F 'libx265' <<<"$encoders" || {
		echo 'libx265 encoder is unavailable' >&2
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
	local timestamp fd_path target fdinfo
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

run_qsv_encode() {
	local input="$1"
	local output="$2"
	local setting="$3"
	local encode_log="$4"
	local fdinfo_log="$5"
	local ffmpeg_pid sampler_pid status
	if [[ "$test_mode" == '1' && -n "${BENCHMARK_TEST_FDINFO_FIXTURE:-}" ]]; then
		cp "$BENCHMARK_TEST_FDINFO_FIXTURE" "$fdinfo_log"
		ffmpeg -v verbose -nostdin -init_hw_device qsv=hw:/dev/dri/renderD128 \
			-filter_hw_device hw -i "$input" -map 0 -c:v hevc_qsv -preset veryslow \
			-global_quality "$setting" -look_ahead 1 -extbrc 1 \
			-c:a copy -c:s copy -map_metadata 0 -map_chapters 0 "$output" >"$encode_log" 2>&1
		return
	fi
	ffmpeg -v verbose -nostdin -init_hw_device qsv=hw:/dev/dri/renderD128 \
		-filter_hw_device hw -i "$input" -map 0 -c:v hevc_qsv -preset veryslow \
		-global_quality "$setting" -look_ahead 1 -extbrc 1 \
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
	local capability_directory source encoded proof_json metrics_json
	local encode_status decode='failed' vmaf='failed' proof_status='passed' reasons=''
	local initialization selected telemetry delta percent fps speed telemetry_reason
	capability_directory="$(dirname "$encode_log")"
	source="$capability_directory/source.mkv"
	encoded="$capability_directory/qsv.mkv"

	set +e
	run_qsv_encode "$source" "$encoded" 22 "$encode_log" "$fdinfo_log"
	encode_status=$?
	set -e
	proof_json="$(qsv_proof "$encode_log" "$fdinfo_log" 0)"
	metrics_json="$(drm_fdinfo_metrics "$fdinfo_log")"
	initialization="$(jq -r '.initialization' <<<"$proof_json")"
	selected="$(jq -r '.selected_rate_control' <<<"$proof_json")"
	fps="$(jq -r '.encode_fps' <<<"$proof_json")"
	speed="$(jq -r '.encode_speed' <<<"$proof_json")"
	telemetry="$(jq -r '.status' <<<"$metrics_json")"
	delta="$(jq -r '.video_busy_nanoseconds' <<<"$metrics_json")"
	percent="$(jq -r '.video_busy_percent' <<<"$metrics_json")"
	telemetry_reason="$(jq -r '.reason' <<<"$metrics_json")"

	if ((encode_status == 0)) && ffmpeg -v error -nostdin -i "$encoded" -map 0:v:0 -f null - \
		>/dev/null 2>&1; then
		decode='passed'
	fi
	if ((encode_status == 0)) && ffmpeg -v error -nostdin -i "$encoded" -i "$source" -lavfi \
		'[0:v][1:v]libvmaf=model=version=vmaf_4k_v0.6.1' -f null - >/dev/null 2>&1; then
		vmaf='passed'
	fi

	[[ "$initialization" == 'passed' ]] || reasons='initialization'
	[[ "$selected" == 'LA-ICQ' ]] || reasons="${reasons:+$reasons;}rate-control"
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
	if [[ "$proof_status" != 'harness-blocked' && -n "$reasons" ]]; then
		proof_status='failed'
	fi

	jq -n -c \
		--arg initialization "$initialization" \
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
		--arg reasons "$reasons" '{
			proofSchemaVersion: 2,
			initialization: $initialization,
			selectedRateControl: $selected,
			telemetryStatus: $telemetry,
			telemetryReason: $telemetry_reason,
			videoBusyNanoseconds: $delta,
			videoBusyPercent: $percent,
			encodeFps: $fps,
			encodeSpeed: $speed,
			decode: $decode,
			vmaf: $vmaf,
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
	ffmpeg -v verbose -i "$input" -map 0 -c:v libx265 -preset slow -crf "$setting" \
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
	local vmaf_file ssim_file source_probe validation metrics value height='0'
	local input_bytes='0' output_bytes='0' duration='0' input_rate='0' output_rate='0'
	local reduction='0.000000' fps='0.000000' speed='0.000000' vmaf_harmonic=''
	local vmaf_low='' ssim='' gpu_busy='' qsv_status='not-applicable' selected='CRF'
	local validation_failures validation_codec validation_duration validation_resolution
	local validation_frame_rate validation_bit_depth validation_hdr validation_audio
	local validation_subtitle validation_chapters decode_status=1 proof_json progress

	run_directory="$benchmark_out/runs/$run_id"
	logs_directory="$run_directory/logs"
	evidence_base="$sample_id-$clip_id-$encoder-$setting-attempt-$attempt"
	mkdir -p "$logs_directory"
	source_probe_file="$logs_directory/$evidence_base-source-probe.json"
	output_probe_file="$logs_directory/$evidence_base-output-probe.json"
	validation_file="$logs_directory/$evidence_base-validation.json"
	vmaf_file="$logs_directory/$evidence_base-vmaf.json"
	ssim_file="$logs_directory/$evidence_base-ssim.log"
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
		if ffmpeg -v error -i "$output" -map 0 -f null -; then decode_status=0; fi
		if [[ "$source_probe" != '{}' ]] && probe_media output "$output" >"$output_probe_file" 2>&1 &&
			jq -e . "$output_probe_file" >/dev/null 2>&1; then
			if ! validation="$(validate_probes "$source_probe_file" "$output_probe_file" "$scope" "$decode_status" 2>/dev/null)"; then
				validation="$(failed_validation validation-parse)"
			fi
		else
			validation="$(failed_validation output-probe)"
		fi
		if [[ "$panel" == 'quality' ]]; then
			if ffmpeg -v error -i "$output" -i "$reference" -lavfi \
				"[0:v][1:v]libvmaf=model=version=vmaf_4k_v0.6.1:log_fmt=json:log_path=$vmaf_file" \
				-f null - && metrics="$(vmaf_stats "$vmaf_file" 2>/dev/null)" &&
				vmaf_harmonic="$(jq -e -r '.harmonic_mean | numbers' <<<"$metrics" 2>/dev/null)" &&
				vmaf_low="$(jq -e -r '.one_percent_low | numbers' <<<"$metrics" 2>/dev/null)"; then
				:
			else
				vmaf_harmonic=''
				vmaf_low=''
				validation="$(add_validation_failure "$validation" vmaf)"
			fi
			if ffmpeg -v info -i "$output" -i "$reference" -lavfi '[0:v][1:v]ssim' \
				-f null - >"$ssim_file" 2>&1 &&
				value="$(grep -o -E 'All:[0-9]+([.][0-9]+)?' "$ssim_file" | tail -n 1 | cut -d: -f2)" &&
				[[ -n "$value" ]]; then
				ssim="$value"
			else
				ssim=''
				validation="$(add_validation_failure "$validation" ssim)"
			fi
		fi
		if [[ -n "$still_prefix" ]] &&
			! "$script_directory/stills.sh" "$reference" "$output" '00:00:00.000' "$still_prefix"; then
			validation="$(add_validation_failure "$validation" stills)"
		fi
	fi
	printf '%s\n' "$validation" >"$validation_file"

	if [[ "$encoder" == 'qsv' ]]; then
		if proof_json="$(qsv_proof "$encode_log" "$busy_log" "$height" 2>/dev/null)" &&
			jq -e . <<<"$proof_json" >/dev/null 2>&1; then
			selected="$(jq -r '.selected_rate_control' <<<"$proof_json")"
			fps="$(jq -r '.encode_fps' <<<"$proof_json")"
			speed="$(jq -r '.encode_speed' <<<"$proof_json")"
			gpu_busy="$(jq -r '.gpu_busy_percent' <<<"$proof_json")"
			qsv_status="$(jq -r '.qsv_proof' <<<"$proof_json")"
		else
			selected='unknown'
			qsv_status='suspect'
			validation="$(add_validation_failure "$validation" qsv-proof)"
			printf '%s\n' "$validation" >"$validation_file"
		fi
	else
		if progress="$(encoder_progress "$encode_log" 2>/dev/null)"; then
			IFS='|' read -r fps speed <<<"$progress"
		fi
	fi

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
		--arg failures "$validation_failures" --arg log_path "logs/${encode_log##*/}" '{
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
			validation_failures: $failures, log_path: $log_path
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
		commands="$(jq -n -c '["ffmpeg -v error -ss <timestamp> -i <source> -t 90 -map 0 -c copy <clip>"]')"
		settings=(20 22 24 26 28)
	else
		mapfile -t settings < <(jq -r '.chosenSettings[]?.globalQuality' "$samples_file" | sort -nu)
	fi
	for setting in "${settings[@]}"; do
		[[ "$setting" =~ ^(20|22|24|26|28)$ ]] || continue
		commands="$(jq -c --arg command \
			"ffmpeg -v verbose -init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw -i <input> -map 0 -c:v hevc_qsv -preset veryslow -global_quality $setting -look_ahead 1 -extbrc 1 -c:a copy -c:s copy -map_metadata 0 -map_chapters 0 <output>" \
			'. + [$command]' <<<"$commands")"
	done
	if [[ "$mode" == 'quality' ]]; then
		for ((setting = 10; setting <= 34; setting += 2)); do
			commands="$(jq -c --arg command \
				"ffmpeg -v verbose -i <input> -map 0 -c:v libx265 -preset slow -crf $setting -c:a copy -c:s copy -map_metadata 0 -map_chapters 0 <output>" \
				'. + [$command]' <<<"$commands")"
		done
	fi
	printf '%s\n' "$commands"
}

encode_one_variant() {
	local run_id="$1" panel="$2" sample_id="$3" cohort="$4" sha="$5" clip_id="$6"
	local encoder="$7" setting="$8" input="$9" scope="${10}" still_prefix="${11:-}"
	local disposition="${12:-record}" run_directory results attempt evidence_base
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
		"$encode_log" "$busy_log" "$still_prefix" "$attempt" "$row_fixture"
	if [[ "$disposition" == 'defer' ]]; then
		printf '%s|%s\n' "$row_fixture" "$output"
		return
	fi
	record_result "$run_id" "$row_fixture" "$output" || record_status=$?
	rm -f -- "$row_fixture"
	return "$record_status"
}

append_comparison_once() {
	local output="$1" comparison="$2" sample_id="$3" clip_id="$4" setting="$5" staged
	staged="$output.$$.tmp"
	rm -f -- "$staged"
	if [[ -e "$output" || -L "$output" ]]; then
		[[ -f "$output" && ! -L "$output" ]] || return 65
		jq -e -s 'all(.[]; type == "object")' "$output" >/dev/null || return 65
		jq -c --arg sample "$sample_id" --arg clip "$clip_id" --arg setting "$setting" '
			select(.sample_id != $sample or .clip_id != $clip or .qsv_setting != $setting)
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

quality_mode() {
	local explicit_run_id="${1:-}" run_id run_directory run_scratch sample sample_id cohort
	local source sha detection clip_id timestamp clip x265_points qsv_points setting attempted_crfs
	local comparison_fixture comparison decision target next_crf
	local panel_samples
	local -a qsv_settings=(20 22 24 26 28) x265_settings=(18 20 22 24)
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
		while IFS=$'\t' read -r clip_id timestamp; do
			clip="$run_scratch/$sample_id-$clip_id-source.mkv"
			ffmpeg -v error -ss "$timestamp" -i "$source" -t 90 -map 0 -c copy "$clip" </dev/null
			for setting in "${qsv_settings[@]}"; do
				if row_is_complete "$run_id" quality "$sha" "$clip_id" qsv "$setting"; then continue; fi
				encode_one_variant "$run_id" quality "$sample_id" "$cohort" "$sha" "$clip_id" \
					qsv "$setting" "$clip" clip \
					"$run_directory/stills/$sample_id-$clip_id-qsv-$setting" >/dev/null
			done
			for setting in "${x265_settings[@]}"; do
				if row_is_complete "$run_id" quality "$sha" "$clip_id" x265 "$setting"; then continue; fi
				encode_one_variant "$run_id" quality "$sample_id" "$cohort" "$sha" "$clip_id" \
					x265 "$setting" "$clip" clip \
					"$run_directory/stills/$sample_id-$clip_id-x265-$setting" >/dev/null
			done
			qsv_points="$(awk -F, -v sha="$sha" -v clip="$clip_id" '
				NR > 1 && $2 == "quality" && $5 == sha && $6 == clip && $7 == "qsv" && $10 == "passed" {
					printf "%s\t%s\t%s\n", $8, $20, $16
				}
			' "$run_directory/results.csv")"
			for target in \
				"$(awk -F$'\t' 'NF == 3 { if (!seen || $2 > value) value = $2; seen = 1 } END { if (seen) print value }' <<<"$qsv_points")" \
				"$(awk -F$'\t' 'NF == 3 { if (!seen || $2 < value) value = $2; seen = 1 } END { if (seen) print value }' <<<"$qsv_points")"; do
				[[ -n "$target" ]] || continue
				while :; do
					x265_points="$(awk -F, -v sha="$sha" -v clip="$clip_id" '
						NR > 1 && $2 == "quality" && $5 == sha && $6 == clip && $7 == "x265" && $10 == "passed" {
							printf "{\"crf\":%s,\"vmaf\":%s,\"bitRate\":%s}\n", $8, $20, $16
						}
					' "$run_directory/results.csv")"
					attempted_crfs="$(awk -F, -v sha="$sha" -v clip="$clip_id" '
						NR > 1 && $2 == "quality" && $5 == sha && $6 == clip && $7 == "x265" { print $8 }
					' "$run_directory/results.csv" | sort -nu | jq -R -s -c 'split("\n") | map(select(length > 0) | tonumber)')"
					comparison_fixture="$run_scratch/next-comparison.json"
					jq -n -c \
						--argjson points "$(jq -s . <<<"$x265_points")" \
						--argjson attempted "$attempted_crfs" \
						--argjson qsv_vmaf "$target" \
						'{points: $points, attemptedCrfs: $attempted, qsvVmaf: $qsv_vmaf, qsvBitRate: 1}' >"$comparison_fixture"
					decision="$(x265_next "$comparison_fixture")"
					[[ "$(jq -r '.status' <<<"$decision")" == 'extend' ]] || break
					next_crf="$(jq -r '.next_crf' <<<"$decision")"
					if ! row_is_complete "$run_id" quality "$sha" "$clip_id" x265 "$next_crf"; then
						encode_one_variant "$run_id" quality "$sample_id" "$cohort" "$sha" "$clip_id" \
							x265 "$next_crf" "$clip" clip \
							"$run_directory/stills/$sample_id-$clip_id-x265-$next_crf" >/dev/null
					fi
				done
			done
			x265_points="$(awk -F, -v sha="$sha" -v clip="$clip_id" '
				NR > 1 && $2 == "quality" && $5 == sha && $6 == clip && $7 == "x265" && $10 == "passed" {
					printf "{\"crf\":%s,\"vmaf\":%s,\"bitRate\":%s}\n", $8, $20, $16
				}
			' "$run_directory/results.csv")"
			while IFS=$'\t' read -r setting qsv_vmaf qsv_rate; do
				[[ -n "$setting" ]] || continue
				comparison_fixture="$run_scratch/comparison.json"
				jq -n -c \
					--argjson points "$(jq -s . <<<"$x265_points")" \
					--argjson qsv_vmaf "$qsv_vmaf" --argjson qsv_rate "$qsv_rate" \
					'{points: $points, qsvVmaf: $qsv_vmaf, qsvBitRate: $qsv_rate}' >"$comparison_fixture"
				comparison="$(x265_match "$comparison_fixture")"
				comparison="$(jq -c --arg sample "$sample_id" --arg clip "$clip_id" --arg setting "$setting" \
					'. + {sample_id: $sample, clip_id: $clip, qsv_setting: $setting}' \
					<<<"$comparison")"
				append_comparison_once "$run_directory/x265-comparisons.jsonl" "$comparison" \
					"$sample_id" "$clip_id" "$setting"
			done <<<"$qsv_points"
			rm -f -- "$clip"
		done < <(jq -r '.clips | to_entries[] | [.key, .value] | @tsv' <<<"$sample")
	done < <(jq -c '.qualityPanel[]?' "$samples_file")
	rm -rf -- "$run_scratch"
	printf '%s\n' "$run_id"
}

savings_mode() {
	local requested_run_id="$1" run_id run_directory run_scratch sample sample_id cohort
	local source sha setting packets probe_file detection prepared row_fixture output
	local failed_row inventory_status
	local panel_samples
	assigned_node_capability_gate || return
	panel_samples="$(jq -c '[.savingsPanel[]?]' "$samples_file")"
	runtime_pre_encode_gate "$panel_samples" || return
	BENCHMARK_ENCODER_COMMANDS_JSON="$(encoder_commands_for_mode savings)"
	export BENCHMARK_ENCODER_COMMANDS_JSON
	run_id="$("$script_directory/runmeta.sh" create savings "$requested_run_id")"
	run_directory="$benchmark_out/runs/$run_id"
	run_scratch="$scratch_root/$run_id"
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
		setting="$(jq -r ".chosenSettings.\"$cohort\".globalQuality // \"\"" "$samples_file")"
		[[ "$setting" =~ ^(20|22|24|26|28)$ ]] || continue
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
	local sample sample_id cohort source sha setting expected_confirmation
	validate_sample_id "$requested_sample_id" || return
	expected_confirmation="copy:encode-benchmark:$requested_run_id:$requested_sample_id"
	[[ "${ENCODE_BENCHMARK_FINALIST_CONFIRM:-}" == "$expected_confirmation" ]] || {
		echo "missing finalist confirmation for $requested_run_id/$requested_sample_id" >&2
		return 64
	}
	sample="$(SAMPLE_ID="$requested_sample_id" jq -c \
		'.qualityPanel[]?, .savingsPanel[]? | select(.id == env.SAMPLE_ID)' "$samples_file" | head -n 1)"
	[[ -n "$sample" ]] || {
		echo "sample not found: $requested_sample_id" >&2
		return 66
	}
	assigned_node_capability_gate || return
	runtime_pre_encode_gate "$(jq -n -c --argjson sample "$sample" '[$sample]')" || return
	BENCHMARK_ENCODER_COMMANDS_JSON="$(encoder_commands_for_mode finalist)"
	export BENCHMARK_ENCODER_COMMANDS_JSON
	run_id="$("$script_directory/runmeta.sh" create finalist "$requested_run_id")"
	run_directory="$benchmark_out/runs/$run_id"
	run_scratch="$scratch_root/$run_id"
	mkdir -p "$run_directory/logs" "$run_scratch"
	sample_id="$(jq -r '.id' <<<"$sample")"
	cohort="$(jq -r '.cohort' <<<"$sample")"
	[[ "$cohort" != 'dolby-vision' && "$(jq -r '.detectionOnly // false' <<<"$sample")" != 'true' ]] || {
		echo 'Dolby Vision samples cannot be encoded' >&2
		return 65
	}
	source="$(jq -r '.path' <<<"$sample")"
	sha="$(jq -r '.sha256' <<<"$sample")"
	setting="$(jq -r ".chosenSettings.\"$cohort\".globalQuality // \"\"" "$samples_file")"
	[[ "$setting" =~ ^(20|22|24|26|28)$ ]] || {
		echo "no committed setting for cohort: $cohort" >&2
		return 65
	}
	if ! row_is_complete "$run_id" finalist "$sha" full qsv "$setting"; then
		encode_one_variant "$run_id" finalist "$sample_id" "$cohort" "$sha" full \
			qsv "$setting" "$source" full '' >/dev/null
	fi
	rm -rf -- "$run_scratch"
	printf '%s\n' "$run_id"
}

contention_mode() (
	local requested_run_id="$1" contention_case="$2" worker_id="$3" requested_sample_id="$4"
	local sample sample_id cohort setting run_id run_directory run_scratch attempt fragment staged
	local output encode_log busy_log row_fixture start end wall encode_status=0 status qsv failures resolution
	trap 'rm -f -- "${output:-}" "${row_fixture:-}" "${staged:-}" 2>/dev/null || true
		if [[ -n "${run_scratch:-}" ]]; then rm -rf -- "$run_scratch"; fi' EXIT
	validate_run_id "$requested_run_id" || return
	validate_sample_id "$requested_sample_id" || return
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
	setting="$(jq -r ".chosenSettings.\"$cohort\".globalQuality // \"\"" "$samples_file")"
	[[ "$setting" =~ ^(20|22|24|26|28)$ ]] || {
		echo "no committed setting for cohort: $cohort" >&2
		return 65
	}
	assigned_node_capability_gate || return
	runtime_pre_encode_gate "$(jq -n -c --argjson sample "$sample" '[$sample]')" || return
	BENCHMARK_ENCODER_COMMANDS_JSON="$(encoder_commands_for_mode contention)"
	export BENCHMARK_ENCODER_COMMANDS_JSON
	run_id="$("$script_directory/runmeta.sh" create "contention-$contention_case" "$requested_run_id")"
	run_directory="$benchmark_out/runs/$run_id"
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
		printf '%s\n' 'run_id,case,worker_id,sample_id,cohort,setting,status,attempt,wall_seconds,qsv_proof,validation_failures,output_disposition'
		jq -r \
			--arg run_id "$run_id" --arg case "$contention_case" --arg worker "$worker_id" \
			--arg sample "$sample_id" --arg cohort "$cohort" --arg setting "$setting" \
			--arg status "$status" --arg attempt "$attempt" --arg wall "$wall" \
			--arg qsv "$qsv" --arg failures "$failures" \
			'[$run_id,$case,$worker,$sample,$cohort,$setting,$status,$attempt,$wall,$qsv,$failures,"discarded"] | @csv' \
			<<<'{}'
	} >"$staged"
	mv -- "$staged" "$fragment"
	staged=''
	printf '%s\n' "$run_id"
)

findings_mode() {
	local run_id="$1" run_directory inputs quality_run savings_run contention_file
	local quality_results quality_comparisons comparisons_json comparison savings_results contention
	local findings_temp cohort distribution stats comparison_status sample_id clip_id qsv_setting
	local premium verdict contention_fragments='[]' fragment fragment_run fragment_file fragment_path
	local fragment_header fragment_row fragment_fields fragment_case fragment_worker fragment_attempt
	validate_run_id "$run_id" || return
	run_directory="$benchmark_out/runs/$run_id"
	inputs="$run_directory/findings-inputs.json"
	[[ -f "$inputs" && ! -L "$inputs" ]] || {
		echo 'findings inputs not found' >&2
		return 66
	}
	quality_run="$(jq -e -r '.qualityRunId | strings' "$inputs")"
	savings_run="$(jq -e -r '.savingsRunId | strings' "$inputs")"
	contention_file="$(jq -e -r '.contentionFile | strings' "$inputs")"
	contention_fragments="$(jq -e -c '
		.contentionFragments |
		select(type == "array" and length >= 1 and length <= 16) |
		if
			all(.[];
				(type == "object") and (keys == ["file", "runId"]) and
				(.runId | type == "string" and test("^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$")) and
				(.file | type == "string" and test("^contention-[a-d]-worker-[12]-attempt-[1-9][0-9]*[.]csv$"))) and
			([.[] | (.runId + "|" + .file)] | unique | length) == length
		then . else error("invalid contention fragments") end
	' "$inputs")" || {
		echo 'invalid contention fragment inputs' >&2
		return 65
	}
	validate_run_id "$quality_run" || return
	validate_run_id "$savings_run" || return
	[[ "$contention_file" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*[.]json$ ]] || return 64
	quality_results="$benchmark_out/runs/$quality_run/results.csv"
	quality_comparisons="$benchmark_out/runs/$quality_run/x265-comparisons.jsonl"
	savings_results="$benchmark_out/runs/$savings_run/results.csv"
	contention="$run_directory/$contention_file"
	ensure_results_file "$quality_results" || return
	ensure_results_file "$savings_results" || return
	[[ -f "$quality_comparisons" && ! -L "$quality_comparisons" ]] || {
		echo 'quality x265 comparisons not found' >&2
		return 66
	}
	[[ -f "$contention" && ! -L "$contention" ]] || return 66
	contention_rows='[]'
	while IFS= read -r fragment; do
		fragment_run="$(jq -r '.runId' <<<"$fragment")"
		fragment_file="$(jq -r '.file' <<<"$fragment")"
		fragment_path="$benchmark_out/runs/$fragment_run/$fragment_file"
		[[ -f "$fragment_path" && ! -L "$fragment_path" ]] || {
			echo 'named contention fragment not found' >&2
			return 66
		}
		fragment_header="$(head -n 1 "$fragment_path")"
		[[ "$fragment_header" == 'run_id,case,worker_id,sample_id,cohort,setting,status,attempt,wall_seconds,qsv_proof,validation_failures,output_disposition' &&
			"$(wc -l <"$fragment_path" | tr -d ' ')" == '2' ]] || {
			echo 'invalid named contention fragment' >&2
			return 65
		}
		fragment_row="$(tail -n 1 "$fragment_path")"
		fragment_fields="$(jq -R -e -c '
			split(",") |
			select(length == 12 and all(.[]; startswith("\"") and endswith("\""))) |
			map(.[1:-1])
		' <<<"$fragment_row")" || {
			echo 'invalid named contention fragment' >&2
			return 65
		}
		jq -e --arg run "$fragment_run" '
			.[0] == $run and
			(.[1] | test("^[a-d]$")) and
			(.[2] | test("^worker-[12]$")) and
			(.[3] | test("^[a-z0-9][a-z0-9._-]*$")) and
			(.[4] | test("^(avc|vc1|hdr10)$")) and
			(.[5] | test("^(20|22|24|26|28)$")) and
			(.[6] | test("^(passed|failed|invalid)$")) and
			(.[7] | test("^[1-9][0-9]*$")) and
			(.[8] | test("^[0-9]+([.][0-9]+)?$")) and
			(.[9] | test("^(passed|suspect)$")) and
			(.[10] | test("^[a-z0-9;-]*$")) and
			.[11] == "discarded"
		' <<<"$fragment_fields" >/dev/null || {
			echo 'invalid named contention fragment' >&2
			return 65
		}
		fragment_case="$(jq -r '.[1]' <<<"$fragment_fields")"
		fragment_worker="$(jq -r '.[2]' <<<"$fragment_fields")"
		fragment_attempt="$(jq -r '.[7]' <<<"$fragment_fields")"
		[[ "$fragment_file" == "contention-$fragment_case-$fragment_worker-attempt-$fragment_attempt.csv" ]] || {
			echo 'named contention fragment identity mismatch' >&2
			return 65
		}
		contention_rows="$(jq -c --argjson row "$fragment_fields" '. + [$row]' <<<"$contention_rows")"
	done < <(jq -c '.[]' <<<"$contention_fragments")
	comparisons_json="$(jq -e -s '
		if all(.[];
			(type == "object") and
			(.sample_id | type) == "string" and (.sample_id | test("^[a-z0-9][a-z0-9._-]*$")) and
			(.clip_id | type) == "string" and (.clip_id | test("^[a-z0-9][a-z0-9._-]*$")) and
			(.qsv_setting | type) == "string" and (.qsv_setting | test("^[0-9]+$")) and
			((.status == "unbracketed") or
			 (.status == "bracketed" and (.lower_crf | type) == "number" and
			  (.upper_crf | type) == "number" and (.matched_bit_rate | type) == "number" and
			  .matched_bit_rate > 0 and (.premium_percent | type) == "number")))
		then . else error("invalid x265 comparison evidence") end
	' "$quality_comparisons")" || return 65
	jq -e '
		(.baselineStartLatencySeconds | type) == "number" and .baselineStartLatencySeconds >= 0 and
		(.bufferingCount | type) == "number" and (.bufferingCount | floor) == .bufferingCount and .bufferingCount >= 0 and
		(.startLatencySeconds | type) == "number" and .startLatencySeconds >= 0 and
		(.seekToResumeSeconds | type) == "number" and .seekToResumeSeconds >= 0 and
		(.nasUplinkMbps | type) == "number" and .nasUplinkMbps > 0 and
		(.measuredThroughputMbps | type) == "number" and .measuredThroughputMbps >= 0
	' "$contention" >/dev/null || {
		echo 'invalid contention evidence' >&2
		return 65
	}
	findings_temp="$run_directory/findings.md.tmp"
	{
		printf '# Encode benchmark findings\n\n'
		printf 'Quality run: `%s`  \n' "$quality_run"
		printf 'Savings run: `%s`\n\n' "$savings_run"
		printf '## Savings by cohort\n\n'
		printf '| Cohort | Median %% | Q1 %% | Q3 %% | IQR %% | Verdict |\n'
		printf '|---|---:|---:|---:|---:|---|\n'
		while IFS= read -r cohort; do
			[[ -n "$cohort" ]] || continue
			distribution="$(awk -F, -v cohort="$cohort" '
				NR > 1 && $2 == "savings" && $4 == cohort && $10 == "passed" { print $14 }
			' "$savings_results" | jq -R -s -c --arg cohort "$cohort" \
				'{cohort: $cohort, reductionPercent: (split("\n") | map(select(length > 0) | tonumber))}')"
			stats="$(savings_stats /dev/stdin <<<"$distribution")"
			printf '| %s | %s | %s | %s | %s | %s |\n' "$cohort" \
				"$(jq -r '.median' <<<"$stats")" "$(jq -r '.q1' <<<"$stats")" \
				"$(jq -r '.q3' <<<"$stats")" "$(jq -r '.iqr' <<<"$stats")" \
				"$(jq -r '.verdict' <<<"$stats")"
		done < <(awk -F, 'NR > 1 && $2 == "savings" && $10 == "passed" { print $4 }' "$savings_results" | sort -u)
		printf '\n## Quality summary\n\n'
		printf 'Passed variants: %s\n\n' "$(awk -F, 'NR > 1 && $2 == "quality" && $10 == "passed" { count += 1 } END { print count + 0 }' "$quality_results")"
		printf '## x265 matched-VMAF comparison\n\n'
		printf '| Sample | Clip | QSV setting | Status | Premium %% | Verdict |\n'
		printf '|---|---|---:|---|---:|---|\n'
		while IFS= read -r comparison; do
			sample_id="$(jq -r '.sample_id' <<<"$comparison")"
			clip_id="$(jq -r '.clip_id' <<<"$comparison")"
			qsv_setting="$(jq -r '.qsv_setting' <<<"$comparison")"
			comparison_status="$(jq -r '.status' <<<"$comparison")"
			premium=''
			verdict='No verdict'
			if [[ "$comparison_status" == 'bracketed' ]]; then
				premium="$(awk -v value="$(jq -r '.premium_percent' <<<"$comparison")" 'BEGIN { printf "%.6f", value }')"
				verdict="$(awk -v value="$premium" 'BEGIN {
					if (value <= 15) print "QSV preferred"
					else if (value <= 30) print "QSV acceptable"
					else print "Escalate"
				}')"
			fi
			printf '| %s | %s | %s | %s | %s | %s |\n' "$sample_id" "$clip_id" \
				"$qsv_setting" "$comparison_status" "$premium" "$verdict"
		done < <(jq -c '.[]' <<<"$comparisons_json")
		printf '\n'
		printf '## Contention encode workers\n\n'
		printf '| Run | Case | Worker | Sample | Cohort | Setting | Status | Wall seconds |\n'
		printf '|---|---|---|---|---|---:|---|---:|\n'
		jq -r '.[] | "| \(.[0]) | \(.[1]) | \(.[2]) | \(.[3]) | \(.[4]) | \(.[5]) | \(.[6]) | \(.[8]) |"' \
			<<<"$contention_rows"
		printf '\n## Contention summary\n\n'
		jq -r '
			"- Baseline start latency: \(.baselineStartLatencySeconds) seconds\n" +
			"- Buffering count: \(.bufferingCount)\n" +
			"- Contended start latency: \(.startLatencySeconds) seconds\n" +
			"- Seek-to-resume: \(.seekToResumeSeconds) seconds\n" +
			"- NAS uplink: \(.nasUplinkMbps) Mbps\n" +
			"- Measured throughput: \(.measuredThroughputMbps) Mbps"
		' "$contention"
	} >"$findings_temp"
	mv -f -- "$findings_temp" "$run_directory/findings.md"
	printf '%s\n' "$run_id"
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
		(($# == 3)) || usage
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
	audio-inventory)
		(($# == 3)) || usage
		append_audio_inventory "$@"
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
	capabilities
	;;
_test) test_dispatch "$@" ;;
quality)
	(($# == 0 || $# == 1)) || usage
	quality_mode "${1:-}"
	;;
savings)
	(($# == 1)) || usage
	savings_mode "$1"
	;;
finalist)
	(($# == 2)) || usage
	finalist_mode "$1" "$2"
	;;
contention)
	(($# == 4)) || usage
	contention_mode "$1" "$2" "$3" "$4"
	;;
findings)
	(($# == 1)) || usage
	findings_mode "$1"
	;;
*) usage ;;
esac
