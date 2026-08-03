#!/usr/bin/env bash
set -euo pipefail

test_mode="${BENCHMARK_TEST_MODE:-0}"
test_fail_second_publish="${BENCHMARK_TEST_FAIL_STILLS_SECOND_PUBLISH:-0}"
test_fail_encoded_backup="${BENCHMARK_TEST_FAIL_STILLS_ENCODED_BACKUP:-0}"
if [[ "$test_mode" != '1' &&
	("$test_fail_second_publish" != '0' || "$test_fail_encoded_backup" != '0') ]]; then
	echo 'BENCHMARK_TEST_* hooks require BENCHMARK_TEST_MODE=1' >&2
	exit 64
fi

usage() {
	echo 'usage: stills.sh <source> <encoded> <timestamp> <destination-prefix>' >&2
	exit 64
}

(($# == 4)) || usage
source_path="$1"
encoded_path="$2"
timestamp="$3"
destination_prefix="$4"

[[ -f "$source_path" ]] || {
	echo 'source still input is not a regular file' >&2
	exit 66
}
[[ -f "$encoded_path" ]] || {
	echo 'encoded still input is not a regular file' >&2
	exit 66
}
[[ "$timestamp" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{3}$ ]] || {
	echo 'invalid still timestamp' >&2
	exit 64
}

destination_directory="$(dirname "$destination_prefix")"
destination_name="${destination_prefix##*/}"
[[ "$destination_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || {
	echo 'invalid still destination prefix' >&2
	exit 64
}
if [[ "$test_mode" != '1' &&
	! "$destination_prefix" =~ ^/out/runs/[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}/stills/[a-zA-Z0-9._-]+$ ]]; then
	echo 'still destination must be inside the named run stills directory' >&2
	exit 64
fi

path_has_symlink_component() {
	local path="$1" current='' component
	[[ "$path" == /* ]] || return 0
	IFS='/' read -r -a components <<<"$path"
	for component in "${components[@]}"; do
		[[ -n "$component" ]] || continue
		current="$current/$component"
		if [[ -L "$current" ]]; then
			if [[ "$test_mode" == '1' && ("$current" == '/var' || "$current" == '/tmp') ]]; then
				continue
			fi
			return 0
		fi
	done
	return 1
}

if path_has_symlink_component "$destination_directory"; then
	echo 'still destination contains a symbolic-link component' >&2
	exit 65
fi
if [[ "$test_mode" != '1' ]]; then
	run_directory="${destination_directory%/stills}"
	for confined_directory in /out /out/runs "$run_directory" "$destination_directory"; do
		[[ ! -L "$confined_directory" ]] || {
			echo 'still destination contains a symbolic-link component' >&2
			exit 65
		}
	done
fi

mkdir -p "$destination_directory"
[[ -d "$destination_directory" && ! -L "$destination_directory" ]] || {
	echo 'still destination is not a confined directory' >&2
	exit 65
}
source_final="$destination_prefix-source.png"
encoded_final="$destination_prefix-encoded.png"
source_temp="$destination_directory/.${destination_name}-source.$$.tmp.png"
encoded_temp="$destination_directory/.${destination_name}-encoded.$$.tmp.png"
source_backup="$destination_directory/.${destination_name}-source.$$.backup.png"
encoded_backup="$destination_directory/.${destination_name}-encoded.$$.backup.png"
source_had_prior=0
encoded_had_prior=0
source_published=0
encoded_published=0

for final_path in "$source_final" "$encoded_final"; do
	[[ ! -L "$final_path" && (! -e "$final_path" || -f "$final_path") ]] || {
		echo 'still destination is not a regular file' >&2
		exit 65
	}
done

cleanup() {
	rm -f -- "$source_temp" "$encoded_temp"
}
trap cleanup EXIT

rollback_pair() {
	local status=0
	if ((source_published)); then rm -f -- "$source_final"; fi
	if ((encoded_published)); then rm -f -- "$encoded_final"; fi
	if ((source_had_prior)); then mv -- "$source_backup" "$source_final" || status=$?; fi
	if ((encoded_had_prior)); then mv -- "$encoded_backup" "$encoded_final" || status=$?; fi
	return "$status"
}

crop_filter="crop='min(iw,ih)':'min(iw,ih)':'(iw-min(iw,ih))/2':'(ih-min(iw,ih))/2'"
ffmpeg -v error -ss "$timestamp" -i "$source_path" \
	-frames:v 1 -vf "$crop_filter" -y "$source_temp"
ffmpeg -v error -ss "$timestamp" -i "$encoded_path" \
	-frames:v 1 -vf "$crop_filter" -y "$encoded_temp"

if [[ -e "$source_final" ]]; then
	mv -- "$source_final" "$source_backup"
	source_had_prior=1
fi
if [[ -e "$encoded_final" ]]; then
	if [[ "$test_fail_encoded_backup" == '1' ]]; then
		rollback_pair || true
		exit 74
	fi
	mv -- "$encoded_final" "$encoded_backup" || {
		rollback_pair || true
		exit 74
	}
	encoded_had_prior=1
fi
if ! mv -- "$source_temp" "$source_final"; then
	rollback_pair || true
	exit 74
fi
source_published=1
if [[ "$test_fail_second_publish" == '1' ]] || ! mv -- "$encoded_temp" "$encoded_final"; then
	rollback_pair || true
	exit 74
fi
encoded_published=1
rm -f -- "$source_backup" "$encoded_backup"
