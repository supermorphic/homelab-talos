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
test_walk_error_path="${BENCHMARK_TEST_WALK_ERROR_PATH:-}"
test_fail_second_publish="${BENCHMARK_TEST_FAIL_SECOND_PUBLISH:-0}"

if [[ -n "$media_override" && "$test_mode" != '1' ]]; then
	echo 'BENCHMARK_MEDIA_ROOT requires BENCHMARK_TEST_MODE=1' >&2
	exit 64
fi
if [[ "$test_mode" != '1' &&
	(-n "$test_walk_error_path" || "$test_fail_second_publish" != '0') ]]; then
	echo 'BENCHMARK_TEST_* hooks require BENCHMARK_TEST_MODE=1' >&2
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

census_temp="$(mktemp "$output_directory/.encode-benchmark-census.XXXXXX")"
audio_temp="$(mktemp "$output_directory/.encode-benchmark-census.XXXXXX")"
paths_temp="$(mktemp "$output_directory/.encode-benchmark-census.XXXXXX")"
state_temp="$(mktemp "$output_directory/.encode-benchmark-census.XXXXXX")"
census_backup="$(mktemp "$output_directory/.encode-benchmark-census.XXXXXX")"
audio_backup="$(mktemp "$output_directory/.encode-benchmark-census.XXXXXX")"
cleanup() {
	rm -f -- \
		"$census_temp" \
		"$audio_temp" \
		"$paths_temp" \
		"$state_temp" \
		"$census_backup" \
		"$audio_backup"
}
trap cleanup EXIT

python3 -c '
import csv
import sys

try:
    with open(sys.argv[1], newline="", encoding="utf-8") as stream:
        reader = csv.reader(stream, dialect="excel-tab")
        header = next(reader, None)
        expected = ["inode", "lifecycle_state", "torrent_hash", "category", "tags"]
        if header != expected:
            raise ValueError("invalid torrent-state TSV header")
        for line_number, row in enumerate(reader, 2):
            if len(row) != 5:
                raise ValueError(
                    f"invalid torrent-state TSV record at physical line {line_number}"
                )
            for field in row:
                sys.stdout.buffer.write(field.encode("utf-8") + b"\0")
except (csv.Error, OSError, UnicodeError, ValueError) as error:
    print(error, file=sys.stderr)
    raise SystemExit(65)
' "$torrent_state" >"$state_temp"

declare -A lifecycle_by_inode=()
declare -A hash_by_inode=()
declare -A category_by_inode=()
declare -A tags_by_inode=()

record_number=0
while IFS= read -r -d '' inode &&
	IFS= read -r -d '' lifecycle &&
	IFS= read -r -d '' torrent_hash &&
	IFS= read -r -d '' category &&
	IFS= read -r -d '' tags; do
	((record_number += 1))
	[[ "$inode" =~ ^[0-9]+$ ]] || {
		echo "invalid inode in torrent-state record $record_number" >&2
		exit 65
	}
	[[ "$lifecycle" =~ ^(active|private-permanent|public-awaiting-cleanup)$ ]] || {
		echo "invalid lifecycle state in torrent-state record $record_number" >&2
		exit 65
	}
	[[ -z "${lifecycle_by_inode[$inode]:-}" ]] || {
		echo "duplicate inode in torrent-state record $record_number" >&2
		exit 65
	}
	lifecycle_by_inode[$inode]="$lifecycle"
	hash_by_inode[$inode]="$torrent_hash"
	category_by_inode[$inode]="$category"
	tags_by_inode[$inode]="$tags"
done <"$state_temp"

printf '%s\n' 'source_path,source_size_bytes,link_count,lifecycle_state,lifecycle_evidence,torrent_hash,torrent_category,torrent_tags,cohort,container,duration_seconds,video_codec,width,height,pixel_format,bit_depth,color_primaries,color_transfer,color_space,hdr_format,dolby_vision_profile,video_bit_rate,frame_rate,audio_track_count,subtitle_count,chapter_count,audio_bytes_total,audio_bytes_method' >"$census_temp"
printf '%s\n' 'source_path,track_index,codec,channels,channel_layout,language,bit_rate,duration_seconds,audio_bytes,audio_bytes_method' >"$audio_temp"

python3 -c '
import os
import sys

root = os.fsencode(sys.argv[1])
resolved_root = os.path.realpath(root)
test_failure = os.environ.get("BENCHMARK_TEST_WALK_ERROR_PATH")
failure_path = os.fsencode(test_failure) if test_failure else None
paths = []
def walk_error(error):
    raise error
try:
    for directory, _, files in os.walk(root, onerror=walk_error):
        if failure_path is not None and os.path.normpath(directory) == os.path.normpath(failure_path):
            raise OSError(13, "deterministic test walk failure", os.fsdecode(directory))
        for filename in files:
            path = os.path.join(directory, filename)
            resolved_path = os.path.realpath(path)
            if os.path.commonpath([resolved_root, resolved_path]) != resolved_root:
                escaped = os.fsdecode(path)
                print(f"source path escapes media root: {escaped}", file=sys.stderr)
                raise SystemExit(65)
            paths.append(path)
except OSError as error:
    print(f"media walk failed: {error}", file=sys.stderr)
    raise SystemExit(65)
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

census_output="$output_directory/census.csv"
audio_output="$output_directory/audio-inventory.csv"
had_census=0
had_audio=0
if [[ -e "$census_output" ]]; then
	cp -p -- "$census_output" "$census_backup"
	had_census=1
fi
if [[ -e "$audio_output" ]]; then
	cp -p -- "$audio_output" "$audio_backup"
	had_audio=1
fi

mv -f -- "$census_temp" "$census_output"
second_publish_failed=0
if [[ "$test_fail_second_publish" == '1' ]]; then
	second_publish_failed=1
elif ! mv -f -- "$audio_temp" "$audio_output"; then
	second_publish_failed=1
fi

if ((second_publish_failed == 1)); then
	rollback_failed=0
	if ((had_census == 1)); then
		mv -f -- "$census_backup" "$census_output" || rollback_failed=1
	else
		rm -f -- "$census_output" || rollback_failed=1
	fi
	if ((had_audio == 1)); then
		mv -f -- "$audio_backup" "$audio_output" || rollback_failed=1
	else
		rm -f -- "$audio_output" || rollback_failed=1
	fi
	if ((rollback_failed == 1)); then
		echo 'second census publication failed; rollback also failed' >&2
		exit 74
	fi
	echo 'second census publication failed; restored prior outputs' >&2
	exit 74
fi

rm -f -- "$paths_temp" "$state_temp" "$census_backup" "$audio_backup"
trap - EXIT
