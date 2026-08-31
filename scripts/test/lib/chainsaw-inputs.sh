#!/usr/bin/env bash

chainsaw_all_yaml_files() {
	local root="$1" relative

	git -C "$root" ls-files -co --exclude-standard -z -- \
		tests/chainsaw tests/fixtures/chainsaw |
		while IFS= read -r -d '' relative; do
			case "$relative" in
			*.yaml | *.yml)
				[[ -f "$root/$relative" && ! -L "$root/$relative" ]] &&
					printf '%s\n' "$relative"
				;;
			esac
		done | LC_ALL=C sort
}

chainsaw_test_files() {
	local root="$1" relative

	while IFS= read -r relative; do
		case "${relative##*/}" in
		chainsaw-test.yaml | chainsaw-test.yml) printf '%s\n' "$relative" ;;
		esac
	done < <(chainsaw_all_yaml_files "$root")
}

chainsaw_yaml_support_files() {
	local root="$1"

	comm -23 \
		<(chainsaw_all_yaml_files "$root") \
		<(chainsaw_test_files "$root")
}
