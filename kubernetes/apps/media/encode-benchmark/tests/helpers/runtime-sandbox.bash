#!/usr/bin/env bash
# Build a PATH containing exactly the commands samples.yaml declares the runtime
# image provides. Running a runtime script against it reproduces the image's
# command surface offline, so an undeclared dependency fails here instead of
# surfacing as "command not found" inside a live Job.

declared_runtime_commands() {
	local samples="$1"
	yq -r '.data."samples.yaml"' "$samples" |
		yq -r '.runtime.requiredCommands[]'
}

# Usage: runtime_sandbox_path <samples.yaml> <sandbox-dir>
# Emits a PATH value restricted to the declared commands.
runtime_sandbox_path() {
	local samples="$1"
	local sandbox="$2"
	local command_name resolved
	local -a declared=()

	mapfile -t declared < <(declared_runtime_commands "$samples")
	((${#declared[@]} > 0)) || {
		echo 'samples.yaml declares no runtime commands' >&2
		return 1
	}

	mkdir -p "$sandbox"
	for command_name in "${declared[@]}"; do
		resolved="$(command -v "$command_name" 2>/dev/null)" || {
			# A declared command absent from the test host would silently weaken
			# the sandbox into a laxer PATH, so fail loudly instead.
			echo "test host is missing declared runtime command: $command_name" >&2
			return 1
		}
		ln -sf "$resolved" "$sandbox/$command_name"
	done

	printf '%s\n' "$sandbox"
}
