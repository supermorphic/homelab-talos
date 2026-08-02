#!/usr/bin/env bash
set -euo pipefail

if (($# != 1)); then
	echo 'usage: probe.sh <source-path>' >&2
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
