#!/usr/bin/env bash
set -euo pipefail

diagnostic_validate_interval() {
	local start="$1" duration="$2"
	[[ "$start" =~ ^([0-9]+([.][0-9]+)?|[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?)$ ]] || return 64
	awk -v value="$duration" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0 && value <= 90) }'
}

# Keep exact HDR values as reduced rationals. Both the diagnostic probes and
# quality evidence use this boundary, so equivalent ffprobe and trace_headers
# representations compare without decimal conversion or rounding.
diagnostic_hdr_normalize_oracle() {
	jq -e -c '
		def exact_keys($wanted): type == "object" and ((keys | sort) == ($wanted | sort));
		def gcd($a; $b):
			if $b == 0 then $a else gcd($b; ($a % $b)) end;
		def rational:
			exact_keys(["denominator", "numerator"]) and
			(.numerator | type == "number" and floor == . and . >= 0) and
			(.denominator | type == "number" and floor == . and . > 0);
		def reduced_rational:
			(gcd(.numerator; .denominator)) as $divisor |
			{numerator:(.numerator / $divisor),denominator:(.denominator / $divisor)};
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
			(.maxCLL | rational) and (.maxFALL | rational);
		def normalize_metadata:
			walk(if type == "object" and exact_keys(["denominator", "numerator"])
				then reduced_rational else . end);
		if
			exact_keys(["metadata", "status"]) and .status == "ok" and
			(.metadata | hdr_metadata)
		then {status:"ok",metadata:(.metadata | normalize_metadata)}
		elif
			exact_keys(["status"]) and
			(.status == "null" or .status == "absent" or .status == "malformed")
		then {status}
		else error("invalid HDR oracle") end
	'
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
		diagnostic_hdr_oracle null <<<"$probe_json" | diagnostic_hdr_normalize_oracle
		;;
	frame)
		probe_json="$(ffprobe -v error -select_streams v:0 -read_intervals "$start%+$duration" \
			-show_frames -show_entries 'frame=side_data_list' -of json "$path")" || return
		diagnostic_hdr_oracle absent <<<"$probe_json" | diagnostic_hdr_normalize_oracle
		;;
	*) return 64 ;;
	esac
}

