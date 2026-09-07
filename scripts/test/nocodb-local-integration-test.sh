#!/usr/bin/env bash
# Offline guard tests for the disposable NocoDB Podman integration runner.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

runner='scripts/test/scenarios/nocodb-local-integration.sh'
[[ -x "$runner" ]] || {
	echo "Missing executable NocoDB local integration runner: $runner" >&2
	exit 1
}

! rg -q 'NC_SECURE_ATTACHMENTS|storage/upload|meta/comments|FileReference|downloadAttachment|Attachment-column|attachment_canary' "$runner" || {
	echo 'NocoDB local integration guard test failed: native attachment behavior is present' >&2
	exit 1
}
rg -Fq 'runtimeCredentialId' "$runner" || {
	echo 'NocoDB local integration guard test failed: generated runtime credential binding is missing' >&2
	exit 1
}
for runtime_node in \
	'Publish Initial Feedback Fact' 'Consume Feedback Before Refresh' \
	'Refresh Feedback Fact' 'Consume Feedback After Refresh'; do
	rg -Fq "$runtime_node" "$runner" || {
		echo "NocoDB local integration guard test failed: runtime credential node binding is missing: $runtime_node" >&2
		exit 1
	}
done
for migrator_node in \
	'Create Acceptance Structure' 'Grant Acceptance Access' 'Clear Reader Negative Residue' \
	'Cleanup Unexpected Reader Insert' 'Clear Feedback Residue' 'Cleanup Feedback Fact'; do
	rg -Fq "$migrator_node" "$runner" || {
		echo "NocoDB local integration guard test failed: migrator credential node binding is missing: $migrator_node" >&2
		exit 1
	}
done
rg -Fq 'acceptance_call feedback' "$runner" || {
	echo 'NocoDB local integration guard test failed: actual feedback operation is missing' >&2
	exit 1
}
rg -Fq 'recoveryCanary.version == 2' "$runner" || {
	echo 'NocoDB local integration guard test failed: record recovery canary v2 proof is missing' >&2
	exit 1
}
rg -Fq 'prove_aged_jobs_rotation_and_restart()' "$runner" || {
	echo 'NocoDB local integration guard test failed: aged-job rotation and restart proof is missing' >&2
	exit 1
}
rg -Fq 'aged-job-api-response.json' "$runner" || {
	echo 'NocoDB local integration guard test failed: aged-job API absence readback is missing' >&2
	exit 1
}
rg -Fq 'prove_interrupted_initial_creation()' "$runner" || {
	echo 'NocoDB local integration guard test failed: interrupted initial creation proof is missing' >&2
	exit 1
}
rg -Fq 'prove_additive_metadata_refresh()' "$runner" || {
	echo 'NocoDB local integration guard test failed: supported source metadata refresh is missing' >&2
	exit 1
}
rg -Fq 'replace_nocodb_scratch()' "$runner" || {
	echo 'NocoDB local integration guard test failed: NocoDB container and scratch replacement proof is missing' >&2
	exit 1
}
rg -Fq 'replacement-settings-before.json' "$runner" || {
	echo 'NocoDB local integration guard test failed: exact retained app-setting proof is missing' >&2
	exit 1
}
rg -Fq 'prove_logical_restore()' "$runner" || {
	echo 'NocoDB local integration guard test failed: isolated logical restore proof is missing' >&2
	exit 1
}
rg -Fq 'fresh logical bundle failed checksum validation.' "$runner" || {
	echo 'NocoDB local integration guard test failed: restored backup checksum proof is missing' >&2
	exit 1
}
rg -Fq -- '--tmpfs /usr/app/data' "$runner" || {
	echo 'NocoDB local integration guard test failed: NocoDB data scratch is not ephemeral' >&2
	exit 1
}
rg -Fq 'slice_run second' "$runner" || {
	echo 'NocoDB local integration guard test failed: second complete vertical slice is missing' >&2
	exit 1
}
! rg -Fq 'REVOKE CONNECT ON DATABASE postgres FROM PUBLIC' "$runner" || {
	echo 'NocoDB local integration guard test failed: runner still normalizes production maintenance ACLs' >&2
	exit 1
}
! rg -q 'saveData(Error|Success)Execution = "all"|/api/v1/executions' "$runner" || {
	echo 'NocoDB local integration guard test failed: runner persists or reads credential-bearing executions' >&2
	exit 1
}
fail() {
	echo "NocoDB local integration guard test failed: $*" >&2
	exit 1
}

fixture="$(mktemp -d "${TMPDIR:-/tmp}/nocodb-local-guard.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"
event_log="$fixture/events.log"
export NOCODB_LOCAL_GUARD_EVENT_LOG="$event_log"

