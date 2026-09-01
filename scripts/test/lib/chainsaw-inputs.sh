#!/usr/bin/env bash

chainsaw_all_yaml_files() {
	local root="$1" relative listing candidates status

	listing="$(mktemp "${TMPDIR:-/tmp}/chainsaw-inputs.XXXXXX")" || return
	candidates="$(mktemp "${TMPDIR:-/tmp}/chainsaw-inputs.XXXXXX")" || {
		rm -f -- "$listing"
		return 1
	}
	if ! git -C "$root" ls-files -co --exclude-standard -z -- \
		tests/chainsaw tests/fixtures/chainsaw >"$listing"; then
		rm -f -- "$listing" "$candidates"
		return 1
	fi

	while IFS= read -r -d '' relative; do
		case "$relative" in
		*.yaml | *.yml)
			if [[ -f "$root/$relative" && ! -L "$root/$relative" ]]; then
				printf '%s\n' "$relative"
			fi
			;;
		esac
	done <"$listing" >"$candidates"
	LC_ALL=C sort "$candidates"
	status="$?"
	rm -f -- "$listing" "$candidates"
	return "$status"
}

chainsaw_test_files() {
	local root="$1" relative all_files

	all_files="$(chainsaw_all_yaml_files "$root")" || return
	[[ -n "$all_files" ]] || return 0

	while IFS= read -r relative; do
		case "${relative##*/}" in
		chainsaw-test.yaml | chainsaw-test.yml) printf '%s\n' "$relative" ;;
		esac
	done <<<"$all_files"
}

chainsaw_yaml_support_files() {
	local root="$1" all_files test_files

	all_files="$(chainsaw_all_yaml_files "$root")" || return
	test_files="$(chainsaw_test_files "$root")" || return

	comm -23 \
		<(printf '%s\n' "$all_files") \
		<(printf '%s\n' "$test_files")
}
