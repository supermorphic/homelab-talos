#!/usr/bin/env bash
# Portable permission inspection for NocoDB test fixtures.
# Sourcing this file must not alter the caller's shell options.

nocodb_test_permission_error() {
	printf 'NocoDB test permissions: %s\n' "$*" >&2
}

nocodb_test_mode() { # <path>
	local mode platform

	[[ "$#" -eq 1 ]] || {
		nocodb_test_permission_error 'mode requires one path.'
		return 2
	}
	platform="$(uname -s)" || return
	case "$platform" in
	Darwin)
		mode="$(stat -f '%Lp' "$1")" || return
		;;
	Linux)
		mode="$(stat -c '%a' "$1")" || return
		;;
	*)
		nocodb_test_permission_error "unsupported platform: $platform."
		return 1
		;;
	esac
	printf '%s\n' "$mode"
}
