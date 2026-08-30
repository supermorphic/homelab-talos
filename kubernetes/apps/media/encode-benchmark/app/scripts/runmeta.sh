#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_directory/contract.sh"
benchmark_out="${BENCHMARK_OUT:-/out}"
runs_root="$benchmark_out/runs"
test_mode="${BENCHMARK_TEST_MODE:-0}"
identity_fixture="${BENCHMARK_IDENTITY_FIXTURE:-}"
clock_override="${BENCHMARK_NOW:-}"
dispatch_correlation_id="${BENCHMARK_DISPATCH_CORRELATION_ID:-}"
samples_file="${BENCHMARK_SAMPLES_FILE:-/config/samples.json}"
new_run_directory=''
manifest_temp=''
# The resume check validates results.csv against this schema. benchmark.sh holds
# the same list because it writes the file; an offline contract asserts the two
# stay identical, since a silent drift would make every resume decision wrong.
results_header='run_id,panel,sample_id,cohort,source_sha256,clip_id,encoder,requested_setting,selected_rate_control,status,attempt,input_bytes,output_bytes,reduction_percent,input_bit_rate,output_bit_rate,wall_seconds,encode_fps,encode_speed,vmaf_harmonic_mean,vmaf_1pct_low,ssim,gpu_busy_percent,qsv_proof,validation_codec,validation_duration,validation_resolution,validation_frame_rate,validation_bit_depth,validation_hdr,validation_audio_tracks,validation_subtitle_tracks,validation_chapters,validation_failures,log_path,output_disposition,strategy_id,qsv_initialization,video_busy_nanoseconds,quality_evidence_path,quality_evidence_sha256'

if [[ "$test_mode" != '1' && -n "${BENCHMARK_OUT+x}" ]]; then
	echo 'BENCHMARK_OUT requires BENCHMARK_TEST_MODE=1' >&2
	exit 64
fi
if [[ "$test_mode" != '1' && -n "${BENCHMARK_SAMPLES_FILE+x}" ]]; then
	echo 'BENCHMARK_SAMPLES_FILE requires BENCHMARK_TEST_MODE=1' >&2
	exit 64
fi
if [[ "$test_mode" != '1' && -n "${BENCHMARK_IDENTITY_FIXTURE+x}" ]]; then
	echo 'BENCHMARK_IDENTITY_FIXTURE requires BENCHMARK_TEST_MODE=1' >&2
	exit 64
fi
if [[ "$test_mode" != '1' && -n "${BENCHMARK_NOW+x}" ]]; then
	echo 'BENCHMARK_NOW requires BENCHMARK_TEST_MODE=1' >&2
	exit 64
fi
contract_load "$samples_file" || exit $?

cleanup_unpublished_manifest() {
	if [[ -n "$manifest_temp" ]]; then
		rm -f -- "$manifest_temp"
	fi
	if [[ -n "$new_run_directory" ]]; then
		rmdir -- "$new_run_directory" 2>/dev/null || true
	fi
}
trap cleanup_unpublished_manifest EXIT

usage() {
	echo 'usage: runmeta.sh create <mode> [run-id] | verify <run-id> | completed <run-id> <row-key>' >&2
	exit 64
}

validate_run_id() {
	local run_id="$1"
	if ! contract_is_run_id "$run_id"; then
		echo "invalid run id: $run_id" >&2
		return 64
	fi
}

validate_mode() {
	local mode="$1"
	if [[ "$mode" != 'capabilities' && "$mode" != 'quality' ]]; then
		echo "invalid benchmark mode: $mode" >&2
		return 64
	fi
}

sha256_file() {
	local path="$1"
	printf 'sha256:%s\n' "$(sha256sum "$path" | awk 'NR == 1 { value = $1; sub(/^\\/, "", value); print value }')"
}

