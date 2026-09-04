#!/usr/bin/env bash
# Isolated source fixtures for monitoring validator mutation tests.
# Sourcing this file must not alter the caller's shell options.

monitoring_fixture_error() {
	printf 'monitoring fixture: %s\n' "$*" >&2
}

monitoring_fixture_canonical_dir() {
	cd -P -- "$1" && pwd
}

monitoring_fixture_prepare() { # <repository-root> <template-root> <case-root>
	local repository_root="$1" template_root="$2" case_root="$3"

	[[ "$#" -eq 3 ]] || {
		monitoring_fixture_error 'prepare requires repository, template, and case roots.'
		return 1
	}
	[[ -d "$repository_root" && -f "$repository_root/.sops.yaml" ]] || {
		monitoring_fixture_error 'repository source is incomplete.'
		return 1
	}
	for source_dir in kubernetes scripts tests; do
		[[ -d "$repository_root/$source_dir" ]] || {
			monitoring_fixture_error "repository source is missing $source_dir."
			return 1
		}
	done
	[[ ! -e "$template_root" && ! -L "$template_root" ]] || {
		monitoring_fixture_error 'template root already exists.'
		return 1
	}
	[[ ! -e "$case_root" && ! -L "$case_root" ]] || {
		monitoring_fixture_error 'case root already exists.'
		return 1
	}

	mkdir "$template_root" "$case_root"
	cp "$repository_root/.sops.yaml" "$template_root/.sops.yaml"
	for source_dir in kubernetes scripts tests; do
		cp -R "$repository_root/$source_dir" "$template_root/$source_dir"
	done
	cp -R "$template_root/." "$case_root"
}

monitoring_fixture_mode() { # <regular-file>
	case "$(uname -s)" in
	Darwin)
		stat -f '%Lp' "$1"
		;;
	Linux)
		stat -c '%a' "$1"
		;;
	*)
		monitoring_fixture_error "unsupported platform: $(uname -s)."
		return 1
		;;
	esac
}

monitoring_fixture_reset() { # <template-root> <case-root> <relative-path>...
	local template_root case_root relative template_target case_target mode
	local template_component case_component
	local -a components

	[[ "$#" -ge 3 ]] || {
		monitoring_fixture_error 'reset requires template, case, and relative paths.'
		return 1
	}
	template_root="$(monitoring_fixture_canonical_dir "$1")" || return 1
	case_root="$(monitoring_fixture_canonical_dir "$2")" || return 1
	shift 2

	for relative in "$@"; do
		case "$relative" in
		'' | /*)
			monitoring_fixture_error "invalid relative path: $relative"
			return 1
			;;
		esac
		[[ "/$relative/" != *'/../'* ]] || {
			monitoring_fixture_error "invalid relative path: $relative"
			return 1
		}
		IFS=/ read -r -a components <<<"$relative"
		for component in "${components[@]}"; do
			[[ -n "$component" && "$component" != '.' ]] || {
				monitoring_fixture_error "invalid relative path: $relative"
				return 1
			}
		done

		template_target="$template_root/$relative"
		case_target="$case_root/$relative"
		template_component="$template_root"
		case_component="$case_root"
		for component in "${components[@]}"; do
			template_component="$template_component/$component"
			case_component="$case_component/$component"
			[[ ! -L "$template_component" && ! -L "$case_component" ]] || {
				monitoring_fixture_error "symlink is not a mutable regular file: $relative"
				return 1
			}
		done
		[[ -f "$template_target" && ! -L "$template_target" ]] || {
			monitoring_fixture_error "template path is not a regular file: $relative"
			return 1
		}
		[[ ! -L "$case_target" ]] || {
			monitoring_fixture_error "case path is a symlink: $relative"
			return 1
		}
		[[ ! -e "$case_target" || -f "$case_target" ]] || {
			monitoring_fixture_error "case path is not a regular file: $relative"
			return 1
		}

		mkdir -p "$(dirname -- "$case_target")"
		mode="$(monitoring_fixture_mode "$template_target")" || return 1
		install -m "$mode" "$template_target" "$case_target"
	done
}
