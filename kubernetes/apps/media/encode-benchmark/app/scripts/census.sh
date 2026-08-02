#!/usr/bin/env bash
set -euo pipefail

if (($# != 2)); then
	echo 'usage: census.sh <torrent-state.tsv> <output-directory>' >&2
	exit 64
fi

torrent_state="$1"
output_directory="$2"
test_mode="${BENCHMARK_TEST_MODE:-0}"
media_override="${BENCHMARK_MEDIA_ROOT:-}"

if [[ -n "$media_override" && "$test_mode" != '1' ]]; then
	echo 'BENCHMARK_MEDIA_ROOT requires BENCHMARK_TEST_MODE=1' >&2
	exit 64
fi
if [[ "$test_mode" == '1' ]]; then
	[[ -n "$media_override" ]] || {
		echo 'BENCHMARK_TEST_MODE=1 requires BENCHMARK_MEDIA_ROOT' >&2
		exit 64
	}
	media_root="${media_override%/}"
else
	media_root='/media'
fi

[[ -f "$torrent_state" ]] || {
	echo "torrent state not found: $torrent_state" >&2
	exit 66
}
[[ -d "$media_root" ]] || {
	echo "media root not found: $media_root" >&2
	exit 66
}
mkdir -p "$output_directory"

declare -A lifecycle_by_inode=()
declare -A hash_by_inode=()
declare -A category_by_inode=()
declare -A tags_by_inode=()

line_number=0
while IFS=$'\t' read -r inode lifecycle torrent_hash category tags extra; do
	((line_number += 1))
	if ((line_number == 1)); then
		[[ "$inode" == 'inode' && "$lifecycle" == 'lifecycle_state' &&
			"$torrent_hash" == 'torrent_hash' && "$category" == 'category' &&
			"$tags" == 'tags' && -z "${extra:-}" ]] || {
			echo 'invalid torrent-state TSV header' >&2
			exit 65
		}
		continue
	fi
	[[ "$inode" =~ ^[0-9]+$ ]] || {
		echo "invalid inode on torrent-state line $line_number" >&2
		exit 65
	}
	[[ "$lifecycle" =~ ^(active|private-permanent|public-awaiting-cleanup)$ ]] || {
		echo "invalid lifecycle state on torrent-state line $line_number" >&2
		exit 65
	}
	[[ -z "${lifecycle_by_inode[$inode]:-}" ]] || {
		echo "duplicate inode on torrent-state line $line_number" >&2
		exit 65
	}
	lifecycle_by_inode[$inode]="$lifecycle"
	hash_by_inode[$inode]="$torrent_hash"
	category_by_inode[$inode]="$category"
	tags_by_inode[$inode]="$tags"
done <"$torrent_state"
((line_number > 0)) || {
	echo 'torrent-state TSV is empty' >&2
	exit 65
}

census_temp="$(mktemp "$output_directory/.encode-benchmark-census.XXXXXX")"
audio_temp="$(mktemp "$output_directory/.encode-benchmark-census.XXXXXX")"
paths_temp="$(mktemp "$output_directory/.encode-benchmark-census.XXXXXX")"
cleanup() {
	rm -f -- "$census_temp" "$audio_temp" "$paths_temp"
}
trap cleanup EXIT

printf '%s\n' 'source_path,source_size_bytes,link_count,lifecycle_state,lifecycle_evidence,torrent_hash,torrent_category,torrent_tags,cohort,container,duration_seconds,video_codec,width,height,pixel_format,bit_depth,color_primaries,color_transfer,color_space,hdr_format,dolby_vision_profile,video_bit_rate,frame_rate,audio_track_count,subtitle_count,chapter_count,audio_bytes_total,audio_bytes_method' >"$census_temp"
printf '%s\n' 'source_path,track_index,codec,channels,channel_layout,language,bit_rate,duration_seconds,audio_bytes,audio_bytes_method' >"$audio_temp"

python3 -c '
import os
import sys

root = os.fsencode(sys.argv[1])
resolved_root = os.path.realpath(root)
paths = []
for directory, _, files in os.walk(root):
    for filename in files:
        path = os.path.join(directory, filename)
        resolved_path = os.path.realpath(path)
        if os.path.commonpath([resolved_root, resolved_path]) != resolved_root:
            escaped = os.fsdecode(path)
            print(f"source path escapes media root: {escaped}", file=sys.stderr)
            raise SystemExit(65)
        paths.append(path)
for path in sorted(paths):
    sys.stdout.buffer.write(path + b"\0")
' "$media_root" >"$paths_temp"

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while IFS= read -r -d '' source_path; do
	stat_fields="$(python3 -c 'import os, sys; value = os.stat(sys.argv[1]); print(f"{value.st_ino}\t{value.st_nlink}\t{value.st_size}")' "$source_path")"
	IFS=$'\t' read -r inode link_count source_size <<<"$stat_fields"

	if ((link_count == 1)); then
		lifecycle='unlinked'
		evidence='link-count-1'
		torrent_hash=''
		torrent_category=''
		torrent_tags=''
	elif [[ -n "${lifecycle_by_inode[$inode]:-}" ]]; then
		lifecycle="${lifecycle_by_inode[$inode]}"
		evidence='torrent-inventory'
		torrent_hash="${hash_by_inode[$inode]}"
		torrent_category="${category_by_inode[$inode]}"
		torrent_tags="${tags_by_inode[$inode]}"
	else
		lifecycle='active'
		evidence='unmatched-hardlink'
		torrent_hash=''
		torrent_category=''
		torrent_tags=''
	fi

	relative_path="${source_path#"$media_root"/}"
	[[ "$relative_path" != "$source_path" && -n "$relative_path" ]] || {
		echo "source path outside media root: $source_path" >&2
		exit 65
	}
	output_path="/media/$relative_path"
	metadata="$("$script_directory"/probe.sh "$source_path")"

	jq -r \
		--arg source_path "$output_path" \
		--argjson source_size "$source_size" \
		--argjson link_count "$link_count" \
		--arg lifecycle "$lifecycle" \
		--arg evidence "$evidence" \
		--arg torrent_hash "$torrent_hash" \
		--arg torrent_category "$torrent_category" \
		--arg torrent_tags "$torrent_tags" '
			([.audioTracks[].audioBytes // 0] | add // 0) as $audio_total
			| ([.audioTracks[].audioBytesMethod] | unique) as $audio_methods
			| (if (.audioTracks | length) == 0 then "none"
				elif ($audio_methods | length) == 1 then $audio_methods[0]
				else "mixed"
				end) as $audio_method
			| [
				$source_path, $source_size, $link_count, $lifecycle, $evidence,
				$torrent_hash, $torrent_category, $torrent_tags,
				.cohort, .container, .durationSeconds, .videoCodec, .width, .height,
				.pixelFormat, .bitDepth, .colorPrimaries, .colorTransfer, .colorSpace,
				.hdrFormat, .dolbyVisionProfile, .videoBitRate, .frameRate,
				.audioTrackCount, .subtitleCount, .chapterCount,
				$audio_total, $audio_method
			] | @csv
		' <<<"$metadata" >>"$census_temp"

	jq -r --arg source_path "$output_path" '
		.audioTracks[]
		| [
			$source_path, .index, .codec, .channels, .channelLayout, .language,
			.bitRate, .durationSeconds, .audioBytes, .audioBytesMethod
		] | @csv
	' <<<"$metadata" >>"$audio_temp"
done <"$paths_temp"

mv -f -- "$census_temp" "$output_directory/census.csv"
mv -f -- "$audio_temp" "$output_directory/audio-inventory.csv"
trap - EXIT
