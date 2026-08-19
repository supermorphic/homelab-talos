#!/usr/bin/env bats

setup() {
	SCRIPTS="$BATS_TEST_DIRNAME/../app/scripts"
	export BENCHMARK_TEST_MODE=1
	export BENCHMARK_NOW=20260802T120000Z
	export BENCHMARK_OUT="$BATS_TEST_TMPDIR/out"
	export BENCHMARK_IDENTITY_FIXTURE="$BATS_TEST_DIRNAME/fixtures/manifests/identity.json"
	export BENCHMARK_SAMPLES_FILE="$BATS_TEST_TMPDIR/samples.json"
	yq -r '.data."samples.json"' "$BATS_TEST_DIRNAME/../app/samples.yaml" >"$BENCHMARK_SAMPLES_FILE"
	export BENCHMARK_DISPATCH_IMAGE='docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	export BENCHMARK_RUNNING_IMAGE='sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	export BENCHMARK_I915_VERSION='fixture-i915'
	export BENCHMARK_VPL_VERSION='fixture-vpl'
	mkdir -p "$BENCHMARK_OUT/runs"
}

run_directory_count() {
	find "$BENCHMARK_OUT/runs" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
}

file_mode() {
	python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$1"
}

results_header() {
	printf '%s\n' 'run_id,panel,sample_id,cohort,source_sha256,clip_id,encoder,requested_setting,selected_rate_control,status,attempt,input_bytes,output_bytes,reduction_percent,input_bit_rate,output_bit_rate,wall_seconds,encode_fps,encode_speed,vmaf_harmonic_mean,vmaf_1pct_low,ssim,gpu_busy_percent,qsv_proof,validation_codec,validation_duration,validation_resolution,validation_frame_rate,validation_bit_depth,validation_hdr,validation_audio_tracks,validation_subtitle_tracks,validation_chapters,validation_failures,log_path,output_disposition,strategy_id,qsv_initialization,video_busy_nanoseconds'
}

results_row() {
	local run_id="$1" encoder="${2:-qsv}" strategy="${3:-qsv-hevc-icq-v1}"
	local initialization="${4:-passed}" busy="${5:-800000000}"
	local selected='ICQ'
	if [[ "$encoder" == 'x265' ]]; then
		selected='CRF'
		initialization='not-applicable'
		busy='0'
	fi
	printf '%s\n' "$run_id,quality,sample-avc,avc,abc123,detail,$encoder,22,$selected,passed,1,100,50,50,1000,500,10,30,1.0,95,90,0.99,80,passed,hevc,10,1920x1080,24,10,hdr10,1,2,3,none,logs/a.log,discarded,$strategy,$initialization,$busy"
}

rewrite_samples_to_test_media() {
	local file="$1"
	local avc_fixture hdr_fixture avc_size hdr_size avc_sha hdr_sha
	avc_fixture="$BATS_TEST_DIRNAME/fixtures/media/avc-8bit.mkv"
	hdr_fixture="$BATS_TEST_DIRNAME/fixtures/media/hdr10-hevc-10bit.mkv"
	avc_size="$(wc -c <"$avc_fixture" | tr -d '[:space:]')"
	hdr_size="$(wc -c <"$hdr_fixture" | tr -d '[:space:]')"
	avc_sha="$(sha256sum "$avc_fixture" | awk 'NR == 1 { print $1 }')"
	hdr_sha="$(sha256sum "$hdr_fixture" | awk 'NR == 1 { print $1 }')"

	jq \
		--arg avc_path "$avc_fixture" \
		--arg hdr_path "$hdr_fixture" \
		--arg avc_sha "$avc_sha" \
		--arg hdr_sha "$hdr_sha" \
		--argjson avc_size "$avc_size" \
		--argjson hdr_size "$hdr_size" '
		.qualityPanel |= map(
			if .cohort == "avc" or .cohort == "vc1" then
				.path = $avc_path | .sizeBytes = $avc_size | .sha256 = $avc_sha
			else
				.path = $hdr_path | .sizeBytes = $hdr_size | .sha256 = $hdr_sha
			end
		) |
		.savingsPanel |= map(
			if .cohort == "avc" or .cohort == "vc1" then
				.path = $avc_path | .sizeBytes = $avc_size | .sha256 = $avc_sha
			else
				.path = $hdr_path | .sizeBytes = $hdr_size | .sha256 = $hdr_sha
			end
		)
	' "$file" >"$file.tmp"
	mv -f -- "$file.tmp" "$file"
}

prepare_configmap_script_mount() {
	configmap_root="$BATS_TEST_TMPDIR/scripts"
	configmap_data="$configmap_root/..2026_08_02_12_00_00.000000000"
	mkdir -p "$configmap_data"
	cp "$SCRIPTS/contract.sh" "$configmap_data/contract.sh"
	cp "$SCRIPTS/runmeta.sh" "$configmap_data/runmeta.sh"
	printf '%s\n' '#!/usr/bin/env bash' 'exit 64' >"$configmap_data/benchmark.sh"
	chmod +x "$configmap_data/contract.sh" "$configmap_data/runmeta.sh" "$configmap_data/benchmark.sh"
	ln -s "${configmap_data##*/}" "$configmap_root/..data"
	ln -s '..data/contract.sh' "$configmap_root/contract.sh"
	ln -s '..data/runmeta.sh' "$configmap_root/runmeta.sh"
	ln -s '..data/benchmark.sh' "$configmap_root/benchmark.sh"

	samples_file="$BATS_TEST_TMPDIR/samples.json"
	yq -r '.data."samples.json"' "$BATS_TEST_DIRNAME/../app/samples.yaml" >"$samples_file"
	rewrite_samples_to_test_media "$samples_file"
	unset BENCHMARK_IDENTITY_FIXTURE
	export BENCHMARK_SAMPLES_FILE="$samples_file"
	export BENCHMARK_DISPATCH_IMAGE='docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	export BENCHMARK_RUNNING_IMAGE='sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	export BENCHMARK_I915_VERSION='fixture-i915'
	export BENCHMARK_VPL_VERSION='fixture-vpl'
}

