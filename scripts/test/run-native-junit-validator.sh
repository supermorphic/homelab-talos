#!/usr/bin/env bash
set -euo pipefail

usage() {
	echo "Usage: $0 --suite SUITE --fragment FILE.xml --label LABEL -- COMMAND [ARG ...]" >&2
	exit 2
}

suite=''
fragment=''
label=''

while [[ "$#" -gt 0 ]]; do
	case "$1" in
	--suite)
		[[ "$#" -ge 2 ]] || usage
		suite="$2"
		shift 2
		;;
	--fragment)
		[[ "$#" -ge 2 ]] || usage
		fragment="$2"
		shift 2
		;;
	--label)
		[[ "$#" -ge 2 ]] || usage
		label="$2"
		shift 2
		;;
	--)
		shift
		break
		;;
	*)
		usage
		;;
	esac
done

[[ -n "$suite" && -n "$fragment" && -n "$label" && "$#" -gt 0 ]] || usage
[[ "$fragment" != */* && "$fragment" != '.' && "$fragment" != '..' ]] || usage

private_target_root=false
temporary=''
target_root="${TEST_RESULT_FRAGMENT_DIR:-}"
if [[ -z "$target_root" ]]; then
	target_root="$(mktemp -d "${TMPDIR:-/tmp}/native-junit.XXXXXX")"
	private_target_root=true
fi

# shellcheck disable=SC2329
cleanup() {
	local status="$?"
	[[ -z "$temporary" ]] || rm -f -- "$temporary"
	[[ "$private_target_root" != true ]] || rm -rf -- "$target_root"
	return "$status"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

[[ -d "$target_root" ]] || {
	echo "Native JUnit fragment directory does not exist: $target_root" >&2
	exit 2
}

target="$target_root/$fragment"
if [[ -e "$target" || -L "$target" ]]; then
	echo "Native JUnit fragment already exists: $target" >&2
	exit 2
fi

temporary="$(mktemp "$target_root/.native-junit.XXXXXX")"
set +e
"$@" >"$temporary"
validator_status="$?"
python scripts/test/junit_tools.py summary --input "$temporary" --label "$label"
summary_status="$?"
set -e

if [[ "$summary_status" -eq 0 ]]; then
	if ! ln -- "$temporary" "$target"; then
		echo "Cannot publish native JUnit fragment without replacing: $target" >&2
		exit 2
	fi
	rm -f -- "$temporary"
	temporary=''
fi

if [[ "$validator_status" -ne 0 ]]; then
	exit "$validator_status"
fi
exit "$summary_status"
