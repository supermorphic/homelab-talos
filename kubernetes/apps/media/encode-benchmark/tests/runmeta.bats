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
	quality_results_header_v3
}

results_row() {
	local run_id="$1" encoder="${2:-qsv}" strategy="${3:-qsv-hevc-icq-v1}"
	local initialization="${4:-passed}" busy="${5:-800000000}"
	local row
	[[ "$encoder" == 'qsv' ]] || return 64
	row="$(quality_evidence_row_v3 "$run_id" 22 passed "$strategy")"
	awk -F, -v initialization="$initialization" -v busy="$busy" \
		'BEGIN {OFS=FS} {$38=initialization; $39=busy; print}' <<<"$row"
}

quality_results_header_v3() {
	printf '%s\n' 'run_id,panel,sample_id,cohort,source_sha256,clip_id,encoder,requested_setting,selected_rate_control,status,attempt,input_bytes,output_bytes,reduction_percent,input_bit_rate,output_bit_rate,wall_seconds,encode_fps,encode_speed,vmaf_harmonic_mean,vmaf_1pct_low,ssim,gpu_busy_percent,qsv_proof,validation_codec,validation_duration,validation_resolution,validation_frame_rate,validation_bit_depth,validation_hdr,validation_audio_tracks,validation_subtitle_tracks,validation_chapters,validation_failures,log_path,output_disposition,strategy_id,qsv_initialization,video_busy_nanoseconds,quality_evidence_path,quality_evidence_sha256'
}

quality_evidence_row_v3() {
	local run_id="$1" setting="${2:-22}" row_status="${3:-passed}"
	local strategy="${4:-qsv-hevc-icq-v1}" evidence_path evidence_file evidence_digest
	evidence_path="quality-evidence/sample-avc-detail-qsv-$setting-attempt-1.json"
	evidence_file="$BENCHMARK_OUT/runs/$run_id/$evidence_path"
	mkdir -p "${evidence_file%/*}"
	jq -S -c -n --arg run "$run_id" --arg strategy "$strategy" --argjson setting "$setting" '{
		clipId:"detail",cohort:"avc",globalQuality:$setting,hdr:null,psnr:40,
		runId:$run,sampleId:"sample-avc",schemaVersion:1,sourceSha256:"abc123",
		ssim:0.99,strategyId:$strategy,
		vmaf:{rawFrameCount:100,evaluatedFrameCount:100,excludedFrames:[],harmonicMean:95,onePercentLow:90}
	}' >"$evidence_file"
	chmod 0600 "$evidence_file"
	evidence_digest="sha256:$(sha256sum "$evidence_file" | awk 'NR == 1 { print $1 }')"
	printf '%s\n' "$run_id,quality,sample-avc,avc,abc123,detail,qsv,$setting,ICQ,$row_status,1,100,50,50,1000,500,10,30,1.0,95,90,0.99,80,passed,hevc,10,1920x1080,24,10,passed,1,2,3,,logs/a.log,discarded,$strategy,passed,800000000,$evidence_path,$evidence_digest"
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

# Catches a production break where a bare create discovers and reuses an older
# identity instead of making the timestamped run an operator-held handle.
@test "no run id always creates a fresh timestamped immutable identity" {
	run "$SCRIPTS/runmeta.sh" create quality
	[ "$status" -eq 0 ]
	[ "$output" = '20260802T120000Z-f7a1c845' ]
	first="$output"
	first_manifest="$BENCHMARK_OUT/runs/$first/manifest.json"
	expected="$BATS_TEST_TMPDIR/expected-manifest.json"
	printf '%s\n' '{"createdAt":"20260802T120000Z","encoderCommands":[],"gpu":{"i915":"fixture-i915","vpl":"fixture-vpl"},"images":{"configured":"sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb","dispatched":"sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb","running":"sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb"},"mode":"quality","node":{"kernel":"","name":""},"resultsSchemaVersion":3,"samplesDigest":"sha256:9f4e2b20cfb4eaf89f18ba1a3f706d384c450f65a150df41d4e5d50b957f829e","schemaVersion":2,"scriptDigests":{},"sources":[],"strategyId":"qsv-hevc-icq-v1","vmaf":{"model":"vmaf_4k_v0.6.1","version":""}}' >"$expected"
	cmp -s "$expected" "$first_manifest"
	[ "$(file_mode "$first_manifest")" = '444' ]
	[ ! -e "$BENCHMARK_OUT/runs/$first/manifest.json.tmp" ]

	export BENCHMARK_NOW=20260802T120001Z
	run "$SCRIPTS/runmeta.sh" create quality
	[ "$status" -eq 0 ]
	[ "$output" = '20260802T120001Z-f7a1c845' ]
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

# Catches create treating an occupied matching directory as resumable, which
# would let a later command replace immutable evidence.
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

# Catches a symlinked run directory escaping the immutable run root.
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
	run_id='20260802T120000Z-c4b9c436'
	collision="$BENCHMARK_OUT/runs/$run_id"
	mkdir "$collision"

	run "$SCRIPTS/runmeta.sh" create quality
	[ "$status" -eq 73 ]
	[[ "$output" == *"run already exists: $run_id" ]]
	[ -d "$collision" ]
	[ "$(run_directory_count)" -eq 1 ]
}

