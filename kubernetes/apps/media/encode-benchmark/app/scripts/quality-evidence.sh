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
	local allowed_index='null' exclusion_index contract_path contract_digest

	[[ -f "$metrics_file" && ! -L "$metrics_file" ]] || return 66
	[[ -f "$samples_file" && ! -L "$samples_file" ]] || return 66
	contract_path="$(realpath "$samples_file")" || return 65
	contract_digest="sha256:$(sha256sum "$contract_path" | awk 'NR == 1 { print $1 }')"
	[[ "$contract_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || return 65
	if [[ ! -v QUALITY_EVIDENCE_CONTRACT_PATH ]]; then
		if [[ ! -v CONTRACT_QUALITY_EVIDENCE_SCHEMA ]]; then
			contract_load "$contract_path" || return 65
		elif ! bash -c 'source "$1"; contract_load "$2"' \
			quality-evidence-contract "$quality_evidence_directory/contract.sh" "$contract_path" >/dev/null; then
			return 65
		fi
		QUALITY_EVIDENCE_CONTRACT_PATH="$contract_path"
		QUALITY_EVIDENCE_CONTRACT_DIGEST="$contract_digest"
		readonly QUALITY_EVIDENCE_CONTRACT_PATH QUALITY_EVIDENCE_CONTRACT_DIGEST
	elif [[ "$contract_path" != "$QUALITY_EVIDENCE_CONTRACT_PATH" ||
		"$contract_digest" != "$QUALITY_EVIDENCE_CONTRACT_DIGEST" ]]; then
		return 65
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

quality_hdr_probe() {
	"$quality_evidence_directory/probe.sh" "$@"
}

quality_hdr_evidence() {
	local source_path="$1" source_start="$2" clip_path="$3" output_path="$4" path
	local stream source_decoded source_trace clip_decoded clip_trace encoded_decoded encoded_trace
	local normalized_oracle document
	for path in "$source_path" "$clip_path" "$output_path"; do
		[[ -f "$path" && -r "$path" ]] || return 66
	done

	stream="$(quality_hdr_probe diagnostic-hdr-stream "$source_path" "$source_start" 10)" || return
	source_decoded="$(quality_hdr_probe diagnostic-hdr-frame "$source_path" "$source_start" 10)" || return
	source_trace="$(quality_hdr_probe diagnostic-hdr-trace "$source_path" "$source_start" 10)" || return
	clip_decoded="$(quality_hdr_probe diagnostic-hdr-frame "$clip_path" 0 10)" || return
	clip_trace="$(quality_hdr_probe diagnostic-hdr-trace "$clip_path" 0 10)" || return
	encoded_decoded="$(quality_hdr_probe diagnostic-hdr-frame "$output_path" 0 10)" || return
	encoded_trace="$(quality_hdr_probe diagnostic-hdr-trace "$output_path" 0 10)" || return

	stream="$(quality_hdr_probe diagnostic-hdr-normalize-oracle <<<"$stream")" || return
	source_decoded="$(quality_hdr_probe diagnostic-hdr-normalize-oracle <<<"$source_decoded")" || return
	source_trace="$(quality_hdr_probe diagnostic-hdr-normalize-oracle <<<"$source_trace")" || return
	clip_decoded="$(quality_hdr_probe diagnostic-hdr-normalize-oracle <<<"$clip_decoded")" || return
	clip_trace="$(quality_hdr_probe diagnostic-hdr-normalize-oracle <<<"$clip_trace")" || return
	encoded_decoded="$(quality_hdr_probe diagnostic-hdr-normalize-oracle <<<"$encoded_decoded")" || return
	encoded_trace="$(quality_hdr_probe diagnostic-hdr-normalize-oracle <<<"$encoded_trace")" || return

	normalized_oracle="$(jq -e -n -c \
		--argjson stream "$stream" \
		--argjson source_decoded "$source_decoded" --argjson source_trace "$source_trace" \
		--argjson clip_decoded "$clip_decoded" --argjson clip_trace "$clip_trace" \
		--argjson encoded_decoded "$encoded_decoded" --argjson encoded_trace "$encoded_trace" '
		def authoritative($decoded; $trace):
			if $decoded.status != "ok" then
				{status:"unresolved",reasons:[("decoded-frame-" + $decoded.status)]}
			elif $trace.status != "ok" then
				{status:"unresolved",reasons:[("trace-headers-" + $trace.status)]}
			elif $decoded.metadata != $trace.metadata then
				{status:"unresolved",reasons:["decoded-trace-disagreement"]}
			else {status:"ok",metadata:$decoded.metadata} end;
		{
			schemaVersion:1,
			source:{
				streamProbe:$stream,
				decoded:$source_decoded,
				trace:$source_trace,
				authoritative:authoritative($source_decoded; $source_trace)
			},
			clip:{
				decoded:$clip_decoded,
				trace:$clip_trace,
				authoritative:authoritative($clip_decoded; $clip_trace)
			},
			encoded:{
				decoded:$encoded_decoded,
				trace:$encoded_trace,
				authoritative:authoritative($encoded_decoded; $encoded_trace)
			}
		}
	')" || return

	document="$(jq -e -n -c --argjson oracle "$normalized_oracle" '
		if $oracle.source.authoritative.status != "ok" then
			{classification:"source-oracle-defect",reasons:$oracle.source.authoritative.reasons}
		elif $oracle.clip.authoritative.status != "ok" then
			{classification:"clip-boundary-defect",reasons:$oracle.clip.authoritative.reasons}
		elif $oracle.clip.authoritative.metadata != $oracle.source.authoritative.metadata then
			{classification:"clip-boundary-defect",reasons:["authoritative-source-metadata","clip-metadata-changed"]}
		elif $oracle.encoded.authoritative.status != "ok" then
			{classification:"encoder-output-defect",reasons:$oracle.encoded.authoritative.reasons}
		elif $oracle.encoded.authoritative.metadata != $oracle.clip.authoritative.metadata then
			{classification:"encoder-output-defect",reasons:["source-and-clip-metadata-agree","encoded-metadata-changed"]}
		else
			{classification:"preserved",reasons:["source-clip-encoded-metadata-agree"]}
		end | . + {normalizedOracle:$oracle}
	')" || return

	printf '%s\n' "$document"
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
	hdr)
		(($# == 4)) || return 64
		quality_hdr_evidence "$@"
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
