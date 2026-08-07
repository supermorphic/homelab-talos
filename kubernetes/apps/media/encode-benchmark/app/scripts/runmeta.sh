#!/usr/bin/env bash
set -euo pipefail

benchmark_out="${BENCHMARK_OUT:-/out}"
runs_root="$benchmark_out/runs"
test_mode="${BENCHMARK_TEST_MODE:-0}"
identity_fixture="${BENCHMARK_IDENTITY_FIXTURE:-}"
clock_override="${BENCHMARK_NOW:-}"
new_run_directory=''
manifest_temp=''

if [[ "$test_mode" != '1' && -n "${BENCHMARK_OUT+x}" ]]; then
	echo 'BENCHMARK_OUT requires BENCHMARK_TEST_MODE=1' >&2
	exit 64
fi
if [[ "$test_mode" != '1' && -n "${BENCHMARK_SAMPLES_FILE+x}" ]]; then
	echo 'BENCHMARK_SAMPLES_FILE requires BENCHMARK_TEST_MODE=1' >&2
	exit 64
fi

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
	if [[ ! "$run_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]]; then
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

normalize_identity() {
	local input_json="$1"
	local mode="$2"
	jq -e -S -c --arg mode "$mode" '
		if
			(keys == [
				"clientDevice", "encoderCommands", "imageDigest", "mode", "node",
				"samplesDigest", "savingsSeed", "schemaVersion", "scriptDigests",
				"sources", "vmaf"
			]) and
			(.node | type == "object" and keys == ["i915", "kernel", "name", "vpl"]) and
			(.vmaf | type == "object" and keys == ["model", "version"]) and
			([.sources[] | keys == ["path", "sha256", "size"]] | all)
		then . else error("invalid benchmark identity") end
		|
		{
			clientDevice: .clientDevice,
			encoderCommands: .encoderCommands,
			imageDigest: .imageDigest,
			mode: $mode,
			node: {
				i915: .node.i915,
				kernel: .node.kernel,
				name: .node.name,
				vpl: .node.vpl
			},
			samplesDigest: .samplesDigest,
			savingsSeed: .savingsSeed,
			schemaVersion: .schemaVersion,
			scriptDigests: .scriptDigests,
			sources: (.sources | map({path: .path, sha256: .sha256, size: .size}) | sort_by(.path)),
			vmaf: {model: .vmaf.model, version: .vmaf.version}
		}
		| if
			.schemaVersion == 1 and
			(.imageDigest | type == "string") and
			(.scriptDigests | type == "object") and
			([.scriptDigests[] | type == "string"] | all) and
			(.samplesDigest | type == "string") and
			(.sources | type == "array") and
			([.sources[] |
				(.path | type == "string") and
				(.size | type == "number" and . >= 0 and floor == .) and
				(.sha256 | type == "string")
			] | all) and
			(.encoderCommands | type == "array") and
			([.encoderCommands[] | type == "string"] | all) and
			(.node | [.name, .kernel, .i915, .vpl] | all(type == "string")) and
			(.vmaf | .model | type == "string") and
			(.vmaf | .version | type == "string") and
			(.savingsSeed | type == "number" and floor == .) and
			(.clientDevice == null or (.clientDevice | type == "string"))
		then . else error("invalid benchmark identity") end
	' <<<"$input_json"
}

discover_identity() {
	local mode="$1"
	local samples_file="${BENCHMARK_SAMPLES_FILE:-/config/samples.json}"
	local script_directory image_digest samples_digest savings_seed
	local script_digests='{}' sources='[]' encoder_commands node_name kernel i915 vpl
	local vmaf_model vmaf_version client_device source_json source_path source_size source_sha
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
	image_digest="$(jq -r '.runtime.image | split("@") | .[1] // ""' "$samples_file")"
	samples_digest="$(sha256_file "$samples_file")"
	savings_seed="$(jq -r '.savingsSeed' "$samples_file")"

	while IFS= read -r script_path; do
		[[ -n "$script_path" ]] || continue
		script_name="${script_path##*/}"
		script_sha="$(sha256_file "$script_path")"
		script_digests="$(jq -S -c --arg name "$script_name" --arg digest "$script_sha" \
			'. + {($name): $digest}' <<<"$script_digests")"
	done < <(find "$script_directory" -maxdepth 1 \( -type f -o -type l \) -name '*.sh' -print | LC_ALL=C sort)

	case "$mode" in
	quality) panel='.qualityPanel[]?' ;;
	savings) panel='.savingsPanel[]?' ;;
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
	done < <(jq -c "$panel" "$samples_file")

	encoder_commands="${BENCHMARK_ENCODER_COMMANDS_JSON:-[]}"
	node_name="${NODE_NAME:-}"
	kernel="$(uname -r)"
	i915="${BENCHMARK_I915_VERSION:-}"
	vpl="${BENCHMARK_VPL_VERSION:-}"
	vmaf_model="${BENCHMARK_VMAF_MODEL:-vmaf_4k_v0.6.1}"
	vmaf_version="${BENCHMARK_VMAF_VERSION:-}"
	client_device="${BENCHMARK_CLIENT_DEVICE:-}"

	jq -n -c \
		--arg mode "$mode" \
		--arg image_digest "$image_digest" \
		--argjson script_digests "$script_digests" \
		--arg samples_digest "$samples_digest" \
		--argjson sources "$sources" \
		--argjson encoder_commands "$encoder_commands" \
		--arg node_name "$node_name" \
		--arg kernel "$kernel" \
		--arg i915 "$i915" \
		--arg vpl "$vpl" \
		--arg vmaf_model "$vmaf_model" \
		--arg vmaf_version "$vmaf_version" \
		--argjson savings_seed "$savings_seed" \
		--arg client_device "$client_device" '
		{
			schemaVersion: 1,
			mode: $mode,
			imageDigest: $image_digest,
			scriptDigests: $script_digests,
			samplesDigest: $samples_digest,
			sources: $sources,
			encoderCommands: $encoder_commands,
			node: {name: $node_name, kernel: $kernel, i915: $i915, vpl: $vpl},
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
	local stored_mode identity
	if ! identity="$(jq -e -S -c 'del(.createdAt)' "$manifest" 2>/dev/null)"; then
		echo 'identity mismatch: manifest (stored=<malformed>, current=<redacted>)' >&2
		return 1
	fi
	if ! jq -e '
		has("createdAt") and
		(.createdAt | type == "string" and test("^[0-9]{8}T[0-9]{6}Z$"))
	' "$manifest" >/dev/null 2>&1; then
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
	local identity identity_digest now run_id run_directory manifest
	validate_mode "$mode" || return
	if [[ -n "$explicit_run_id" ]]; then
		validate_run_id "$explicit_run_id" || return
		run_directory="$runs_root/$explicit_run_id"
		if [[ -L "$run_directory" || (-e "$run_directory" && ! -d "$run_directory") ]]; then
			echo "run path is not a confined directory: $explicit_run_id" >&2
			return 73
		fi
		if [[ -d "$run_directory" ]]; then
			if [[ ! -f "$run_directory/manifest.json" || -L "$run_directory/manifest.json" ]]; then
				echo "run already exists without a manifest: $explicit_run_id" >&2
				return 73
			fi
			verify_run "$explicit_run_id" "$mode" || return
			printf '%s\n' "$explicit_run_id"
			return
		fi
		identity="$(discover_identity "$mode")" || return
		now="${explicit_run_id%-*}"
		run_id="$explicit_run_id"
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
		[[ "$now" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || {
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
	python3 - "$results" "$run_id" "$row_key" "$test_mode" <<'PYTHON'
import csv
import sys

results_path, expected_run_id, expected_key, test_mode = sys.argv[1:]
expected_header = [
    "run_id", "panel", "sample_id", "cohort", "source_sha256", "clip_id",
    "encoder", "requested_setting", "selected_rate_control", "status", "attempt",
    "input_bytes", "output_bytes", "reduction_percent", "input_bit_rate",
    "output_bit_rate", "wall_seconds", "encode_fps", "encode_speed",
    "vmaf_harmonic_mean", "vmaf_1pct_low", "ssim", "gpu_busy_percent",
    "qsv_proof", "validation_codec", "validation_duration",
    "validation_resolution", "validation_frame_rate", "validation_bit_depth",
    "validation_hdr", "validation_audio_tracks", "validation_subtitle_tracks",
    "validation_chapters", "validation_failures", "log_path", "output_disposition",
]


def invalid(message):
    print(message, file=sys.stderr)
    raise SystemExit(65)


try:
    with open(results_path, newline="", encoding="utf-8") as stream:
        reader = csv.reader(stream, strict=True)
        try:
            first = next(reader)
        except StopIteration:
            raise SystemExit(1)

        if first != expected_header:
            if test_mode != "1" or len(first) != 2:
                invalid("invalid results CSV header")
            rows = [first]
            try:
                rows.extend(reader)
            except csv.Error:
                invalid(f"invalid results CSV: malformed row {reader.line_num}")
            for row_number, row in enumerate(rows, 1):
                if len(row) != 2 or row[1] not in {"passed", "failed", "invalid"}:
                    invalid(f"invalid compact results CSV row {row_number}")
            found = any(row[0] == expected_key and row[1] == "passed" for row in rows)
            raise SystemExit(0 if found else 1)

        found = False
        try:
            for row_number, row in enumerate(reader, 2):
                if len(row) != len(expected_header):
                    invalid(
                        f"invalid results CSV: row {row_number} has {len(row)} columns; "
                        f"expected {len(expected_header)}"
                    )
                if row[0] != expected_run_id:
                    invalid(f"invalid results CSV: row {row_number} has a mismatched run id")
                if row[9] not in {"passed", "failed", "invalid"}:
                    invalid(f"invalid results CSV: row {row_number} has an invalid status")
                if not row[10].isdigit() or int(row[10]) < 1:
                    invalid(f"invalid results CSV: row {row_number} has an invalid attempt")
                key_parts = [row[1], row[4], row[5], row[6], row[7]]
                if any(not part or "|" in part for part in key_parts):
                    invalid(f"invalid results CSV: row {row_number} has an invalid row key")
                candidate = "|".join(key_parts)
                if candidate == expected_key and row[9] == "passed":
                    found = True
        except csv.Error:
            invalid(f"invalid results CSV: malformed row {reader.line_num}")
except (OSError, UnicodeError):
    invalid("invalid results CSV: unreadable input")

raise SystemExit(0 if found else 1)
PYTHON
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