prepare_diagnostic_samples() {
	unset BENCHMARK_IDENTITY_FIXTURE
	diagnostic_media="$BATS_TEST_TMPDIR/diagnostic-media"
	mkdir -p "$diagnostic_media"
	avc_fixture="$BATS_TEST_DIRNAME/fixtures/media/avc-8bit.mkv"
	hdr_fixture="$BATS_TEST_DIRNAME/fixtures/media/hdr10-hevc-10bit.mkv"
	avc_size="$(wc -c <"$avc_fixture" | tr -d '[:space:]')"
	hdr_size="$(wc -c <"$hdr_fixture" | tr -d '[:space:]')"
	avc_sha="$(sha256sum "$avc_fixture" | awk 'NR == 1 { print $1 }')"
	hdr_sha="$(sha256sum "$hdr_fixture" | awk 'NR == 1 { print $1 }')"

	coco="$diagnostic_media/Coco (2017).mkv"
	memento="$diagnostic_media/Memento (2000).mkv"
	fugitive="$diagnostic_media/Fugitive (1993).mkv"
	ministry="$diagnostic_media/Ministry Of Ungentlemanly Warfare (2024).mkv"
	goodfellas="$diagnostic_media/Goodfellas (1990).mkv"
	john_wick="$diagnostic_media/John Wick Chapter 2 (2017).mkv"
	cp "$avc_fixture" "$coco"
	cp "$avc_fixture" "$memento"
	cp "$avc_fixture" "$fugitive"
	cp "$hdr_fixture" "$ministry"
	cp "$hdr_fixture" "$goodfellas"
	cp "$hdr_fixture" "$john_wick"

	jq \
		--arg coco "$coco" \
		--arg memento "$memento" \
		--arg fugitive "$fugitive" \
		--arg ministry "$ministry" \
		--arg goodfellas "$goodfellas" \
		--arg john_wick "$john_wick" \
		--arg avc_sha "$avc_sha" \
		--arg hdr_sha "$hdr_sha" \
		--argjson avc_size "$avc_size" \
		--argjson hdr_size "$hdr_size" '
		.qualityPanel |= map(
			if .id == "avc-clean-coco" then
				.path = $coco | .sizeBytes = $avc_size | .sha256 = $avc_sha
			elif .id == "avc-grain-memento" then
				.path = $memento | .sizeBytes = $avc_size | .sha256 = $avc_sha
			elif .id == "vc1-fugitive" then
				.path = $fugitive | .sizeBytes = $avc_size | .sha256 = $avc_sha
			elif .id == "hdr10-clean-ministry" then
				.path = $ministry | .sizeBytes = $hdr_size | .sha256 = $hdr_sha
			elif .id == "hdr10-grain-goodfellas" then
				.path = $goodfellas | .sizeBytes = $hdr_size | .sha256 = $hdr_sha
			elif .id == "hdr10-motion-john-wick-2" then
				.path = $john_wick | .sizeBytes = $hdr_size | .sha256 = $hdr_sha
			else
				.
			end
		)
	' "$BENCHMARK_SAMPLES_FILE" >"$BENCHMARK_SAMPLES_FILE.tmp"
	mv -f -- "$BENCHMARK_SAMPLES_FILE.tmp" "$BENCHMARK_SAMPLES_FILE"

	export BENCHMARK_ENCODER_COMMANDS_JSON='[
		"ffmpeg -nostdin -ss <clip-start> -i <source> -t 90 -map 0:v:0 -c copy <clip>",
		"ffmpeg -nostdin -init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw -i <clip> -map 0 -c:v hevc_qsv -preset veryslow -global_quality <setting> -look_ahead 0 -extbrc 0 -c:a copy -c:s copy -map_metadata 0 -map_chapters 0 <output>",
		"ffmpeg -nostdin -i <source-clip> -i <encoded-output> -lavfi libvmaf=log_fmt=json:log_path=<window>.json -f null -",
		"ffmpeg -nostdin -i <source-clip> -i <encoded-output> -filter_complex [0:v]setpts=PTS-STARTPTS[source];[1:v]setpts=PTS-STARTPTS[encoded];[source][encoded]libvmaf=log_fmt=json:log_path=<window-reset>.json -f null -",
		"ffmpeg -nostdin -i <source-clip> -i <encoded-output> -lavfi ssim;[0:v][1:v]psnr -f null -",
		"ffprobe -show_frames -select_streams v -read_intervals <window> -show_entries frame=best_effort_timestamp_time,pkt_duration_time,key_frame,pict_type <media>",
		"ffprobe -show_streams -show_frames -show_packets -show_entries stream_side_data,pkt_pts_time,pkt_dts_time <media>",
		"ffmpeg -nostdin -i <media> -c copy -bsf:v trace_headers -f null -"
	]'
}

diagnostic_expected_sources() {
	jq -S -c '
		[
			.qualityPanel[] |
			select(.id == "avc-clean-coco" or .id == "avc-grain-memento" or
				.id == "vc1-fugitive" or .id == "hdr10-clean-ministry" or
				.id == "hdr10-grain-goodfellas" or .id == "hdr10-motion-john-wick-2") |
			{path, size: .sizeBytes, sha256: ("sha256:" + .sha256)}
		] | sort_by(.path)
	' "$BENCHMARK_SAMPLES_FILE"
}

diagnostic_expected_panel_sha() {
	local payload
	payload="$(jq -S -c '
		.diagnostics |
		{vmafPanel, hdrPanel, vmafSettings, hdrSetting, frameRadius, frameOffsets, traceWindowSeconds}
	' "$BENCHMARK_SAMPLES_FILE")"
	printf 'sha256:%s\n' "$(printf '%s' "$payload" | sha256sum | awk 'NR == 1 { print $1 }')"
}

# Catches a production break where a bare create discovers and reuses an older
# identity instead of making the timestamped run an operator-held handle.
@test "no run id always creates a fresh timestamped immutable identity" {
	run "$SCRIPTS/runmeta.sh" create quality
	[ "$status" -eq 0 ]
	[ "$output" = '20260802T120000Z-6cdfc9f3' ]
	first="$output"
	first_manifest="$BENCHMARK_OUT/runs/$first/manifest.json"
	expected="$BATS_TEST_TMPDIR/expected-manifest.json"
	printf '%s\n' '{"clientDevice":null,"cpu":null,"createdAt":"20260802T120000Z","encoderCommands":[],"gpu":{"i915":"fixture-i915","vpl":"fixture-vpl"},"images":{"configured":"sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb","dispatched":"sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb","running":"sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb"},"mode":"quality","node":{"kernel":"","name":""},"resultsSchemaVersion":2,"samplesDigest":"sha256:9f4e2b20cfb4eaf89f18ba1a3f706d384c450f65a150df41d4e5d50b957f829e","savingsSeed":20260802,"schemaVersion":2,"scriptDigests":{},"selectedSettings":[],"sources":[],"strategyId":"qsv-hevc-icq-v1","upstream":{},"vmaf":{"model":"vmaf_4k_v0.6.1","version":""}}' >"$expected"
	cmp -s "$expected" "$first_manifest"
	[ "$(file_mode "$first_manifest")" = '444' ]
	[ ! -e "$BENCHMARK_OUT/runs/$first/manifest.json.tmp" ]

	export BENCHMARK_NOW=20260802T120001Z
	run "$SCRIPTS/runmeta.sh" create quality
	[ "$status" -eq 0 ]
	[ "$output" = '20260802T120001Z-6cdfc9f3' ]
	[ "$output" != "$first" ]
	[ "$(run_directory_count)" -eq 2 ]
}

# Catches the dispatcher-owned run handle being treated as resume-only. The
# first exact handle must atomically publish its manifest, and the second call
# must verify/resume without changing a byte.
@test "first explicit run id creates immutable identity and exact repeat resumes" {
	run_id='20260802T121500Z-deadbeef'
	run "$SCRIPTS/runmeta.sh" create quality "$run_id"
	[ "$status" -eq 0 ]
	[ "$output" = "$run_id" ]
	manifest="$BENCHMARK_OUT/runs/$run_id/manifest.json"
	[ -f "$manifest" ]
	[ "$(jq -r '.createdAt' "$manifest")" = '20260802T121500Z' ]
	[ "$(file_mode "$manifest")" = '444' ]
	before="$BATS_TEST_TMPDIR/explicit-manifest-before"
	cp "$manifest" "$before"

	run "$SCRIPTS/runmeta.sh" create quality "$run_id"
	[ "$status" -eq 0 ]
	[ "$output" = "$run_id" ]
	cmp -s "$before" "$manifest"
	[ "$(run_directory_count)" -eq 1 ]
}