image_digest() {
	local image="$1"
	if [[ "$image" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
		printf '%s\n' "${image##*@}"
	elif [[ "$image" =~ ^sha256:[0-9a-f]{64}$ ]]; then
		printf '%s\n' "$image"
	else
		return 65
	fi
}

normalize_identity() {
	local input_json="$1"
	local mode="$2"
	local output status
	set +e
	output="$(contract_normalize_run_identity "$input_json" "$mode" 2>&1)"
	status=$?
	set -e
	if [[ "$status" -ne 0 ]]; then
		printf '%s\n' "$output" >&2
		return "$status"
	fi
	printf '%s\n' "$output"
}

discover_identity() {
	local mode="$1"
	local script_directory configured_image dispatched_image running_image
	local configured_digest dispatched_digest running_digest samples_digest
	local script_digests='{}' sources='[]' encoder_commands node_name kernel i915 vpl
	local vmaf_model vmaf_version source_json source_path source_size source_sha source_index=0

	if [[ -n "$identity_fixture" ]]; then
		[[ "$test_mode" == '1' ]] || {
			echo 'BENCHMARK_IDENTITY_FIXTURE requires BENCHMARK_TEST_MODE=1' >&2
			return 64
		}
		[[ -f "$identity_fixture" ]] || {
			echo "identity fixture not found: $identity_fixture" >&2
			return 66
		}
		normalize_identity "$(jq -c . "$identity_fixture")" "$mode"
		return
	fi

	[[ -f "$samples_file" ]] || {
		echo "samples configuration not found: $samples_file" >&2
		return 66
	}
	script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	configured_image="$(jq -e -r '.runtime.image | strings' "$samples_file")" || return 65
	configured_digest="$(image_digest "$configured_image")" || {
		echo 'configured runtime image must use an immutable sha256 digest' >&2
		return 65
	}
	dispatched_image="${BENCHMARK_DISPATCH_IMAGE:-}"
	dispatched_digest="$(image_digest "$dispatched_image")" || {
		echo 'dispatched runtime image evidence is missing or malformed' >&2
		return 65
	}
	running_image="${BENCHMARK_RUNNING_IMAGE:-}"
	running_digest="$(image_digest "$running_image")" || {
		echo 'running runtime image evidence is missing or malformed' >&2
		return 65
	}
	[[ "$configured_digest" == "$dispatched_digest" && "$configured_digest" == "$running_digest" ]] || {
		echo 'runtime image digests do not match' >&2
		return 65
	}
	samples_digest="$(sha256_file "$samples_file")"

	while IFS= read -r script_path; do
		[[ -n "$script_path" ]] || continue
		script_name="${script_path##*/}"
		script_sha="$(sha256_file "$script_path")"
		script_digests="$(jq -S -c --arg name "$script_name" --arg digest "$script_sha" \
			'. + {($name): $digest}' <<<"$script_digests")"
	done < <(find "$script_directory" -maxdepth 1 \( -type f -o -type l \) -name '*.sh' -print | LC_ALL=C sort)

	if [[ "$mode" == 'quality' ]]; then
		while IFS= read -r source_json; do
			[[ -n "$source_json" ]] || continue
			source_path="$(jq -r '.path' <<<"$source_json")"
			[[ -f "$source_path" ]] || {
				printf 'identity unavailable: sources.%s.path (stored=<redacted>, current=<unavailable>)\n' \
					"$source_index" >&2
				return 66
			}
			source_size="$(wc -c <"$source_path" | tr -d '[:space:]')"
			source_sha="$(sha256_file "$source_path")"
			sources="$(jq -S -c --arg path "$source_path" --argjson size "$source_size" \
				--arg sha256 "$source_sha" '. + [{path:$path,size:$size,sha256:$sha256}]' <<<"$sources")"
			((source_index += 1))
		done < <(jq -c '.qualityPanel[]?' "$samples_file")
	fi

	encoder_commands="${BENCHMARK_ENCODER_COMMANDS_JSON:-[]}"
	node_name="${NODE_NAME:-}"
	kernel="$(uname -r)"
	i915="${BENCHMARK_I915_VERSION:-}"
	vpl="${BENCHMARK_VPL_VERSION:-}"
	[[ -n "$i915" && -n "$vpl" ]] || {
		echo 'GPU runtime identity is incomplete' >&2
		return 65
	}
	vmaf_model="${BENCHMARK_VMAF_MODEL:-vmaf_4k_v0.6.1}"
	vmaf_version="${BENCHMARK_VMAF_VERSION:-}"

	jq -n -c \
		--arg mode "$mode" \
		--arg configured_digest "$configured_digest" --arg dispatched_digest "$dispatched_digest" \
		--arg running_digest "$running_digest" --arg strategy "$CONTRACT_STRATEGY_ID" \
		--argjson results_schema "$CONTRACT_RESULTS_SCHEMA" --argjson manifest_schema "$CONTRACT_MANIFEST_SCHEMA" \
		--argjson script_digests "$script_digests" --arg samples_digest "$samples_digest" \
		--argjson sources "$sources" --argjson encoder_commands "$encoder_commands" \
		--arg node_name "$node_name" --arg kernel "$kernel" --arg i915 "$i915" --arg vpl "$vpl" \
		--arg vmaf_model "$vmaf_model" --arg vmaf_version "$vmaf_version" '{
			schemaVersion:$manifest_schema,strategyId:$strategy,resultsSchemaVersion:$results_schema,
			mode:$mode,images:{configured:$configured_digest,dispatched:$dispatched_digest,running:$running_digest},
			scriptDigests:$script_digests,samplesDigest:$samples_digest,sources:$sources,
			encoderCommands:$encoder_commands,node:{name:$node_name,kernel:$kernel},
			gpu:{i915:$i915,vpl:$vpl},vmaf:{model:$vmaf_model,version:$vmaf_version}
		}' | normalize_identity "$(cat)" "$mode"
}

print_identity_diff() {
	local stored="$1"
	local current="$2"
	local path stored_present current_present stored_mode current_mode stored_value current_value
	while IFS=$'\t' read -r path stored_present current_present; do
		[[ -n "$path" ]] || continue
		if [[ "$path" == 'mode' && "$stored_present" == 'true' && "$current_present" == 'true' ]]; then
			stored_mode="$(jq -r '.mode' <<<"$stored")"
			current_mode="$(jq -r '.mode' <<<"$current")"
			printf 'identity mismatch: mode (stored=%s, current=%s)\n' "$stored_mode" "$current_mode" >&2
		else
			if [[ "$stored_present" == 'true' ]]; then
				stored_value='<redacted>'
			else
				stored_value='<missing>'
			fi
			if [[ "$current_present" == 'true' ]]; then
				current_value='<redacted>'
			else
				current_value='<missing>'
			fi
			printf 'identity mismatch: %s (stored=%s, current=%s)\n' \
				"$path" "$stored_value" "$current_value" >&2
		fi
	done < <(jq -n -r --argjson stored "$stored" --argjson current "$current" '
		def key_nodes($side; $path):
			if type == "object" or type == "array" then
				to_entries[] as $entry
				| {side: $side, path: ($path + [$entry.key])},
					($entry.value | key_nodes($side; $path + [$entry.key]))
			else empty end;
		def leaves($side; $path):
			if type == "object" or type == "array" then
				to_entries[] as $entry
				| $entry.value | leaves($side; $path + [$entry.key])
			else {side: $side, path: $path, value: .} end;
		[
			($stored | key_nodes("stored"; [])),
			($current | key_nodes("current"; []))
		] as $nodes
		| [
			$nodes
			| group_by(.path)[]
			| select((map(.side) | unique | length) != 2)
			| .[0].path
		] as $key_differences
		| [
			($stored | leaves("stored"; [])),
			($current | leaves("current"; []))
		]
		| group_by(.path)
		| map(select(
			(map(.side) | unique | length) != 2 or
			(length == 2 and .[0].value != .[1].value)
		) | .[0].path) as $leaf_differences
		| ($key_differences + $leaf_differences | unique)[] as $path
		| [
			($path | map(tostring) | join(".")),
			(any($nodes[]; .side == "stored" and .path == $path) | tostring),
			(any($nodes[]; .side == "current" and .path == $path) | tostring)
		]
		| @tsv
	')
}

stored_identity() {
	local manifest="$1"
	local stored_mode identity created_at
	if ! identity="$(jq -e -S -c 'del(.createdAt)' "$manifest" 2>/dev/null)"; then
		echo 'identity mismatch: manifest (stored=<malformed>, current=<redacted>)' >&2
		return 1
	fi
	created_at="$(jq -e -r '.createdAt | strings' "$manifest" 2>/dev/null)" || true
	if ! contract_is_compact_utc_timestamp "$created_at"; then
		echo 'identity mismatch: createdAt (stored=<redacted>, current=<ignored>)' >&2
		return 1
	fi
	stored_mode="$(jq -e -r '.mode | select(type == "string")' "$manifest")" || {
		if jq -e 'has("mode")' "$manifest" >/dev/null; then
			echo 'identity mismatch: mode (stored=<redacted>, current=<redacted>)' >&2
		else
			echo 'identity mismatch: mode (stored=<missing>, current=<redacted>)' >&2
		fi
		return 1
	}
	printf '%s\n' "$identity"
}

verify_run() {
	local run_id="$1"
	local requested_mode="${2:-}"
	local manifest stored mode current
	validate_run_id "$run_id" || return
	manifest="$runs_root/$run_id/manifest.json"
	[[ -f "$manifest" && ! -L "$manifest" ]] || {
		echo "run manifest not found: $run_id" >&2
		return 66
	}
	stored="$(stored_identity "$manifest")" || return
	mode="$(jq -r '.mode' <<<"$stored")"
	if [[ -n "$requested_mode" && "$mode" != "$requested_mode" ]]; then
		printf 'identity mismatch: mode (stored=%s, current=%s)\n' "$mode" "$requested_mode" >&2
		return 65
	fi
	if [[ -n "$requested_mode" ]]; then
		mode="$requested_mode"
	fi
	current="$(discover_identity "$mode")" || return
	if [[ "$stored" != "$current" ]]; then
		print_identity_diff "$stored" "$current"
		return 1
	fi
}

create_run() {
	local mode="$1"
	local explicit_run_id="${2:-}"
	local identity='' identity_digest now run_id run_directory manifest out_physical runs_physical
	validate_mode "$mode" || return
	if [[ -n "$explicit_run_id" ]]; then
		validate_run_id "$explicit_run_id" || return
		now="${explicit_run_id%-*}"
		if [[ -n "$dispatch_correlation_id" ]]; then
			[[ "$mode" == 'quality' && "$explicit_run_id" == "$dispatch_correlation_id" ]] || {
				echo 'dispatch correlation is valid only for its generated quality run' >&2
				return 64
			}
			validate_run_id "$dispatch_correlation_id" || return
			identity="$(discover_identity "$mode")" || return
			identity_digest="$(printf '%s\n' "$identity" | sha256sum | awk '{print substr($1, 1, 8)}')"
			run_id="$now-$identity_digest"
		else
			run_id="$explicit_run_id"
		fi
		run_directory="$runs_root/$run_id"
		if [[ -L "$run_directory" || (-e "$run_directory" && ! -d "$run_directory") ]]; then
			echo "run path is not a confined directory: $run_id" >&2
			return 73
		fi
		if [[ -d "$run_directory" ]]; then
			if [[ ! -f "$run_directory/manifest.json" || -L "$run_directory/manifest.json" ]]; then
				echo "run already exists without a manifest: $run_id" >&2
				return 73
			fi
			verify_run "$run_id" "$mode" || return
			printf '%s\n' "$run_id"
			return
		fi
		if [[ -z "$identity" ]]; then
			identity="$(discover_identity "$mode")" || return
		fi
	else
		identity="$(discover_identity "$mode")" || return
		identity_digest="$(printf '%s\n' "$identity" | sha256sum | awk '{print substr($1, 1, 8)}')"
		if [[ -n "$clock_override" ]]; then
			[[ "$test_mode" == '1' ]] || {
				echo 'BENCHMARK_NOW requires BENCHMARK_TEST_MODE=1' >&2
				return 64
			}
			now="$clock_override"
		else
			now="$(date -u '+%Y%m%dT%H%M%SZ')"
		fi
		contract_is_compact_utc_timestamp "$now" || {
			echo "invalid benchmark timestamp: $now" >&2
			return 64
		}
		run_id="$now-$identity_digest"
	fi
	[[ -d "$benchmark_out" && ! -L "$benchmark_out" ]] || {
		echo 'benchmark output hierarchy is not confined' >&2
		return 65
	}
	out_physical="$(cd -P "$benchmark_out" && pwd)"
	if [[ -e "$runs_root" || -L "$runs_root" ]]; then
		[[ -d "$runs_root" && ! -L "$runs_root" ]] || {
			echo 'benchmark runs hierarchy is not confined' >&2
			return 65
		}
	else
		mkdir "$runs_root" || return
	fi
	runs_physical="$(cd -P "$runs_root" && pwd)"
	[[ "$runs_physical" == "$out_physical/runs" ]] || {
		echo 'benchmark runs hierarchy is not confined' >&2
		return 65
	}
	run_directory="$runs_root/$run_id"
	if ! mkdir "$run_directory"; then
		echo "run already exists: $run_id" >&2
		return 73
	fi
	new_run_directory="$run_directory"
	manifest="$new_run_directory/manifest.json"
	manifest_temp="$new_run_directory/manifest.json.tmp"
	umask 022
	jq -S -c --arg created_at "$now" '. + {createdAt: $created_at}' <<<"$identity" >"$manifest_temp"
	chmod 0444 "$manifest_temp"
	mv "$manifest_temp" "$manifest"
	manifest_temp=''
	new_run_directory=''
	printf '%s\n' "$run_id"
}

validate_completed_quality_evidence() {
	local run_id="$1" row_number="$2" sample_id="$3" cohort="$4" source_sha="$5"
	local clip_id="$6" setting="$7" status="$8" vmaf_harmonic="$9" vmaf_low="${10}"
	local ssim="${11}" validation_hdr="${12}" evidence_path="${13}" evidence_digest="${14}"
	local run_directory evidence_directory evidence_file expected_path actual_digest
	run_directory="$runs_root/$run_id"
	evidence_directory="$run_directory/quality-evidence"
	expected_path="quality-evidence/$sample_id-$clip_id-qsv-$setting-attempt-${15}.json"
	if [[ ! "$sample_id" =~ ^[a-z0-9][a-z0-9._-]*$ || ! "$clip_id" =~ ^[a-z0-9][a-z0-9._-]*$ ||
		"$evidence_path" != "$expected_path" || ! "$evidence_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
		echo "invalid results CSV: row $row_number has an unsafe quality evidence reference" >&2
		return 65
	fi
	if [[ ! -d "$run_directory" || -L "$run_directory" || ! -d "$evidence_directory" ||
		-L "$evidence_directory" ]]; then
		echo "invalid results CSV: row $row_number quality evidence directory is not confined" >&2
		return 65
	fi
	evidence_file="$run_directory/$evidence_path"
	if [[ ! -f "$evidence_file" || -L "$evidence_file" ]] ||
		[[ "$(realpath "$evidence_file")" != "$(cd -P "$run_directory" && pwd)/$evidence_path" ]]; then
		echo "invalid results CSV: row $row_number quality evidence is not a regular confined file" >&2
		return 65
	fi
	actual_digest="$(sha256_file "$evidence_file")"
	if [[ "$actual_digest" != "$evidence_digest" ]]; then
		echo "invalid results CSV: row $row_number quality evidence digest does not match" >&2
		return 65
	fi
	if ! jq -e \
		--arg run "$run_id" --arg sample "$sample_id" --arg cohort "$cohort" \
		--arg source_sha "$source_sha" --arg clip "$clip_id" --argjson setting "$setting" \
		--arg row_status "$status" --arg vmaf_harmonic "$vmaf_harmonic" \
		--arg vmaf_low "$vmaf_low" --arg ssim "$ssim" --arg validation_hdr "$validation_hdr" \
		--arg strategy "$CONTRACT_STRATEGY_ID" --argjson schema "$CONTRACT_QUALITY_EVIDENCE_SCHEMA" '
		def exact_keys($wanted): type == "object" and ((keys | sort) == ($wanted | sort));
		def finite_number: type == "number" and isfinite;
		def nonnegative_integer: finite_number and floor == . and . >= 0;
		def excluded_frame:
			exact_keys(["frameIndex","vmaf"]) and
			(.frameIndex | nonnegative_integer) and .vmaf == 0;
		exact_keys(["clipId","cohort","globalQuality","hdr","psnr","runId","sampleId",
			"schemaVersion","sourceSha256","ssim","strategyId","vmaf"]) and
		.schemaVersion == $schema and .strategyId == $strategy and .runId == $run and
		.sampleId == $sample and .cohort == $cohort and .sourceSha256 == $source_sha and
		.clipId == $clip and .globalQuality == $setting and
		(.ssim | finite_number) and .ssim == ($ssim | tonumber) and
		(.psnr | finite_number) and
		(.vmaf |
			exact_keys(["evaluatedFrameCount","excludedFrames","harmonicMean","onePercentLow","rawFrameCount"]) and
			(.rawFrameCount | nonnegative_integer and . > 0) and
			(.evaluatedFrameCount | nonnegative_integer and . > 0) and
			(.excludedFrames | type == "array" and length <= 1 and all(.[]; excluded_frame)) and
			.evaluatedFrameCount == (.rawFrameCount - (.excludedFrames | length)) and
			(.harmonicMean | finite_number) and .harmonicMean == ($vmaf_harmonic | tonumber) and
			(.onePercentLow | finite_number) and .onePercentLow == ($vmaf_low | tonumber)) and
		(if $cohort == "hdr10" then
			(.hdr |
				exact_keys(["classification","normalizedOracle","reasons"]) and
				(.classification as $classification |
					["preserved","source-oracle-defect","clip-boundary-defect","encoder-output-defect"] |
					index($classification)) != null and
				(.reasons | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)) and
				(.normalizedOracle | type == "object")) and
			(if $row_status == "passed" then
				$validation_hdr == "passed" and .hdr.classification == "preserved"
			else true end)
		else .hdr == null end)
	' "$evidence_file" >/dev/null; then
		echo "invalid results CSV: row $row_number quality evidence does not match the result" >&2
		return 65
	fi
}

completed_row() {
	local run_id="$1"
	local row_key="$2"
	local results evidence_rows parse_status=0
	validate_run_id "$run_id" || return
	if [[ ! "$row_key" =~ ^[^,\|]+\|[^,\|]+\|[^,\|]+\|[^,\|]+\|[^,\|]+$ ]]; then
		echo 'invalid result row key' >&2
		return 64
	fi
	results="$runs_root/$run_id/results.csv"
	[[ -f "$results" && ! -L "$results" ]] || return 1
	set +e
	evidence_rows="$(awk -v expected_run_id="$run_id" -v expected_key="$row_key" \
		-v expected_strategy="$CONTRACT_STRATEGY_ID" -v expected_icq_settings="$CONTRACT_ICQ_SETTINGS" \
		-v test_mode="$test_mode" -v header_spec="$results_header" \
		'
	# RFC4180 reader for the resume check. The runtime image has mawk, not gawk, so
	# FPAT is unavailable and quoted fields must be parsed by hand. Two numbering
	# schemes are deliberate and match the contract: a malformed record is reported
	# by physical line, a validated record by record number with the header as 1.
	function invalid(message) {
		print message >"/dev/stderr"
		aborted = 1
		exit 65
	}

	function flush_field() {
		nf += 1
		field[nf] = cur
		cur = ""
	}

	function reset_record() {
		for (i = 1; i <= nf; i++) delete field[i]
		nf = 0
		cur = ""
	}

	function is_icq_setting(value,   settings, count, position) {
		count = split(expected_icq_settings, settings, " ")
		for (position = 1; position <= count; position++)
			if (value == settings[position]) return 1
		return 0
	}

	function process_record(   candidate, part, bad) {
		record_no += 1
		if (record_no == 1) {
			header_ok = (nf == expected_columns)
			for (i = 1; i <= nf; i++)
				if (field[i] != expected_header[i]) header_ok = 0
			if (!header_ok) invalid("invalid results CSV header")
			return
		}

		if (record_no == 1) return

		if (nf != expected_columns)
			invalid("invalid results CSV: row " record_no " has " nf \
				" columns; expected " expected_columns)
		if (field[1] != expected_run_id)
			invalid("invalid results CSV: row " record_no " has a mismatched run id")
		if (field[10] != "passed" && field[10] != "failed" && field[10] != "invalid")
			invalid("invalid results CSV: row " record_no " has an invalid status")
		if (field[11] !~ /^[0-9]+$/ || field[11] + 0 < 1)
			invalid("invalid results CSV: row " record_no " has an invalid attempt")
		if (field[37] != expected_strategy)
			invalid("invalid results CSV: row " record_no " has a mismatched strategy")
		if (field[7] == "qsv" && field[10] == "passed") {
			if (!is_icq_setting(field[8]))
				invalid("invalid results CSV: row " record_no " has an invalid ICQ setting")
			if (field[9] != "ICQ")
				invalid("invalid results CSV: row " record_no " has an invalid QSV rate control")
			if (field[24] != "passed")
				invalid("invalid results CSV: row " record_no " has an invalid QSV proof")
			if (field[38] != "passed")
				invalid("invalid results CSV: row " record_no " has an invalid QSV initialization")
			if (field[39] !~ /^[0-9]+$/ || field[39] + 0 <= 0)
				invalid("invalid results CSV: row " record_no " has invalid QSV video busy time")
		}
		if (field[2] == "quality") {
			if (field[7] != "qsv")
				invalid("invalid results CSV: row " record_no " has an invalid quality encoder")
			expected_evidence = "quality-evidence/" field[3] "-" field[6] "-qsv-" \
				field[8] "-attempt-" field[11] ".json"
			if (field[3] !~ /^[a-z0-9][a-z0-9._-]*$/ || field[6] !~ /^[a-z0-9][a-z0-9._-]*$/ ||
				field[40] != expected_evidence || field[41] !~ /^sha256:[0-9a-f]{64}$/)
				invalid("invalid results CSV: row " record_no " has an unsafe quality evidence reference")
			printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
				record_no, field[3], field[4], field[5], field[6], field[8], field[10], \
				field[20], field[21], field[22], field[30], field[40], field[41], field[11]
		} else if (field[40] != "" || field[41] != "") {
			invalid("invalid results CSV: row " record_no " has unexpected quality evidence")
		}

		bad = 0
		candidate = ""
		for (k = 1; k <= 5; k++) {
			part = field[key_index[k]]
			if (part == "" || index(part, "|") > 0) bad = 1
			candidate = (k == 1) ? part : candidate "|" part
		}
		if (bad) invalid("invalid results CSV: row " record_no " has an invalid row key")
		if (candidate == expected_key && field[10] == "passed") found = 1
	}

	BEGIN {
		split(header_spec, expected_header, ",")
		expected_columns = 0
		for (i in expected_header) expected_columns += 1
		# panel, source_sha256, clip_id, encoder, requested_setting
		key_index[1] = 2; key_index[2] = 5; key_index[3] = 6
		key_index[4] = 7; key_index[5] = 8
		record_no = 0
		nf = 0
		cur = ""
		in_quotes = 0
		found = 0
		saw_record = 0
	}

	{
		line_no += 1
		line = $0
		len = length(line)
		pos = 1
		while (pos <= len) {
			c = substr(line, pos, 1)
			if (in_quotes) {
				if (c == "\"") {
					if (substr(line, pos + 1, 1) == "\"") { cur = cur "\""; pos += 2; continue }
					in_quotes = 0
					pos += 1
					continue
				}
				cur = cur c
				pos += 1
				continue
			}
			if (c == "\"" && cur == "") { in_quotes = 1; pos += 1; continue }
			if (c == ",") { flush_field(); pos += 1; continue }
			cur = cur c
			pos += 1
		}
		if (in_quotes) { cur = cur "\n"; next }
		flush_field()
		saw_record = 1
		process_record()
		reset_record()
	}

	END {
		# awk runs END even after exit, so the abort status must survive it.
		if (aborted) exit 65
		if (in_quotes) invalid("invalid results CSV: malformed row " line_no)
		if (!saw_record) exit 1
		exit (found ? 0 : 1)
	}
	' "$results")"
	parse_status=$?
	set -e
	if ((parse_status != 0 && parse_status != 1)); then return "$parse_status"; fi
	while IFS=$'\t' read -r row_number sample_id cohort source_sha clip_id setting row_status \
		vmaf_harmonic vmaf_low ssim validation_hdr evidence_path evidence_digest attempt; do
		[[ -n "$row_number" ]] || continue
		validate_completed_quality_evidence "$run_id" "$row_number" "$sample_id" "$cohort" \
			"$source_sha" "$clip_id" "$setting" "$row_status" "$vmaf_harmonic" "$vmaf_low" \
			"$ssim" "$validation_hdr" "$evidence_path" "$evidence_digest" "$attempt" || return
	done <<<"$evidence_rows"
	return "$parse_status"
}

(($# >= 1)) || usage
action="$1"
shift
case "$action" in
create)
	(($# == 1 || $# == 2)) || usage
	create_run "$@"
	;;
verify)
	(($# == 1)) || usage
	verify_run "$1"
	;;
completed)
	(($# == 2)) || usage
	completed_row "$1" "$2"
	;;
*) usage ;;
esac
