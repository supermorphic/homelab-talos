#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
benchmark_out="${BENCHMARK_OUT:-/out}"
scratch_root="${BENCHMARK_SCRATCH:-/scratch}"
samples_file="${BENCHMARK_SAMPLES_FILE:-/config/samples.yaml}"
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

usage() {
	echo 'usage: benchmark.sh capabilities | quality [run-id] | savings <run-id> | finalist <run-id> <sample-id> | findings <run-id>' >&2
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
		if (.points | type) != "array" or (.points | length) == 0 or
			([.points[] | select(
				(.crf | type) == "number" and (.vmaf | type) == "number" and
				(.bitRate | type) == "number" and .bitRate > 0
			)] | length) != (.points | length)
		then error("invalid x265 measurements")
		else .points | sort_by(.vmaf, .crf)[] | [.vmaf, .bitRate, .crf] | @tsv
		end
	' "$fixture")
	point_count="${#points[@]}"
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
	local qsv_vmaf minimum_vmaf maximum_vmaf minimum_crf maximum_crf next
	qsv_vmaf="$(jq -e -r '.qsvVmaf | numbers' "$fixture")"
	minimum_vmaf="$(jq -e -r '[.points[].vmaf] | min' "$fixture")"
	maximum_vmaf="$(jq -e -r '[.points[].vmaf] | max' "$fixture")"
	minimum_crf="$(jq -e -r '[.points[].crf] | min' "$fixture")"
	maximum_crf="$(jq -e -r '[.points[].crf] | max' "$fixture")"
	if awk -v q="$qsv_vmaf" -v low="$minimum_vmaf" -v high="$maximum_vmaf" \
		'BEGIN { exit !(low <= q && q <= high) }'; then
		printf '%s\n' '{"status":"bracketed"}'
	elif awk -v q="$qsv_vmaf" -v high="$maximum_vmaf" 'BEGIN { exit !(q > high) }'; then
		next=$((minimum_crf - 2))
		if ((next < 10)); then
			printf '%s\n' '{"status":"unbracketed"}'
		else
			printf '{"status":"extend","next_crf":%s}\n' "$next"
		fi
	else
		next=$((maximum_crf + 2))
		if ((next > 34)); then
			printf '%s\n' '{"status":"unbracketed"}'
		else
			printf '{"status":"extend","next_crf":%s}\n' "$next"
		fi
	fi
}

busy_metrics() {
	local fixture="$1"
	awk '
		($2 ~ /\/engine\/video/ || $2 ~ /\/engine\/vcs/ || $2 ~ /\/engine\/vecs/) &&
			$2 ~ /\/busy$/ && $1 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {
			path = $2
			if (!(path in first_value)) {
				first_value[path] = $3
				first_time[path] = $1
			}
			last_value[path] = $3
			last_time[path] = $1
			present = 1
		}
		END {
			total_delta = 0
			elapsed = 0
			for (path in first_value) {
				delta = last_value[path] - first_value[path]
				span = last_time[path] - first_time[path]
				if (delta > 0) total_delta += delta
				if (span > elapsed) elapsed = span
			}
			percent = (elapsed > 0 ? total_delta * 100 / elapsed : 0)
			printf "%.6f|%.0f|%d\n", percent, total_delta, present
		}
	' "$fixture"
}

