#!/usr/bin/env bats

setup() {
	PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)"
	SCRIPTS="$BATS_TEST_DIRNAME/../app/scripts"
	SOURCE_FIXTURES="$BATS_TEST_DIRNAME/fixtures"
	FIXTURES="$BATS_TEST_TMPDIR/fixtures"
	GOLDEN="$BATS_TEST_DIRNAME/golden"
	INVENTORY="$PROJECT_ROOT/scripts/encode-benchmark/torrent-inventory.py"
	cp -R "$SOURCE_FIXTURES" "$FIXTURES"
}

emit_inventory_record() {
	jq -c -n -S \
		--argjson inode "$1" \
		--arg lifecycle_state "$2" \
		--arg torrent_hash "$3" \
		--arg category "$4" \
		--arg tags "$5" \
		'{inode: $inode, lifecycle_state: $lifecycle_state, torrent_hash: $torrent_hash, category: $category, tags: $tags}'
}

create_ffprobe_stub() {
	stub_bin="$BATS_TEST_TMPDIR/ffprobe-bin"
	mkdir -p "$stub_bin"
	cat >"$stub_bin/ffprobe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if (($# != 8)) ||
	[[ "$1" != '-v' || "$2" != 'error' || "$3" != '-show_streams' ||
		"$4" != '-show_format' || "$5" != '-show_chapters' ||
		"$6" != '-of' || "$7" != 'json' ]]; then
	echo 'unexpected ffprobe arguments' >&2
	exit 97
fi

source_path="$8"
filename="${source_path##*/}"
if [[ -n "${FFPROBE_FAIL_PATTERN:-}" && "$filename" == *"$FFPROBE_FAIL_PATTERN"* ]]; then
	echo "fixture ffprobe failure: $filename" >&2
	exit 23
fi

case "$filename" in
	*Dolby*) fixture='dolby-vision-profile7.json' ;;
	*HDRStatic*) fixture='hdr-static-metadata.json' ;;
	*'Public Cleanup'* | *'Unlinked AVC'*) fixture='multi-audio.json' ;;
	*TrueHD*) fixture='truehd-unknown.json' ;;
	*) fixture='vc1.json' ;;
esac

exec jq -c . "$FFPROBE_FIXTURE_DIR/$fixture"
EOF
	chmod +x "$stub_bin/ffprobe"
}

create_diagnostic_probe_stubs() {
	stub_bin="$BATS_TEST_TMPDIR/diagnostic-probe-bin"
	mkdir -p "$stub_bin"
	cat >"$stub_bin/ffprobe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
arguments="$*"
if [[ "$arguments" == *'stream_side_data'* ]]; then
	jq -n '{streams:[{side_data_list:[
		{side_data_type:"Mastering display metadata",red_x:"34000/50000",red_y:"16000/50000",green_x:"13250/50000",green_y:"34500/50000",blue_x:"7500/50000",blue_y:"3000/50000",white_point_x:"15635/50000",white_point_y:"16450/50000",min_luminance:"1/10000",max_luminance:"10000000/10000"},
		{side_data_type:"Content light level metadata",max_content:1000,max_average:400}
	]}]}'
	exit 0
fi
if [[ "$arguments" == *'frame=side_data_list'* ]]; then
	jq -n '{frames:[{side_data_list:[
		{side_data_type:"Mastering display metadata",red_x:"34000/50000",red_y:"16000/50000",green_x:"13250/50000",green_y:"34500/50000",blue_x:"7500/50000",blue_y:"3000/50000",white_point_x:"15635/50000",white_point_y:"16450/50000",min_luminance:"1/10000",max_luminance:"10000000/10000"},
		{side_data_type:"Content light level metadata",max_content:1000,max_average:400}
	]}]}'
	exit 0
fi
jq -n '{
	streams:[{start_time:"0.000000",duration:"90.000000",time_base:"1/1000",avg_frame_rate:"24/1"}],
	frames:[range(0;45) | {best_effort_timestamp_time:(. / 24 | tostring),pkt_duration_time:"0.041667",key_frame:(if . == 0 then 1 else 0 end),pict_type:(if . == 0 then "I" else "P" end)}]
}'
EOF
	cat >"$stub_bin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == *'-ss 00:10:00.000 -i '* ]]
[[ "$*" == *'-t 10 -map 0:v:0 -c:v copy -bsf:v trace_headers -f null -'* ]]
mastering_first_half() {
	printf '%s\n' 'Mastering Display Colour Volume' \
		'display_primaries_x[0] = 13250' 'display_primaries_y[0] = 34500' \
		'display_primaries_x[1] = 7500' 'display_primaries_y[1] = 3000' \
		'display_primaries_x[2] = 34000' >&2
}
mastering_first_half_conflicting() {
	printf '%s\n' 'Mastering Display Colour Volume' \
		'display_primaries_x[0] = 999' 'display_primaries_y[0] = 34500' \
		'display_primaries_x[1] = 7500' 'display_primaries_y[1] = 3000' \
		'display_primaries_x[2] = 34000' >&2
}
mastering_second_half() {
	printf '%s\n' 'display_primaries_y[2] = 16000' \
		'white_point_x = 15635' 'white_point_y = 16450' \
		'max_display_mastering_luminance = 10000000' \
		'min_display_mastering_luminance = 1' >&2
}
content_light() {
	printf '%s\n' 'Content Light Level Information' \
		'max_content_light_level = 1000' 'max_pic_average_light_level = 400' >&2
}
case "${BENCHMARK_DIAGNOSTIC_TRACE_SCENARIO:-complete}" in
split-partial)
	mastering_first_half
	printf '%s\n' 'Mastering Display Colour Volume' >&2
	mastering_second_half
	content_light
	;;
