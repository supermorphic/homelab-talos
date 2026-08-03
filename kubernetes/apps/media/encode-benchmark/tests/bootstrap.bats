#!/usr/bin/env bats

setup() {
	PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)"
	BOOTSTRAP_JUST="$PROJECT_ROOT/.just/bootstrap.just"
	CATALOG="$PROJECT_ROOT/tests/catalog.yaml"
	REAL_JUST="$(command -v just)"
	REAL_YQ="$(command -v yq)"
	STUB_BIN="$BATS_TEST_TMPDIR/bin"
	STUB_CALLS="$BATS_TEST_TMPDIR/calls.tsv"
	KUBECONFIG_FIXTURE="$BATS_TEST_TMPDIR/kubeconfig"
	mkdir -p "$STUB_BIN"
	: >"$STUB_CALLS"
	printf '%s\n' 'apiVersion: v1' >"$KUBECONFIG_FIXTURE"
	export PROJECT_ROOT REAL_YQ STUB_CALLS
	export PATH="$STUB_BIN:$PATH"
	create_bootstrap_stubs
}

create_bootstrap_stubs() {
	cat >"$STUB_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git\t%s\n' "$*" >>"$STUB_CALLS"
case "${1:-} ${2:-}" in
	'remote get-url')
		printf '%s\n' 'https://github.com/7yXwscXEzv6phzUnKfrw/homelab-talos.git'
		;;
	'status --porcelain') ;;
	'ls-remote --exit-code')
		printf '%s\t%s\n' '1111111111111111111111111111111111111111' 'refs/heads/main'
		;;
	'cat-file -e') ;;
	'diff --quiet') ;;
	'diff --name-only') ;;
	*)
		echo "unexpected git invocation: $*" >&2
		exit 97
		;;
esac
EOF

	cat >"$STUB_BIN/just" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'just\t%s\n' "$*" >>"$STUB_CALLS"
if [[ "$*" == 'kube encode-benchmark-verify' && "${STUB_VERIFY_FAIL:-0}" == '1' ]]; then
	echo 'fixture verification failure' >&2
	exit 42
fi
EOF

	cat >"$STUB_BIN/flux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'flux\t%s\n' "$*" >>"$STUB_CALLS"
EOF

	cat >"$STUB_BIN/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl\t%s\n' "$*" >>"$STUB_CALLS"
if [[ "$*" == *'get kustomization encode-benchmark'* ]]; then
	printf '%s\n' "${STUB_LIVE_SUSPEND:-true}"
	exit 0
fi
if [[ "$*" == *'wait --for=condition=Ready kustomization/encode-benchmark'* ]]; then
	exit 0
fi
echo "unexpected kubectl invocation: $*" >&2
exit 98
EOF

	cat >"$STUB_BIN/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *'.spec.suspend'* && "$*" == *'encode-benchmark/ks.yaml'* ]]; then
	printf '%s\n' "${STUB_SOURCE_SUSPEND:-true}"
	exit 0
fi
exec "$REAL_YQ" "$@"
EOF

	chmod +x "$STUB_BIN/git" "$STUB_BIN/just" "$STUB_BIN/flux" "$STUB_BIN/kubectl" "$STUB_BIN/yq"
}

run_bootstrap() {
	run "$REAL_JUST" --justfile "$BOOTSTRAP_JUST" \
		--set kubeconfig "$KUBECONFIG_FIXTURE" encode-benchmark
}

assert_flux_not_called() {
	local operation="$1"
	! awk -F '\t' -v operation="$operation" '$1 == "flux" && $2 ~ "^" operation " " {found = 1} END {exit !found}' "$STUB_CALLS"
}

# Catches a missing or weakened confirmation gate that allows Flux activation.
@test "bootstrap refuses missing and wrong confirmation without resuming Flux" {
	unset ENCODE_BENCHMARK_BOOTSTRAP_CONFIRM
	run_bootstrap
	[ "$status" -ne 0 ]
	[[ "$output" == *'ENCODE_BENCHMARK_BOOTSTRAP_CONFIRM'* ]]
	assert_flux_not_called resume

	: >"$STUB_CALLS"
	export ENCODE_BENCHMARK_BOOTSTRAP_CONFIRM='bootstrap:media:wrong-app'
	run_bootstrap
	[ "$status" -ne 0 ]
	[[ "$output" == *'ENCODE_BENCHMARK_BOOTSTRAP_CONFIRM'* ]]
	assert_flux_not_called resume
}

