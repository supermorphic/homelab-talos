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
child_pid=''
target_root="${TEST_RESULT_FRAGMENT_DIR:-}"
if [[ -z "$target_root" ]]; then
	target_root="$(mktemp -d "${TMPDIR:-/tmp}/native-junit.XXXXXX")"
	private_target_root=true
fi

# shellcheck disable=SC2329
cleanup() {
	local status="$?"
	if [[ -n "$child_pid" ]]; then
		kill -TERM "$child_pid" 2>/dev/null || true
		wait "$child_pid" 2>/dev/null || true
		child_pid=''
	fi
	[[ -z "$temporary" ]] || rm -f -- "$temporary"
	[[ "$private_target_root" != true ]] || rm -rf -- "$target_root"
	return "$status"
}

# shellcheck disable=SC2329
handle_signal() {
	local signal="$1"
	local status="$2"
	trap - TERM INT
	if [[ -n "$child_pid" ]]; then
		kill -"$signal" "$child_pid" 2>/dev/null || true
		wait "$child_pid" 2>/dev/null || true
		child_pid=''
	fi
	exit "$status"
}

trap cleanup EXIT
trap 'handle_signal TERM 143' TERM
trap 'handle_signal INT 130' INT

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
"$@" >"$temporary" &
child_pid="$!"
wait "$child_pid"
validator_status="$?"
child_pid=''
python scripts/test/junit_tools.py summary --input "$temporary" --label "$label"
summary_status="$?"
set -e

publication_status=0
if [[ "$summary_status" -eq 0 ]]; then
	if ! ln -- "$temporary" "$target"; then
		echo "Cannot publish native JUnit fragment without replacing: $target" >&2
		publication_status=2
	else
		rm -f -- "$temporary"
		temporary=''
	fi
fi

if [[ "$validator_status" -ne 0 ]]; then
	exit "$validator_status"
fi
if [[ "$summary_status" -ne 0 ]]; then
	exit "$summary_status"
fi
exit "$publication_status"