diagnostic_hdr_trace_oracle() {
	local trace_log="$1"
	jq -Rn -c '
		def field_event:
			try (
				capture("(?<key>display_primaries_[xy]\\[[0-2]\\]|white_point_[xy]|(?:max|min)_display_mastering_luminance|max_content_light_level|max_pic_average_light_level)[^=]*=[[:space:]]*(?<value>[0-9]+)") |
				{type:"field",key:.key,value:(.value | tonumber)}
			) catch null;
		def collapse($expected):
			if (.values | keys | sort) != ($expected | sort) then
				error("partial trace_headers message")
			elif any(.values[]; (unique | length) != 1) then
				error("conflicting trace_headers message field")
			else .values | with_entries(.value = .value[0]) end;
		def mastering_fields: [
			"display_primaries_x[0]", "display_primaries_y[0]",
			"display_primaries_x[1]", "display_primaries_y[1]",
			"display_primaries_x[2]", "display_primaries_y[2]",
			"white_point_x", "white_point_y",
			"max_display_mastering_luminance", "min_display_mastering_luminance"
		];
		def content_fields: ["max_content_light_level", "max_pic_average_light_level"];
		[inputs |
			if test("Mastering Display Colour Volume[[:space:]]*$") then
				{type:"start",kind:"mastering"}
			elif test("Content Light Level Information[[:space:]]*$") then
				{type:"start",kind:"content"}
			else field_event // empty end
		] as $events |
		([$events[] | select(.type == "start")] | length) as $heading_count |
		([$events[] | select(.type == "field")] | length) as $field_count |
		if $heading_count == 0 then
			if $field_count == 0 then {status:"absent"}
			else error("trace_headers fields lack message boundaries") end
		else
			reduce $events[] as $event (
				{blocks:[],current:null};
				if $event.type == "start" then
					(if .current == null then . else .blocks += [.current] end) |
					.current = {kind:$event.kind,values:{}}
				elif .current == null then
					error("trace_headers field precedes message boundary")
				else
					.current.values[$event.key] = ((.current.values[$event.key] // []) + [$event.value])
				end
			) |
			if .current == null then . else .blocks += [.current] end |
			[.blocks[] |
				if .kind == "mastering" then {kind,values:collapse(mastering_fields)}
				elif .kind == "content" then {kind,values:collapse(content_fields)}
				else error("unknown trace_headers message") end
			] as $blocks |
			([$blocks[] | select(.kind == "mastering") | .values] | unique) as $mastering |
			([$blocks[] | select(.kind == "content") | .values] | unique) as $content |
			if ($mastering | length) != 1 or ($content | length) != 1 then
				error("missing or conflicting trace_headers messages")
			else
				($mastering[0]) as $m | ($content[0]) as $c | {
					status:"ok",
					metadata:{
						masteringDisplay:{
							displayPrimaries:{
								green:{x:{numerator:$m["display_primaries_x[0]"],denominator:50000},y:{numerator:$m["display_primaries_y[0]"],denominator:50000}},
								blue:{x:{numerator:$m["display_primaries_x[1]"],denominator:50000},y:{numerator:$m["display_primaries_y[1]"],denominator:50000}},
								red:{x:{numerator:$m["display_primaries_x[2]"],denominator:50000},y:{numerator:$m["display_primaries_y[2]"],denominator:50000}}
							},
							whitePoint:{x:{numerator:$m.white_point_x,denominator:50000},y:{numerator:$m.white_point_y,denominator:50000}},
							luminance:{min:{numerator:$m.min_display_mastering_luminance,denominator:10000},max:{numerator:$m.max_display_mastering_luminance,denominator:10000}}
						},
						maxCLL:{numerator:$c.max_content_light_level,denominator:1},
						maxFALL:{numerator:$c.max_pic_average_light_level,denominator:1}
					}
				}
			end
		end
	' <"$trace_log"
}

diagnostic_hdr_trace() {
	local path="$1" start="$2" duration="$3" trace_log trace_pid
	local process_status=0 complete=0 oracle
	[[ -f "$path" && -r "$path" ]] || return 66
	diagnostic_validate_interval "$start" "$duration" || return
	awk -v value="$duration" 'BEGIN { exit !(value <= 10) }' || return 64
	trace_log="$(mktemp "${TMPDIR:-/tmp}/encode-benchmark-trace.XXXXXX")" || return
	: >"$trace_log"
	ffmpeg -nostdin -v verbose -ss "$start" -i "$path" -t "$duration" \
		-map 0:v:0 -c:v copy -bsf:v trace_headers -f null - >"$trace_log" 2>&1 &
	trace_pid=$!
	while kill -0 "$trace_pid" 2>/dev/null; do
		if oracle="$(diagnostic_hdr_trace_oracle "$trace_log" 2>/dev/null)" &&
			jq -e '.status == "ok"' <<<"$oracle" >/dev/null; then
			complete=1
			kill "$trace_pid" 2>/dev/null || true
			break
		fi
		sleep 0.1
	done
	set +e
	wait "$trace_pid" 2>/dev/null
	process_status=$?
	set -e
	if ((process_status != 0 && complete == 0)); then
		rm -f -- "$trace_log"
		return "$process_status"
	fi
	set +e
	oracle="$(diagnostic_hdr_trace_oracle "$trace_log")"
	process_status=$?
	set -e
	rm -f -- "$trace_log"
	((process_status == 0)) || return "$process_status"
	diagnostic_hdr_normalize_oracle <<<"$oracle"
}

case "${1:-}" in
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
diagnostic-hdr-normalize-oracle)
	(($# == 1)) || exit 64
	diagnostic_hdr_normalize_oracle
	exit
	;;
esac

if (($# != 1)); then
	echo 'usage: probe.sh <source-path> | diagnostic-hdr-{stream,frame,trace} <source-path> <start> <duration> | diagnostic-hdr-normalize-oracle' >&2
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