@test "failed concurrent create preserves the winning run directory" {
	run_id='20260802T120000Z-c4b9c436'
	collision="$BENCHMARK_OUT/runs/$run_id"
	stub_bin="$BATS_TEST_TMPDIR/mkdir-bin"
	mkdir -p "$stub_bin"
	cat >"$stub_bin/mkdir" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if (($# == 1)) && [[ "$1" == */20260802T120000Z-c4b9c436 ]]; then
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
	quality_evidence_row_v3 "$run_id" 24 passed >>"$results"
	quality_evidence_row_v3 "$run_id" 22 failed >>"$results"
	quality_evidence_row_v3 "$run_id" 24 invalid >>"$results"

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

# Catches resume trusting a quality row after its bounded metric evidence is
# missing, redirected, changed, or rebound to a different row contract.
@test "quality evidence resume authenticates path digest identity and schema" {
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	results="$BENCHMARK_OUT/runs/$run_id/results.csv"
	quality_results_header_v3 >"$results"
	quality_evidence_row_v3 "$run_id" >>"$results"
	evidence="$BENCHMARK_OUT/runs/$run_id/quality-evidence/sample-avc-detail-qsv-22-attempt-1.json"
	baseline_results="$BATS_TEST_TMPDIR/quality-evidence-results.csv"
	baseline_evidence="$BATS_TEST_TMPDIR/quality-evidence.json"
	cp "$results" "$baseline_results"
	cp "$evidence" "$baseline_evidence"

	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
	[ "$status" -eq 0 ]

	for mutation in missing symlink escaping mutated wrong-row wrong-schema; do
		cp "$baseline_results" "$results"
		rm -f -- "$evidence"
		cp "$baseline_evidence" "$evidence"
		case "$mutation" in
		missing) rm -f -- "$evidence" ;;
		symlink)
			outside="$BATS_TEST_TMPDIR/outside-quality-evidence.json"
			cp "$baseline_evidence" "$outside"
			rm -f -- "$evidence"
			ln -s "$outside" "$evidence"
			;;
		escaping)
			awk -F, 'BEGIN {OFS=FS} NR == 2 {$40="../quality-evidence.json"} {print}' \
				"$results" >"$results.tmp"
			mv -f -- "$results.tmp" "$results"
			;;
		mutated) printf '%s\n' 'changed' >>"$evidence" ;;
		wrong-row)
			jq -S -c '.sampleId = "other-sample"' "$baseline_evidence" >"$evidence"
			digest="sha256:$(sha256sum "$evidence" | awk 'NR == 1 { print $1 }')"
			awk -F, -v digest="$digest" 'BEGIN {OFS=FS} NR == 2 {$41=digest} {print}' \
				"$results" >"$results.tmp"
			mv -f -- "$results.tmp" "$results"
			;;
		wrong-schema)
			jq -S -c '.schemaVersion = 2' "$baseline_evidence" >"$evidence"
			digest="sha256:$(sha256sum "$evidence" | awk 'NR == 1 { print $1 }')"
			awk -F, -v digest="$digest" 'BEGIN {OFS=FS} NR == 2 {$41=digest} {print}' \
				"$results" >"$results.tmp"
			mv -f -- "$results.tmp" "$results"
			;;
		esac
		run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
		[ "$status" -eq 65 ] || {
			echo "resume accepted $mutation quality evidence: status=$status output=$output" >&3
			return 1
		}
	done
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
	[ "$output" = 'invalid results CSV: row 2 has 10 columns; expected 41' ]
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
	row="$(quality_evidence_row_v3 "$run_id")"
	evidence_path="$(awk -F, '{print $40}' <<<"$row")"
	evidence_digest="$(awk -F, '{print $41}' <<<"$row")"
	printf '%s\n' "$run_id,quality,sample-avc,avc,abc123,detail,qsv,22,ICQ,passed,1,100,50,50,1000,500,10,30,1.0,95,90,0.99,80,passed,hevc,10,1920x1080,24,10,passed,1,2,3,\"none, verified\",\"logs/a,b.log\",discarded,qsv-hevc-icq-v1,passed,800000000,$evidence_path,$evidence_digest" >>"$results"

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
	results_row "$run_id" | cut -d, -f1-36,40-41 >>"$results"

	run "$SCRIPTS/runmeta.sh" completed "$run_id" 'quality|abc123|detail|qsv|22'
	[ "$status" -eq 65 ]
	[ "$output" = 'invalid results CSV: row 2 has 38 columns; expected 41' ]

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
		quality_evidence_row_v3 "$run_id" "$setting" passed >>"$results"
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

# Catches an incomplete stored identity being accepted as exact.
@test "verify rejects a stored manifest with a missing canonical identity field" {
	run_id="$($SCRIPTS/runmeta.sh create quality)"
	manifest="$BENCHMARK_OUT/runs/$run_id/manifest.json"
	tampered="$BATS_TEST_TMPDIR/tampered-manifest.json"
	jq -S -c 'del(.gpu)' "$manifest" >"$tampered"
	chmod 0444 "$tampered"
	mv -f "$tampered" "$manifest"

	run "$SCRIPTS/runmeta.sh" verify "$run_id"
	[ "$status" -eq 1 ]
	[ "$output" = $'identity mismatch: gpu (stored=<missing>, current=<redacted>)\nidentity mismatch: gpu.i915 (stored=<missing>, current=<redacted>)\nidentity mismatch: gpu.vpl (stored=<missing>, current=<redacted>)' ]
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

# Catches a live GPU run publishing a manifest without its runtime identity.
@test "discovery requires execution-class runtime identities" {
	prepare_configmap_script_mount
	unset BENCHMARK_I915_VERSION
	run "$configmap_root/runmeta.sh" create quality
	[ "$status" -eq 65 ]
	[ "$output" = 'GPU runtime identity is incomplete' ]
}

# Catches an unknown field widening the exact stored quality identity.
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

	run "$SCRIPTS/runmeta.sh" create capabilities "$run_id"
	[ "$status" -eq 65 ]
	[ "$output" = 'identity mismatch: mode (stored=quality, current=capabilities)' ]
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
# scaffold after all seven behavior contracts have landed.
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
	[ "$(awk -F, '{print NF}' <<<"$runmeta_header")" -eq 41 ]
}