conflicting-repeat)
	mastering_first_half
	mastering_second_half
	mastering_first_half_conflicting
	mastering_second_half
	content_light
	;;
*)
	content_light
	mastering_first_half
	mastering_second_half
	;;
esac
EOF
	chmod +x "$stub_bin/ffprobe" "$stub_bin/ffmpeg"
}

create_qbittorrent_stub() {
	stub_python="$BATS_TEST_TMPDIR/qbittorrent-stub"
	mkdir -p "$stub_python"
	cat >"$stub_python/qbittorrentapi.py" <<'PYTHON'
import json
import os
from pathlib import Path
from types import SimpleNamespace


def _object(value):
    return SimpleNamespace(**value)


class Client:
    def __init__(self, *, host, username, password, REQUESTS_ARGS):
        if host != "http://qbittorrent.media.svc.cluster.local:8080":
            raise AssertionError(f"unexpected host: {host}")
        if username != "fixture-user" or password != "fixture-pass":
            raise AssertionError("fixture credentials were not passed to the client")
        if REQUESTS_ARGS != {"timeout": 30}:
            raise AssertionError(f"unexpected request settings: {REQUESTS_ARGS}")
        fixture_dir = Path(os.environ["QBT_FIXTURE_DIR"])
        scenarios = []
        for fixture_path in sorted(fixture_dir.glob("*.json")):
            scenario = json.loads(fixture_path.read_text())
            if scenario["torrent"] is not None:
                if (
                    scenario["torrent"]["hash"] == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                    and "QBT_STUB_TAGS" in os.environ
                ):
                    scenario["torrent"]["tags"] = os.environ["QBT_STUB_TAGS"]
                scenarios.append(scenario)
        self._scenarios = scenarios

    def auth_log_in(self):
        if os.environ.get("QBT_STUB_AUTH_ERROR") == "1":
            raise RuntimeError(
                "fixture-user fixture-pass https://tracker.invalid/announce?passkey=fixture-secret"
            )
        return None

    def torrents_info(self, *, category):
        if category != "movies":
            raise AssertionError(f"unexpected category filter: {category}")
        return [_object(item["torrent"]) for item in self._scenarios]

    def torrents_files(self, *, torrent_hash):
        for item in self._scenarios:
            if item["torrent"]["hash"] == torrent_hash:
                return [_object(file_info) for file_info in item["files"]]
        raise AssertionError(f"unknown torrent hash: {torrent_hash}")
PYTHON
}

prepare_library() {
	media_root="$BATS_TEST_TMPDIR/media"
	download_root="$BATS_TEST_TMPDIR/downloads"
	hidden_root="$BATS_TEST_TMPDIR/hidden"
	mkdir -p \
		"$media_root" \
		"$hidden_root" \
		"$download_root/movies/uploading-public" \
		"$download_root/movies/stopped-public" \
		"$download_root/movies/uploading-czteam" \
		"$download_root/movies/stopped-czteam"

	printf 'A' >"$media_root/Active Public.mkv"
	printf 'BB' >"$media_root/Dolby \"Private\", Feature.mkv"
	printf 'CCC' >"$media_root/Public Cleanup.mkv"
	printf 'DDDD' >"$media_root/TrueHD Unmatched.mkv"
	printf 'EEEEE' >"$media_root/Unlinked AVC.mkv"
	printf 'FFFFFF' >"$media_root/Shared Priority VC1.mkv"
	printf 'GGGGGGG' >"$media_root/Active CZTeam.mkv"

	ln "$media_root/Active Public.mkv" \
		"$download_root/movies/uploading-public/Active Public.mkv"
	ln "$media_root/Shared Priority VC1.mkv" \
		"$download_root/movies/uploading-public/Shared Priority VC1 active.mkv"
	ln "$media_root/Public Cleanup.mkv" \
		"$download_root/movies/stopped-public/Public Cleanup.mkv"
	ln "$media_root/Shared Priority VC1.mkv" \
		"$download_root/movies/stopped-public/Shared Priority VC1 stopped.mkv"
	ln "$media_root/Active CZTeam.mkv" \
		"$download_root/movies/uploading-czteam/Active CZTeam.mkv"
	ln "$media_root/Dolby \"Private\", Feature.mkv" \
		"$download_root/movies/stopped-czteam/Dolby Private Feature.mkv"
	ln "$media_root/TrueHD Unmatched.mkv" \
		"$hidden_root/TrueHD Unmatched download-side remnant.mkv"
}

inode_for() {
	python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_ino)' "$1"
}

