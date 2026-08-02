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

prepare_configmap_script_mount() {
	configmap_root="$BATS_TEST_TMPDIR/scripts"
	configmap_data="$configmap_root/..2026_08_02_12_00_00.000000000"
	mkdir -p "$configmap_data"
	cp "$SCRIPTS/runmeta.sh" "$configmap_data/runmeta.sh"
	printf '%s\n' '#!/usr/bin/env bash' 'exit 64' >"$configmap_data/benchmark.sh"
	chmod +x "$configmap_data/runmeta.sh" "$configmap_data/benchmark.sh"
	ln -s "${configmap_data##*/}" "$configmap_root/..data"
	ln -s '..data/runmeta.sh' "$configmap_root/runmeta.sh"
	ln -s '..data/benchmark.sh' "$configmap_root/benchmark.sh"

	samples_file="$BATS_TEST_TMPDIR/samples.yaml"
	printf '%s\n' \
		'runtime:' \
		'  image: docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb' \
		'savingsSeed: 20260802' \
		'qualityPanel: []' \
		'savingsPanel: []' >"$samples_file"
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

# Catches a production break where prefix keys, failed attempts, or malformed
# rows are mistaken for exact successful rows and are incorrectly skipped.
@test "completed accepts only an exact row key whose status is passed" {
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	results="$BENCHMARK_OUT/runs/$run_id/results.csv"
	printf '%s\n' \
		'quality|abc123|detail|qsv|22-extra,passed' \
		'quality|abc123|detail|qsv|22,failed' \
		'quality|abc123|detail|qsv|23,invalid' \
		'malformed-row' >"$results"

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
	[ "$output" = 'identity mismatch: scriptDigests.benchmark.sh (stored=<redacted>, current=<redacted>)' ]
	[[ "$output" != *'ae253cad'* ]]
	cmp -s "$before" "$manifest"
	[ "$(file_mode "$manifest")" = '444' ]
	[ "$(run_directory_count)" -eq 1 ]

	run "$SCRIPTS/runmeta.sh" create quality "$run_id"
	[ "$status" -eq 1 ]
	[ "$output" = 'identity mismatch: scriptDigests.benchmark.sh (stored=<redacted>, current=<redacted>)' ]
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
	[ "$status" -eq 65 ]
	[ "$output" = "invalid run manifest: $manifest" ]
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
	[ "$status" -eq 65 ]
	[ "$output" = "invalid run manifest: $manifest" ]
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
	export BENCHMARK_TEST_MODE=0
	run "$SCRIPTS/runmeta.sh" create quality
	[ "$status" -eq 64 ]
	[ "$output" = 'BENCHMARK_IDENTITY_FIXTURE requires BENCHMARK_TEST_MODE=1' ]
	[ "$(run_directory_count)" -eq 0 ]
}

# Catches a production break where later command mappings are enabled before
# their behavior contracts land or runmeta remains pointed at the scaffold.
@test "ConfigMap maps only probe census and runmeta to real scripts" {
	kustomization="$SCRIPTS/../kustomization.yaml"
	run yq -r '.configMapGenerator[0].files | join(",")' "$kustomization"
	[ "$status" -eq 0 ]
	[ "$output" = 'probe.sh=scripts/probe.sh,census.sh=scripts/census.sh,runmeta.sh=scripts/runmeta.sh,benchmark.sh=scripts/not-ready.sh,stills.sh=scripts/not-ready.sh' ]
}