cat >"$fixture/bin/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${NOCODB_LOCAL_GUARD_EVENT_LOG:?}"
case "$*" in
	'info') exit "${NOCODB_LOCAL_GUARD_INFO_STATUS:-0}" ;;
	'image exists postgres:17.11-alpine3.24') exit 0 ;;
	'image exists docker.n8n.io/n8nio/n8n:2.36.7') exit 0 ;;
	'image exists docker.io/nocodb/nocodb@sha256:4b760f0d25471fb49707d515f161d9d36b49c88e7ecbe25eded774af385be5a9') exit 0 ;;
	'container exists nocodb-local-'*)
		[[ "${NOCODB_LOCAL_GUARD_COLLISION:-false}" == true ]] && exit 0
		exit 1
		;;
	'network exists nocodb-local-cleanupguard-network')
		[[ -e "${NOCODB_LOCAL_GUARD_CLEANUP_STATE:?}" ]] && exit 0
		exit 1
		;;
	'network exists nocodb-local-'*)
		[[ "${NOCODB_LOCAL_GUARD_COLLISION:-false}" == true ]] && exit 0
		exit 1
		;;
	'volume exists nocodb-local-'*)
		[[ "${NOCODB_LOCAL_GUARD_COLLISION:-false}" == true ]] && exit 0
		exit 1
		;;
	'inspect --format {{ index .Config.Labels "homelab-talos.test-run" }} nocodb-local-'*)
		printf '%s\n' foreign-run
		;;
	'network inspect --format {{ index .Labels "homelab-talos.test-run" }} nocodb-local-'*)
		if [[ "${NOCODB_LOCAL_GUARD_CLEANUP:-false}" == true ]]; then
			printf '%s\n' nocodb-local-cleanupguard
		else
			printf '%s\n' foreign-run
		fi
		;;
	'volume inspect --format {{ index .Labels "homelab-talos.test-run" }} nocodb-local-'*)
		printf '%s\n' foreign-run
		;;
	'network create --label homelab-talos.test-run=nocodb-local-cleanupguard nocodb-local-cleanupguard-network')
		: >"${NOCODB_LOCAL_GUARD_CLEANUP_STATE:?}"
		;;
	'network rm nocodb-local-cleanupguard-network') exit 80 ;;
	*) exit 64 ;;
esac
EOF
chmod 700 "$fixture/bin/podman"

run_preflight() {
	local output status
	set +e
	output="$(PATH="$fixture/bin:$PATH" "$runner" --preflight 2>&1)"
	status=$?
	set -e
	printf '%s\n' "$output" >"$fixture/output"
	return "$status"
}

output_sentinel='task7-output-sentinel-do-not-print-334'
run_output_safety_test() { # <safe|stdout|stderr>
	local leak_stream="$1" result_code
	set +e
	NOCODB_LOCAL_OUTPUT_TEST_SENTINEL="$output_sentinel" \
		NOCODB_LOCAL_OUTPUT_TEST_LEAK_STREAM="$leak_stream" \
		"$runner" --output-safety-test >"$fixture/output-safety.stdout" \
		2>"$fixture/output-safety.stderr"
	result_code=$?
	set -e
	return "$result_code"
}

run_output_safety_test safe || fail 'safe sentinel output self-test failed'
! rg -Fq "$output_sentinel" "$fixture/output-safety.stdout" "$fixture/output-safety.stderr" ||
	fail 'safe sentinel appeared in captured output'
for leak_stream in stdout stderr; do
	if run_output_safety_test "$leak_stream"; then
		fail "$leak_stream sentinel leak was accepted"
	fi
	! rg -Fq "$output_sentinel" "$fixture/output-safety.stdout" "$fixture/output-safety.stderr" ||
		fail "$leak_stream sentinel was replayed after leak detection"
	rg -Fq 'credential output safety check failed' "$fixture/output-safety.stderr" ||
		fail "$leak_stream sentinel refusal was unclear"
done

if NOCODB_LOCAL_PODMAN='podman-does-not-exist' run_preflight; then
	fail 'missing Podman was accepted'
fi
rg -Fq 'Podman is required' "$fixture/output" || fail 'missing Podman refusal was unclear'

if NOCODB_LOCAL_POSTGRES_IMAGE='postgres:latest' run_preflight; then
	fail 'an unpinned PostgreSQL image was accepted'
fi
rg -Fq 'PostgreSQL image must be exactly' "$fixture/output" || fail 'invalid image refusal was unclear'

if NOCODB_LOCAL_NOCODB_URL='https://nocodb.lab.supermorphic.com' run_preflight; then
	fail 'a production NocoDB endpoint was accepted'
fi
rg -Fq 'loopback' "$fixture/output" || fail 'production endpoint refusal did not name the loopback boundary'

if NOCODB_LOCAL_N8N_URL='http://0.0.0.0:5678' run_preflight; then
	fail 'a wildcard n8n endpoint was accepted'
fi
rg -Fq 'loopback' "$fixture/output" || fail 'wildcard endpoint refusal did not name the loopback boundary'

: >"$event_log"
if NOCODB_LOCAL_RUN_ID='guardcollision' NOCODB_LOCAL_GUARD_COLLISION=true run_preflight; then
	fail 'a foreign resource collision was accepted'
fi
rg -Fq 'not owned by this run' "$fixture/output" || fail 'foreign collision refusal was unclear'
! rg -q '^(rm|network rm|volume rm)' "$event_log" || fail 'foreign collision triggered deletion'

cleanup_state="$fixture/cleanup-state"
export NOCODB_LOCAL_GUARD_CLEANUP_STATE="$cleanup_state"
: >"$event_log"
set +e
PATH="$fixture/bin:$PATH" NOCODB_LOCAL_RUN_ID=cleanupguard \
	NOCODB_LOCAL_GUARD_CLEANUP=true "$runner" --cleanup-test >"$fixture/output" 2>&1
cleanup_status=$?
set -e
[[ "$cleanup_status" -eq 1 ]] || fail 'cleanup failure did not override the scenario exit status'
rg -Fq 'cleanup failed or could not prove exact resource absence' "$fixture/output" ||
	fail 'cleanup failure was not reported'
rg -Fq 'network rm nocodb-local-cleanupguard-network' "$event_log" ||
	fail 'cleanup did not target the exact run-owned network'

echo 'NocoDB local integration guard tests passed.'
