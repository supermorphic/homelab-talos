#!/usr/bin/env bash
set -euo pipefail

benchmark_out="${BENCHMARK_OUT:-/out}"
runs_root="$benchmark_out/runs"
test_mode="${BENCHMARK_TEST_MODE:-0}"
identity_fixture="${BENCHMARK_IDENTITY_FIXTURE:-}"
clock_override="${BENCHMARK_NOW:-}"
new_run_directory=''
manifest_temp=''

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
	printf 'sha256:%s\n' "$(sha256sum "$path" | awk '{print $1}')"
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
	local samples_file="${BENCHMARK_SAMPLES_FILE:-/config/samples.yaml}"
	local script_directory image_digest samples_digest savings_seed
	local script_digests='{}' sources='[]' encoder_commands node_name kernel i915 vpl
	local vmaf_model vmaf_version client_device source_json source_path source_size source_sha

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
	image_digest="$(yq -r '.runtime.image | split("@") | .[1] // ""' "$samples_file")"
	samples_digest="$(sha256_file "$samples_file")"
	savings_seed="$(yq -r '.savingsSeed' "$samples_file")"

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
			echo "benchmark source not found: $source_path" >&2
			return 66
		}
		source_size="$(wc -c <"$source_path" | tr -d '[:space:]')"
		source_sha="$(sha256_file "$source_path")"
		sources="$(jq -S -c \
			--arg path "$source_path" \
			--argjson size "$source_size" \
			--arg sha256 "$source_sha" \
			'. + [{path: $path, size: $size, sha256: $sha256}]' <<<"$sources")"
	done < <(yq -o=json -I=0 "$panel" "$samples_file")

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
	local path stored_mode current_mode
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		if [[ "$path" == 'mode' ]]; then
			stored_mode="$(jq -r '.mode' <<<"$stored")"
			current_mode="$(jq -r '.mode' <<<"$current")"
			printf 'identity mismatch: mode (stored=%s, current=%s)\n' "$stored_mode" "$current_mode" >&2
		else
			printf 'identity mismatch: %s (stored=<redacted>, current=<redacted>)\n' "$path" >&2
		fi
	done < <(jq -n -r --argjson stored "$stored" --argjson current "$current" '
		[($stored | paths(scalars)), ($current | paths(scalars))]
		| unique
		| .[] as $path
		| select(($stored | getpath($path)) != ($current | getpath($path)))
		| $path | map(tostring) | join(".")
	')
}

stored_identity() {
	local manifest="$1"
	local stored_mode normalized
	if ! jq -e '
		has("createdAt") and
		(.createdAt | type == "string" and test("^[0-9]{8}T[0-9]{6}Z$"))
	' "$manifest" >/dev/null 2>&1; then
		echo "invalid run manifest: $manifest" >&2
		return 65
	fi
	stored_mode="$(jq -e -r '.mode | select(type == "string")' "$manifest")" || {
		echo "invalid run manifest: $manifest" >&2
		return 65
	}
	if ! normalized="$(normalize_identity "$(jq -c 'del(.createdAt)' "$manifest")" "$stored_mode" 2>/dev/null)"; then
		echo "invalid run manifest: $manifest" >&2
		return 65
	fi
	printf '%s\n' "$normalized"
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
	local identity identity_digest now run_id manifest
	validate_mode "$mode" || return
	if [[ -n "$explicit_run_id" ]]; then
		verify_run "$explicit_run_id" "$mode" || return
		printf '%s\n' "$explicit_run_id"
		return
	fi

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
	mkdir -p "$runs_root"
	new_run_directory="$runs_root/$run_id"
	if ! mkdir "$new_run_directory"; then
		echo "run already exists: $run_id" >&2
		return 73
	fi
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
	awk -F, -v key="$row_key" '
		NR == 1 && $1 == "run_id" { full_schema = 1; next }
		full_schema {
			candidate = $2 "|" $5 "|" $6 "|" $7 "|" $8
			if (candidate == key && $10 == "passed") found = 1
			next
		}
		NF == 2 && $1 == key && $2 == "passed" { found = 1 }
		END { exit(found ? 0 : 1) }
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
