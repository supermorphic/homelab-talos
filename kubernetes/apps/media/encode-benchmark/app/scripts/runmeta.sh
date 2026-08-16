#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_directory/contract.sh"
benchmark_out="${BENCHMARK_OUT:-/out}"
runs_root="$benchmark_out/runs"
test_mode="${BENCHMARK_TEST_MODE:-0}"
identity_fixture="${BENCHMARK_IDENTITY_FIXTURE:-}"
cpuinfo_file="${BENCHMARK_CPUINFO_FILE:-/proc/cpuinfo}"
clock_override="${BENCHMARK_NOW:-}"
dispatch_correlation_id="${BENCHMARK_DISPATCH_CORRELATION_ID:-}"
samples_file="${BENCHMARK_SAMPLES_FILE:-/config/samples.json}"
new_run_directory=''
manifest_temp=''
# The resume check validates results.csv against this schema. benchmark.sh holds
# the same list because it writes the file; an offline contract asserts the two
# stay identical, since a silent drift would make every resume decision wrong.
results_header='run_id,panel,sample_id,cohort,source_sha256,clip_id,encoder,requested_setting,selected_rate_control,status,attempt,input_bytes,output_bytes,reduction_percent,input_bit_rate,output_bit_rate,wall_seconds,encode_fps,encode_speed,vmaf_harmonic_mean,vmaf_1pct_low,ssim,gpu_busy_percent,qsv_proof,validation_codec,validation_duration,validation_resolution,validation_frame_rate,validation_bit_depth,validation_hdr,validation_audio_tracks,validation_subtitle_tracks,validation_chapters,validation_failures,log_path,output_disposition,strategy_id,qsv_initialization,video_busy_nanoseconds'

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
if [[ "$test_mode" != '1' && -n "${BENCHMARK_CPUINFO_FILE+x}" ]]; then
	echo 'BENCHMARK_CPUINFO_FILE requires BENCHMARK_TEST_MODE=1' >&2
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
	if [[ ! "$mode" =~ ^[a-z][a-z0-9-]*$ ]]; then
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
	contract_normalize_run_identity "$input_json" "$mode"
}