run_inventory_to_fixture() {
	run env \
		PYTHONPATH="$stub_python" \
		QBT_FIXTURE_DIR="$FIXTURES/qbittorrent" \
		QBT_USER='fixture-user' \
		QBT_PASS='fixture-pass' \
		BENCHMARK_TEST_MODE=1 \
		BENCHMARK_DOWNLOAD_ROOT="$download_root" \
		python3 "$INVENTORY"
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" >"$FIXTURES/qbittorrent/inodes.jsonl"
}

# Catches a production break where real fixture probing stops using the pinned
# ffprobe path or loses AVC/HDR10 classification and normalized video metadata.
@test "real media fixtures normalize AVC and HDR10 metadata" {
	run "$SCRIPTS/probe.sh" "$SOURCE_FIXTURES/media/avc-8bit.mkv"
	[ "$status" -eq 0 ]
	avc="$output"
	jq -e '
		.cohort == "avc" and
		.videoCodec == "h264" and
		.width == 1920 and .height == 1080 and
		.pixelFormat == "yuv420p" and .bitDepth == 8 and
		.container == "matroska" and .sizeBytes > 0
	' <<<"$avc"

	run "$SCRIPTS/probe.sh" "$SOURCE_FIXTURES/media/hdr10-hevc-10bit.mkv"
	[ "$status" -eq 0 ]
	hdr="$output"
	jq -e '
		.cohort == "hdr10" and
		.videoCodec == "hevc" and
		.width == 3840 and .height == 2160 and
		.pixelFormat == "yuv420p10le" and .bitDepth == 10 and
		.colorPrimaries == "bt2020" and
		.colorTransfer == "smpte2084" and
		.colorSpace == "bt2020nc" and
		.hdrFormat == "hdr10"
	' <<<"$hdr"
}

# Catches a production break where parser-only VC-1 or Dolby Vision Profile 7
# metadata is classified in the wrong precedence order.
@test "documented metadata fixtures classify VC-1 and Dolby Vision Profile 7" {
	create_ffprobe_stub
	export PATH="$stub_bin:$PATH"
	export FFPROBE_FIXTURE_DIR="$FIXTURES/ffprobe"

	run "$SCRIPTS/probe.sh" "$BATS_TEST_TMPDIR/VC1 Fixture.mkv"
	[ "$status" -eq 0 ]
	jq -e '.cohort == "vc1" and .videoCodec == "vc1" and .bitDepth == 8' <<<"$output"

	run "$SCRIPTS/probe.sh" "$BATS_TEST_TMPDIR/Dolby Fixture.mkv"
	[ "$status" -eq 0 ]
	jq -e '
		.cohort == "dolby-vision" and
		.dolbyVisionProfile == 7 and
		.hdrFormat == "dolby-vision"
	' <<<"$output"
}

# Catches a production break where Task 5's HDR validation receives no
# normalized mastering-display or max-CLL fields from the shared probe source.
@test "HDR static metadata is normalized for exact output validation" {
	create_ffprobe_stub
	export PATH="$stub_bin:$PATH"
	export FFPROBE_FIXTURE_DIR="$FIXTURES/ffprobe"

	run "$SCRIPTS/probe.sh" "$BATS_TEST_TMPDIR/HDRStatic Fixture.mkv"
	[ "$status" -eq 0 ]
	run jq -e '
		.masteringDisplay == {
			redX: 0.68, redY: 0.32, greenX: 0.265, greenY: 0.69,
			blueX: 0.15, blueY: 0.06, whitePointX: 0.3127,
			whitePointY: 0.329, minLuminance: 0.0001, maxLuminance: 1000
		} and
		.maxCLL == {maxContent: 1000, maxAverage: 400}
	' <<<"$output"
	[ "$status" -eq 0 ]
}

# Catches the diagnostic probes rounding HDR rationals, accepting a partial
# five-frame window, or publishing the input host path in normalized evidence.
@test "diagnostic probes emit bounded frame and exact dual-oracle metadata" {
	create_diagnostic_probe_stubs
	export PATH="$stub_bin:$PATH"
	media="$BATS_TEST_TMPDIR/Diagnostic Source.mkv"
	printf 'diagnostic probe bytes' >"$media"

	run "$SCRIPTS/probe.sh" diagnostic-identity "$media"
	[ "$status" -eq 0 ]
	identity="$output"
	run jq -e '
		keys == ["sha256","sizeBytes"] and
		(.sha256 | test("^[0-9a-f]{64}$")) and .sizeBytes == 22 and
		([.. | strings] | index($path) == null)
	' --arg path "$media" <<<"$identity"
	[ "$status" -eq 0 ]

	run "$SCRIPTS/probe.sh" diagnostic-window "$media" 0 90 40 44
	[ "$status" -eq 0 ]
	window="$output"
	run jq -e '
		.decodedFrameCount == 45 and
		.stream == {startTime:"0.000000",duration:"90.000000",timeBase:"1/1000",averageFrameRate:"24/1"} and
		(.frames | map(.frameIndex)) == [40,41,42,43,44] and
		all(.frames[];
			keys == ["bestEffortTimestamp","frameIndex","keyFrame","packetDuration","pictureType"] and
			(.bestEffortTimestamp | type == "string") and
			.packetDuration == "0.041667" and (.keyFrame | type == "boolean") and
			(.pictureType == "I" or .pictureType == "P")) and
		([.. | strings] | index($path) == null)
	' --arg path "$media" <<<"$window"
	[ "$status" -eq 0 ]

	for action in diagnostic-hdr-stream diagnostic-hdr-frame; do
		run "$SCRIPTS/probe.sh" "$action" "$media" 00:10:00.000 10
		[ "$status" -eq 0 ]
		run jq -e '
			.status == "ok" and
			.metadata.masteringDisplay.displayPrimaries.red.x == {numerator:34000,denominator:50000} and
			.metadata.masteringDisplay.luminance.max == {numerator:10000000,denominator:10000} and
			.metadata.maxCLL == {numerator:1000,denominator:1} and
			.metadata.maxFALL == {numerator:400,denominator:1}
		' <<<"$output"
		[ "$status" -eq 0 ]
	done

	run "$SCRIPTS/probe.sh" diagnostic-hdr-trace "$media" 00:10:00.000 10
	[ "$status" -eq 0 ]
	run jq -e '
		.status == "ok" and
		.metadata.masteringDisplay.displayPrimaries.green.x == {numerator:13250,denominator:50000} and
		.metadata.masteringDisplay.displayPrimaries.blue.y == {numerator:3000,denominator:50000} and
		.metadata.masteringDisplay.whitePoint.y == {numerator:16450,denominator:50000} and
		.metadata.maxFALL == {numerator:400,denominator:1}
	' <<<"$output"
	[ "$status" -eq 0 ]
}