# Catches an explicit creator claiming or removing a pre-existing directory it
# did not create, or overwriting an immutable manifest after identity drift.
@test "explicit create preserves collision ownership and refuses identity mismatch" {
	collision_id='20260802T121500Z-cafef00d'
	collision="$BENCHMARK_OUT/runs/$collision_id"
	mkdir "$collision"
	run "$SCRIPTS/runmeta.sh" create quality "$collision_id"
	[ "$status" -eq 73 ]
	[ "$output" = "run already exists without a manifest: $collision_id" ]
	[ -d "$collision" ]
	[ ! -e "$collision/manifest.json" ]

	run_id='20260802T121500Z-deadbeef'
	run "$SCRIPTS/runmeta.sh" create quality "$run_id"
	[ "$status" -eq 0 ]
	manifest="$BENCHMARK_OUT/runs/$run_id/manifest.json"
	before="$BATS_TEST_TMPDIR/mismatch-before"
	cp "$manifest" "$before"
	changed_identity="$BATS_TEST_TMPDIR/changed-identity.json"
	jq '.node.name = "different-node"' "$BENCHMARK_IDENTITY_FIXTURE" >"$changed_identity"
	export BENCHMARK_IDENTITY_FIXTURE="$changed_identity"
	run "$SCRIPTS/runmeta.sh" create quality "$run_id"
	[ "$status" -eq 1 ]
	[[ "$output" == *'identity mismatch: node.name'* ]]
	cmp -s "$before" "$manifest"
}

# Catches a run identity accepting a wrong schema or strategy as a fresh
# manifest, where it would later be indistinguishable from trusted ICQ work.
@test "create rejects a non-contract manifest schema results schema or strategy" {
	for mutation in \
		'.schemaVersion = 1' \
		'.resultsSchemaVersion = 1' \
		'.strategyId = "qsv-hevc-la-icq-v1"'; do
		changed="$BATS_TEST_TMPDIR/non-contract-identity.json"
		jq "$mutation" "$BATS_TEST_DIRNAME/fixtures/manifests/identity.json" >"$changed"
		export BENCHMARK_IDENTITY_FIXTURE="$changed"
		run "$SCRIPTS/runmeta.sh" create quality
		[ "$status" -eq 5 ]
		[[ "$output" == *'invalid benchmark identity'* ]]
	done
}

# Catches resumed ICQ work being accepted after its selected setting or upstream
# evidence changes. Values are deliberately redacted by the public resume
# diagnostic; the stable field path is the observable API.
@test "verify refuses changed selected settings and upstream identity" {
	base_identity="$BATS_TEST_TMPDIR/identity-with-upstream.json"
	jq '.selectedSettings = [{cohort:"avc", globalQuality:22, qualityRunId:"20260815T120000Z-deadbeef"}] |
		.upstream = {qualityRunId:"20260802T120000Z-deadbeef", resultsDigest:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' \
		"$BENCHMARK_IDENTITY_FIXTURE" >"$base_identity"
	export BENCHMARK_IDENTITY_FIXTURE="$base_identity"
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	for mutation in \
		'.selectedSettings[0].globalQuality = 24|selectedSettings.0.globalQuality' \
		'.upstream.qualityRunId = "20260802T120000Z-cafef00d"|upstream.qualityRunId'; do
		expression="${mutation%%|*}"
		expected_path="${mutation#*|}"
		changed="$BATS_TEST_TMPDIR/changed-$expected_path.json"
		jq "$expression" "$base_identity" >"$changed"
		export BENCHMARK_IDENTITY_FIXTURE="$changed"
		run "$SCRIPTS/runmeta.sh" verify "$run_id"
		[ "$status" -eq 1 ]
		[[ "$output" == "identity mismatch: $expected_path "* ]]
		export BENCHMARK_IDENTITY_FIXTURE="$base_identity"
	done
}

# Catches a scoped downstream selection being ignored in favor of every chosen
# record, or a malformed scoped override becoming durable run identity.
@test "selected settings override is scoped strict and falls back only when absent" {
	prepare_configmap_script_mount
	jq '.chosenSettings = {
		avc:{globalQuality:24,qualityRunId:"20260815T120000Z-aaaaaaaa"},
		hdr10:{globalQuality:22,qualityRunId:"20260815T120000Z-bbbbbbbb"}
	}' "$BENCHMARK_SAMPLES_FILE" >"$BENCHMARK_SAMPLES_FILE.tmp"
	mv -f -- "$BENCHMARK_SAMPLES_FILE.tmp" "$BENCHMARK_SAMPLES_FILE"
	export BENCHMARK_SELECTED_SETTINGS_JSON='[{"cohort":"hdr10","globalQuality":22,"qualityRunId":"20260815T120000Z-bbbbbbbb"}]'

	run "$configmap_root/runmeta.sh" create finalist '20260815T150000Z-deadbeef'
	[ "$status" -eq 0 ]
	run jq -e '.selectedSettings == [{cohort:"hdr10",globalQuality:22,qualityRunId:"20260815T120000Z-bbbbbbbb"}]' \
		"$BENCHMARK_OUT/runs/20260815T150000Z-deadbeef/manifest.json"
	[ "$status" -eq 0 ]

	for invalid in \
		'{"cohort":"hdr10"}' \
		'[{"cohort":"hdr10","globalQuality":23,"qualityRunId":"20260815T120000Z-bbbbbbbb"}]' \
		'[{"cohort":"hdr10","globalQuality":22,"qualityRunId":"20261315T120000Z-bbbbbbbb"}]' \
		'[{"cohort":"hdr10","globalQuality":22,"qualityRunId":"20260815T120000Z-bbbbbbbb","extra":true}]' \
		'[{"cohort":"hdr10","globalQuality":22,"qualityRunId":"20260815T120000Z-bbbbbbbb"},{"cohort":"hdr10","globalQuality":24,"qualityRunId":"20260815T120000Z-aaaaaaaa"}]'; do
		export BENCHMARK_SELECTED_SETTINGS_JSON="$invalid"
		run "$configmap_root/runmeta.sh" create savings '20260815T150001Z-cafef00d'
		[ "$status" -ne 0 ]
		[ ! -e "$BENCHMARK_OUT/runs/20260815T150001Z-cafef00d" ]
	done

	unset BENCHMARK_SELECTED_SETTINGS_JSON
	run "$configmap_root/runmeta.sh" create savings '20260815T150002Z-cafef00d'
	[ "$status" -eq 0 ]
	run jq -e '.selectedSettings == [
		{cohort:"avc",globalQuality:24,qualityRunId:"20260815T120000Z-aaaaaaaa"},
		{cohort:"hdr10",globalQuality:22,qualityRunId:"20260815T120000Z-bbbbbbbb"}
	]' "$BENCHMARK_OUT/runs/20260815T150002Z-cafef00d/manifest.json"
	[ "$status" -eq 0 ]
}

# Catches CPU-only x265 results being resumed across processors or runtime
# builds, which would make matched-quality comparisons non-comparable.
@test "node-bound x265 resume refuses changed node kernel CPU FFmpeg and libx265 identities" {
	cpu_identity="$BATS_TEST_TMPDIR/cpu-identity.json"
	jq '.gpu = null | .cpu = {model:"Intel(R) Core(TM) i5", ffmpeg:"8.1.2", libx265:"4.1"} |
		.node = {name:"nuc3",kernel:"6.12.0-fixture"}' \
		"$BENCHMARK_IDENTITY_FIXTURE" >"$cpu_identity"
	export BENCHMARK_IDENTITY_FIXTURE="$cpu_identity"
	run_id="$($SCRIPTS/runmeta.sh create x265)"
	for mutation in \
		'.node.name = "nuc1"|node.name' \
		'.node.kernel = "6.12.1-fixture"|node.kernel' \
		'.cpu.model = "other cpu"|cpu.model' \
		'.cpu.ffmpeg = "8.1.3"|cpu.ffmpeg' \
		'.cpu.libx265 = "4.2"|cpu.libx265'; do
		expression="${mutation%%|*}"
		expected_path="${mutation#*|}"
		changed="$BATS_TEST_TMPDIR/changed-$expected_path.json"
		jq "$expression" "$cpu_identity" >"$changed"
		export BENCHMARK_IDENTITY_FIXTURE="$changed"
		run "$SCRIPTS/runmeta.sh" verify "$run_id"
		[ "$status" -eq 1 ]
		[[ "$output" == "identity mismatch: $expected_path "* ]]
		export BENCHMARK_IDENTITY_FIXTURE="$cpu_identity"
	done
}

