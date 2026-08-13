#!/usr/bin/env bats

setup() {
	PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)"
	SELECT_SAMPLES="$PROJECT_ROOT/scripts/encode-benchmark/select-samples.sh"
	MOVIE_ROOT="$BATS_TEST_TMPDIR/movies"
	CENSUS_ASC="$BATS_TEST_TMPDIR/census-ascending.csv"
	CENSUS_DESC="$BATS_TEST_TMPDIR/census-descending.csv"
	mkdir -p "$MOVIE_ROOT"
	write_census_fixtures
}

write_census_fixtures() {
	header='source_path,source_size_bytes,link_count,lifecycle_state,lifecycle_evidence,torrent_hash,torrent_category,torrent_tags,cohort,container,duration_seconds,video_codec,width,height,pixel_format,bit_depth,color_primaries,color_transfer,color_space,hdr_format,dolby_vision_profile,video_bit_rate,frame_rate,audio_track_count,subtitle_count,chapter_count,audio_bytes_total,audio_bytes_method,probe_status,probe_error'
	rows="$BATS_TEST_TMPDIR/rows.csv"
	: >"$rows"
	for cohort in avc vc1 hdr10; do
		for index in 1 2 3 4 5 6 7 8; do
			name="$cohort-$index.mkv"
			content="$cohort fixture $index"
			printf '%s' "$content" >"$MOVIE_ROOT/$name"
			size="$(wc -c <"$MOVIE_ROOT/$name" | tr -d ' ')"
			case "$cohort" in
			avc)
				codec='h264'
				width=1920
				height=1080
				hdr=''
				;;
			vc1)
				codec='vc1'
				width=1920
				height=1080
				hdr=''
				;;
			hdr10)
				codec='hevc'
				width=3840
				height=2160
				hdr='hdr10'
				;;
			esac
			lifecycle='public-awaiting-cleanup'
			[[ "$index" != 8 ]] || lifecycle='active'
			bitrate=$((index * 1000000))
			printf '"/media/%s",%s,2,%s,torrent-inventory,,,tracker-public,%s,matroska,7200,%s,%s,%s,yuv420p,8,bt709,bt709,bt709,%s,,%s,24000/1001,1,0,0,100,estimated,probed,\n' \
				"$name" "$size" "$lifecycle" "$cohort" "$codec" "$width" "$height" "$hdr" "$bitrate" >>"$rows"
		done
	done
	{
		printf '%s\n' "$header"
		sort "$rows"
	} >"$CENSUS_ASC"
	{
		printf '%s\n' "$header"
		sort -r "$rows"
	} >"$CENSUS_DESC"
}

write_single_row_census() {
	output="$1"
	bitrate="$2"
	duration="$3"
	size="$(wc -c <"$MOVIE_ROOT/avc-1.mkv" | tr -d ' ')"
	{
		head -n 1 "$CENSUS_ASC"
		printf '"/media/avc-1.mkv",%s,2,active,torrent-inventory,,,tracker-public,avc,matroska,%s,h264,1920,1080,yuv420p,8,bt709,bt709,bt709,,,%s,24000/1001,1,0,0,100,estimated,probed,\n' \
			"$size" "$duration" "$bitrate"
	} >"$output"
}

write_formula_ranking_census() {
	output="$1"
	rows="$BATS_TEST_TMPDIR/formula-ranking-rows.csv"
	: >"$rows"
	while IFS=',' read -r index size duration bitrate; do
		printf '%*s' "$size" '' >"$MOVIE_ROOT/formula-$index.mkv"
		printf '"/media/formula-%s.mkv",%s,2,active,torrent-inventory,,,tracker-public,avc,matroska,%s,h264,1920,1080,yuv420p,8,bt709,bt709,bt709,,,%s,24000/1001,1,0,0,100,estimated,probed,\n' \
			"$index" "$size" "$duration" "$bitrate" >>"$rows"
	done <<'ROWS'
1,1815,104,1843
2,1104,171,3447
3,1148,122,
4,1661,197,
5,198,132,
6,414,183,
7,1710,134,
8,1690,145,
9,1515,64,
10,1984,43,
11,792,50,
12,836,61,
ROWS
	{
		head -n 1 "$CENSUS_ASC"
		cat "$rows"
	} >"$output"
}

# Catches replacing the fallback with a positive constant or calculating it
# without either source_size_bytes or duration_seconds. With size * 8 /
# duration, formula-7 is selected and formula-4 is omitted; all three broken
# rankings reverse those identities for this hand-checked fixture.
@test "derived bitrate uses source size and duration to rank mixed candidates" {
	census="$BATS_TEST_TMPDIR/census-formula-ranking.csv"
	write_formula_ranking_census "$census"

	run "$SELECT_SAMPLES" "$census" 20260802 "$MOVIE_ROOT"
	[ "$status" -eq 0 ]
	[ "$(yq -r '.savingsPanel | length' <<<"$output")" -eq 8 ]
	[ "$(yq -r '[.savingsPanel[].path] | join(",")' <<<"$output")" = '/media/formula-1.mkv,/media/formula-10.mkv,/media/formula-11.mkv,/media/formula-2.mkv,/media/formula-5.mkv,/media/formula-6.mkv,/media/formula-7.mkv,/media/formula-9.mkv' ]
}