# Catches a frame-field or HDR side-data parser treating a partial structure as
# admissible evidence instead of failing closed.
@test "diagnostic probes reject incomplete windows and partial HDR metadata" {
	create_diagnostic_probe_stubs
	export PATH="$stub_bin:$PATH"
	media="$BATS_TEST_TMPDIR/Diagnostic Source.mkv"
	printf 'diagnostic probe bytes' >"$media"
	for action in diagnostic-hdr-stream diagnostic-hdr-frame diagnostic-hdr-trace; do
		run "$SCRIPTS/probe.sh" "$action" "$media" 0 10.1
		[ "$status" -ne 0 ]
	done

	cat >"$stub_bin/ffprobe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *'frame=side_data_list'* ]]; then
	printf '%s\n' '{"frames":[{"side_data_list":[{"side_data_type":"Mastering display metadata","red_x":"34000/50000"}]}]}'
else
	printf '%s\n' '{"streams":[{"start_time":"0.000000","duration":"90.000000","time_base":"1/1000","avg_frame_rate":"24/1"}],"frames":[{"best_effort_timestamp_time":"0","pkt_duration_time":"0.041667","key_frame":1,"pict_type":"I"}]}'
fi
EOF
	chmod +x "$stub_bin/ffprobe"

	run "$SCRIPTS/probe.sh" diagnostic-window "$media" 0 90 40 44
	[ "$status" -ne 0 ]
	run "$SCRIPTS/probe.sh" diagnostic-hdr-frame "$media" 0 10
	[ "$status" -ne 0 ]

	export BENCHMARK_DIAGNOSTIC_TRACE_SCENARIO=conflicting-repeat
	run "$SCRIPTS/probe.sh" diagnostic-hdr-trace "$media" 00:10:00.000 10
	[ "$status" -ne 0 ]
	export BENCHMARK_DIAGNOSTIC_TRACE_SCENARIO=split-partial
	run "$SCRIPTS/probe.sh" diagnostic-hdr-trace "$media" 00:10:00.000 10
	[ "$status" -ne 0 ]
}

# Catches a frame-window parser that records fields but silently calls a gap or
# non-monotonic timestamp sequence clean.  The fixture is ffprobe-shaped and
# includes a packet-duration relationship that cannot be recovered by display
# rounding.
@test "diagnostic window accepts one-tick timestamp quantization and preserves discontinuity kinds" {
	create_diagnostic_probe_stubs
	export PATH="$stub_bin:$PATH"
	media="$BATS_TEST_TMPDIR/Diagnostic Source.mkv"
	printf 'diagnostic probe bytes' >"$media"
	fixture="$SOURCE_FIXTURES/ffprobe/diagnostic-window-quantized.json"
	cat >"$stub_bin/ffprobe" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec jq -c . "$fixture"
EOF
	chmod +x "$stub_bin/ffprobe"

	run "$SCRIPTS/probe.sh" diagnostic-window "$media" 0 90 40 44
	[ "$status" -eq 0 ]
	run jq -e '
		.sourceWindow == {status:"clean",issue:null} and
		(.frames | map(.frameIndex)) == [40,41,42,43,44]
	' <<<"$output"
	[ "$status" -eq 0 ]

	while IFS=$'\t' read -r expected_kind mutation; do
		fixture="$BATS_TEST_TMPDIR/mutated-window-$expected_kind.json"
		jq "$mutation" "$SOURCE_FIXTURES/ffprobe/diagnostic-window-quantized.json" >"$fixture"
		cat >"$stub_bin/ffprobe" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec jq -c . "$fixture"
EOF
		chmod +x "$stub_bin/ffprobe"
		run "$SCRIPTS/probe.sh" diagnostic-window "$media" 0 90 40 44
		[ "$status" -eq 0 ]
		run jq -e --arg kind "$expected_kind" '
			.sourceWindow.status == "discontinuity" and
			.sourceWindow.issue.afterFrameIndex == 40 and
			.sourceWindow.issue.kind == $kind
		' <<<"$output"
		[ "$status" -eq 0 ]
	done <<'EOF'
repeat	.frames[41].best_effort_timestamp_time = .frames[40].best_effort_timestamp_time
non-monotonic-timestamp	.frames[41].best_effort_timestamp_time = "1.659"
inconsistent-duration	.frames[40].pkt_duration_time = "0"
repeat	.frames[40].pkt_duration_time = "0" | .frames[41].best_effort_timestamp_time = .frames[40].best_effort_timestamp_time
non-monotonic-timestamp	.frames[40].pkt_duration_time = "0" | .frames[41].best_effort_timestamp_time = "1.659"
EOF

	fixture="$SOURCE_FIXTURES/ffprobe/diagnostic-window-discontinuity.json"
	cat >"$stub_bin/ffprobe" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec jq -c . "$fixture"
EOF
	chmod +x "$stub_bin/ffprobe"
	run "$SCRIPTS/probe.sh" diagnostic-window "$media" 0 90 40 44
	[ "$status" -eq 0 ]
	run jq -e '
		.sourceWindow.status == "discontinuity" and
		.sourceWindow.issue == {kind:"gap",afterFrameIndex:41}
	' <<<"$output"
	[ "$status" -eq 0 ]
}