# Catches an explicit run handle following a pre-existing symlink out of the
# confined runs tree and treating another directory's manifest as its own.
@test "explicit create refuses a symlinked run directory" {
	source_id='20260802T121500Z-deadbeef'
	link_id='20260802T121501Z-cafef00d'
	run "$SCRIPTS/runmeta.sh" create quality "$source_id"
	[ "$status" -eq 0 ]
	source_manifest="$BENCHMARK_OUT/runs/$source_id/manifest.json"
	before="$BATS_TEST_TMPDIR/symlink-source-before"
	cp "$source_manifest" "$before"
	ln -s "$BENCHMARK_OUT/runs/$source_id" "$BENCHMARK_OUT/runs/$link_id"

	run "$SCRIPTS/runmeta.sh" create quality "$link_id"
	[ "$status" -eq 73 ]
	[ "$output" = "run path is not a confined directory: $link_id" ]
	[ -L "$BENCHMARK_OUT/runs/$link_id" ]
	cmp -s "$before" "$source_manifest"
}

# Catches a production break where collision cleanup removes an empty run
# directory that existed before this process attempted its atomic mkdir.
@test "failed create preserves an existing empty run directory" {
	run_id='20260802T120000Z-6cdfc9f3'
	collision="$BENCHMARK_OUT/runs/$run_id"
	mkdir "$collision"

	run "$SCRIPTS/runmeta.sh" create quality
	[ "$status" -eq 73 ]
	[[ "$output" == *"run already exists: $run_id" ]]
	[ -d "$collision" ]
	[ "$(run_directory_count)" -eq 1 ]
}

@test "diagnostics identity binds the bounded panel sources and historical evidence" {
	prepare_diagnostic_samples
	run "$SCRIPTS/runmeta.sh" create diagnostics
	[ "$status" -eq 0 ]
	run_id="$output"
	manifest="$BENCHMARK_OUT/runs/$run_id/manifest.json"
	expected_sources="$(diagnostic_expected_sources)"
	expected_panel_sha="$(diagnostic_expected_panel_sha)"

	run jq -e \
		--argjson expected_sources "$expected_sources" \
		--arg expected_panel_sha "$expected_panel_sha" '
		.mode == "diagnostics" and
		.schemaVersion == 2 and
		.resultsSchemaVersion == 2 and
		.selectedSettings == [] and
		.sources == $expected_sources and
		.encoderCommands == [
			"ffmpeg -nostdin -ss <clip-start> -i <source> -t 90 -map 0:v:0 -c copy <clip>",
			"ffmpeg -nostdin -init_hw_device qsv=hw:/dev/dri/renderD128 -filter_hw_device hw -i <clip> -map 0 -c:v hevc_qsv -preset veryslow -global_quality <setting> -look_ahead 0 -extbrc 0 -c:a copy -c:s copy -map_metadata 0 -map_chapters 0 <output>",
			"ffmpeg -nostdin -i <source-clip> -i <encoded-output> -lavfi libvmaf=log_fmt=json:log_path=<window>.json -f null -",
			"ffmpeg -nostdin -i <source-clip> -i <encoded-output> -filter_complex [0:v]setpts=PTS-STARTPTS[source];[1:v]setpts=PTS-STARTPTS[encoded];[source][encoded]libvmaf=log_fmt=json:log_path=<window-reset>.json -f null -",
			"ffmpeg -nostdin -i <source-clip> -i <encoded-output> -lavfi ssim;[0:v][1:v]psnr -f null -",
			"ffprobe -show_frames -select_streams v -read_intervals <window> -show_entries frame=best_effort_timestamp_time,pkt_duration_time,key_frame,pict_type <media>",
			"ffprobe -show_streams -show_frames -show_packets -show_entries stream_side_data,pkt_pts_time,pkt_dts_time <media>",
			"ffmpeg -nostdin -i <media> -c copy -bsf:v trace_headers -f null -"
		] and
		.upstream == {
			diagnostics: {
				manifestSchemaVersion: 1,
				resultSchemaVersion: 1,
				acceptedFindingsSha256: "sha256:eb7ddcb42bffecb0ac0f8ab2df58be8317c586c56bb4485d48169568a6061294",
				decisionSha256: "sha256:17c476c4646e28bef71514bb48473771f449aa2c749b1d611f6c69ed518cc330",
				historicalQualityRunId: "20260817T233546Z-debc0498",
				historicalFindingsRunId: "20260818T214739Z-8bc2de3e",
				panelSha256: $expected_panel_sha
			}
		}
	' "$manifest"
	[ "$status" -eq 0 ]
}

@test "diagnostics identity refuses missing command identities" {
	prepare_diagnostic_samples
	unset BENCHMARK_ENCODER_COMMANDS_JSON

	run "$SCRIPTS/runmeta.sh" create diagnostics
	[ "$status" -eq 65 ]
	[[ "$output" == *'diagnostic command identity is missing or malformed'* ]]

	export BENCHMARK_ENCODER_COMMANDS_JSON='[]'
	run "$SCRIPTS/runmeta.sh" create diagnostics
	[ "$status" -eq 65 ]
	[[ "$output" == *'diagnostic command identity is missing or malformed'* ]]
}

@test "diagnostics fixture identity refuses missing command identities" {
	prepare_diagnostic_samples
	expected_sources="$(diagnostic_expected_sources)"
	expected_panel_sha="$(diagnostic_expected_panel_sha)"
	fixture="$BATS_TEST_TMPDIR/diagnostics-identity-fixture.json"
	jq \
		--argjson sources "$expected_sources" \
		--arg panel_sha "$expected_panel_sha" '
		.mode = "diagnostics" |
		.encoderCommands = [] |
		.sources = $sources |
		.selectedSettings = [] |
		.upstream = {
			diagnostics: {
				manifestSchemaVersion: 1,
				resultSchemaVersion: 1,
				acceptedFindingsSha256: "sha256:eb7ddcb42bffecb0ac0f8ab2df58be8317c586c56bb4485d48169568a6061294",
				decisionSha256: "sha256:17c476c4646e28bef71514bb48473771f449aa2c749b1d611f6c69ed518cc330",
				historicalQualityRunId: "20260817T233546Z-debc0498",
				historicalFindingsRunId: "20260818T214739Z-8bc2de3e",
				panelSha256: $panel_sha
			}
		}
	' "$BATS_TEST_DIRNAME/fixtures/manifests/identity.json" >"$fixture"
	export BENCHMARK_IDENTITY_FIXTURE="$fixture"

	run "$SCRIPTS/runmeta.sh" create diagnostics
	[ "$status" -eq 65 ]
	[[ "$output" == *'diagnostic command identity is missing or malformed'* ]]
}

