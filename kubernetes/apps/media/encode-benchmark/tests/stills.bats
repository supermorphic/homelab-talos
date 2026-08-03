#!/usr/bin/env bats

setup() {
	STILLS="$BATS_TEST_DIRNAME/../app/scripts/stills.sh"
	export BENCHMARK_TEST_MODE=1
	source_video="$BATS_TEST_TMPDIR/source.mkv"
	encoded_video="$BATS_TEST_TMPDIR/encoded.mkv"
	ffmpeg -v error \
		-f lavfi -i 'color=c=red:s=96x64:d=1:r=10' \
		-f lavfi -i 'color=c=blue:s=96x64:d=1:r=10' \
		-filter_complex '[0:v][1:v]concat=n=2:v=1:a=0' \
		-c:v ffv1 "$source_video"
	cp "$source_video" "$encoded_video"
}

pixel_rgb() {
	ffmpeg -v error -i "$1" -vf scale=1:1 -frames:v 1 \
		-f rawvideo -pix_fmt rgb24 - 2>/dev/null |
		od -An -tu1 |
		tr -s '[:space:]' ' ' |
		sed 's/^ //; s/ $//'
}

# Catches mismatched source/variant seek timestamps, non-square crops, or a
# filename drift that makes visual pairs impossible to review mechanically.
@test "stills emits an exact matched 1:1 PNG pair at the requested timestamp" {
	prefix="$BATS_TEST_TMPDIR/stills/sample-clip-qsv-22"
	run "$STILLS" "$source_video" "$encoded_video" '00:00:01.500' "$prefix"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ -f "$prefix-source.png" ]
	[ -f "$prefix-encoded.png" ]
	[ "$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$prefix-source.png")" = '64,64' ]
	[ "$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$prefix-encoded.png")" = '64,64' ]

	IFS=' ' read -r source_red source_green source_blue <<<"$(pixel_rgb "$prefix-source.png")"
	IFS=' ' read -r encoded_red encoded_green encoded_blue <<<"$(pixel_rgb "$prefix-encoded.png")"
	((source_blue > source_red + 200 && source_blue > source_green + 200))
	((encoded_blue > encoded_red + 200 && encoded_blue > encoded_green + 200))
}

# Catches publishing the source still before the variant seek succeeds, which
# would leave an unmatched artifact that looks reviewable but has no pair.
@test "stills publishes neither image when either side cannot be decoded" {
	prefix="$BATS_TEST_TMPDIR/stills/sample-clip-qsv-22"
	invalid="$BATS_TEST_TMPDIR/not-video.mkv"
	printf '%s' 'not media' >"$invalid"

	run "$STILLS" "$source_video" "$invalid" '00:00:01.500' "$prefix"
	[ "$status" -ne 0 ]
	[ "$status" -ne 127 ]
	[ ! -e "$prefix-source.png" ]
	[ ! -e "$prefix-encoded.png" ]
	[ "$(find "$BATS_TEST_TMPDIR/stills" -type f 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]
}

@test "stills rejects a symlink destination escape" {
	outside="$BATS_TEST_TMPDIR/outside"
	container="$BATS_TEST_TMPDIR/container"
	mkdir -p "$outside"
	mkdir -p "$container"
	ln -s "$outside" "$container/link"
	prefix="$container/link/nested/sample-clip-qsv-22"

	run "$STILLS" "$source_video" "$encoded_video" '00:00:01.500' "$prefix"
	[ "$status" -ne 0 ]
	[ ! -e "$outside/nested/sample-clip-qsv-22-source.png" ]
	[ ! -e "$outside/nested/sample-clip-qsv-22-encoded.png" ]
}

@test "stills second-publication failure removes a new pair and restores a prior pair" {
	prefix="$BATS_TEST_TMPDIR/stills/sample-clip-qsv-22"
	mkdir -p "$(dirname "$prefix")"
	export BENCHMARK_TEST_FAIL_STILLS_SECOND_PUBLISH=1

	run "$STILLS" "$source_video" "$encoded_video" '00:00:01.500' "$prefix"
	[ "$status" -ne 0 ]
	[ ! -e "$prefix-source.png" ]
	[ ! -e "$prefix-encoded.png" ]

	printf '%s' 'prior source' >"$prefix-source.png"
	printf '%s' 'prior encoded' >"$prefix-encoded.png"
	run "$STILLS" "$source_video" "$encoded_video" '00:00:01.500' "$prefix"
	[ "$status" -ne 0 ]
	[ "$(<"$prefix-source.png")" = 'prior source' ]
	[ "$(<"$prefix-encoded.png")" = 'prior encoded' ]
	[ "$(find "$(dirname "$prefix")" -type f -name '*.tmp.png' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "stills encoded-backup failure preserves both untouched prior names" {
	prefix="$BATS_TEST_TMPDIR/stills/sample-clip-qsv-22"
	mkdir -p "$(dirname "$prefix")"
	printf '%s' 'prior source' >"$prefix-source.png"
	printf '%s' 'prior encoded' >"$prefix-encoded.png"
	export BENCHMARK_TEST_FAIL_STILLS_ENCODED_BACKUP=1

	run "$STILLS" "$source_video" "$encoded_video" '00:00:01.500' "$prefix"
	[ "$status" -ne 0 ]
	[ "$(<"$prefix-source.png")" = 'prior source' ]
	[ "$(<"$prefix-encoded.png")" = 'prior encoded' ]
}

@test "stills failure hooks are rejected outside test mode" {
	export BENCHMARK_TEST_MODE=0
	export BENCHMARK_TEST_FAIL_STILLS_SECOND_PUBLISH=1
	run "$STILLS" "$source_video" "$encoded_video" '00:00:01.500' \
		'/out/runs/20260802T120000Z-aaaaaaaa/stills/sample-clip-qsv-22'
	[ "$status" -eq 64 ]
	[ "$output" = 'BENCHMARK_TEST_* hooks require BENCHMARK_TEST_MODE=1' ]
}