# Catches a production break where aggregate container bitrate is allocated to
# audio tracks or reported/Matroska-estimated bytes lose their provenance.
@test "audio bytes preserve reported estimated and unknown provenance" {
	create_ffprobe_stub
	export PATH="$stub_bin:$PATH"
	export FFPROBE_FIXTURE_DIR="$FIXTURES/ffprobe"

	run "$SCRIPTS/probe.sh" "$BATS_TEST_TMPDIR/Public Cleanup.mkv"
	[ "$status" -eq 0 ]
	jq -e '
		.audioTrackCount == 2 and
		.audioTracks[0] == {
			index: 1, codec: "ac3", channels: 6, channelLayout: "5.1(side)",
			language: "eng", bitRate: 640000, durationSeconds: 100,
			audioBytes: 8000000, audioBytesMethod: "reported"
		} and
		.audioTracks[1] == {
			index: 2, codec: "aac", channels: 2, channelLayout: "stereo",
			language: "jpn", bitRate: 192000, durationSeconds: 100,
			audioBytes: 2400000, audioBytesMethod: "estimated"
		}
	' <<<"$output"

	run "$SCRIPTS/probe.sh" "$BATS_TEST_TMPDIR/TrueHD Fixture.mkv"
	[ "$status" -eq 0 ]
	jq -e '
		.audioTracks[0].codec == "truehd" and
		.audioTracks[0].bitRate == null and
		.audioTracks[0].audioBytes == null and
		.audioTracks[0].audioBytesMethod == "unknown"
	' <<<"$output"
}

# Catches a production break where the read-only qBittorrent bridge leaks API
# details, ignores lifecycle precedence, or does not stat actual hardlinks.
@test "torrent inventory emits redacted lifecycle JSON Lines with inode precedence" {
	prepare_library
	create_qbittorrent_stub
	run_inventory_to_fixture

	[[ "$output" != *'fixture-user'* ]]
	[[ "$output" != *'fixture-pass'* ]]
	[[ "$output" != *'announce'* ]]
	[[ "$output" != *'fixture-public-secret'* ]]

	expected="$BATS_TEST_TMPDIR/expected-inodes.jsonl"
	{
		emit_inventory_record "$(inode_for "$media_root/Active Public.mkv")" \
			active 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' movies tracker-public
		emit_inventory_record "$(inode_for "$media_root/Shared Priority VC1.mkv")" \
			active 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' movies tracker-public
		emit_inventory_record "$(inode_for "$media_root/Public Cleanup.mkv")" \
			public-awaiting-cleanup 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' movies tracker-public
		emit_inventory_record "$(inode_for "$media_root/Active CZTeam.mkv")" \
			active 'cccccccccccccccccccccccccccccccccccccccc' movies tracker-czteam,tracker-private
		emit_inventory_record "$(inode_for "$media_root/Dolby \"Private\", Feature.mkv")" \
			private-permanent 'dddddddddddddddddddddddddddddddddddddddd' movies tracker-czteam,tracker-private
	} | sort -n >"$expected"

	run diff -u "$expected" "$FIXTURES/qbittorrent/inodes.jsonl"
	[ "$status" -eq 0 ]
}

# Catches a production break where a test-only download root can alter the
# fixed production /data/downloads boundary.
@test "torrent inventory refuses download-root override outside test mode" {
	run env \
		QBT_USER='fixture-user' \
		QBT_PASS='fixture-pass' \
		BENCHMARK_DOWNLOAD_ROOT="$BATS_TEST_TMPDIR/not-production" \
		python3 "$INVENTORY"
	[ "$status" -eq 64 ]
	[[ "$output" == *'BENCHMARK_DOWNLOAD_ROOT requires BENCHMARK_TEST_MODE=1'* ]]
}