qsv_proof() {
	local encode_log="$1"
	local busy_log="$2"
	local height="$3"
	local selected='unknown' initialization='failed' fps='0.000000' speed='0.000000'
	local gpu delta telemetry reasons='' proof='suspect' value
	if rg -q 'Successfully initialized the hardware device|Successfully initialised the hardware device' "$encode_log" &&
		! rg -q 'Device creation failed|Failed to (initialise|initialize)' "$encode_log"; then
		initialization='passed'
	fi
	if rg -q 'LA[_-]ICQ|LA-ICQ' "$encode_log"; then
		selected='LA-ICQ'
	elif rg -q '(^|[^A-Z])CQP([^A-Z]|$)' "$encode_log"; then
		selected='CQP'
	elif rg -q '(^|[^A-Z])ICQ([^A-Z]|$)' "$encode_log"; then
		selected='ICQ'
	elif value="$(rg -o '(CBR|VBR|AVBR|QVBR)' "$encode_log" | tail -n 1)" && [[ -n "$value" ]]; then
		selected="$value"
	fi
	value="$(rg -o 'fps=[[:space:]]*[0-9]+([.][0-9]+)?' "$encode_log" | tail -n 1 | sed 's/fps=[[:space:]]*//' || true)"
	[[ -z "$value" ]] || fps="$(awk -v value="$value" 'BEGIN { printf "%.6f", value }')"
	value="$(rg -o 'speed=[[:space:]]*[0-9]+([.][0-9]+)?x' "$encode_log" | tail -n 1 | sed 's/speed=[[:space:]]*//; s/x$//' || true)"
	[[ -z "$value" ]] || speed="$(awk -v value="$value" 'BEGIN { printf "%.6f", value }')"
	IFS='|' read -r gpu delta telemetry <<<"$(busy_metrics "$busy_log")"

	if [[ "$initialization" != 'passed' ]]; then
		reasons='initialization'
	fi
	if [[ "$selected" != 'LA-ICQ' ]]; then
		reasons="${reasons:+$reasons;}rate-control"
	fi
	if [[ "$telemetry" != '1' ]] || ! awk -v delta="$delta" 'BEGIN { exit !(delta > 0) }'; then
		reasons="${reasons:+$reasons;}telemetry"
	fi
	if ((height >= 2160)); then
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

validate_probes() {
	local source_probe="$1"
	local output_probe="$2"
	local scope="$3"
	local decode_status="$4"
	local tolerance source_duration output_duration duration_difference
	local codec duration resolution frame_rate bit_depth hdr audio subtitle chapters
	local failures=''
	[[ "$scope" == 'clip' || "$scope" == 'full' ]] || return 64
	if [[ "$scope" == 'clip' ]]; then tolerance='1.0'; else tolerance='2.0'; fi
	source_duration="$(jq -e -r '.durationSeconds | numbers' "$source_probe")"
	output_duration="$(jq -e -r '.durationSeconds | numbers' "$output_probe")"
	duration_difference="$(awk -v source="$source_duration" -v output="$output_duration" '
		BEGIN { difference = source - output; if (difference < 0) difference = -difference; print difference }
	')"

	codec="$(passed_or_failed jq -e '.videoCodec == "hevc"' "$output_probe")"
	duration="$(passed_or_failed awk -v difference="$duration_difference" -v tolerance="$tolerance" \
		'BEGIN { exit !(difference <= tolerance) }')"
	resolution="$(passed_or_failed jq -e -n --slurpfile source "$source_probe" --slurpfile output "$output_probe" \
		'$source[0].width == $output[0].width and $source[0].height == $output[0].height')"
	frame_rate="$(passed_or_failed awk \
		-v source="$(jq -r '.frameRate' "$source_probe")" \
		-v output="$(jq -r '.frameRate' "$output_probe")" '
		function rational(value, parts) {
			split(value, parts, "/")
			if (length(parts) != 2 || parts[2] == 0) return -1
			return parts[1] / parts[2]
		}
		BEGIN {
			a = rational(source)
			b = rational(output)
			difference = a - b
			if (difference < 0) difference = -difference
			exit !(a >= 0 && b >= 0 && difference < 0.000001)
		}')"
	bit_depth="$(passed_or_failed jq -e -n --slurpfile source "$source_probe" --slurpfile output "$output_probe" '
		$source[0].bitDepth == $output[0].bitDepth and
		(if $source[0].hdrFormat == "hdr10" then $output[0].bitDepth == 10 else true end)
	')"
	hdr="$(passed_or_failed jq -e -n --slurpfile source "$source_probe" --slurpfile output "$output_probe" '
		$source[0].hdrFormat == $output[0].hdrFormat and
		$source[0].colorPrimaries == $output[0].colorPrimaries and
		$source[0].colorTransfer == $output[0].colorTransfer and
		$source[0].colorSpace == $output[0].colorSpace and
		($source[0].masteringDisplay // "") == ($output[0].masteringDisplay // "") and
		($source[0].maxCLL // "") == ($output[0].maxCLL // "")
	')"
	audio="$(passed_or_failed jq -e -n --slurpfile source "$source_probe" --slurpfile output "$output_probe" \
		'$source[0].audioTrackCount == $output[0].audioTrackCount')"
	subtitle="$(passed_or_failed jq -e -n --slurpfile source "$source_probe" --slurpfile output "$output_probe" \
		'$source[0].subtitleCount == $output[0].subtitleCount')"
	chapters="$(passed_or_failed jq -e -n --slurpfile source "$source_probe" --slurpfile output "$output_probe" \
		'$source[0].chapterCount == $output[0].chapterCount')"

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

record_result() {
	local run_id="$1"
	local fixture="$2"
	local scratch_output="$3"
	local run_directory results panel sample_id cohort source_sha clip encoder setting
	local selected status attempt disposition='discarded' confirmation destination
	local -a columns
	validate_run_id "$run_id" || return
	[[ -f "$fixture" ]] || return 66
	run_directory="$benchmark_out/runs/$run_id"
	[[ -d "$run_directory" && ! -L "$run_directory" ]] || {
		echo "run directory not found: $run_id" >&2
		return 66
	}
	panel="$(jq -e -r '.panel | strings' "$fixture")"
	sample_id="$(jq -e -r '.sample_id | strings' "$fixture")"
	cohort="$(jq -e -r '.cohort | strings' "$fixture")"
	source_sha="$(jq -e -r '.source_sha256 | strings' "$fixture")"
	clip="$(jq -e -r '.clip_id | strings' "$fixture")"
	encoder="$(jq -e -r '.encoder | strings' "$fixture")"
	setting="$(jq -e -r '.requested_setting | strings' "$fixture")"
	selected="$(jq -e -r '.selected_rate_control | strings' "$fixture")"
	validate_sample_id "$sample_id" || return
	results="$run_directory/results.csv"
	ensure_results_file "$results" || return
	if result_key_passed "$results" "$panel" "$source_sha" "$clip" "$encoder" "$setting"; then
		attempt=$(("$(result_attempt "$results" "$panel" "$source_sha" "$clip" "$encoder" "$setting")" - 1))
		rm -f -- "$scratch_output"
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
			rm -f -- "$scratch_output"
			echo "missing finalist confirmation for $run_id/$sample_id" >&2
			return 64
		fi
		if [[ "$status" == 'passed' ]]; then
			mkdir -p "$run_directory/encodes"
			destination="$run_directory/encodes/$sample_id-$encoder-gq$setting.mkv"
			cp -- "$scratch_output" "$destination"
			disposition='copied'
		fi
	fi

	mapfile -t columns < <(jq -e -r '
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
	' "$fixture")
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
	(
		IFS=,
		printf '%s\n' "${columns[*]}"
	) >>"$results"
	rm -f -- "$scratch_output"
	printf '{"status":"%s","attempt":%s,"output_disposition":"%s"}\n' \
		"$status" "$attempt" "$disposition"
}

append_audio_inventory() {
	local packets="$1"
	local probe="$2"
	local output="$3"
	local header='source_path,track_index,codec,channels,channel_layout,language,bit_rate,duration_seconds,audio_bytes,audio_bytes_method'
	local sums track index bytes
	declare -A packet_bytes=()
	if [[ -e "$output" ]]; then
		IFS= read -r existing <"$output" || true
		[[ "$existing" == "$header" ]] || return 65
	else
		printf '%s\n' "$header" >"$output"
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
	while IFS= read -r track; do
		index="$(jq -r '.index' <<<"$track")"
		bytes="${packet_bytes[$index]:-0}"
		jq -r \
			--argjson bytes "$bytes" \
			--arg source_path "$(jq -r '.path' "$probe")" '
			[
				$source_path, .index, .codec, .channels, .channelLayout, .language,
				.bitRate,
				(if (.durationSeconds | floor) == .durationSeconds then (.durationSeconds | floor) else .durationSeconds end),
				$bytes, "packet-counted"
			] | @csv
		' <<<"$track" >>"$output"
	done < <(jq -c '.audioTracks[]' "$probe")
}

capabilities() {
	local capability_directory source encoded encode_log ffmpeg_version ffprobe_version
	local encoders filters uid
	encoders="$(ffmpeg -hide_banner -encoders)"
	filters="$(ffmpeg -hide_banner -filters)"
	rg -q 'hevc_qsv' <<<"$encoders" || return 1
	rg -q 'libvmaf' <<<"$filters" || return 1
	rg -q 'libx265' <<<"$encoders" || return 1
	command -v sh awk jq stat sha256sum ffprobe >/dev/null || return 1
	uid="$(id -u)"
	[[ "$uid" == '568' ]] || return 1
	mkdir -p "$scratch_root"
	capability_directory="$(mktemp -d "$scratch_root/capabilities.XXXXXX")"
	trap 'rm -rf -- "$capability_directory"' RETURN
	source="$capability_directory/source.mkv"
	encoded="$capability_directory/qsv.mkv"
	encode_log="$capability_directory/qsv.log"
	ffmpeg -v error -f lavfi -i 'testsrc2=size=1920x1080:rate=30' -t 5 \
		-pix_fmt yuv420p "$source"
	ffmpeg -v verbose -init_hw_device qsv=hw:/dev/dri/renderD128 \
		-filter_hw_device hw -i "$source" -map 0:v:0 -c:v hevc_qsv -preset veryslow \
		-global_quality 22 -look_ahead 1 -extbrc 1 "$encoded" >"$encode_log" 2>&1
	ffmpeg -v error -i "$encoded" -map 0:v:0 -f null -
	ffmpeg -v error -i "$encoded" -i "$source" -lavfi \
		'[0:v][1:v]libvmaf=model=version=vmaf_4k_v0.6.1' -f null -
	ffmpeg_version="$(ffmpeg -version | awk 'NR == 1 { print $3 }')"
	ffprobe_version="$(ffprobe -version | awk 'NR == 1 { print $3 }')"
	jq -n -c \
		--arg ffmpeg "$ffmpeg_version" \
		--arg ffprobe "$ffprobe_version" \
		--arg node "${NODE_NAME:-}" \
		--arg image "${KUBERNETES_IMAGE_ID:-}" \
		--argjson uid "$uid" '{
			status: "passed", uid: $uid,
			hevcQsv: true, realQsvEncode: true, decoded: true,
			libvmaf4k: true, libx265: true,
			ffmpegVersion: $ffmpeg, ffprobeVersion: $ffprobe,
			nodeName: $node, imageId: $image
		}'
}

probe_media() {
	local role="$1"
	local path="$2"
	if [[ "$test_mode" == '1' && "$role" == 'source' && -n "${BENCHMARK_TEST_SOURCE_PROBE:-}" ]]; then
		jq -c . "$BENCHMARK_TEST_SOURCE_PROBE"
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

now_nanoseconds() {
	local value
	value="$(date '+%s%N')"
	if [[ "$value" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$value"
	else
		awk -v seconds="$(date '+%s')" 'BEGIN { printf "%.0f\n", seconds * 1000000000 }'
	fi
}

sample_drm_busy() {
	local ffmpeg_pid="$1"
	local output="$2"
	local timestamp path value
	local -a busy_paths
	: >"$output"
	while kill -0 "$ffmpeg_pid" 2>/dev/null; do
		timestamp="$(now_nanoseconds)"
		shopt -s nullglob
		busy_paths=(/sys/class/drm/card*/engine/*/busy)
		shopt -u nullglob
		for path in "${busy_paths[@]}"; do
			if IFS= read -r value <"$path" && [[ "$value" =~ ^[0-9]+$ ]]; then
				printf '%s %s %s\n' "$timestamp" "$path" "$value" >>"$output"
			fi
		done
		sleep 1
	done
}

run_qsv_encode() {
	local input="$1"
	local output="$2"
	local setting="$3"
	local encode_log="$4"
	local busy_log="$5"
	local ffmpeg_pid sampler_pid status
	if [[ "$test_mode" == '1' && -n "${BENCHMARK_TEST_BUSY_FIXTURE:-}" ]]; then
		cp "$BENCHMARK_TEST_BUSY_FIXTURE" "$busy_log"
		ffmpeg -v verbose -init_hw_device qsv=hw:/dev/dri/renderD128 \
			-filter_hw_device hw -i "$input" -map 0 -c:v hevc_qsv -preset veryslow \
			-global_quality "$setting" -look_ahead 1 -extbrc 1 \
			-c:a copy -c:s copy -map_metadata 0 -map_chapters 0 "$output" >"$encode_log" 2>&1
		return
	fi
	ffmpeg -v verbose -init_hw_device qsv=hw:/dev/dri/renderD128 \
		-filter_hw_device hw -i "$input" -map 0 -c:v hevc_qsv -preset veryslow \
		-global_quality "$setting" -look_ahead 1 -extbrc 1 \
		-c:a copy -c:s copy -map_metadata 0 -map_chapters 0 "$output" >"$encode_log" 2>&1 &
	ffmpeg_pid=$!
	sample_drm_busy "$ffmpeg_pid" "$busy_log" &
	sampler_pid=$!
	set +e
	wait "$ffmpeg_pid"
	status=$?
	wait "$sampler_pid"
	set -e
	return "$status"
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
	value="$(rg -o 'fps=[[:space:]]*[0-9]+([.][0-9]+)?' "$encode_log" | tail -n 1 | sed 's/fps=[[:space:]]*//' || true)"
	[[ -z "$value" ]] || fps="$(awk -v value="$value" 'BEGIN { printf "%.6f", value }')"
	value="$(rg -o 'speed=[[:space:]]*[0-9]+([.][0-9]+)?x' "$encode_log" | tail -n 1 | sed 's/speed=[[:space:]]*//; s/x$//' || true)"
	[[ -z "$value" ]] || speed="$(awk -v value="$value" 'BEGIN { printf "%.6f", value }')"
	printf '%s|%s\n' "$fps" "$speed"
}

process_variant() {
	local run_id="$1" panel="$2" sample_id="$3" cohort="$4" source_sha="$5"
	local clip_id="$6" encoder="$7" setting="$8" reference="$9" output="${10}"
	local scope="${11}" encode_status="${12}" wall_seconds="${13}" encode_log="${14}"
	local busy_log="${15}" still_prefix="${16:-}"
	local run_directory logs_directory source_probe_file output_probe_file validation_file
	local vmaf_file ssim_file row_fixture source_probe output_probe validation
	local input_bytes='0' output_bytes='0' duration='0' input_rate='0' output_rate='0'
	local reduction='0.000000' fps='0.000000' speed='0.000000' vmaf_harmonic=''
	local vmaf_low='' ssim='' gpu_busy='' qsv_status='not-applicable' selected='CRF'
	local validation_failures validation_codec validation_duration validation_resolution
	local validation_frame_rate validation_bit_depth validation_hdr validation_audio
	local validation_subtitle validation_chapters decode_status=1 proof_json progress

	run_directory="$benchmark_out/runs/$run_id"
	logs_directory="$run_directory/logs"
	mkdir -p "$logs_directory"
	source_probe_file="$logs_directory/$sample_id-$clip_id-$encoder-$setting-source-probe.json"
	output_probe_file="$logs_directory/$sample_id-$clip_id-$encoder-$setting-output-probe.json"
	validation_file="$logs_directory/$sample_id-$clip_id-$encoder-$setting-validation.json"
	vmaf_file="$logs_directory/$sample_id-$clip_id-$encoder-$setting-vmaf.json"
	ssim_file="$logs_directory/$sample_id-$clip_id-$encoder-$setting-ssim.log"
	row_fixture="$scratch_root/$run_id/$sample_id-$clip_id-$encoder-$setting-row.json"
	probe_media source "$reference" >"$source_probe_file"
	source_probe="$(jq -c . "$source_probe_file")"
	duration="$(jq -r '.durationSeconds // 0' <<<"$source_probe")"
	input_bytes="$(file_size "$reference")"
	input_rate="$(awk -v bytes="$input_bytes" -v seconds="$duration" \
		'BEGIN { if (seconds > 0) printf "%.0f", bytes * 8 / seconds; else print 0 }')"

	if [[ "$encode_status" == '0' && -f "$output" ]]; then
		output_bytes="$(file_size "$output")"
		output_rate="$(awk -v bytes="$output_bytes" -v seconds="$duration" \
			'BEGIN { if (seconds > 0) printf "%.0f", bytes * 8 / seconds; else print 0 }')"
		reduction="$(awk -v input="$input_bytes" -v output="$output_bytes" \
			'BEGIN { if (input > 0) printf "%.6f", (input - output) * 100 / input; else print "0.000000" }')"
		set +e
		ffmpeg -v error -i "$output" -map 0 -f null -
		decode_status=$?
		set -e
		probe_media output "$output" >"$output_probe_file"
		output_probe="$(jq -c . "$output_probe_file")"
		validation="$(validate_probes "$source_probe_file" "$output_probe_file" "$scope" "$decode_status")"
		printf '%s\n' "$validation" >"$validation_file"
		if [[ "$panel" == 'quality' ]]; then
			ffmpeg -v error -i "$output" -i "$reference" -lavfi \
				"[0:v][1:v]libvmaf=model=version=vmaf_4k_v0.6.1:log_fmt=json:log_path=$vmaf_file" \
				-f null -
			metrics="$(vmaf_stats "$vmaf_file")"
			vmaf_harmonic="$(jq -r '.harmonic_mean' <<<"$metrics")"
			vmaf_low="$(jq -r '.one_percent_low' <<<"$metrics")"
			ffmpeg -v info -i "$output" -i "$reference" -lavfi '[0:v][1:v]ssim' \
				-f null - >"$ssim_file" 2>&1
			ssim="$(rg -o 'All:[0-9]+([.][0-9]+)?' "$ssim_file" | tail -n 1 | cut -d: -f2)"
		fi
		if [[ -n "$still_prefix" ]]; then
			if ! "$script_directory/stills.sh" "$reference" "$output" '00:00:00.000' "$still_prefix"; then
				validation="$(jq -c '.validation_failures = ((.validation_failures + ";stills") | ltrimstr(";"))' <<<"$validation")"
			fi
		fi
	else
		validation='{"validation_codec":"failed","validation_duration":"failed","validation_resolution":"failed","validation_frame_rate":"failed","validation_bit_depth":"failed","validation_hdr":"failed","validation_audio_tracks":"failed","validation_subtitle_tracks":"failed","validation_chapters":"failed","validation_failures":"encode"}'
		printf '%s\n' "$validation" >"$validation_file"
	fi

	if [[ "$encoder" == 'qsv' ]]; then
		proof_json="$(qsv_proof "$encode_log" "$busy_log" "$(jq -r '.height // 0' <<<"$source_probe")")"
		selected="$(jq -r '.selected_rate_control' <<<"$proof_json")"
		fps="$(jq -r '.encode_fps' <<<"$proof_json")"
		speed="$(jq -r '.encode_speed' <<<"$proof_json")"
		gpu_busy="$(jq -r '.gpu_busy_percent' <<<"$proof_json")"
		qsv_status="$(jq -r '.qsv_proof' <<<"$proof_json")"
	else
		progress="$(encoder_progress "$encode_log")"
		IFS='|' read -r fps speed <<<"$progress"
	fi

	validation_codec="$(jq -r '.validation_codec' <<<"$validation")"
	validation_duration="$(jq -r '.validation_duration' <<<"$validation")"
	validation_resolution="$(jq -r '.validation_resolution' <<<"$validation")"
	validation_frame_rate="$(jq -r '.validation_frame_rate' <<<"$validation")"
	validation_bit_depth="$(jq -r '.validation_bit_depth' <<<"$validation")"
	validation_hdr="$(jq -r '.validation_hdr' <<<"$validation")"
	validation_audio="$(jq -r '.validation_audio_tracks' <<<"$validation")"
	validation_subtitle="$(jq -r '.validation_subtitle_tracks' <<<"$validation")"
	validation_chapters="$(jq -r '.validation_chapters' <<<"$validation")"
	validation_failures="$(jq -r '.validation_failures' <<<"$validation")"

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
	record_result "$run_id" "$row_fixture" "$output"
	rm -f -- "$row_fixture"
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
		mapfile -t settings < <(yq -r '.chosenSettings[]?.globalQuality' "$samples_file" | sort -nu)
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
	local run_directory output encode_log busy_log start end wall status=0
	run_directory="$benchmark_out/runs/$run_id"
	output="$scratch_root/$run_id/$sample_id-$clip_id-$encoder-$setting.mkv"
	encode_log="$run_directory/logs/$sample_id-$clip_id-$encoder-$setting.log"
	busy_log="$run_directory/logs/$sample_id-$clip_id-$encoder-$setting-busy.log"
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
		"$encode_log" "$busy_log" "$still_prefix"
}

quality_mode() {
	local explicit_run_id="${1:-}" run_id run_directory run_scratch sample sample_id cohort
	local source sha detection clip_id timestamp clip x265_points qsv_points setting
	local comparison_fixture comparison decision target next_crf
	local -a qsv_settings=(20 22 24 26 28) x265_settings=(18 20 22 24)
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
					comparison_fixture="$run_scratch/next-comparison.json"
					jq -n -c \
						--argjson points "$(jq -s . <<<"$x265_points")" \
						--argjson qsv_vmaf "$target" \
						'{points: $points, qsvVmaf: $qsv_vmaf, qsvBitRate: 1}' >"$comparison_fixture"
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
				jq -c --arg sample "$sample_id" --arg clip "$clip_id" --arg setting "$setting" \
					'. + {sample_id: $sample, clip_id: $clip, qsv_setting: $setting}' \
					<<<"$comparison" >>"$run_directory/x265-comparisons.jsonl"
			done <<<"$qsv_points"
			rm -f -- "$clip"
		done < <(jq -r '.clips | to_entries[] | [.key, .value] | @tsv' <<<"$sample")
	done < <(yq -o=json -I=0 '.qualityPanel[]?' "$samples_file")
	rm -rf -- "$run_scratch"
	printf '%s\n' "$run_id"
}

savings_mode() {
	local requested_run_id="$1" run_id run_directory run_scratch sample sample_id cohort
	local source sha setting packets probe_file
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
		setting="$(yq -r ".chosenSettings.\"$cohort\".globalQuality // \"\"" "$samples_file")"
		[[ "$setting" =~ ^(20|22|24|26|28)$ ]] || continue
		if row_is_complete "$run_id" savings "$sha" full qsv "$setting"; then continue; fi
		encode_one_variant "$run_id" savings "$sample_id" "$cohort" "$sha" full \
			qsv "$setting" "$source" full '' >/dev/null
		packets="$run_scratch/$sample_id-audio-packets.csv"
		ffprobe -show_packets -select_streams a -show_entries packet=stream_index,size \
			-of csv=p=0 "$source" >"$packets"
		probe_file="$run_scratch/$sample_id-source-probe.json"
		probe_media source "$source" >"$probe_file"
		append_audio_inventory "$packets" "$probe_file" "$run_directory/audio-inventory.csv"
		rm -f -- "$packets" "$probe_file"
	done < <(yq -o=json -I=0 '.savingsPanel[]?' "$samples_file")
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
	BENCHMARK_ENCODER_COMMANDS_JSON="$(encoder_commands_for_mode finalist)"
	export BENCHMARK_ENCODER_COMMANDS_JSON
	run_id="$("$script_directory/runmeta.sh" create finalist "$requested_run_id")"
	run_directory="$benchmark_out/runs/$run_id"
	run_scratch="$scratch_root/$run_id"
	mkdir -p "$run_directory/logs" "$run_scratch"
	sample="$(yq -o=json -I=0 ".qualityPanel[]?, .savingsPanel[]? | select(.id == \"$requested_sample_id\")" "$samples_file" | head -n 1)"
	[[ -n "$sample" ]] || {
		echo "sample not found: $requested_sample_id" >&2
		return 66
	}
	sample_id="$(jq -r '.id' <<<"$sample")"
	cohort="$(jq -r '.cohort' <<<"$sample")"
	[[ "$cohort" != 'dolby-vision' && "$(jq -r '.detectionOnly // false' <<<"$sample")" != 'true' ]] || {
		echo 'Dolby Vision samples cannot be encoded' >&2
		return 65
	}
	source="$(jq -r '.path' <<<"$sample")"
	sha="$(jq -r '.sha256' <<<"$sample")"
	setting="$(yq -r ".chosenSettings.\"$cohort\".globalQuality // \"\"" "$samples_file")"
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

findings_mode() {
	local run_id="$1" run_directory inputs quality_run savings_run contention_file
	local quality_results savings_results contention findings_temp cohort distribution stats
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
	validate_run_id "$quality_run" || return
	validate_run_id "$savings_run" || return
	[[ "$contention_file" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*[.]json$ ]] || return 64
	quality_results="$benchmark_out/runs/$quality_run/results.csv"
	savings_results="$benchmark_out/runs/$savings_run/results.csv"
	contention="$run_directory/$contention_file"
	ensure_results_file "$quality_results" || return
	ensure_results_file "$savings_results" || return
	[[ -f "$contention" && ! -L "$contention" ]] || return 66
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
		printf '## Contention summary\n\n'
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
findings)
	(($# == 1)) || usage
	findings_mode "$1"
	;;
*) usage ;;
esac
