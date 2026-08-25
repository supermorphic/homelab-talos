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
probe_error_temp="$(mktemp "$output_directory/.encode-benchmark-census.XXXXXX")"
cleanup() {
	rm -f -- \
		"$census_temp" \
		"$audio_temp" \
		"$paths_temp" \
		"$state_temp" \
		"$census_backup" \
		"$audio_backup" \
		"$probe_error_temp"
}
trap cleanup EXIT

# The inventory arrives as JSON Lines so jq owns the quoting: tags carry
# arbitrary operator text including tabs, newlines and quotes, and jq is the only
# parser this runtime image provides that handles them correctly.
#
# Fields are base64-encoded rather than delimiter-separated. jq silently discards
# NUL bytes, so a NUL-delimited stream loses every field boundary; and any
# printable delimiter can legitimately occur inside a tag. base64 output is
# restricted to [A-Za-z0-9+/=], so a space-separated line is unambiguous by
# construction rather than by assumption about the data.
jq -r -e '
	if (type != "object") then error("torrent-state record is not an object") else . end
	| if (["category", "inode", "lifecycle_state", "tags", "torrent_hash"] - keys | length) != 0
		then error("torrent-state record is missing required fields")
		else . end
	| if (.inode | type) != "number" then error("torrent-state inode is not a number") else . end
	| ([.lifecycle_state, .torrent_hash, .category, .tags]
		| map(if type == "string" then . else error("torrent-state field is not a string") end)
		| map(@base64)) as $encoded
	| [(.inode | tostring)] + $encoded
	| join(" ")
' "$torrent_state" >"$state_temp" || {
	echo 'invalid torrent-state inventory' >&2
	exit 65
}

declare -A lifecycle_by_inode=()
declare -A hash_by_inode=()
declare -A category_by_inode=()
declare -A tags_by_inode=()

record_number=0
source_count=0
probe_failures=0
while read -r inode lifecycle_b64 hash_b64 category_b64 tags_b64; do
	((record_number += 1))
	[[ "$inode" =~ ^[0-9]+$ ]] || {
		echo "invalid inode in torrent-state record $record_number" >&2
		exit 65
	}
	lifecycle="$(printf '%s' "$lifecycle_b64" | base64 -d)" || {
		echo "undecodable lifecycle state in torrent-state record $record_number" >&2
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
	hash_by_inode[$inode]="$(printf '%s' "$hash_b64" | base64 -d)"
	category_by_inode[$inode]="$(printf '%s' "$category_b64" | base64 -d)"
	tags_by_inode[$inode]="$(printf '%s' "$tags_b64" | base64 -d)"
done <"$state_temp"

printf '%s\n' 'source_path,source_size_bytes,link_count,lifecycle_state,lifecycle_evidence,torrent_hash,torrent_category,torrent_tags,cohort,container,duration_seconds,video_codec,width,height,pixel_format,bit_depth,color_primaries,color_transfer,color_space,hdr_format,dolby_vision_profile,video_bit_rate,frame_rate,audio_track_count,subtitle_count,chapter_count,audio_bytes_total,audio_bytes_method,probe_status,probe_error' >"$census_temp"
printf '%s\n' 'source_path,track_index,codec,channels,channel_layout,language,bit_rate,duration_seconds,audio_bytes,audio_bytes_method' >"$audio_temp"

# Enumerate sources with find and resolve containment with realpath. The walk
# must fail closed: a permission error that silently truncated the list would
# under-report the library rather than error, so pipefail plus find's exit status
# are both load-bearing here.
media_root_resolved="$(realpath -- "$media_root")" || {
	echo "media walk failed: cannot resolve media root" >&2
	exit 65
}
if [[ -n "$test_walk_error_path" ]]; then
	echo "media walk failed: deterministic test walk failure at $test_walk_error_path" >&2
	exit 65
fi
# "! -type d" rather than "-type f": a symlink is not a regular file, so -type f
# would silently skip an escaping symlink instead of rejecting it, under-reporting
# the library and losing the explicit containment failure the design requires.
find "$media_root" ! -type d -print0 | LC_ALL=C sort -z >"$paths_temp" || {
	echo 'media walk failed: source enumeration did not complete' >&2
	exit 65
}

# GNU coreutils in the runtime image, BSD stat on the operator workstation that
# runs the offline contracts. Both are exercised: the fallback here, and a
# functional stat check in the capability probe that runs inside the real image.
stat_fields() {
	stat -c '%i %h %s' -- "$1" 2>/dev/null || stat -f '%i %l %z' -- "$1"
}

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while IFS= read -r -d '' source_path; do
	# Component-wise containment, not a string prefix: the trailing slash stops a
	# sibling such as /media-evil from satisfying a /media root.
	resolved_source="$(realpath -- "$source_path")" || {
		echo 'media walk failed: cannot resolve source path' >&2
		exit 65
	}
	[[ "$resolved_source" == "$media_root_resolved"/* ]] || {
		echo "source path escapes media root: $source_path" >&2
		exit 65
	}
	read -r inode link_count source_size <<<"$(stat_fields "$source_path")"

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
	((source_count += 1))
	# An unreadable file is a per-library finding, so record it and continue. One
	# title must not block the inventory, while the threshold below still fails
	# loudly when the mount itself is broken.
	probe_status='probed'
	probe_error=''
	if metadata="$("$script_directory"/probe.sh "$source_path" 2>"$probe_error_temp")"; then
		:
	else
		((probe_failures += 1))
		probe_status='probe-failed'
		# One line, bounded: the prober echoes the source path back, which this
		# row already carries, and a multi-line message would break the CSV.
		probe_error="$(tr '\n\r\t' '   ' <"$probe_error_temp" | cut -c1-200)"
		[[ -n "$probe_error" ]] || probe_error='probe failed without a message'
		metadata='{}'
	fi

	jq -r \
		--arg source_path "$output_path" \
		--argjson source_size "$source_size" \
		--argjson link_count "$link_count" \
		--arg lifecycle "$lifecycle" \
		--arg evidence "$evidence" \
		--arg torrent_hash "$torrent_hash" \
		--arg torrent_category "$torrent_category" \
		--arg torrent_tags "$torrent_tags" \
		--arg probe_status "$probe_status" \
		--arg probe_error "$probe_error" '
			([(.audioTracks // [])[].audioBytes // 0] | add // 0) as $audio_total
			| ([(.audioTracks // [])[].audioBytesMethod] | unique) as $audio_methods
			| (if ((.audioTracks // []) | length) == 0 then "none"
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
				$audio_total, $audio_method, $probe_status, $probe_error
			] | @csv
		' <<<"$metadata" >>"$census_temp"

	jq -r --arg source_path "$output_path" '
		(.audioTracks // [])[]
		| [
			$source_path, .index, .codec, .channels, .channelLayout, .language,
			.bitRate, .durationSeconds, .audioBytes, .audioBytesMethod
		] | @csv
	' <<<"$metadata" >>"$audio_temp"
done <"$paths_temp"

# Fail loudly when the failure rate implies a broken mount rather than a bad
# title: a census of nothing but failure rows would otherwise look complete.
if ((source_count > 0 && probe_failures * 20 > source_count)); then
	echo "census aborted: $probe_failures of $source_count sources could not be probed" >&2
	exit 65
fi

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

rm -f -- "$paths_temp" "$state_temp" "$census_backup" "$audio_backup" "$probe_error_temp"
trap - EXIT
