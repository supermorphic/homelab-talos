#!/usr/bin/env bats

setup() {
	SCRIPTS="$BATS_TEST_DIRNAME/../app/scripts"
	export BENCHMARK_TEST_MODE=1
	export BENCHMARK_NOW=20260802T120000Z
	export BENCHMARK_OUT="$BATS_TEST_TMPDIR/out"
	export BENCHMARK_IDENTITY_FIXTURE="$BATS_TEST_DIRNAME/fixtures/manifests/identity.json"
	mkdir -p "$BENCHMARK_OUT/runs"
}

run_directory_count() {
	find "$BENCHMARK_OUT/runs" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
}

file_mode() {
	python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$1"
}

results_header() {
	printf '%s\n' 'run_id,panel,sample_id,cohort,source_sha256,clip_id,encoder,requested_setting,selected_rate_control,status,attempt,input_bytes,output_bytes,reduction_percent,input_bit_rate,output_bit_rate,wall_seconds,encode_fps,encode_speed,vmaf_harmonic_mean,vmaf_1pct_low,ssim,gpu_busy_percent,qsv_proof,validation_codec,validation_duration,validation_resolution,validation_frame_rate,validation_bit_depth,validation_hdr,validation_audio_tracks,validation_subtitle_tracks,validation_chapters,validation_failures,log_path,output_disposition'
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
	jq -n '{
		runtime: {image: "docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb"},
		savingsSeed: 20260802,
		qualityPanel: [],
		savingsPanel: []
	}' >"$samples_file"
	unset BENCHMARK_IDENTITY_FIXTURE
	export BENCHMARK_SAMPLES_FILE="$samples_file"
}

# Catches a production break where a bare create discovers and reuses an older
# identity instead of making the timestamped run an operator-held handle.
@test "no run id always creates a fresh timestamped immutable identity" {
	run "$SCRIPTS/runmeta.sh" create quality
	[ "$status" -eq 0 ]
	[ "$output" = '20260802T120000Z-037fa5c4' ]
	first="$output"
	first_manifest="$BENCHMARK_OUT/runs/$first/manifest.json"
	expected="$BATS_TEST_TMPDIR/expected-manifest.json"
	printf '%s\n' '{"clientDevice":null,"createdAt":"20260802T120000Z","encoderCommands":[],"imageDigest":"sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb","mode":"quality","node":{"i915":"","kernel":"","name":"","vpl":""},"samplesDigest":"sha256:9f4e2b20cfb4eaf89f18ba1a3f706d384c450f65a150df41d4e5d50b957f829e","savingsSeed":20260802,"schemaVersion":1,"scriptDigests":{},"sources":[],"vmaf":{"model":"vmaf_4k_v0.6.1","version":""}}' >"$expected"
	cmp -s "$expected" "$first_manifest"
	[ "$(file_mode "$first_manifest")" = '444' ]
	[ ! -e "$BENCHMARK_OUT/runs/$first/manifest.json.tmp" ]

	export BENCHMARK_NOW=20260802T120001Z
	run "$SCRIPTS/runmeta.sh" create quality
	[ "$status" -eq 0 ]
	[ "$output" = '20260802T120001Z-037fa5c4' ]
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
	run_id='20260802T120000Z-037fa5c4'
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
	run_id='20260802T120000Z-037fa5c4'
	collision="$BENCHMARK_OUT/runs/$run_id"
	stub_bin="$BATS_TEST_TMPDIR/mkdir-bin"
	mkdir -p "$stub_bin"
	cat >"$stub_bin/mkdir" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if (($# == 1)) && [[ "$1" == */20260802T120000Z-037fa5c4 ]]; then
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
	printf '%s\n' 'quality|abc123|detail|qsv|22,passed' >"$BENCHMARK_OUT/runs/$run_id/results.csv"

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
	printf '%s\n' \
		'quality|abc123|detail|qsv|22-extra,passed' \
		'quality|abc123|detail|qsv|22,failed' \
		'quality|abc123|detail|qsv|23,invalid' >"$results"

	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
	[ "$status" -eq 1 ]
	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|23'
	[ "$status" -eq 1 ]
	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|2'
	[ "$status" -eq 1 ]

	printf '%s\n' 'quality|abc123|detail|qsv|22,passed' >>"$results"
	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
	[ "$status" -eq 0 ]
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
	[ "$output" = 'invalid results CSV: row 2 has 10 columns; expected 36' ]
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
	printf '%s\n' "$run_id,quality,sample-avc,avc,abc123,detail,qsv,22,global_quality,passed,1,100,50,50,1000,500,10,30,1.0,95,90,0.99,80,yes,hevc,10,1920x1080,24,10,hdr10,1,2,3,\"none, verified\",\"logs/a,b.log\",discarded" >>"$results"

	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
	[ "$status" -eq 0 ]

	printf '%s\n' '"unterminated' >>"$results"
	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
	[ "$status" -eq 65 ]
	[ "$output" = 'invalid results CSV: malformed row 3' ]
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
	jq -n --arg path "$source_path" '{
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
	[ "$(awk -F, '{print NF}' <<<"$runmeta_header")" -eq 36 ]
}