# Catches a production break where a dependency exception can reflect injected
# credentials or an announce URL into logs.
@test "torrent inventory redacts dependency failure details" {
	create_qbittorrent_stub
	run env \
		PYTHONPATH="$stub_python" \
		QBT_FIXTURE_DIR="$FIXTURES/qbittorrent" \
		QBT_STUB_AUTH_ERROR=1 \
		QBT_USER='fixture-user' \
		QBT_PASS='fixture-pass' \
		BENCHMARK_TEST_MODE=1 \
		BENCHMARK_DOWNLOAD_ROOT="$BATS_TEST_TMPDIR/downloads" \
		python3 "$INVENTORY"
	[ "$status" -ne 0 ]
	[[ "$output" == *'qBittorrent inventory failed: RuntimeError'* ]]
	[[ "$output" != *'fixture-user'* ]]
	[[ "$output" != *'fixture-pass'* ]]
	[[ "$output" != *'announce'* ]]
	[[ "$output" != *'fixture-secret'* ]]
}

# Catches a production break where BENCHMARK_MEDIA_ROOT can redirect a live
# census outside the fixed /media mount without explicit test mode.
@test "census refuses media-root override outside test mode" {
	torrent_state="$BATS_TEST_TMPDIR/empty-inodes.jsonl"
	printf 'inode\tlifecycle_state\ttorrent_hash\tcategory\ttags\n' >"$torrent_state"
	run env \
		BENCHMARK_MEDIA_ROOT="$SOURCE_FIXTURES/media" \
		"$SCRIPTS/census.sh" "$torrent_state" "$BATS_TEST_TMPDIR/output"
	[ "$status" -eq 64 ]
	[[ "$output" == *'BENCHMARK_MEDIA_ROOT requires BENCHMARK_TEST_MODE=1'* ]]
}

# Catches production breaks in CSV escaping, lifecycle fail-safety, bytewise
# source sorting, normalized metadata, and per-track audio inventory.
@test "census emits exact golden lifecycle and audio CSVs" {
	prepare_library
	create_qbittorrent_stub
	run_inventory_to_fixture
	create_ffprobe_stub
	export PATH="$stub_bin:$PATH"
	export FFPROBE_FIXTURE_DIR="$FIXTURES/ffprobe"
	export BENCHMARK_TEST_MODE=1
	export BENCHMARK_MEDIA_ROOT="$media_root"
	output_dir="$BATS_TEST_TMPDIR/output"

	run "$SCRIPTS/census.sh" "$FIXTURES/qbittorrent/inodes.jsonl" "$output_dir"
	[ "$status" -eq 0 ]
	run diff -u "$GOLDEN/census.csv" "$output_dir/census.csv"
	[ "$status" -eq 0 ]
	run diff -u "$GOLDEN/audio-inventory.csv" "$output_dir/audio-inventory.csv"
	[ "$status" -eq 0 ]
}