@test "selection rejects malformed reported bitrate instead of applying the fallback" {
	census="$BATS_TEST_TMPDIR/census-malformed-video-bitrate.csv"
	write_single_row_census "$census" 'not-a-number' 7200

	run "$SELECT_SAMPLES" "$census" 20260802 "$MOVIE_ROOT"
	[ "$status" -ne 0 ]
	[[ "$output" == *'invalid numeric census field at row 2'* ]]
}

@test "selection rejects unusable duration when deriving a bitrate" {
	census="$BATS_TEST_TMPDIR/census-unusable-duration.csv"
	write_single_row_census "$census" '' 0

	run "$SELECT_SAMPLES" "$census" 20260802 "$MOVIE_ROOT"
	[ "$status" -ne 0 ]
	[[ "$output" == *'invalid numeric census field at row 2'* ]]
}

# Catches input-order dependence, a changed seed, duplicate IDs, lifecycle
# filtering, and selection that misses a populated source-bitrate quartile.
@test "seeded savings selection is stable stratified unique and lifecycle-neutral" {
	run "$SELECT_SAMPLES" "$CENSUS_ASC" 20260802 "$MOVIE_ROOT"
	[ "$status" -eq 0 ]
	ascending="$output"

	run "$SELECT_SAMPLES" "$CENSUS_DESC" 20260802 "$MOVIE_ROOT"
	[ "$status" -eq 0 ]
	[ "$output" = "$ascending" ]

	[ "$(yq -r '.savingsSeed' <<<"$ascending")" = '20260802' ]
	[ "$(yq -r '.savingsPanel | length' <<<"$ascending")" -eq 24 ]
	[ "$(yq -r '[.savingsPanel[].id] | unique | length' <<<"$ascending")" -eq 24 ]
	for cohort in avc vc1 hdr10; do
		[ "$(yq -r "[.savingsPanel[] | select(.cohort == \"$cohort\")] | length" <<<"$ascending")" -eq 8 ]
		quartile_count="$(
			yq -r ".savingsPanel[] | select(.cohort == \"$cohort\") | .path" <<<"$ascending" |
				awk -F '[-.]' '{print int(($(NF-1) - 1) / 2)}' | sort -u | wc -l | tr -d ' '
		)"
		[ "$quartile_count" -eq 4 ]
		[ "$(yq -r "[.savingsPanel[] | select(.cohort == \"$cohort\" and .path == \"/media/$cohort-8.mkv\")] | length" <<<"$ascending")" -eq 1 ]
	done
}

# Catches hashing the pod path, trusting stale census size, or rewriting the
# emitted source path to the operator workstation's local mount.
@test "selected samples verify local bytes while preserving absolute pod paths" {
	run "$SELECT_SAMPLES" "$CENSUS_ASC" 20260802 "$MOVIE_ROOT"
	[ "$status" -eq 0 ]
	document="$output"
	path='/media/avc-1.mkv'
	expected_sha="$(sha256sum "$MOVIE_ROOT/avc-1.mkv" | awk '{print $1}')"
	[ "$(yq -r ".savingsPanel[] | select(.path == \"$path\") | .sha256" <<<"$document")" = "$expected_sha" ]
	[ "$(yq -r ".savingsPanel[] | select(.path == \"$path\") | .path" <<<"$document")" = "$path" ]
	[ "$(yq -r ".savingsPanel[] | select(.path == \"$path\") | .width" <<<"$document")" = '1920' ]
	[ "$(yq -r ".savingsPanel[] | select(.path == \"$path\") | .height" <<<"$document")" = '1080' ]
	[ "$(yq -r '.savingsPanel[] | select(.path == "/media/hdr10-1.mkv") | [.width,.height] | join("x")' <<<"$document")" = '3840x2160' ]
	! rg -F "$MOVIE_ROOT" <<<"$document"

	printf 'changed-size' >>"$MOVIE_ROOT/avc-1.mkv"
	run "$SELECT_SAMPLES" "$CENSUS_ASC" 20260802 "$MOVIE_ROOT"
	[ "$status" -ne 0 ]
	[[ "$output" == *'size mismatch for /media/avc-1.mkv'* ]]
}

# Catches traversal through a census-controlled /media path into another local
# tree before the script performs its size or content verification.
@test "selection rejects media traversal before local file access" {
	malformed="$BATS_TEST_TMPDIR/census-traversal.csv"
	{
		head -n 1 "$CENSUS_ASC"
		printf '%s\n' '"/media/../secret.mkv",1,1,active,link-count-1,,,,avc,matroska,1,h264,1920,1080,yuv420p,8,bt709,bt709,bt709,,,1000000,24/1,1,0,0,1,estimated,probed,'
	} >"$malformed"

	run "$SELECT_SAMPLES" "$malformed" 20260802 "$MOVIE_ROOT"
	[ "$status" -ne 0 ]
	[[ "$output" == *'invalid census media path'* ]]
}

# Catches the selector emitting YAML after the samples artifact became JSON.
# Its output is merged into samples.json, so a YAML fragment cannot be applied.
@test "selection emits a JSON object mergeable into samples.json" {
	run "$SELECT_SAMPLES" "$CENSUS_ASC" 20260802 "$MOVIE_ROOT"
	[ "$status" -eq 0 ]

	run jq -e '
		(.savingsSeed == 20260802) and
		(.savingsPanel | type == "array") and
		(.savingsPanel | length > 0) and
		all(.savingsPanel[];
			(keys | sort) == ["cohort","height","id","path","sha256","sizeBytes","width"]
			and (.sizeBytes | type == "number")
			and (.sha256 | test("^[0-9a-f]{64}$")))
	' <<<"$output"
	[ "$status" -eq 0 ]
}
