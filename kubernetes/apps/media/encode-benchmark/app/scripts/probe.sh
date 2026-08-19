#!/usr/bin/env bash
set -euo pipefail

diagnostic_file_size() {
	local path="$1"
	if stat -c '%s' "$path" 2>/dev/null; then
		return
	fi
	stat -f '%z' "$path"
}

diagnostic_identity() {
	local path="$1" size digest
	[[ -f "$path" && -r "$path" ]] || return 66
	size="$(diagnostic_file_size "$path")" || return
	digest="$(sha256sum "$path" | awk 'NR == 1 { value = $1; sub(/^\\/, "", value); print value }')"
	[[ "$size" =~ ^[0-9]+$ && "$digest" =~ ^[0-9a-f]{64}$ ]] || return 65
	jq -n -c --argjson size "$size" --arg digest "$digest" \
		'{sha256:$digest,sizeBytes:$size}'
}

diagnostic_validate_interval() {
	local start="$1" duration="$2"
	[[ "$start" =~ ^([0-9]+([.][0-9]+)?|[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?)$ ]] || return 64
	awk -v value="$duration" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0 && value <= 90) }'
}

diagnostic_window() {
	local path="$1" start="$2" duration="$3" first="$4" last="$5" probe_json
	[[ -f "$path" && -r "$path" ]] || return 66
	diagnostic_validate_interval "$start" "$duration" || return
	[[ "$first" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ && $((last - first)) -eq 4 ]] || return 64
	probe_json="$(ffprobe -v error -select_streams v:0 -read_intervals "$start%+$duration" \
		-show_streams -show_format -show_frames \
		-show_entries 'stream=start_time,duration,time_base,avg_frame_rate:format=start_time,duration:frame=best_effort_timestamp_time,pkt_duration_time,duration_time,key_frame,pict_type' \
		-of json "$path")" || return
	jq -e -c --argjson first "$first" --argjson last "$last" '
		def numeric_string: type == "string" and test("^-?[0-9]+([.][0-9]+)?$");
		def rational_string: type == "string" and test("^-?[0-9]+/[1-9][0-9]*$");
		if
			(.streams | type) == "array" and (.streams | length) == 1 and
			(.frames | type) == "array" and (.frames | length) > $last and
			((.streams[0].start_time // .format.start_time) | numeric_string) and
			((.streams[0].duration // .format.duration) | numeric_string) and
			(.streams[0].time_base | rational_string) and
			(.streams[0].avg_frame_rate | rational_string)
		then
			.frames as $frames |
			[$frames | to_entries[] | select(.key >= $first and .key <= $last) |
				if
					(.value.best_effort_timestamp_time | numeric_string) and
					((.value.pkt_duration_time // .value.duration_time) | numeric_string) and
					(.value.key_frame == 0 or .value.key_frame == 1) and
					(.value.pict_type == "I" or .value.pict_type == "P" or .value.pict_type == "B")
				then {
					frameIndex:.key,
					bestEffortTimestamp:.value.best_effort_timestamp_time,
					packetDuration:(.value.pkt_duration_time // .value.duration_time),
					keyFrame:(.value.key_frame == 1),
					pictureType:.value.pict_type
				} else error("incomplete diagnostic frame") end
			] as $window |
			if ($window | length) != 5 then error("incomplete diagnostic frame window") else {
				decodedFrameCount:($frames | length),
				stream:{
					startTime:(.streams[0].start_time // .format.start_time),
					duration:(.streams[0].duration // .format.duration),
					timeBase:.streams[0].time_base,
					averageFrameRate:.streams[0].avg_frame_rate
				},
				frames:$window
			} end
		else error("incomplete diagnostic stream") end
	' <<<"$probe_json"
}

diagnostic_hdr_oracle() {
	local absent_status="$1"
	jq -e -c --arg absent "$absent_status" '
		def rational:
			if type == "number" and floor == . and . >= 0 then
				{numerator:.,denominator:1}
			elif type == "string" and test("^[0-9]+/[1-9][0-9]*$") then
				(split("/") | {numerator:(.[0] | tonumber),denominator:(.[1] | tonumber)})
			else error("invalid HDR rational") end;
		def from_side_data:
			(. // []) as $side_data |
			([$side_data[]? | select(.side_data_type == "Mastering display metadata")]) as $mastering |
			([$side_data[]? | select(.side_data_type == "Content light level metadata")]) as $content |
			if ($mastering | length) == 0 and ($content | length) == 0 then
				{status:$absent}
			elif ($mastering | length) != 1 or ($content | length) != 1 then
				error("partial HDR side data")
			else
				($mastering[0]) as $m | ($content[0]) as $c |
				{
					status:"ok",
					metadata:{
						masteringDisplay:{
							displayPrimaries:{
								red:{x:($m.red_x | rational),y:($m.red_y | rational)},
								green:{x:($m.green_x | rational),y:($m.green_y | rational)},
								blue:{x:($m.blue_x | rational),y:($m.blue_y | rational)}
							},
							whitePoint:{x:($m.white_point_x | rational),y:($m.white_point_y | rational)},
							luminance:{min:($m.min_luminance | rational),max:($m.max_luminance | rational)}
						},
						maxCLL:($c.max_content | rational),
						maxFALL:($c.max_average | rational)
					}
				}
			end;
		if $absent == "null" then
			if (.streams | type) != "array" or (.streams | length) != 1 then
				error("invalid HDR stream probe")
			else (.streams[0].side_data_list | from_side_data) end
		else
			if (.frames | type) != "array" or (.frames | length) == 0 then
				error("invalid HDR frame probe")
			else
				[.frames[] | (.side_data_list | from_side_data)] as $oracles |
				([$oracles[] | select(.status == "ok")]) as $populated |
				if ($populated | length) == 0 then {status:$absent}
				elif ([$populated[].metadata] | unique | length) != 1 then error("conflicting HDR frame side data")
				else $populated[0] end
			end
		end
	'
}

diagnostic_hdr_probe() {
	local kind="$1" path="$2" start="$3" duration="$4" probe_json
	[[ -f "$path" && -r "$path" ]] || return 66
	diagnostic_validate_interval "$start" "$duration" || return
	awk -v value="$duration" 'BEGIN { exit !(value <= 10) }' || return 64
	case "$kind" in
	stream)
		probe_json="$(ffprobe -v error -select_streams v:0 -read_intervals "$start%+$duration" \
			-show_streams -show_entries 'stream_side_data' -of json "$path")" || return
		diagnostic_hdr_oracle null <<<"$probe_json"
		;;
	frame)
		probe_json="$(ffprobe -v error -select_streams v:0 -read_intervals "$start%+$duration" \
			-show_frames -show_entries 'frame=side_data_list' -of json "$path")" || return
		diagnostic_hdr_oracle absent <<<"$probe_json"
		;;
	*) return 64 ;;
	esac
}

diagnostic_hdr_trace() {
	local path="$1" start="$2" duration="$3" trace_log trace_pid
	local process_status=0 complete=0 values field
	local -a required_fields=(
		'display_primaries_x[0]' 'display_primaries_y[0]'
		'display_primaries_x[1]' 'display_primaries_y[1]'
		'display_primaries_x[2]' 'display_primaries_y[2]'
		'white_point_x' 'white_point_y'
		'max_display_mastering_luminance' 'min_display_mastering_luminance'
		'max_content_light_level' 'max_pic_average_light_level'
	)
	[[ -f "$path" && -r "$path" ]] || return 66
	diagnostic_validate_interval "$start" "$duration" || return
	awk -v value="$duration" 'BEGIN { exit !(value <= 10) }' || return 64
	trace_log="$(mktemp "${TMPDIR:-/tmp}/encode-benchmark-trace.XXXXXX")" || return
	trap 'rm -f -- "$trace_log"' RETURN
	: >"$trace_log"
	ffmpeg -nostdin -v verbose -ss "$start" -i "$path" -t "$duration" \
		-map 0:v:0 -c:v copy -bsf:v trace_headers -f null - >"$trace_log" 2>&1 &
	trace_pid=$!
	while kill -0 "$trace_pid" 2>/dev/null; do
		complete=1
		for field in "${required_fields[@]}"; do
			grep -q -F "$field" "$trace_log" || complete=0
		done
		if ((complete)); then
			kill "$trace_pid" 2>/dev/null || true
			break
		fi
		sleep 0.1
	done
	set +e
	wait "$trace_pid" 2>/dev/null
	process_status=$?
	set -e
	if ((process_status != 0 && complete == 0)); then return "$process_status"; fi
	values="$(jq -Rn '
		[inputs |
			capture("(?<key>display_primaries_[xy]\\[[0-2]\\]|white_point_[xy]|(?:max|min)_display_mastering_luminance|max_content_light_level|max_pic_average_light_level)[^=]*=[[:space:]]*(?<value>[0-9]+)") |
			{key:.key,value:(.value | tonumber)}
		] |
		if any(group_by(.key)[]; ([.[].value] | unique | length) != 1) then
			error("conflicting trace_headers metadata")
		else reduce .[] as $item ({}; .[$item.key] = $item.value) end
	' <"$trace_log")" || return
	if [[ "$(jq -r 'length' <<<"$values")" == '0' ]]; then
		printf '%s\n' '{"status":"absent"}'
		return
	fi
	jq -e -n -c --argjson values "$values" '
		if ($values | keys | length) != 12 then error("partial trace_headers metadata") else {
			status:"ok",
			metadata:{
				masteringDisplay:{
					displayPrimaries:{
						green:{x:{numerator:$values["display_primaries_x[0]"],denominator:50000},y:{numerator:$values["display_primaries_y[0]"],denominator:50000}},
						blue:{x:{numerator:$values["display_primaries_x[1]"],denominator:50000},y:{numerator:$values["display_primaries_y[1]"],denominator:50000}},
						red:{x:{numerator:$values["display_primaries_x[2]"],denominator:50000},y:{numerator:$values["display_primaries_y[2]"],denominator:50000}}
					},
					whitePoint:{x:{numerator:$values.white_point_x,denominator:50000},y:{numerator:$values.white_point_y,denominator:50000}},
					luminance:{min:{numerator:$values.min_display_mastering_luminance,denominator:10000},max:{numerator:$values.max_display_mastering_luminance,denominator:10000}}
				},
				maxCLL:{numerator:$values.max_content_light_level,denominator:1},
				maxFALL:{numerator:$values.max_pic_average_light_level,denominator:1}
			}
		} end
	'
}

case "${1:-}" in
diagnostic-identity)
	(($# == 2)) || exit 64
	diagnostic_identity "$2"
	exit
	;;
diagnostic-window)
	(($# == 6)) || exit 64
	diagnostic_window "$2" "$3" "$4" "$5" "$6"
	exit
	;;
diagnostic-hdr-stream)
	(($# == 4)) || exit 64
	diagnostic_hdr_probe stream "$2" "$3" "$4"
	exit
	;;
diagnostic-hdr-frame)
	(($# == 4)) || exit 64
	diagnostic_hdr_probe frame "$2" "$3" "$4"
	exit
	;;
diagnostic-hdr-trace)
	(($# == 4)) || exit 64
	diagnostic_hdr_trace "$2" "$3" "$4"
	exit
	;;
esac

if (($# != 1)); then
	echo 'usage: probe.sh <source-path> | diagnostic-identity <source-path> | diagnostic-window <source-path> <start> <duration> <first-frame> <last-frame> | diagnostic-hdr-{stream,frame,trace} <source-path> <start> <duration>' >&2
	exit 64
fi

source_path="$1"
probe_json="$(ffprobe -v error -show_streams -show_format -show_chapters -of json "$source_path")"

jq -c --arg source_path "$source_path" '
	def numeric:
		(if type == "number" then .
		elif type == "string" and test("^[0-9]+([.][0-9]+)?$") then tonumber
		else null
		end)
		| if . != null and . == floor then floor
		elif . != null then . + 0
		else .
		end;
	def rational:
		if type == "number" then .
		elif type == "string" and test("^-?[0-9]+/[1-9][0-9]*$") then
			(split("/") | (.[0] | tonumber) / (.[1] | tonumber))
		elif type == "string" and test("^-?[0-9]+([.][0-9]+)?$") then tonumber
		else null
		end;
	def bit_depth($video):
		($video.bits_per_raw_sample | numeric) //
		(if (($video.pix_fmt // "") | test("p[0-9]+(le|be)?$")) then
			(($video.pix_fmt | capture("p(?<depth>[0-9]+)(le|be)?$").depth) | tonumber)
		elif ($video.pix_fmt // "") != "" then 8
		else null
		end);

	(.format.duration | numeric) as $duration
	| ((.format.format_name // "") | split(",")[0]) as $container
	| ([.streams[]? | select(.codec_type == "video")][0] // {}) as $video
	| (bit_depth($video)) as $bit_depth
	| ($video.color_primaries // $video.tags.COLOR_PRIMARIES // "") as $color_primaries
	| ($video.color_transfer // $video.tags.COLOR_TRANSFER // "") as $color_transfer
	| ($video.color_space // $video.tags.COLOR_SPACE // "") as $color_space
	| ([$video.side_data_list[]? | (.dv_profile | numeric) | select(. != null)][0] // null) as $dv_profile
	| ([$video.side_data_list[]? | select(.side_data_type == "Mastering display metadata")][0] // null) as $mastering
	| ([$video.side_data_list[]? | select(.side_data_type == "Content light level metadata")][0] // null) as $content_light
	| (if $dv_profile == 7 then "dolby-vision"
		elif ($video.codec_name == "hevc" and ($bit_depth // 0) >= 10 and
			$color_transfer == "smpte2084" and $color_primaries == "bt2020") then "hdr10"
		elif $video.codec_name == "vc1" then "vc1"
		elif $video.codec_name == "h264" then "avc"
		else "other"
		end) as $cohort
	| ([.streams[]? | select(.codec_type == "audio")
		| . as $audio
		| (($audio.duration | numeric) // $duration) as $audio_duration
		| ($audio.bit_rate | numeric) as $reported_rate
		| (if $container == "matroska" then
			(($audio.tags.BPS // $audio.tags."BPS-eng" // null) | numeric)
			else null
			end) as $estimated_rate
		| (if $reported_rate != null then $reported_rate
			elif $estimated_rate != null then $estimated_rate
			else null
			end) as $audio_rate
		| (if $reported_rate != null then "reported"
			elif $estimated_rate != null then "estimated"
			else "unknown"
			end) as $audio_method
		| {
			index: $audio.index,
			codec: ($audio.codec_name // ""),
			channels: ($audio.channels // null),
			channelLayout: ($audio.channel_layout // ""),
			language: ($audio.tags.language // "und"),
			bitRate: $audio_rate,
			durationSeconds: $audio_duration,
			audioBytes: (if $audio_rate != null and $audio_duration != null
				then (($audio_rate * $audio_duration / 8) | floor)
				else null
				end),
			audioBytesMethod: $audio_method
		}]) as $audio_tracks
	| {
		path: $source_path,
		sizeBytes: (.format.size | numeric),
		durationSeconds: $duration,
		container: $container,
		cohort: $cohort,
		videoCodec: ($video.codec_name // ""),
		width: ($video.width // null),
		height: ($video.height // null),
		pixelFormat: ($video.pix_fmt // ""),
		bitDepth: $bit_depth,
		colorPrimaries: $color_primaries,
		colorTransfer: $color_transfer,
		colorSpace: $color_space,
		masteringDisplay: (if $mastering == null then null else {
			redX: ($mastering.red_x | rational),
			redY: ($mastering.red_y | rational),
			greenX: ($mastering.green_x | rational),
			greenY: ($mastering.green_y | rational),
			blueX: ($mastering.blue_x | rational),
			blueY: ($mastering.blue_y | rational),
			whitePointX: ($mastering.white_point_x | rational),
			whitePointY: ($mastering.white_point_y | rational),
			minLuminance: ($mastering.min_luminance | rational),
			maxLuminance: ($mastering.max_luminance | rational)
		} end),
		maxCLL: (if $content_light == null then null else {
			maxContent: ($content_light.max_content | numeric),
			maxAverage: ($content_light.max_average | numeric)
		} end),
		hdrFormat: (if $cohort == "dolby-vision" then "dolby-vision"
			elif $cohort == "hdr10" then "hdr10"
			else ""
			end),
		dolbyVisionProfile: $dv_profile,
		videoBitRate: ($video.bit_rate | numeric),
		frameRate: (if ($video.avg_frame_rate // "0/0") != "0/0"
			then $video.avg_frame_rate
			else ($video.r_frame_rate // "")
			end),
		audioTrackCount: ($audio_tracks | length),
		subtitleCount: ([.streams[]? | select(.codec_type == "subtitle")] | length),
		chapterCount: ((.chapters // []) | length),
		audioTracks: $audio_tracks
	}
' <<<"$probe_json"