@test "diagnostics resume refuses panel timestamp and historical scope drift" {
	prepare_diagnostic_samples
	run "$SCRIPTS/runmeta.sh" create diagnostics
	[ "$status" -eq 0 ]
	run_id="$output"
	base_samples="$BATS_TEST_TMPDIR/diagnostic-base-samples.json"
	cp "$BENCHMARK_SAMPLES_FILE" "$base_samples"

	jq '.diagnostics.vmafPanel[0].observedFrameIndex = 1642' \
		"$base_samples" >"$BENCHMARK_SAMPLES_FILE.tmp"
	mv -f -- "$BENCHMARK_SAMPLES_FILE.tmp" "$BENCHMARK_SAMPLES_FILE"
	run "$SCRIPTS/runmeta.sh" verify "$run_id"
	[ "$status" -eq 65 ]
	cp "$base_samples" "$BENCHMARK_SAMPLES_FILE"

	expression='(.qualityPanel[] | select(.id == "avc-clean-coco") | .clips.motion) = "00:05:01.000"'
	jq "$expression" "$base_samples" >"$BENCHMARK_SAMPLES_FILE.tmp"
	mv -f -- "$BENCHMARK_SAMPLES_FILE.tmp" "$BENCHMARK_SAMPLES_FILE"
	run "$SCRIPTS/runmeta.sh" verify "$run_id"
	[ "$status" -eq 1 ]
	[[ "$output" == *"identity mismatch: samplesDigest "* ]]
	cp "$base_samples" "$BENCHMARK_SAMPLES_FILE"

	jq '.diagnostics.historicalQualityRunId = "20260817T233546Z-aaaaaaaa"' \
		"$base_samples" >"$BENCHMARK_SAMPLES_FILE.tmp"
	mv -f -- "$BENCHMARK_SAMPLES_FILE.tmp" "$BENCHMARK_SAMPLES_FILE"
	run "$SCRIPTS/runmeta.sh" verify "$run_id"
	[ "$status" -eq 1 ]
	[[ "$output" == *"identity mismatch: upstream.diagnostics.historicalQualityRunId "* ]]
	cp "$base_samples" "$BENCHMARK_SAMPLES_FILE"
}

