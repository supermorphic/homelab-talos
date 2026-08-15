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
	local selected='LA-ICQ'
	if [[ "$encoder" == 'x265' ]]; then
		selected='CRF'
		initialization='not-applicable'
		busy='0'
	fi
	printf '%s\n' "$run_id,quality,sample-avc,avc,abc123,detail,$encoder,22,$selected,passed,1,100,50,50,1000,500,10,30,1.0,95,90,0.99,80,passed,hevc,10,1920x1080,24,10,hdr10,1,2,3,none,logs/a.log,discarded,$strategy,$initialization,$busy"
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
	jq '.qualityPanel = [] | .savingsPanel = []' "$samples_file" >"$samples_file.tmp"
	mv -f -- "$samples_file.tmp" "$samples_file"
	unset BENCHMARK_IDENTITY_FIXTURE
	export BENCHMARK_SAMPLES_FILE="$samples_file"
	export BENCHMARK_DISPATCH_IMAGE='docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	export BENCHMARK_RUNNING_IMAGE='sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	export BENCHMARK_I915_VERSION='fixture-i915'
	export BENCHMARK_VPL_VERSION='fixture-vpl'
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
		'.strategyId = "la-hevc-icq-v1"'; do
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
	jq '.selectedSettings = [{cohort:"avc", globalQuality:22}] |
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

# Catches CPU-only x265 results being resumed across processors or runtime
# builds, which would make matched-quality comparisons non-comparable.
@test "verify refuses changed CPU model FFmpeg and libx265 identities" {
	cpu_identity="$BATS_TEST_TMPDIR/cpu-identity.json"
	jq '.gpu = null | .cpu = {model:"Intel(R) Core(TM) i5", ffmpeg:"8.1.2", libx265:"4.1"}' \
		"$BENCHMARK_IDENTITY_FIXTURE" >"$cpu_identity"
	export BENCHMARK_IDENTITY_FIXTURE="$cpu_identity"
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	for mutation in \
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
	results_row "$run_id" | sed 's/,qsv,22,LA-ICQ,passed,1,/,qsv,22-extra,LA-ICQ,passed,1,/' >>"$results"
	results_row "$run_id" | sed 's/,LA-ICQ,passed,1,/,LA-ICQ,failed,1,/' >>"$results"
	results_row "$run_id" | sed 's/,qsv,22,LA-ICQ,passed,1,/,qsv,23,LA-ICQ,invalid,1,/' >>"$results"

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
	printf '%s\n' "$run_id,quality,sample-avc,avc,abc123,detail,qsv,22,global_quality,passed,1,100,50,50,1000,500,10,30,1.0,95,90,0.99,80,yes,hevc,10,1920x1080,24,10,hdr10,1,2,3,\"none, verified\",\"logs/a,b.log\",discarded,qsv-hevc-icq-v1,passed,800000000" >>"$results"

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

# Catches the CPU reference stage inheriting GPU proof values instead of the
# explicit not-applicable zero pair required by the shared results schema.
@test "completed accepts x265 only with the not-applicable QSV proof pair" {
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	results="$BENCHMARK_OUT/runs/$run_id/results.csv"
	results_header >"$results"
	results_row "$run_id" x265 >>"$results"

	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|x265|22'
	[ "$status" -eq 0 ]
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
	printf '%s' 'media-bytes' >"$source_path"
	samples_file="$BATS_TEST_TMPDIR/samples-with-source.json"
	jq -n --arg path "$source_path" \
		--argjson strategy "$(yq -r '.data."samples.json"' "$BATS_TEST_DIRNAME/../app/samples.yaml" | jq -c '.strategy')" '{
		schemaVersion: 2, strategy: $strategy,
		runtime: {image: "docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb"},
		savingsSeed: 20260802,
		qualityPanel: [{
			id: "secret-movie", cohort: "avc", path: $path, sizeBytes: 11,
			sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		}],
		savingsPanel: []
	}' >"$samples_file"
	unset BENCHMARK_IDENTITY_FIXTURE
	export BENCHMARK_SAMPLES_FILE="$samples_file"
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	rm "$source_path"

	run "$SCRIPTS/runmeta.sh" verify "$run_id"
	[ "$status" -eq 66 ]
	[ "$output" = 'identity unavailable: sources.0.path (stored=<redacted>, current=<unavailable>)' ]
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
