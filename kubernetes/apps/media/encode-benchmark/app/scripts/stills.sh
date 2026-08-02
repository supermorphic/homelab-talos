#!/usr/bin/env bash
set -euo pipefail

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
if [[ "${BENCHMARK_TEST_MODE:-0}" != '1' &&
	! "$destination_prefix" =~ ^/out/runs/[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}/stills/[a-zA-Z0-9._-]+$ ]]; then
	echo 'still destination must be inside the named run stills directory' >&2
	exit 64
fi

mkdir -p "$destination_directory"
source_final="$destination_prefix-source.png"
encoded_final="$destination_prefix-encoded.png"
source_temp="$destination_directory/.${destination_name}-source.$$.tmp.png"
encoded_temp="$destination_directory/.${destination_name}-encoded.$$.tmp.png"

cleanup() {
	rm -f -- "$source_temp" "$encoded_temp"
}
trap cleanup EXIT

crop_filter="crop='min(iw,ih)':'min(iw,ih)':'(iw-min(iw,ih))/2':'(ih-min(iw,ih))/2'"
ffmpeg -v error -ss "$timestamp" -i "$source_path" \
	-frames:v 1 -vf "$crop_filter" -y "$source_temp"
ffmpeg -v error -ss "$timestamp" -i "$encoded_path" \
	-frames:v 1 -vf "$crop_filter" -y "$encoded_temp"

mv -f -- "$source_temp" "$source_final"
mv -f -- "$encoded_temp" "$encoded_final"