# Catches the race where a concurrent creator wins mkdir after this process has
# selected the run ID and the losing process removes the winner's empty tree.
@test "failed concurrent create preserves the winning run directory" {
	run_id='20260802T120000Z-6cdfc9f3'
	collision="$BENCHMARK_OUT/runs/$run_id"
	stub_bin="$BATS_TEST_TMPDIR/mkdir-bin"
	mkdir -p "$stub_bin"
	cat >"$stub_bin/mkdir" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if (($# == 1)) && [[ "$1" == */20260802T120000Z-6cdfc9f3 ]]; then
	/bin/mkdir "$1"
	exit 1
fi
exec /bin/mkdir "$@"
EOF
	chmod +x "$stub_bin/mkdir"
	export PATH="$stub_bin:$PATH"

	run "$SCRIPTS/runmeta.sh" create quality
	[ "$status" -eq 73 ]
	[[ "$output" == *"run already exists: $run_id" ]]
	[ -d "$collision" ]
	[ "$(run_directory_count)" -eq 1 ]
}

# Catches a production break where an explicitly selected, byte-identical run
# is recreated, or a successful exact row is encoded again.
@test "matching explicit run id resumes without changing manifest bytes and skips an exact passed row" {
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	manifest="$BENCHMARK_OUT/runs/$run_id/manifest.json"
	before="$BATS_TEST_TMPDIR/manifest-before"
	cp "$manifest" "$before"
	results="$BENCHMARK_OUT/runs/$run_id/results.csv"
	results_header >"$results"
	results_row "$run_id" | sed 's/,abc123,detail,qsv,22,/,abc123,detail,qsv,22,/' >>"$results"

	run "$SCRIPTS/runmeta.sh" create quality "$run_id"
	[ "$status" -eq 0 ]
	[ "$output" = "$run_id" ]
	cmp -s "$before" "$manifest"
	[ "$(file_mode "$manifest")" = '444' ]
	[ "$(run_directory_count)" -eq 1 ]

	run "$SCRIPTS/runmeta.sh" verify "$run_id"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

# Catches a production break where prefix keys or failed attempts are mistaken
# for exact successful rows and are incorrectly skipped.
@test "completed accepts only an exact row key whose status is passed" {
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	results="$BENCHMARK_OUT/runs/$run_id/results.csv"
	results_header >"$results"
	results_row "$run_id" | sed 's/,qsv,22,ICQ,passed,1,/,qsv,24,ICQ,passed,1,/' >>"$results"
	results_row "$run_id" | sed 's/,ICQ,passed,1,/,ICQ,failed,1,/' >>"$results"
	results_row "$run_id" | sed 's/,qsv,22,ICQ,passed,1,/,qsv,24,ICQ,invalid,1,/' >>"$results"

	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
	[ "$status" -eq 1 ]
	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|23'
	[ "$status" -eq 1 ]
	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|2'
	[ "$status" -eq 1 ]

	results_row "$run_id" >>"$results"
	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
	[ "$status" -eq 0 ]
}

# Catches test-only compact rows bypassing the schema-v2 header, strategy, and
# QSV evidence checks that protect production resume behavior.
@test "completed rejects compact passed rows under the ICQ results schema" {
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	printf '%s\n' 'quality|abc123|detail|qsv|22,passed' >"$BENCHMARK_OUT/runs/$run_id/results.csv"

	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
	[ "$status" -eq 65 ]
	[ "$output" = 'invalid results CSV header' ]
}

# Catches a production break where a crash-truncated row ending at a positional
# passed status is trusted even though Task 5 did not append a complete record.
@test "completed rejects a truncated full-schema passed row" {
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	results="$BENCHMARK_OUT/runs/$run_id/results.csv"
	results_header >"$results"
	printf '%s\n' "$run_id,quality,sample-avc,avc,abc123,detail,qsv,22,global_quality,passed" >>"$results"

	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
	[ "$status" -eq 65 ]
	[ "$output" = 'invalid results CSV: row 2 has 10 columns; expected 39' ]
}

# Catches a production break where a header with only the first field correct is
# treated as Task 5 output and positional columns can suppress an encode.
@test "completed requires the exact Task 5 results header" {
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	results="$BENCHMARK_OUT/runs/$run_id/results.csv"
	printf '%s\n' 'run_id,panel,sample_id,cohort,source_sha256,clip_id,encoder,requested_setting,selected_rate_control,status' >"$results"
	printf '%s\n' "$run_id,quality,sample-avc,avc,abc123,detail,qsv,22,global_quality,passed" >>"$results"

	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
	[ "$status" -eq 65 ]
	[ "$output" = 'invalid results CSV header' ]
}

# Catches a production break where valid RFC 4180 quoted commas shift positional
# fields or where malformed quoting is accepted after a complete passed row.
@test "completed parses quoted commas and rejects malformed full-schema CSV" {
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	results="$BENCHMARK_OUT/runs/$run_id/results.csv"
	results_header >"$results"
	printf '%s\n' "$run_id,quality,sample-avc,avc,abc123,detail,qsv,22,ICQ,passed,1,100,50,50,1000,500,10,30,1.0,95,90,0.99,80,yes,hevc,10,1920x1080,24,10,hdr10,1,2,3,\"none, verified\",\"logs/a,b.log\",discarded,qsv-hevc-icq-v1,passed,800000000" >>"$results"

	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
	[ "$status" -eq 0 ]

	printf '%s\n' '"unterminated' >>"$results"
	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
	[ "$status" -eq 65 ]
	[ "$output" = 'invalid results CSV: malformed row 3' ]
}

# Catches a stale results schema or another strategy claiming a passed row and
# suppressing an ICQ retry.
@test "completed refuses passed rows without the ICQ strategy identity" {
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	results="$BENCHMARK_OUT/runs/$run_id/results.csv"
	results_header >"$results"
	results_row "$run_id" | sed 's/,qsv-hevc-icq-v1,passed,800000000$//' >>"$results"

	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
	[ "$status" -eq 65 ]
	[ "$output" = 'invalid results CSV: row 2 has 36 columns; expected 39' ]

	results_header >"$results"
	results_row "$run_id" qsv la-hevc-icq-v1 >>"$results"
	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
	[ "$status" -eq 65 ]
	[ "$output" = 'invalid results CSV: row 2 has a mismatched strategy' ]
}

# Catches a stale QSV completed-row reader accepting LA-ICQ or a setting that
# cannot reach every later ICQ stage, thereby skipping the required retry.
@test "completed rejects stale mode and out-of-range QSV settings" {
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	results="$BENCHMARK_OUT/runs/$run_id/results.csv"
	for setting in 14 17 32; do
		results_header >"$results"
		results_row "$run_id" | sed "s/,qsv,22,ICQ,passed,1,/,qsv,$setting,ICQ,passed,1,/" >>"$results"
		run "$SCRIPTS/runmeta.sh" completed "$run_id" "quality|abc123|detail|qsv|$setting"
		[ "$status" -eq 65 ]
		[ "$output" = 'invalid results CSV: row 2 has an invalid ICQ setting' ]
	done

	results_header >"$results"
	results_row "$run_id" | sed 's/,qsv,22,ICQ,passed,1,/,qsv,22,LA-ICQ,passed,1,/' >>"$results"
	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
	[ "$status" -eq 65 ]
	[ "$output" = 'invalid results CSV: row 2 has an invalid QSV rate control' ]
}

# Catches a passed QSV row relying on encode success alone instead of retaining
# the required initialization and positive hardware-work evidence.
@test "completed requires QSV initialization and positive video busy time" {
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	results="$BENCHMARK_OUT/runs/$run_id/results.csv"
	results_header >"$results"
	results_row "$run_id" qsv qsv-hevc-icq-v1 failed 800000000 >>"$results"

	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
	[ "$status" -eq 65 ]
	[ "$output" = 'invalid results CSV: row 2 has an invalid QSV initialization' ]

	results_header >"$results"
	results_row "$run_id" qsv qsv-hevc-icq-v1 passed 0 >>"$results"
	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
	[ "$status" -eq 65 ]
	[ "$output" = 'invalid results CSV: row 2 has invalid QSV video busy time' ]
}

# Catches the CPU reference stage resuming from a row with GPU proof values,
# the old quality panel, a non-CRF setting, or incomplete output evidence.
@test "completed accepts only a complete x265 CPU result row" {
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	results="$BENCHMARK_OUT/runs/$run_id/results.csv"
	valid="$BATS_TEST_TMPDIR/valid-x265-row"
	results_header >"$results"
	printf '%s\n' "$run_id,x265,sample-avc,avc,abc123,detail,x265,22,CRF,passed,1,100,50,50,1000,500,10,30,1.0,95,90,,,not-applicable,passed,passed,passed,passed,passed,passed,passed,passed,passed,,logs/a.log,discarded,qsv-hevc-icq-v1,not-applicable,0" >"$valid"
	cat "$valid" >>"$results"

	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'x265|abc123|detail|x265|22'
	[ "$status" -eq 0 ]

	for mutation in \
		's/,x265,sample-avc,/,quality,sample-avc,/' \
		's/,x265,22,CRF,/,x265,22,LA-ICQ,/' \
		's/,x265,22,CRF,/,x265,35,CRF,/' \
		's/,,,not-applicable,passed/,,,passed,passed/' \
		's/,not-applicable,passed,passed,/,not-applicable,failed,passed,/'; do
		results_header >"$results"
		sed "$mutation" "$valid" >>"$results"
		run "$SCRIPTS/runmeta.sh" completed "$run_id" 'x265|abc123|detail|x265|22'
		[ "$status" -eq 65 ]
	done
}

# Catches a production break where changed executable bytes reuse stale result
# rows, overwrite the original evidence, leak digest values, or fork silently.
@test "changed script digest aborts explicit resume with a redacted field diff" {
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	manifest="$BENCHMARK_OUT/runs/$run_id/manifest.json"
	before="$BATS_TEST_TMPDIR/manifest-before"
	cp "$manifest" "$before"
	export BENCHMARK_IDENTITY_FIXTURE="$BATS_TEST_DIRNAME/fixtures/manifests/changed-script.json"

	run "$SCRIPTS/runmeta.sh" verify "$run_id"
	[ "$status" -eq 1 ]
	[ "$output" = 'identity mismatch: scriptDigests.benchmark.sh (stored=<missing>, current=<redacted>)' ]
	[[ "$output" != *'ae253cad'* ]]
	cmp -s "$before" "$manifest"
	[ "$(file_mode "$manifest")" = '444' ]
	[ "$(run_directory_count)" -eq 1 ]

	run "$SCRIPTS/runmeta.sh" create quality "$run_id"
	[ "$status" -eq 1 ]
	[ "$output" = 'identity mismatch: scriptDigests.benchmark.sh (stored=<missing>, current=<redacted>)' ]
	cmp -s "$before" "$manifest"
	[ "$(run_directory_count)" -eq 1 ]
}

# Catches a production break where a missing nullable identity field is silently
# normalized to null and an incomplete stored manifest is accepted as exact.
@test "verify rejects a stored manifest with a missing canonical identity field" {
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	manifest="$BENCHMARK_OUT/runs/$run_id/manifest.json"
	tampered="$BATS_TEST_TMPDIR/tampered-manifest.json"
	jq -S -c 'del(.clientDevice)' "$manifest" >"$tampered"
	chmod 0444 "$tampered"
	mv -f "$tampered" "$manifest"

	run "$SCRIPTS/runmeta.sh" verify "$run_id"
	[ "$status" -eq 1 ]
	[ "$output" = 'identity mismatch: clientDevice (stored=<missing>, current=<redacted>)' ]
}

# Catches a production break where ConfigMap data symlinks are skipped and
# changed deployed script bytes therefore remain absent from exact run identity.
@test "real discovery hashes ConfigMap symlinked scripts and blocks changed bytes" {
	prepare_configmap_script_mount
	run_id="$($configmap_root/runmeta.sh create quality)"
	manifest="$BENCHMARK_OUT/runs/$run_id/manifest.json"
	benchmark_digest="sha256:$(sha256sum "$configmap_data/benchmark.sh" | awk '{print $1}')"
	run jq -e --arg digest "$benchmark_digest" \
		'.scriptDigests["benchmark.sh"] == $digest and (.scriptDigests["runmeta.sh"] | startswith("sha256:"))' \
		"$manifest"
	[ "$status" -eq 0 ]

	printf '%s\n' '#!/usr/bin/env bash' 'exit 65' >"$configmap_data/benchmark.sh"
	run "$configmap_root/runmeta.sh" verify "$run_id"
	[ "$status" -eq 1 ]
	[ "$output" = 'identity mismatch: scriptDigests.benchmark.sh (stored=<redacted>, current=<redacted>)' ]
}

# Catches a live GPU or CPU run publishing a manifest that has no runtime
# identity for the environment that produced the measured rows.
@test "discovery requires execution-class runtime identities" {
	prepare_configmap_script_mount
	unset BENCHMARK_I915_VERSION
	run "$configmap_root/runmeta.sh" create quality
	[ "$status" -eq 65 ]
	[ "$output" = 'GPU runtime identity is incomplete' ]

	export BENCHMARK_I915_VERSION='fixture-i915'
	export BENCHMARK_EXECUTION_CLASS=cpu
	export BENCHMARK_CPU_MODEL='fixture CPU'
	export BENCHMARK_FFMPEG_VERSION='8.1.2'
	unset BENCHMARK_LIBX265_VERSION
	run "$configmap_root/runmeta.sh" create quality
	[ "$status" -eq 65 ]
	[ "$output" = 'CPU runtime identity is incomplete' ]
}

# Catches CPU identity being collected after directory creation, accepting a
# missing oracle, or recording caller-provided GPU identity for an x265 run.
@test "CPU discovery reads model FFmpeg and libx265 before x265 manifest creation" {
	prepare_configmap_script_mount
	cpuinfo="$BATS_TEST_TMPDIR/cpuinfo"
	printf '%s\n' 'processor : 0' 'model name : Fixture CPU Model' >"$cpuinfo"
	stub_bin="$BATS_TEST_TMPDIR/cpu-bin"
	mkdir -p "$stub_bin"
	cat >"$stub_bin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$RUNMETA_CPU_COMMAND_LOG"
if [[ "$*" == *'-version'* ]]; then
	[[ "${RUNMETA_MISSING_FFMPEG_VERSION:-0}" != '1' ]] && printf '%s\n' 'ffmpeg version 8.1.2 fixture-build'
	exit 0
fi
if [[ "$*" == *'-c:v libx265 -f null -'* ]]; then
	[[ "${RUNMETA_MISSING_X265_VERSION:-0}" != '1' ]] && printf '%s\n' 'x265 [info]: HEVC encoder version 4.1+1' >&2
	exit 0
fi
exit 97
EOF
	cat >"$stub_bin/uname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '-r' ]] || exit 97
printf '%s\n' '6.12.0-fixture'
EOF
	chmod +x "$stub_bin/ffmpeg" "$stub_bin/uname"
	export PATH="$stub_bin:$PATH"
	export RUNMETA_CPU_COMMAND_LOG="$BATS_TEST_TMPDIR/cpu-commands.log"
	: >"$RUNMETA_CPU_COMMAND_LOG"
	unset BENCHMARK_IDENTITY_FIXTURE BENCHMARK_CPU_MODEL BENCHMARK_FFMPEG_VERSION BENCHMARK_LIBX265_VERSION
	unset BENCHMARK_I915_VERSION BENCHMARK_VPL_VERSION
	export BENCHMARK_EXECUTION_CLASS=cpu
	export BENCHMARK_CPUINFO_FILE="$cpuinfo"
	export BENCHMARK_X265_SAMPLE_ID='avc-grain-memento'
	export NODE_NAME='nuc3'

	run "$configmap_root/runmeta.sh" create x265 '20260815T130000Z-bbbbbbbb'
	[ "$status" -eq 0 ]
	manifest="$BENCHMARK_OUT/runs/20260815T130000Z-bbbbbbbb/manifest.json"
	run jq -e '
		.mode == "x265" and .gpu == null and
		.cpu == {ffmpeg:"ffmpeg version 8.1.2 fixture-build",libx265:"4.1+1",model:"Fixture CPU Model"} and
		.node == {kernel:"6.12.0-fixture",name:"nuc3"}
	' "$manifest"
	[ "$status" -eq 0 ]
	run rg -F -- '-nostdin -v info -f lavfi -i color=size=16x16:rate=1 -frames:v 1 -c:v libx265 -f null -' \
		"$RUNMETA_CPU_COMMAND_LOG"
	[ "$status" -eq 0 ]

	for missing in cpu ffmpeg x265; do
		rm -rf -- "$BENCHMARK_OUT/runs"
		mkdir -p "$BENCHMARK_OUT/runs"
		unset RUNMETA_MISSING_FFMPEG_VERSION RUNMETA_MISSING_X265_VERSION
		printf '%s\n' 'processor : 0' 'model name : Fixture CPU Model' >"$cpuinfo"
		case "$missing" in
		cpu) printf '%s\n' 'processor : 0' >"$cpuinfo" ;;
		ffmpeg) export RUNMETA_MISSING_FFMPEG_VERSION=1 ;;
		x265) export RUNMETA_MISSING_X265_VERSION=1 ;;
		esac
		run "$configmap_root/runmeta.sh" create x265 '20260815T130000Z-bbbbbbbb'
		[ "$status" -eq 65 ]
		[ "$output" = 'CPU runtime identity is incomplete' ]
		[ "$(run_directory_count)" -eq 0 ]
	done
}