# Catches activation against a live child that is already operator-managed.
@test "bootstrap refuses a live child that is not suspended" {
	export ENCODE_BENCHMARK_BOOTSTRAP_CONFIRM='bootstrap:media:encode-benchmark'
	export STUB_LIVE_SUSPEND=false
	run_bootstrap
	[ "$status" -ne 0 ]
	[[ "$output" == *'not suspended in the live cluster'* ]]
	assert_flux_not_called resume
}

# Catches an initial rollout whose Git source has already enabled reconciliation.
@test "bootstrap refuses an initial source that is not suspended" {
	export ENCODE_BENCHMARK_BOOTSTRAP_CONFIRM='bootstrap:media:encode-benchmark'
	export STUB_SOURCE_SUSPEND=false
	run_bootstrap
	[ "$status" -ne 0 ]
	[[ "$output" == *'must be staged suspended in Git'* ]]
	assert_flux_not_called resume
}

# Catches removal of the post-resume failure trap or a cleanup targeting the wrong child.
@test "bootstrap re-suspends the child when live verification fails" {
	export ENCODE_BENCHMARK_BOOTSTRAP_CONFIRM='bootstrap:media:encode-benchmark'
	export STUB_VERIFY_FAIL=1
	run_bootstrap
	[ "$status" -ne 0 ]
	awk -F '\t' '$1 == "flux" && $2 ~ /^resume kustomization encode-benchmark / {resumed = 1} END {exit !resumed}' "$STUB_CALLS"
	awk -F '\t' '$1 == "flux" && $2 ~ /^suspend kustomization encode-benchmark / {suspended = 1} END {exit !suspended}' "$STUB_CALLS"
}

# Catches a successful bootstrap that re-suspends the app or omits the operator handoff.
@test "bootstrap success leaves the child resumed and prints the capabilities handoff" {
	export ENCODE_BENCHMARK_BOOTSTRAP_CONFIRM='bootstrap:media:encode-benchmark'
	run_bootstrap
	[ "$status" -eq 0 ]
	awk -F '\t' '$1 == "flux" && $2 ~ /^resume kustomization encode-benchmark / {resumed = 1} END {exit !resumed}' "$STUB_CALLS"
	assert_flux_not_called suspend
	[[ "$output" == *'mise exec -- just kube encode-benchmark-capabilities'* ]]
}

# Catches catalog registration that is absent, misplaced, cluster-mutating, or machine-owned.
@test "catalog exposes offline validation and human-owned read-only verification" {
	[ "$("$REAL_YQ" -r '.executions.ci | to_entries | .[] | select(.value == "validation.encode-benchmark") | .key' "$CATALOG")" = '15' ]
	[ "$("$REAL_YQ" -r '.campaigns.verification.members | to_entries | .[] | select(.value == "verification.encode-benchmark") | .key' "$CATALOG")" = '9' ]
	[ "$("$REAL_YQ" -r '.campaigns."scoped-verification".members | to_entries | .[] | select(.value == "verification.encode-benchmark") | .key' "$CATALOG")" = '9' ]
	[ "$("$REAL_YQ" -r '.suites[] | select(.metadata.id == "validation.encode-benchmark") | [.metadata.framework, .metadata.tier, .metadata.mutates_cluster, .metadata.execution_owner, .runner.command] | @tsv' "$CATALOG")" = $'bash\toffline\tfalse\tshared\tmise exec -- just kube encode-benchmark-validate' ]
	[ "$("$REAL_YQ" -r '.suites[] | select(.metadata.id == "verification.encode-benchmark") | [.metadata.mutates_cluster, .metadata.execution_owner, .access.tier, .runner.command] | @tsv' "$CATALOG")" = $'false\thuman\tobserver\tmise exec -- just kube encode-benchmark-verify' ]
}

# Catches adding or removing a guarded rollout without updating repository accounting.
@test "repository guard accounting covers all 30 guarded rollout entrypoints" {
	run bash -c 'cd "$1"; rg -c '\''require_deployed_source '\'' .just/bootstrap.just kubernetes/mod.just | awk -F: '\''{sum += $2} END {print sum}'\''' \
		-- "$PROJECT_ROOT"
	[ "$status" -eq 0 ]
  [ "$output" = '30' ]
}