discover_identity() {
	local mode="$1"
	local script_directory configured_image dispatched_image running_image configured_digest dispatched_digest running_digest
	local samples_digest savings_seed execution_class selected_settings upstream_identity
	local script_digests='{}' sources='[]' encoder_commands node_name kernel i915 vpl cpu_model ffmpeg_version libx265_version
	local vmaf_model vmaf_version client_device source_json source_path source_size source_sha probe_log=''
	local savings_cohorts=''
	local source_index=0

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
	running_image="${BENCHMARK_RUNNING_IMAGE:-${BENCHMARK_RUNNING_IMAGE_DIGEST:-}}"
	running_digest="$(image_digest "$running_image")" || {
		echo 'running runtime image evidence is missing or malformed' >&2
		return 65
	}
	[[ "$configured_digest" == "$dispatched_digest" && "$configured_digest" == "$running_digest" ]] || {
		echo 'runtime image digests do not match' >&2
		return 65
	}
	samples_digest="$(sha256_file "$samples_file")"
	savings_seed="$(jq -r '.savingsSeed' "$samples_file")"
	if [[ -v BENCHMARK_SELECTED_SETTINGS_JSON ]]; then
		selected_settings="$BENCHMARK_SELECTED_SETTINGS_JSON"
	else
		selected_settings="$(jq -e -c '
			(.chosenSettings // {}) | to_entries |
			map({cohort: .key, globalQuality: (.value.globalQuality // null), qualityRunId: (.value.qualityRunId // null)}) |
			sort_by(.cohort)
		' "$samples_file")" || return 65
	fi
	selected_settings="$(contract_normalize_selected_settings "$selected_settings")" || {
		echo 'selected settings identity is malformed' >&2
		return 65
	}
	if [[ -v BENCHMARK_UPSTREAM_IDENTITY_JSON ]]; then
		upstream_identity="$BENCHMARK_UPSTREAM_IDENTITY_JSON"
	else
		upstream_identity='{}'
	fi
	jq -e -c 'type == "object"' <<<"$upstream_identity" >/dev/null || {
		echo 'upstream identity must be a JSON object' >&2
		return 65
	}
	execution_class="${BENCHMARK_EXECUTION_CLASS:-gpu}"
	[[ "$execution_class" == 'gpu' || "$execution_class" == 'cpu' ]] || {
		echo 'benchmark execution class must be gpu or cpu' >&2
		return 64
	}

	while IFS= read -r script_path; do
		[[ -n "$script_path" ]] || continue
		script_name="${script_path##*/}"
		script_sha="$(sha256_file "$script_path")"
		script_digests="$(jq -S -c --arg name "$script_name" --arg digest "$script_sha" \
			'. + {($name): $digest}' <<<"$script_digests")"
	done < <(find "$script_directory" -maxdepth 1 \( -type f -o -type l \) -name '*.sh' -print | LC_ALL=C sort)

	case "$mode" in
	quality) panel='.qualityPanel[]?' ;;
	x265)
		[[ "${BENCHMARK_X265_SAMPLE_ID:-}" =~ ^(avc-grain-memento|hdr10-grain-goodfellas)$ ]] || {
			echo 'x265 sample identity is missing or invalid' >&2
			return 65
		}
		panel='.qualityPanel[]? | select(.id == env.BENCHMARK_X265_SAMPLE_ID)'
		;;
	savings)
		if [[ -v BENCHMARK_SAVINGS_COHORTS_JSON ]]; then
			savings_cohorts="$BENCHMARK_SAVINGS_COHORTS_JSON"
			jq -e '
				type == "array" and length > 0 and length <= 3 and
				all(.[]; . == "avc" or . == "vc1" or . == "hdr10") and
				(unique | length) == length
			' <<<"$savings_cohorts" >/dev/null || {
				echo 'savings cohort identity is malformed' >&2
				return 65
			}
			panel='.savingsPanel[]? | select(.cohort as $cohort | ($cohorts | index($cohort)) != null)'
		else
			panel='.savingsPanel[]?'
		fi
		;;
	*) panel='(.qualityPanel[]?, .savingsPanel[]?)' ;;
	esac
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
		sources="$(jq -S -c \
			--arg path "$source_path" \
			--argjson size "$source_size" \
			--arg sha256 "$source_sha" \
			'. + [{path: $path, size: $size, sha256: $sha256}]' <<<"$sources")"
		((source_index += 1))
	done < <(
		if [[ -n "$savings_cohorts" ]]; then
			jq -c --argjson cohorts "$savings_cohorts" "$panel" "$samples_file"
		else
			jq -c "$panel" "$samples_file"
		fi
	)

	encoder_commands="${BENCHMARK_ENCODER_COMMANDS_JSON:-[]}"
	node_name="${NODE_NAME:-}"
	kernel="$(uname -r)"
	i915="${BENCHMARK_I915_VERSION:-}"
	vpl="${BENCHMARK_VPL_VERSION:-}"
	cpu_model="${BENCHMARK_CPU_MODEL:-}"
	ffmpeg_version="${BENCHMARK_FFMPEG_VERSION:-}"
	libx265_version="${BENCHMARK_LIBX265_VERSION:-}"
	if [[ "$execution_class" == 'cpu' && "$mode" == 'x265' ]]; then
		cpu_model="$(awk -F ':' '$1 ~ /^[[:space:]]*model name[[:space:]]*$/ {
			sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2); print $2; exit
		}' "$cpuinfo_file" 2>/dev/null || true)"
		ffmpeg_version="$(ffmpeg -nostdin -version 2>/dev/null | awk 'NR == 1 {print; exit}' || true)"
		probe_log="$(mktemp "${TMPDIR:-/tmp}/encode-benchmark-x265-probe.XXXXXX")" || return
		if ! ffmpeg -nostdin -v info -f lavfi -i 'color=size=16x16:rate=1' \
			-frames:v 1 -c:v libx265 -f null - >"$probe_log" 2>&1; then
			libx265_version=''
		else
			libx265_version="$(sed -n -E 's/^.*HEVC encoder version[[:space:]]+//p' "$probe_log" | head -n 1)"
		fi
		rm -f -- "$probe_log"
		probe_log=''
	fi
	if [[ "$execution_class" == 'gpu' && (-z "$i915" || -z "$vpl") ]]; then
		echo 'GPU runtime identity is incomplete' >&2
		return 65
	fi
	if [[ "$execution_class" == 'cpu' &&
		(-z "$cpu_model" || -z "$ffmpeg_version" || -z "$libx265_version" ||
		("$mode" == 'x265' && (-z "$node_name" || -z "$kernel"))) ]]; then
		echo 'CPU runtime identity is incomplete' >&2
		return 65
	fi
	vmaf_model="${BENCHMARK_VMAF_MODEL:-vmaf_4k_v0.6.1}"
	vmaf_version="${BENCHMARK_VMAF_VERSION:-}"
	client_device="${BENCHMARK_CLIENT_DEVICE:-}"

	jq -n -c \
		--arg mode "$mode" \
		--arg configured_digest "$configured_digest" --arg dispatched_digest "$dispatched_digest" \
		--arg running_digest "$running_digest" --arg strategy "$CONTRACT_STRATEGY_ID" \
		--argjson results_schema "$CONTRACT_RESULTS_SCHEMA" --argjson manifest_schema "$CONTRACT_MANIFEST_SCHEMA" \
		--argjson script_digests "$script_digests" \
		--arg samples_digest "$samples_digest" \
		--argjson sources "$sources" \
		--argjson encoder_commands "$encoder_commands" \
		--argjson selected_settings "$selected_settings" --argjson upstream "$upstream_identity" \
		--arg node_name "$node_name" \
		--arg kernel "$kernel" \
		--arg i915 "$i915" \
		--arg vpl "$vpl" \
		--arg execution_class "$execution_class" --arg cpu_model "$cpu_model" \
		--arg ffmpeg_version "$ffmpeg_version" --arg libx265_version "$libx265_version" \
		--arg vmaf_model "$vmaf_model" \
		--arg vmaf_version "$vmaf_version" \
		--argjson savings_seed "$savings_seed" \
		--arg client_device "$client_device" '
		{
			schemaVersion: $manifest_schema,
			strategyId: $strategy,
			resultsSchemaVersion: $results_schema,
			mode: $mode,
			images: {configured: $configured_digest, dispatched: $dispatched_digest, running: $running_digest},
			scriptDigests: $script_digests,
			samplesDigest: $samples_digest,
			sources: $sources,
			encoderCommands: $encoder_commands,
			selectedSettings: $selected_settings,
			upstream: $upstream,
			node: {name: $node_name, kernel: $kernel},
			gpu: (if $execution_class == "gpu" then {i915: $i915, vpl: $vpl} else null end),
			cpu: (if $execution_class == "cpu" then {model: $cpu_model, ffmpeg: $ffmpeg_version, libx265: $libx265_version} else null end),
			vmaf: {model: $vmaf_model, version: $vmaf_version},
			savingsSeed: $savings_seed,
			clientDevice: (if $client_device == "" then null else $client_device end)
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
	local identity='' identity_digest now run_id run_directory manifest
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
	mkdir -p "$runs_root"
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

completed_row() {
	local run_id="$1"
	local row_key="$2"
	local results
	validate_run_id "$run_id" || return
	if [[ ! "$row_key" =~ ^[^,\|]+\|[^,\|]+\|[^,\|]+\|[^,\|]+\|[^,\|]+$ ]]; then
		echo 'invalid result row key' >&2
		return 64
	fi
	results="$runs_root/$run_id/results.csv"
	[[ -f "$results" && ! -L "$results" ]] || return 1
	awk -v expected_run_id="$run_id" -v expected_key="$row_key" \
		-v expected_strategy="$CONTRACT_STRATEGY_ID" -v test_mode="$test_mode" -v header_spec="$results_header" \
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
			if (field[38] != "passed")
				invalid("invalid results CSV: row " record_no " has an invalid QSV initialization")
			if (field[39] !~ /^[0-9]+$/ || field[39] + 0 <= 0)
				invalid("invalid results CSV: row " record_no " has invalid QSV video busy time")
		}
		if (field[7] == "x265" && (field[38] != "not-applicable" || field[39] != "0"))
			invalid("invalid results CSV: row " record_no " has invalid x265 QSV evidence")
		if (field[7] == "x265") {
			if (field[2] != "x265" || field[9] != "CRF" ||
				field[8] !~ /^[0-9]+$/ || field[8] + 0 < 10 || field[8] + 0 > 34 || field[8] % 2 != 0)
				invalid("invalid results CSV: row " record_no " has an invalid x265 identity")
			if (field[24] != "not-applicable")
				invalid("invalid results CSV: row " record_no " has invalid x265 proof status")
			if (field[10] == "passed") {
				if (field[16] !~ /^[0-9]+([.][0-9]+)?$/ || field[16] + 0 <= 0 ||
					field[20] !~ /^[0-9]+([.][0-9]+)?$/ ||
					field[21] !~ /^[0-9]+([.][0-9]+)?$/ || field[22] != "" || field[23] != "")
					invalid("invalid results CSV: row " record_no " has invalid x265 metrics")
				for (validation_field = 25; validation_field <= 33; validation_field++)
					if (field[validation_field] != "passed")
						invalid("invalid results CSV: row " record_no " has incomplete x265 validation")
				if (field[34] != "" || field[36] != "discarded")
					invalid("invalid results CSV: row " record_no " has invalid x265 disposition")
			}
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
	' "$results"
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