# Catches a production break where unrecognized stored fields are discarded by
# normalization even though createdAt is the only field resume may ignore.
@test "verify rejects unknown stored identity fields" {
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	manifest="$BENCHMARK_OUT/runs/$run_id/manifest.json"
	tampered="$BATS_TEST_TMPDIR/tampered-manifest.json"
	jq -S -c '.unexpectedIdentityField = true' "$manifest" >"$tampered"
	chmod 0444 "$tampered"
	mv -f "$tampered" "$manifest"

	run "$SCRIPTS/runmeta.sh" verify "$run_id"
	[ "$status" -eq 1 ]
	[ "$output" = 'identity mismatch: unexpectedIdentityField (stored=<redacted>, current=<missing>)' ]
}

# Catches a production break where a known field with a malformed type is
# rejected without identifying which redacted identity field is unusable.
@test "verify names a malformed stored identity field without exposing values" {
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	manifest="$BENCHMARK_OUT/runs/$run_id/manifest.json"
	tampered="$BATS_TEST_TMPDIR/tampered-manifest.json"
	jq -S -c '.node.kernel = 17' "$manifest" >"$tampered"
	chmod 0444 "$tampered"
	mv -f "$tampered" "$manifest"

	run "$SCRIPTS/runmeta.sh" verify "$run_id"
	[ "$status" -eq 1 ]
	[ "$output" = 'identity mismatch: node.kernel (stored=<redacted>, current=<redacted>)' ]
}

# Catches a production break where source recomputation echoes a sensitive media
# pathname instead of reporting only the redacted identity field that vanished.
@test "verify redacts a source path that disappears before resume" {
	source_path="$BATS_TEST_TMPDIR/Secret Movie Name.mkv"
	cp "$BATS_TEST_DIRNAME/fixtures/media/avc-8bit.mkv" "$source_path"
	samples_file="$BATS_TEST_TMPDIR/samples-with-source.json"
	yq -r '.data."samples.json"' "$BATS_TEST_DIRNAME/../app/samples.yaml" >"$samples_file"
	rewrite_samples_to_test_media "$samples_file"
	jq \
		--arg path "$source_path" \
		--arg sha "$(sha256sum "$source_path" | awk 'NR == 1 { print $1 }')" \
		--argjson size "$(wc -c <"$source_path" | tr -d '[:space:]')" '
		.qualityPanel |= map(
			if .id == "avc-clean-coco" then
				.path = $path | .sizeBytes = $size | .sha256 = $sha
			else
				.
			end
		)
	' "$samples_file" >"$samples_file.tmp"
	mv -f -- "$samples_file.tmp" "$samples_file"
	unset BENCHMARK_IDENTITY_FIXTURE
	export BENCHMARK_SAMPLES_FILE="$samples_file"
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	rm "$source_path"

	run "$SCRIPTS/runmeta.sh" verify "$run_id"
	[ "$status" -eq 66 ]
	[[ "$output" == identity\ unavailable:\ sources.*.path\ \(stored=\<redacted\>,\ current=\<unavailable\>\) ]]
	[[ "$output" != *'Secret Movie Name.mkv'* ]]
}

