#!/usr/bin/env bash

# This helper is sourceable by the benchmark producer. Its direct CLI remains
# test-only so the production path cannot be invoked outside that producer.
quality_evidence_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F contract_load >/dev/null; then
	# shellcheck disable=SC1091
	source "$quality_evidence_directory/contract.sh"
fi

quality_vmaf_stats() {
	local metrics_file="$1" samples_file="$2" sample_id="$3" clip_id="$4"
	local allowed_index='null' exclusion_index

	[[ -f "$metrics_file" && ! -L "$metrics_file" ]] || return 66
	[[ -f "$samples_file" && ! -L "$samples_file" ]] || return 66
	if [[ ! -v CONTRACT_QUALITY_EVIDENCE_SCHEMA ]]; then
		contract_load "$samples_file" || return 65
	fi
	jq -e '
		(.frames | type) == "array" and (.frames | length) > 0 and
		all(.frames[];
			(.frameNum | type) == "number" and (.frameNum | isfinite) and
			(.frameNum | floor == .) and .frameNum >= 0 and
			(.metrics | type) == "object" and
			(.metrics.vmaf | type) == "number" and (.metrics.vmaf | isfinite))
	' "$metrics_file" >/dev/null || return 65

	if exclusion_index="$(contract_quality_vmaf_exclusion "$samples_file" "$sample_id" "$clip_id")"; then
		allowed_index="$exclusion_index"
	fi

	jq -c --argjson allowed_index "$allowed_index" '
		def decimal6: (. * 1000000 | round) / 1000000;
		[.frames[] | {frameIndex:.frameNum,vmaf:.metrics.vmaf}] as $raw |
		([$raw[] | select(.frameIndex == $allowed_index)]) as $matches |
		(if $allowed_index == null then []
		 elif (($matches | length) == 1 and $matches[0].vmaf == 0) then $matches
		 else [] end) as $excluded |
		($excluded | if length == 1 then .[0].frameIndex else null end) as $excluded_index |
		[$raw[] | select(.frameIndex != $excluded_index) | .vmaf] as $evaluated |
		($evaluated | length) as $evaluated_count |
		($evaluated | sort) as $sorted |
		(($evaluated_count + 99) / 100 | floor) as $low_count |
		{
			rawFrameCount:($raw | length),
			evaluatedFrameCount:$evaluated_count,
			excludedFrames:$excluded,
			harmonicMean:(if any($evaluated[]; . == 0) then 0 else ($evaluated_count / ($evaluated | map(1 / .) | add) | decimal6) end),
			onePercentLow:($sorted[0:$low_count] | add / $low_count)
		}
	' "$metrics_file"
}

quality_parse_metric() {
	local kind="$1" log_file="$2" pattern value
	[[ -f "$log_file" && ! -L "$log_file" ]] || return 66
	case "$kind" in
	ssim) pattern='All:[0-9]+([.][0-9]+)?' ;;
	psnr) pattern='average:[0-9]+([.][0-9]+)?' ;;
	*) return 64 ;;
	esac
	value="$(grep -o -E "$pattern" "$log_file" | tail -n 1 | cut -d: -f2)" || return 65
	[[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 65
	printf '%s\n' "$value"
}

quality_evidence_test_cli() {
	local command="${1:-}"
	shift || true
	case "$command" in
	vmaf)
		(($# == 4)) || return 64
		quality_vmaf_stats "$@"
		;;
	metric)
		(($# == 2)) || return 64
		quality_parse_metric "$@"
		;;
	*) return 64 ;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	if [[ "${1:-}" != '_test' ]]; then
		echo 'quality-evidence.sh is source-only; use _test for isolated checks' >&2
		exit 64
	fi
	shift
	quality_evidence_test_cli "$@"
fi
