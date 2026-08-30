#!/usr/bin/env bats

setup() {
	PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)"
}

@test "encode benchmark exposes only the capability and quality evaluation surface" {
	local expected_recipes expected_scripts expected_benchmark_modes expected_dispatch_actions expected_probe_actions
	local actual_recipes actual_scripts actual_benchmark_modes actual_dispatch_actions actual_probe_actions
	expected_recipes=$'encode-benchmark-capabilities\nencode-benchmark-preflight\nencode-benchmark-quality\nencode-benchmark-results\nencode-benchmark-validate\nencode-benchmark-verify'
	expected_scripts=$'benchmark.sh\ncontract.sh\nprobe.sh\nquality-evidence.sh\nrunmeta.sh'
	expected_benchmark_modes=$'capabilities\nquality'
	expected_dispatch_actions=$'capabilities\nrun'
	expected_probe_actions=$'diagnostic-hdr-frame\ndiagnostic-hdr-normalize-oracle\ndiagnostic-hdr-stream\ndiagnostic-hdr-trace'

	actual_recipes="$(awk '
		/^encode-benchmark-[a-z0-9-]+([^:]*)?:/ {
			name = $1
			sub(/:.*/, "", name)
			print name
		}
	' "$PROJECT_ROOT/kubernetes/mod.just" | LC_ALL=C sort)"
	[ "$actual_recipes" = "$expected_recipes" ]

	actual_scripts="$(yq -r '
		.configMapGenerator[] | select(.name == "encode-benchmark-scripts") | .files[] |
		sub("=.*"; "")
	' "$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/kustomization.yaml" | LC_ALL=C sort)"
	[ "$actual_scripts" = "$expected_scripts" ]

	actual_benchmark_modes="$(awk '
		/^mode="\$1"$/ { in_main = 1; next }
		in_main && /^case "\$mode" in$/ { in_case = 1; next }
		in_case && /^esac$/ { exit }
		in_case && /^[a-z][a-z0-9-]*\)$/ {
			mode = $0
			sub(/\)$/, "", mode)
			print mode
		}
	' "$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/benchmark.sh" | LC_ALL=C sort)"
	[ "$actual_benchmark_modes" = "$expected_benchmark_modes" ]

	actual_dispatch_actions="$(awk '
		/^case "\$action" in$/ { in_case = 1; next }
		in_case && /^esac$/ { exit }
		in_case && /^[a-z][a-z0-9-]*\)$/ {
			action = $0
			sub(/\)$/, "", action)
			print action
		}
	' "$PROJECT_ROOT/scripts/encode-benchmark/dispatch.sh" | LC_ALL=C sort)"
	[ "$actual_dispatch_actions" = "$expected_dispatch_actions" ]

	actual_probe_actions="$(awk '
		/^case "\$\{1:-\}" in$/ { in_case = 1; next }
		in_case && /^esac$/ { exit }
		in_case && /^[a-z][a-z0-9-]*\)$/ {
			action = $0
			sub(/\)$/, "", action)
			print action
		}
	' "$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/probe.sh" | LC_ALL=C sort)"
	[ "$actual_probe_actions" = "$expected_probe_actions" ]
	! rg -n 'diagnostic-(identity|window)|diagnostic-contract' \
		"$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/probe.sh"
	rg -F 'clips: {detail: "00:17:23.456", motion: "00:27:23.456", dark: "00:37:23.456"}' \
		"$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/tests/benchmark.bats"
	! rg -n 'clips: \{[^}]*grain:' \
		"$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/tests/benchmark.bats"
}