# Catches a production break where an explicit run handle can escape the run
# root or where its requested mode is not part of exact resume identity.
@test "explicit resume rejects unsafe run ids and a changed mode" {
	run_id="$($SCRIPTS/runmeta.sh create quality)"

	run "$SCRIPTS/runmeta.sh" create savings "$run_id"
	[ "$status" -eq 1 ]
	[ "$output" = 'identity mismatch: mode (stored=quality, current=savings)' ]
	[ "$(run_directory_count)" -eq 1 ]

	run "$SCRIPTS/runmeta.sh" verify '../escape'
	[ "$status" -eq 64 ]
	[ "$output" = 'invalid run id: ../escape' ]
	[ ! -e "$BENCHMARK_OUT/escape" ]
}

# Catches regex-only timestamp checks accepting calendar-invalid run handles or
# stored manifest instants that cannot be exact UTC evidence.
@test "run ids and manifest createdAt require real UTC instants" {
	for invalid_run in \
		'20261302T120000Z-deadbeef' \
		'20260230T120000Z-deadbeef' \
		'20260802T250000Z-deadbeef'; do
		run "$SCRIPTS/runmeta.sh" create quality "$invalid_run"
		[ "$status" -eq 64 ]
		[ "$output" = "invalid run id: $invalid_run" ]
	done

	run_id="$($SCRIPTS/runmeta.sh create quality)"
	manifest="$BENCHMARK_OUT/runs/$run_id/manifest.json"
	cp "$manifest" "$manifest.good"
	for invalid_created_at in 20261302T120000Z 20260230T120000Z 20260802T250000Z; do
		jq -S -c --arg value "$invalid_created_at" '.createdAt = $value' \
			"$manifest.good" >"$manifest.tmp"
		chmod 0444 "$manifest.tmp"
		mv -f "$manifest.tmp" "$manifest"
		run "$SCRIPTS/runmeta.sh" verify "$run_id"
		[ "$status" -eq 1 ]
		[ "$output" = 'identity mismatch: createdAt (stored=<redacted>, current=<ignored>)' ]
	done
}

# Catches a production break where the fixture override becomes reachable in a
# real benchmark environment and can replace runtime-discovered identity.
@test "identity fixture is refused outside test mode" {
	test_out="$BENCHMARK_OUT"
	export BENCHMARK_TEST_MODE=0
	unset BENCHMARK_OUT BENCHMARK_NOW BENCHMARK_SAMPLES_FILE
	run "$SCRIPTS/runmeta.sh" create quality
	[ "$status" -eq 64 ]
	[ "$output" = 'BENCHMARK_IDENTITY_FIXTURE requires BENCHMARK_TEST_MODE=1' ]
	[ "$(find "$test_out/runs" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq 0 ]
}

# Catches a production break where an output-root override can redirect run
# creation away from the fixed writable /out mount.
@test "output override is refused outside test mode" {
	export BENCHMARK_TEST_MODE=0
	unset BENCHMARK_IDENTITY_FIXTURE BENCHMARK_NOW BENCHMARK_SAMPLES_FILE
	run "$SCRIPTS/runmeta.sh" create quality
	[ "$status" -eq 64 ]
	[ "$output" = 'BENCHMARK_OUT requires BENCHMARK_TEST_MODE=1' ]
	[ "$(run_directory_count)" -eq 0 ]
}

# Catches a production break where a samples override can replace the fixed
# /config/samples.json identity input in a live benchmark environment.
@test "samples override is refused outside test mode" {
	export BENCHMARK_TEST_MODE=0
	unset BENCHMARK_IDENTITY_FIXTURE BENCHMARK_NOW BENCHMARK_OUT
	export BENCHMARK_SAMPLES_FILE="$BATS_TEST_DIRNAME/fixtures/manifests/identity.json"
	run "$SCRIPTS/runmeta.sh" create quality
	[ "$status" -eq 64 ]
	[ "$output" = 'BENCHMARK_SAMPLES_FILE requires BENCHMARK_TEST_MODE=1' ]
}

# Catches a production break where any tested command regresses to the shared
# scaffold after all five behavior contracts have landed.
@test "ConfigMap maps all six tested commands to real scripts" {
	kustomization="$SCRIPTS/../kustomization.yaml"
	run yq -r '.configMapGenerator[0].files | join(",")' "$kustomization"
	[ "$status" -eq 0 ]
	[ "$output" = 'contract.sh=scripts/contract.sh,probe.sh=scripts/probe.sh,census.sh=scripts/census.sh,runmeta.sh=scripts/runmeta.sh,benchmark.sh=scripts/benchmark.sh,stills.sh=scripts/stills.sh' ]
	[ ! -e "$SCRIPTS/not-ready.sh" ]
}

# Catches the two copies of the results schema drifting apart. benchmark.sh
# writes results.csv and runmeta.sh validates it on resume, so a mismatch would
# make every resume decision wrong while both scripts looked self-consistent.
@test "runmeta and benchmark agree on the results schema" {
	benchmark_header="$("$SCRIPTS/benchmark.sh" _test results-header)"
	runmeta_header="$(
		# shellcheck disable=SC1090
		results_header=''
		eval "$(grep -m1 '^results_header=' "$SCRIPTS/runmeta.sh")"
		printf '%s\n' "$results_header"
	)"

	[ -n "$benchmark_header" ]
	[ -n "$runmeta_header" ]
	[ "$runmeta_header" = "$benchmark_header" ]
	[ "$(awk -F, '{print NF}' <<<"$runmeta_header")" -eq 39 ]
}

@test "findings identity has no sources and resume binds the input digest" {
	unset BENCHMARK_IDENTITY_FIXTURE
	inputs_digest="sha256:$(printf findings-inputs | sha256sum | awk '{print $1}')"
	export BENCHMARK_FINDINGS_INPUTS_SHA256="$inputs_digest"
	export BENCHMARK_UPSTREAM_IDENTITY_JSON="$(jq -n --arg digest "$inputs_digest" '{findingsInputsSha256:$digest,quality:{runId:"20260815T120000Z-aaaaaaaa"}}')"
	export BENCHMARK_EXECUTION_CLASS=cpu BENCHMARK_CPU_MODEL=findings-metadata BENCHMARK_FFMPEG_VERSION=not-applicable BENCHMARK_LIBX265_VERSION=not-applicable
	export BENCHMARK_DISPATCH_IMAGE="$(jq -r '.runtime.image' "$BENCHMARK_SAMPLES_FILE")"
	export BENCHMARK_RUNNING_IMAGE="$BENCHMARK_DISPATCH_IMAGE"
	export BENCHMARK_NOW=20260815T160000Z
	run "$SCRIPTS/runmeta.sh" create findings
	[ "$status" -eq 0 ]
	run_id="$output"
	run jq -e '.mode == "findings" and .sources == [] and .upstream.findingsInputsSha256 == env.BENCHMARK_FINDINGS_INPUTS_SHA256' "$BENCHMARK_OUT/runs/$run_id/manifest.json"
	[ "$status" -eq 0 ]
	run "$SCRIPTS/runmeta.sh" create findings "$run_id"
	[ "$status" -eq 0 ]
	export BENCHMARK_FINDINGS_INPUTS_SHA256="sha256:$(printf changed | sha256sum | awk '{print $1}')"
	run "$SCRIPTS/runmeta.sh" create findings "$run_id"
	[ "$status" -ne 0 ]
}