# Catches a production break where a failed media walk replaces either prior
# census artifact or leaves a partial temporary output behind.
@test "census publishes neither output when probing fails" {
	prepare_library
	create_qbittorrent_stub
	run_inventory_to_fixture
	create_ffprobe_stub
	export PATH="$stub_bin:$PATH"
	export FFPROBE_FIXTURE_DIR="$FIXTURES/ffprobe"
	export FFPROBE_FAIL_PATTERN='Public Cleanup'
	export BENCHMARK_TEST_MODE=1
	export BENCHMARK_MEDIA_ROOT="$media_root"
	output_dir="$BATS_TEST_TMPDIR/output"
	mkdir -p "$output_dir"
	printf 'previous census\n' >"$output_dir/census.csv"
	printf 'previous audio\n' >"$output_dir/audio-inventory.csv"

	run "$SCRIPTS/census.sh" "$FIXTURES/qbittorrent/inodes.jsonl" "$output_dir"
	[ "$status" -ne 0 ]
	[ "$(<"$output_dir/census.csv")" = 'previous census' ]
	[ "$(<"$output_dir/audio-inventory.csv")" = 'previous audio' ]
	run find "$output_dir" -type f -name '.encode-benchmark-census.*' -print
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

# Catches a production break where a symlink escapes the allowed media root or
# a failed path walk is ignored before atomic publication.
@test "census rejects path escapes without replacing prior outputs" {
	prepare_library
	create_qbittorrent_stub
	run_inventory_to_fixture
	create_ffprobe_stub
	export PATH="$stub_bin:$PATH"
	export FFPROBE_FIXTURE_DIR="$FIXTURES/ffprobe"
	export BENCHMARK_TEST_MODE=1
	export BENCHMARK_MEDIA_ROOT="$media_root"
	outside_file="$BATS_TEST_TMPDIR/outside-media.mkv"
	printf 'outside' >"$outside_file"
	ln -s "$outside_file" "$media_root/Escaped Source.mkv"
	output_dir="$BATS_TEST_TMPDIR/output"
	mkdir -p "$output_dir"
	printf 'previous census\n' >"$output_dir/census.csv"
	printf 'previous audio\n' >"$output_dir/audio-inventory.csv"

	run "$SCRIPTS/census.sh" "$FIXTURES/qbittorrent/inodes.jsonl" "$output_dir"
	[ "$status" -ne 0 ]
	[[ "$output" == *'source path escapes media root'* ]]
	[ "$(<"$output_dir/census.csv")" = 'previous census' ]
	[ "$(<"$output_dir/audio-inventory.csv")" = 'previous audio' ]
}

# Catches a production break where os.walk suppresses a directory scan error,
# allowing an incomplete path inventory to be published as a successful census.
@test "census rejects directory-walk errors without replacing prior outputs" {
	prepare_library
	create_qbittorrent_stub
	run_inventory_to_fixture
	create_ffprobe_stub
	export PATH="$stub_bin:$PATH"
	export FFPROBE_FIXTURE_DIR="$FIXTURES/ffprobe"
	export BENCHMARK_TEST_MODE=1
	export BENCHMARK_MEDIA_ROOT="$media_root"
	walk_failure="$media_root/Unreadable Subtree"
	mkdir -p "$walk_failure"
	printf 'unseen' >"$walk_failure/Hidden Film.mkv"
	export BENCHMARK_TEST_WALK_ERROR_PATH="$walk_failure"
	output_dir="$BATS_TEST_TMPDIR/output"
	mkdir -p "$output_dir"
	printf 'previous census\n' >"$output_dir/census.csv"
	printf 'previous audio\n' >"$output_dir/audio-inventory.csv"

	run "$SCRIPTS/census.sh" "$FIXTURES/qbittorrent/inodes.jsonl" "$output_dir"
	[ "$status" -ne 0 ]
	[[ "$output" == *'media walk failed'* ]]
	[ "$(<"$output_dir/census.csv")" = 'previous census' ]
	[ "$(<"$output_dir/audio-inventory.csv")" = 'previous audio' ]
}

# Catches a production break where the checked NUL-separated path inventory is
# not removed after both outputs publish successfully.
@test "successful census leaves no temporary path inventory" {
	prepare_library
	create_qbittorrent_stub
	run_inventory_to_fixture
	create_ffprobe_stub
	export PATH="$stub_bin:$PATH"
	export FFPROBE_FIXTURE_DIR="$FIXTURES/ffprobe"
	export BENCHMARK_TEST_MODE=1
	export BENCHMARK_MEDIA_ROOT="$media_root"
	output_dir="$BATS_TEST_TMPDIR/output"

	run "$SCRIPTS/census.sh" "$FIXTURES/qbittorrent/inodes.jsonl" "$output_dir"
	[ "$status" -eq 0 ]
	run find "$output_dir" -type f -name '.encode-benchmark-census.*' -print
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

# Catches a production break where the first new CSV remains visible after a
# handled failure publishing the second CSV.
@test "second publication failure restores both prior outputs" {
	prepare_library
	create_qbittorrent_stub
	run_inventory_to_fixture
	create_ffprobe_stub
	export PATH="$stub_bin:$PATH"
	export FFPROBE_FIXTURE_DIR="$FIXTURES/ffprobe"
	export BENCHMARK_TEST_MODE=1
	export BENCHMARK_MEDIA_ROOT="$media_root"
	export BENCHMARK_TEST_FAIL_SECOND_PUBLISH=1
	output_dir="$BATS_TEST_TMPDIR/output"
	mkdir -p "$output_dir"
	printf 'previous census\n' >"$output_dir/census.csv"
	printf 'previous audio\n' >"$output_dir/audio-inventory.csv"

	run "$SCRIPTS/census.sh" "$FIXTURES/qbittorrent/inodes.jsonl" "$output_dir"
	[ "$status" -ne 0 ]
	[[ "$output" == *'second census publication failed; restored prior outputs'* ]]
	[ "$(<"$output_dir/census.csv")" = 'previous census' ]
	[ "$(<"$output_dir/audio-inventory.csv")" = 'previous audio' ]
	run find "$output_dir" -type f -name '.encode-benchmark-census.*' -print
	[ "$status" -eq 0 ]
	[ -z "$output" ]

	output_dir="$BATS_TEST_TMPDIR/output-without-prior-generation"
	run "$SCRIPTS/census.sh" "$FIXTURES/qbittorrent/inodes.jsonl" "$output_dir"
	[ "$status" -ne 0 ]
	[ ! -e "$output_dir/census.csv" ]
	[ ! -e "$output_dir/audio-inventory.csv" ]
}

# Catches a production break where the Excel-tab producer is decoded by raw tab
# splitting rather than as a five-column quoted record stream.
@test "torrent inventory round-trips quote tab and newline tag data into census CSV" {
	prepare_library
	create_qbittorrent_stub
	export QBT_STUB_TAGS=$'quote"two,alpha\tone,line\nthree'
	run_inventory_to_fixture
	expected_tags=$'alpha\tone,line\nthree,quote"two'

	# jq, not python3: this asserts the exact parser the runtime image will use.
	run jq -e -s --arg expected "$expected_tags" '
		if any(.[]; (keys | length) != 5)
			then error("inventory record did not contain exactly five fields")
			else . end
		| map(select(.torrent_hash == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
		| if length == 0
			then error("no inventory record matched the fixture hash")
			else . end
		| all(.[]; .tags == $expected)
	' "$FIXTURES/qbittorrent/inodes.jsonl"
	[ "$status" -eq 0 ]

	create_ffprobe_stub
	export PATH="$stub_bin:$PATH"
	export FFPROBE_FIXTURE_DIR="$FIXTURES/ffprobe"
	export BENCHMARK_TEST_MODE=1
	export BENCHMARK_MEDIA_ROOT="$media_root"
	output_dir="$BATS_TEST_TMPDIR/output"
	run "$SCRIPTS/census.sh" "$FIXTURES/qbittorrent/inodes.jsonl" "$output_dir"
	[ "$status" -eq 0 ]
	run python3 -c '
import csv
import json
import sys

with open(sys.argv[1], newline="", encoding="utf-8") as stream:
    rows = csv.DictReader(stream)
    row = next(item for item in rows if item["source_path"] == "/media/Active Public.mkv")
print(json.dumps(row["torrent_tags"]))
' "$output_dir/census.csv"
	[ "$status" -eq 0 ]
	run jq -e --arg expected "$expected_tags" '. == $expected' <<<"$output"
	[ "$status" -eq 0 ]
}

# Catches a production break where any of the six tested commands regresses to
# a scaffold mapping after the encode and still-generation contracts land.
@test "ConfigMap maps all tested scripts to real implementations" {
	kustomization="$SCRIPTS/../kustomization.yaml"
	run yq -r '.configMapGenerator[0].files | join(",")' "$kustomization"
	[ "$status" -eq 0 ]
	[ "$output" = 'contract.sh=scripts/contract.sh,diagnostic-contract.jq=scripts/diagnostic-contract.jq,probe.sh=scripts/probe.sh,census.sh=scripts/census.sh,runmeta.sh=scripts/runmeta.sh,benchmark.sh=scripts/benchmark.sh,diagnostic-evidence.sh=scripts/diagnostic-evidence.sh,stills.sh=scripts/stills.sh' ]
	[ ! -e "$SCRIPTS/not-ready.sh" ]
}

# Catches a runtime script depending on a command the runtime image does not
# provide. The live census Job failed on an undeclared python3 while this suite
# stayed green, because CI runs the scripts against the full host PATH.
@test "census runs against only the declared runtime commands" {
	load helpers/runtime-sandbox
	prepare_library
	create_qbittorrent_stub
	run_inventory_to_fixture
	create_ffprobe_stub
	export FFPROBE_FIXTURE_DIR="$FIXTURES/ffprobe"
	export BENCHMARK_TEST_MODE=1
	export BENCHMARK_MEDIA_ROOT="$media_root"
	output_dir="$BATS_TEST_TMPDIR/output"
	samples="$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/samples.yaml"

	# python3, rg and yq are confirmed absent from the runtime image, so the
	# census path must run without them even though benchmark.sh still declares
	# them. Withholding them here is what proves the census can actually run.
	run runtime_sandbox_path "$samples" "$BATS_TEST_TMPDIR/sandbox" python3 rg yq
	[ "$status" -eq 0 ]
	sandbox="$output"

	run env PATH="$stub_bin:$sandbox" \
		"$SCRIPTS/census.sh" "$FIXTURES/qbittorrent/inodes.jsonl" "$output_dir"
	[ "$status" -eq 0 ]
	run diff -u "$GOLDEN/census.csv" "$output_dir/census.csv"
	[ "$status" -eq 0 ]
}

# Catches the census reverting to aborting on the first unreadable title. One
# 19GB source that ffprobe cannot open blocked the entire live inventory, and
# each retry cost a dispatch cycle to discover the next bad file.
@test "an isolated probe failure is recorded as a row and the census completes" {
	prepare_library
	create_qbittorrent_stub
	run_inventory_to_fixture
	create_ffprobe_stub
	# Dilute below the 5% abort threshold: 1 failure in 32 sources is a bad
	# title, 1 in 7 is the signal of a broken mount the threshold must still catch.
	for index in $(seq 1 25); do
		printf 'padding' >"$media_root/Padding $index.mkv"
	done
	export PATH="$stub_bin:$PATH"
	export FFPROBE_FIXTURE_DIR="$FIXTURES/ffprobe"
	export FFPROBE_FAIL_PATTERN='Unlinked AVC'
	export BENCHMARK_TEST_MODE=1
	export BENCHMARK_MEDIA_ROOT="$media_root"
	output_dir="$BATS_TEST_TMPDIR/output"

	run "$SCRIPTS/census.sh" "$FIXTURES/qbittorrent/inodes.jsonl" "$output_dir"
	[ "$status" -eq 0 ]

	# The unreadable title is present, marked, and carries its reason.
	run jq -R -r -s '
		split("\n") | map(select(length > 0)) | .[1:]
		| map(select(test("Unlinked AVC")))
	' "$output_dir/census.csv"
	[ "$status" -eq 0 ]
	[[ "$output" == *'probe-failed'* ]]
	[[ "$output" == *'fixture ffprobe failure'* ]]

	# Every other source still probed normally, so a failure row cannot be
	# mistaken for a degraded census.
	run grep -c 'probe-failed' "$output_dir/census.csv"
	[ "$output" -eq 1 ]
	run grep -c '"probed"' "$output_dir/census.csv"
	[ "$output" -eq 31 ]
}
