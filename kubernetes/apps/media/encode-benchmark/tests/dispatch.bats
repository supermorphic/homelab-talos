#!/usr/bin/env bats

setup() {
	PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)"
	DISPATCH="$PROJECT_ROOT/scripts/encode-benchmark/dispatch.sh"
	PREFLIGHT="$PROJECT_ROOT/scripts/encode-benchmark/preflight.sh"
	RESULTS="$PROJECT_ROOT/scripts/encode-benchmark/results.sh"
	STUB_BIN="$BATS_TEST_TMPDIR/bin"
	STUB_CAPTURE_DIR="$BATS_TEST_TMPDIR/captures"
	STUB_CALLS="$BATS_TEST_TMPDIR/calls.tsv"
	KUBECONFIG_FIXTURE="$BATS_TEST_TMPDIR/kubeconfig"
	REAL_YQ="$(command -v yq)"
	mkdir -p "$STUB_BIN" "$STUB_CAPTURE_DIR"
	: >"$STUB_CALLS"
	printf '%s\n' 'apiVersion: v1' >"$KUBECONFIG_FIXTURE"
	export STUB_CAPTURE_DIR STUB_CALLS REAL_YQ
	export PATH="$STUB_BIN:$PATH"
	export ENCODE_BENCHMARK_TEST_MODE=1
	export ENCODE_BENCHMARK_NOW=20260802T120000Z
	create_cluster_stubs
}

create_cluster_stubs() {
	cat >"$STUB_BIN/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'kubectl\t%s\n' "$*" >>"$STUB_CALLS"

contains() {
	local expected="$1"
	shift
	local argument
	for argument in "$@"; do
		[[ "$argument" != "$expected" ]] || return 0
	done
	return 1
}

argument_after() {
	local expected="$1"
	shift
	local previous='' argument
	for argument in "$@"; do
		if [[ "$previous" == "$expected" ]]; then
			printf '%s\n' "$argument"
			return 0
		fi
		previous="$argument"
	done
	return 1
}

if contains config "$@" && contains view "$@"; then
	printf '%s\n' "${STUB_API_SERVER:-https://192.168.90.20:6443}"
	exit 0
fi

if contains exec "$@"; then
	if [[ "${STUB_INVENTORY_FAIL:-0}" == '1' ]]; then
		exit 23
	fi
	printf '%s\n' \
		$'inode\tlifecycle_state\ttorrent_hash\tcategory\ttags' \
		$'123\tactive\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tmovies\ttracker-public'
	exit 0
fi

if contains create "$@"; then
	manifest="$(argument_after --filename "$@" || argument_after -f "$@")"
	count_file="$STUB_CAPTURE_DIR/.count"
	count=0
	[[ ! -f "$count_file" ]] || read -r count <"$count_file"
	count=$((count + 1))
	printf '%s\n' "$count" >"$count_file"
	capture="$STUB_CAPTURE_DIR/create-$count.yaml"
	if [[ "$manifest" == '-' ]]; then
		cp /dev/stdin "$capture"
	else
		cp "$manifest" "$capture"
	fi
	kind="$(yq -r '.kind' "$capture")"
	name="$(yq -r '.metadata.name' "$capture")"
	cp "$capture" "$STUB_CAPTURE_DIR/$kind-$name.yaml"
	if [[ "${STUB_CONFIGMAP_CREATE_FAIL:-0}" == '1' && "$kind" == 'ConfigMap' ]]; then
		exit 24
	fi
	if [[ "${STUB_JOB_CREATE_FAIL:-0}" == '1' && "$kind" == 'Job' ]]; then
		exit 25
	fi
	jq -n -c \
		--arg kind "$kind" \
		--arg name "$name" \
		'{apiVersion:"v1",kind:$kind,metadata:{name:$name,uid:"fixture-job-uid"}}'
	exit 0
fi

if contains patch "$@"; then
	if [[ "${STUB_PATCH_FAIL:-0}" == '1' ]]; then
		exit 26
	fi
	printf '%s\n' 'job.batch/fixture patched'
	exit 0
fi

if contains delete "$@"; then
	printf '%s\n' 'job.batch/fixture deleted'
	exit 0
fi

if contains logs "$@"; then
	if [[ -n "${STUB_LOGS_FILE:-}" ]]; then
		sed -n '1,$p' "$STUB_LOGS_FILE"
	fi
	exit 0
fi

if contains get "$@" && contains jobs "$@"; then
	if [[ "${STUB_COLLISION:-0}" == '1' ]]; then
		printf '%s\n' '{"apiVersion":"v1","items":[{"metadata":{"name":"existing-run"}}]}'
	elif [[ -n "${STUB_JOBS_JSON:-}" ]]; then
		sed -n '1,$p' "$STUB_JOBS_JSON"
	else
		printf '%s\n' '{"apiVersion":"v1","items":[]}'
	fi
	exit 0
fi

if contains get "$@" && contains pods "$@"; then
	if [[ "$*" == *'app.kubernetes.io/name=encode-benchmark'* && -n "${STUB_BENCHMARK_PODS_JSON:-}" ]]; then
		sed -n '1,$p' "$STUB_BENCHMARK_PODS_JSON"
	elif [[ "$*" == *'app.kubernetes.io/name=plex'* && -n "${STUB_PLEX_PODS_JSON:-}" ]]; then
		sed -n '1,$p' "$STUB_PLEX_PODS_JSON"
	else
		sed -n '1,$p' "${STUB_PODS_JSON:?}"
	fi
	exit 0
fi

if contains get "$@" && contains priorityclass "$@"; then
	sed -n '1,$p' "${STUB_PRIORITYCLASS_JSON:?}"
	exit 0
fi

if contains get "$@" && contains configmaps "$@"; then
	sed -n '1,$p' "${STUB_CONFIGMAPS_JSON:?}"
	exit 0
fi

if contains get "$@" && [[ "$*" == *' configmap/'* ]]; then
	if [[ "${STUB_CONFIGMAP_GET_FAIL:-0}" == '1' ]]; then
		exit 27
	fi
	resource=''
	previous=''
	for argument in "$@"; do
		if [[ "$argument" == configmap/* ]]; then resource="$argument"; fi
		previous="$argument"
	done
	name="${resource#configmap/}"
	capture="$STUB_CAPTURE_DIR/ConfigMap-$name.yaml"
	if [[ "${STUB_PERSISTED_OWNER_BAD:-0}" == '1' ]]; then
		yq -o=json -I=0 '.metadata.ownerReferences[0].uid = "spoofed-owner-uid"' "$capture"
	else
		yq -o=json -I=0 '.' "$capture"
	fi
	exit 0
fi

if contains get "$@" && contains prometheusrule "$@"; then
	sed -n '1,$p' "${STUB_PROMETHEUSRULE_JSON:?}"
	exit 0
fi

if contains get "$@" && contains deployment,statefulset,daemonset,cronjob "$@"; then
	sed -n '1,$p' "${STUB_PERSISTENT_JSON:?}"
	exit 0
fi

if contains get "$@" && contains nodes "$@"; then
	sed -n '1,$p' "${STUB_NODES_JSON:?}"
	exit 0
fi

if contains get "$@" && contains pvc "$@"; then
	sed -n '1,$p' "${STUB_PVC_JSON:?}"
	exit 0
fi

if contains get "$@" && contains kustomization "$@"; then
	sed -n '1,$p' "${STUB_KUSTOMIZATION_JSON:?}"
	exit 0
fi

if contains get "$@" && contains --raw "$@"; then
	raw="$(argument_after --raw "$@")"
	node="${raw#*/nodes/}"
	node="${node%%/*}"
	sed -n '1,$p' "${STUB_SUMMARY_DIR:?}/$node.json"
	exit 0
fi

echo "unhandled kubectl stub invocation: $*" >&2
exit 97
EOF

	cat >"$STUB_BIN/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${STUB_CONFIGMAP_RENDER_FAIL:-0}" == '1' && -n "${INVENTORY_FILE:-}" ]]; then
	exit 28
fi
exec "$REAL_YQ" "$@"
EOF

	cat >"$STUB_BIN/chmod" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'chmod\t%s\n' "$*" >>"$STUB_CALLS"
if [[ "${STUB_CHMOD_FAIL:-0}" == '1' && "${1:-}" == '0600' ]]; then
	exit 29
fi
exec /bin/chmod "$@"
EOF

	cat >"$STUB_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git\t%s\n' "$*" >>"$STUB_CALLS"
case "${1:-} ${2:-}" in
	'status --porcelain') exit 0 ;;
	'ls-remote --exit-code')
		printf '%s\t%s\n' '1111111111111111111111111111111111111111' 'refs/heads/main'
		exit 0
		;;
	'cat-file -e') exit 0 ;;
	'diff --quiet')
		[[ "${STUB_GIT_STALE:-0}" != '1' ]]
		exit
		;;
	'diff --name-only')
		printf '%s\n' 'scripts/encode-benchmark/dispatch.sh'
		exit 0
		;;
esac
exit 0
EOF

	cat >"$STUB_BIN/flux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'flux\t%s\n' "$*" >>"$STUB_CALLS"
echo 'unexpected flux invocation in offline dispatch test' >&2
exit 98
EOF
	chmod +x "$STUB_BIN/kubectl" "$STUB_BIN/git" "$STUB_BIN/flux" "$STUB_BIN/yq" "$STUB_BIN/chmod"
}

mutation_count() {
	awk -F '\t' '$1 == "kubectl" && $2 ~ /(^| )(create|apply|delete|exec|patch)( |$)/ {count += 1} END {print count + 0}' "$STUB_CALLS"
}

assert_no_mutations() {
	[ "$(mutation_count)" -eq 0 ]
}

run_dispatch() {
	run "$DISPATCH" "$KUBECONFIG_FIXTURE" "$@"
}

assert_guard_refuses() {
	local variable="$1" wrong="$2"
	shift 2

	unset "$variable"
	run_dispatch "$@"
	[ "$status" -ne 0 ]
	assert_no_mutations

	export "$variable="
	run_dispatch "$@"
	[ "$status" -ne 0 ]
	assert_no_mutations

	export "$variable=$wrong"
	run_dispatch "$@"
	[ "$status" -ne 0 ]
	assert_no_mutations
}

job_capture() {
	find "$STUB_CAPTURE_DIR" -maxdepth 1 -type f -name 'Job-*.yaml' -print | sort | tail -n 1
}

configmap_capture() {
	find "$STUB_CAPTURE_DIR" -maxdepth 1 -type f -name 'ConfigMap-*.yaml' -print | sort | tail -n 1
}

assert_hardened_job() {
	local job="$1" dispatch_id
	dispatch_id="$(yq -r '.metadata.labels."homelab-talos/benchmark-dispatch" // ""' "$job")"
	[[ "$dispatch_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]]
	[ "$(yq -r '.spec.template.metadata.labels."homelab-talos/benchmark-dispatch" // ""' "$job")" = "$dispatch_id" ]
	[ "$(yq -r '.spec.template.spec.automountServiceAccountToken' "$job")" = 'false' ]
}

# Catches any confirmation branch that treats an absent, empty, or merely
# similar capability token as authority to create a cluster resource.
@test "capabilities requires the exact confirmation before creating a Job" {
	assert_guard_refuses ENCODE_BENCHMARK_CAPABILITIES_CONFIRM wrong:capabilities capabilities

	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	run_dispatch capabilities
	[ "$status" -eq 0 ]
	[ "$(mutation_count)" -eq 1 ]
}

# Catches the corresponding missing guard on the census lifecycle, including
# the otherwise-dangerous qbit_manage exec used to bridge download state.
@test "census requires the exact confirmation before exec or resource creation" {
	assert_guard_refuses ENCODE_BENCHMARK_CENSUS_CONFIRM run:encode-benchmark:quality census

	export ENCODE_BENCHMARK_CENSUS_CONFIRM='run:encode-benchmark:census'
	run_dispatch census
	[ "$status" -eq 0 ]
	[ "$(mutation_count)" -ge 4 ]
}

# Catches mode interpolation or prefix matching that authorizes a benchmark
# run with an absent, empty, or wrong mode-bound token.
@test "run requires the exact mode-bound confirmation before creating a Job" {
	assert_guard_refuses ENCODE_BENCHMARK_RUN_CONFIRM run:encode-benchmark:savings run quality

	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'
	run_dispatch run quality
	[ "$status" -eq 0 ]
	[ "$(mutation_count)" -eq 1 ]
	job="$(job_capture)"
	assert_hardened_job "$job"
	run_id="$(yq -r '.metadata.labels."homelab-talos/benchmark-run"' "$job")"
	[[ "$run_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]]
	[ "$(yq -r '.spec.template.metadata.labels."homelab-talos/benchmark-run"' "$job")" = "$run_id" ]
	[ "$(yq -r '.spec.template.spec.containers[0].command | join(" ")' "$job")" = "/scripts/benchmark.sh quality $run_id" ]
	[[ "$output" == *"run_id=$run_id"* ]]
}

# Catches a finalist dispatch that forwards an unbound copy approval into the
# pod, where a successful full-title encode could otherwise persist output.
@test "finalist requires exact run and sample copy confirmation" {
	run_id='20260802T120000Z-1234abcd'
	sample_id='sample-avc'
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:finalist'
	assert_guard_refuses ENCODE_BENCHMARK_FINALIST_CONFIRM wrong:finalist \
		run finalist "$run_id" "$sample_id"

	export ENCODE_BENCHMARK_FINALIST_CONFIRM="copy:encode-benchmark:$run_id:$sample_id"
	run_dispatch run finalist "$run_id" "$sample_id"
	[ "$status" -eq 0 ]
	[ "$(mutation_count)" -eq 1 ]
}

# Catches cleanup accepting a generic delete token rather than one exact run
# handle, which would broaden a destructive operation beyond one run tree.
@test "cleanup requires the exact run-scoped confirmation before creating a Job" {
	run_id='20260802T120000Z-1234abcd'
	assert_guard_refuses ENCODE_BENCHMARK_CLEAN_CONFIRM delete:encode-benchmark:all \
		clean "$run_id"

	export ENCODE_BENCHMARK_CLEAN_CONFIRM="delete:encode-benchmark:$run_id"
	run_dispatch clean "$run_id"
	[ "$status" -eq 0 ]
	[ "$(mutation_count)" -eq 1 ]
}

# Catches validation after side effects: malformed mode, run, and sample inputs
# must be rejected before any cluster mutation is attempted.
@test "malformed dispatch inputs are refused before every mutation" {
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'
	run_dispatch run 'QUALITY'
	[ "$status" -ne 0 ]
	assert_no_mutations

	run_dispatch run quality '../bad-run'
	[ "$status" -ne 0 ]
	assert_no_mutations

	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:finalist'
	export ENCODE_BENCHMARK_FINALIST_CONFIRM='copy:encode-benchmark:bad:../sample'
	run_dispatch run finalist bad '../sample'
	[ "$status" -ne 0 ]
	assert_no_mutations

	export ENCODE_BENCHMARK_CLEAN_CONFIRM='delete:encode-benchmark:all'
	run_dispatch clean all
	[ "$status" -ne 0 ]
	assert_no_mutations
}

# Catches recipes that consult deployed-source drift only after dispatch. The
# PATH stub makes a stale origin/main comparison observable without Git or API access.
@test "deployed-source drift refuses capabilities census and run before dispatch" {
	export STUB_GIT_STALE=1
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	export ENCODE_BENCHMARK_CENSUS_CONFIRM='run:encode-benchmark:census'
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'

	for recipe in \
		encode-benchmark-capabilities \
		encode-benchmark-census \
		'encode-benchmark-run quality'; do
		read -r -a arguments <<<"$recipe"
		run just --justfile "$PROJECT_ROOT/kubernetes/mod.just" "${arguments[@]}"
		[ "$status" -ne 0 ]
		assert_no_mutations
	done
}

# Catches dispatching through an arbitrary kubeconfig target; confirmation is
# necessary but never sufficient to mutate a non-production API server.
@test "wrong API server is refused before every mutation" {
	export STUB_API_SERVER='https://example.invalid:6443'
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	run_dispatch capabilities
	[ "$status" -ne 0 ]
	assert_no_mutations
}

# Catches creating a second resource set under an ownership handle already
# present in the cluster instead of refusing the dispatcher correlation collision.
@test "generated run id collision is refused before resource creation" {
	export STUB_COLLISION=1
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'
	run_dispatch run quality
	[ "$status" -ne 0 ]
	[[ "$output" == *'generated benchmark run already has owned Jobs'* ]]
	assert_no_mutations
}

# Catches stale hash placeholders, image drift, and an accidental media/output
# mount in the capability probe's rendered Job.
@test "capability Job resolves current source identity and mounts only GPU scratch inputs" {
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	run_dispatch capabilities
	[ "$status" -eq 0 ]
	job="$(job_capture)"
	[ -n "$job" ]
	assert_hardened_job "$job"

	render="$BATS_TEST_TMPDIR/app-render.yaml"
	kustomize build "$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app" >"$render"
	expected_scripts="$(yq -r 'select(.kind == "ConfigMap" and (.metadata.name | test("^encode-benchmark-scripts-"))) | .metadata.name' "$render")"
	expected_image="$(yq -r '.data."samples.yaml" | from_yaml | .runtime.image' "$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/samples.yaml")"

	[ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "scripts") | .configMap.name' "$job")" = "$expected_scripts" ]
	[ "$(yq -r '.spec.template.spec.containers[0].image' "$job")" = "$expected_image" ]
	[ "$(yq -r '.spec.template.spec.containers[0].command | join(" ")' "$job")" = '/scripts/benchmark.sh capabilities' ]
	[ "$(yq -r '[.spec.template.spec.volumes[].name] | sort | join(",")' "$job")" = 'samples,scratch,scripts' ]
	[ "$(yq -r '.spec.template.spec.containers[0].resources.requests."gpu.intel.com/i915"' "$job")" = '1' ]
	# The probe writes a five-second synthetic encode, so reserving the benchmark
	# scratch budget would exceed node allocatable ephemeral storage and leave the
	# Job permanently Unschedulable while still reporting a clean dispatch.
	[ "$(yq -r '.spec.template.spec.containers[0].resources.requests."ephemeral-storage" // ""' "$job")" = '' ]
	[ "$(yq -r '.spec.template.spec.containers[0].resources.limits."ephemeral-storage" // ""' "$job")" = '' ]
	# Anti-affinity must survive: the probe still needs a GPU on a non-Plex node.
	[ -n "$(yq -r '.spec.template.spec.affinity // ""' "$job")" ]
	! yq -e '.. | select(tag == "!!str") | select(test("downloads|/media|/out"))' "$job"
}

# Catches census publication races: the inode ConfigMap must be owned by a
# suspended Job before that exact Job is unsuspended, and the Job never mounts downloads.
@test "census owns transient inventory before unsuspending a metadata-only Job" {
	export ENCODE_BENCHMARK_CENSUS_CONFIRM='run:encode-benchmark:census'
	run_dispatch census
	[ "$status" -eq 0 ]
	job="$(job_capture)"
	inventory="$(configmap_capture)"
	assert_hardened_job "$job"
	[ "$(yq -r '.spec.suspend' "$job")" = 'true' ]
	[ "$(yq -r '.metadata.ownerReferences[0].uid' "$inventory")" = 'fixture-job-uid' ]
	[ "$(yq -r '.metadata.ownerReferences[0].kind' "$inventory")" = 'Job' ]
	[ "$(yq -r '.spec.template.spec.affinity // ""' "$job")" = '' ]
	[ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "scratch") | .name' "$job")" = '' ]
	[ "$(yq -r '.spec.template.spec.containers[0].resources.requests."gpu.intel.com/i915" // ""' "$job")" = '' ]
	[ "$(yq -r '.spec.template.spec.containers[0].resources.requests."ephemeral-storage" // ""' "$job")" = '' ]
	[ "$(yq -r '[.spec.template.spec.volumes[].name] | sort | join(",")' "$job")" = 'inventory,media,out,samples,scripts' ]
	[ "$(yq -r '.spec.template.spec.automountServiceAccountToken' "$job")" = 'false' ]
	! yq -e '.. | select(tag == "!!str") | select(test("downloads"))' "$job"
	awk -F '\t' '
		$1 == "kubectl" && $2 ~ / exec / && !bridge {bridge=NR}
		$1 == "chmod" && $2 ~ /^0600 / && !staged {staged=NR}
		$1 == "kubectl" && $2 ~ / create / && $2 ~ /census[.]yaml/ && !job {job=NR}
		$1 == "kubectl" && $2 ~ / create / && $2 ~ /inventory-configmap[.]yaml/ && !configmap {configmap=NR}
		$1 == "kubectl" && $2 ~ / get configmap\// && !persisted {persisted=NR}
		$1 == "kubectl" && $2 ~ / patch / && !patched {patched=NR}
		END {exit !(bridge < staged && staged < job && job < configmap && configmap < persisted && persisted < patched)}
	' "$STUB_CALLS"
}

# Catches inventory failure or a failed mode-0600 stage occurring after a
# suspended Job has already been created and can be orphaned.
@test "census bridge and chmod failures happen before Job creation" {
	export ENCODE_BENCHMARK_CENSUS_CONFIRM='run:encode-benchmark:census'
	export STUB_INVENTORY_FAIL=1
	run_dispatch census
	[ "$status" -ne 0 ]
	awk -F '\t' '$1 == "kubectl" && $2 ~ / exec / {executed=1} $1 == "kubectl" && $2 ~ / (create|delete|patch) / {mutated=1} END {exit !(executed && !mutated)}' "$STUB_CALLS"

	: >"$STUB_CALLS"
	unset STUB_INVENTORY_FAIL
	export STUB_CHMOD_FAIL=1
	run_dispatch census
	[ "$status" -ne 0 ]
	awk -F '\t' '$1 == "chmod" && $2 ~ /^0600 / {staged=1} $1 == "kubectl" && $2 ~ / (create|delete|patch) / {mutated=1} END {exit !(staged && !mutated)}' "$STUB_CALLS"

	: >"$STUB_CALLS"
	unset STUB_CHMOD_FAIL
	export STUB_JOB_CREATE_FAIL=1
	run_dispatch census
	[ "$status" -ne 0 ]
	awk -F '\t' '$1 == "kubectl" && $2 ~ / create / && $2 ~ /census[.]yaml/ {created=1} $1 == "kubectl" && $2 ~ / delete job\// {deleted=1} END {exit !(created && deleted)}' "$STUB_CALLS"
	! awk -F '\t' '$1 == "kubectl" && $2 ~ / (create .*inventory-configmap|patch) / {found=1} END {exit !found}' "$STUB_CALLS"
}

# Catches any post-Job error path relying only on owner garbage collection or
# leaving a suspended Job/ConfigMap pair when render, create, persisted-owner
# proof, or unsuspension fails.
@test "census post-Job failures clean every possibly persisted remote resource" {
	export ENCODE_BENCHMARK_CENSUS_CONFIRM='run:encode-benchmark:census'

	for failure in STUB_CONFIGMAP_RENDER_FAIL STUB_CONFIGMAP_CREATE_FAIL STUB_CONFIGMAP_GET_FAIL STUB_PERSISTED_OWNER_BAD STUB_PATCH_FAIL; do
		: >"$STUB_CALLS"
		unset STUB_CONFIGMAP_RENDER_FAIL STUB_CONFIGMAP_CREATE_FAIL STUB_CONFIGMAP_GET_FAIL STUB_PERSISTED_OWNER_BAD STUB_PATCH_FAIL
		export "$failure=1"
		run_dispatch census
		[ "$status" -ne 0 ]
		awk -F '\t' '$1 == "kubectl" && $2 ~ / create / && $2 ~ /census[.]yaml/ {job=1} $1 == "kubectl" && $2 ~ / delete job\// {deleted_job=1} END {exit !(job && deleted_job)}' "$STUB_CALLS"
		if [[ "$failure" != 'STUB_CONFIGMAP_RENDER_FAIL' ]]; then
			awk -F '\t' '$1 == "kubectl" && $2 ~ / delete configmap\// {deleted_configmap=1} END {exit !deleted_configmap}' "$STUB_CALLS"
		fi
		if [[ "$failure" != 'STUB_PATCH_FAIL' ]]; then
			! awk -F '\t' '$1 == "kubectl" && $2 ~ / patch / {patched=1} END {exit !patched}' "$STUB_CALLS"
		fi
	done
}

# Catches cleanup inheriting the benchmark template's broad mounts or deleting
# anything other than one syntactically valid run directory inside /out/runs.
@test "cleanup Job mounts only out and removes exactly one validated run tree" {
	run_id='20260802T120000Z-1234abcd'
	export ENCODE_BENCHMARK_CLEAN_CONFIRM="delete:encode-benchmark:$run_id"
	run_dispatch clean "$run_id"
	[ "$status" -eq 0 ]
	job="$(job_capture)"
	assert_hardened_job "$job"
	[ "$(yq -r '[.spec.template.spec.volumes[].name] | join(",")' "$job")" = 'out' ]
	[ "$(yq -r '[.spec.template.spec.containers[0].volumeMounts[].name] | join(",")' "$job")" = 'out' ]
	[ "$(yq -r '.spec.template.spec.affinity // ""' "$job")" = '' ]
	[ "$(yq -r '.spec.template.spec.containers[0].resources.requests."gpu.intel.com/i915" // ""' "$job")" = '' ]
	command="$(yq -r '.spec.template.spec.containers[0].command | join(" ")' "$job")"
	[[ "$command" == *'rm -rf -- "$run_directory"'* ]]
	[[ "$command" == *'^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$'* ]]
	! yq -e '.. | select(tag == "!!str") | select(test("downloads|/media|/scratch|/scripts"))' "$job"

	cleanup_command="$(yq -r '.spec.template.spec.containers[0].command[4]' "$job")"
	configured_root="$(yq -r '.spec.template.spec.containers[0].command[8]' "$job")"
	[ "$configured_root" = '/out/runs' ]
	[ "$(yq -r '.spec.template.spec.containers[0].command[9]' "$job")" = '/out' ]
	sandbox_out="$BATS_TEST_TMPDIR/cleanup-out"
	outside="$BATS_TEST_TMPDIR/cleanup-outside"
	mkdir -p "$sandbox_out" "$outside/$run_id"
	printf '%s' 'preserve' >"$outside/$run_id/evidence"
	ln -s "$outside" "$sandbox_out/runs"
	run /bin/bash -euo pipefail -c "$cleanup_command" cleanup "$run_id" "$ENCODE_BENCHMARK_CLEAN_CONFIRM" "$sandbox_out/runs" "$sandbox_out"
	[ "$status" -eq 65 ]
	[ "$(<"$outside/$run_id/evidence")" = 'preserve' ]

	rm "$sandbox_out/runs"
	mkdir -p "$outside/runs"
	ln -s "$outside" "$sandbox_out/intermediate"
	run /bin/bash -euo pipefail -c "$cleanup_command" cleanup "$run_id" "$ENCODE_BENCHMARK_CLEAN_CONFIRM" "$sandbox_out/intermediate/runs" "$sandbox_out"
	[ "$status" -eq 65 ]
	[ "$(<"$outside/$run_id/evidence")" = 'preserve' ]
	rm "$sandbox_out/intermediate"

	mkdir -p "$sandbox_out/runs/$run_id"
	printf '%s' 'delete' >"$sandbox_out/runs/$run_id/evidence"
	run /bin/bash -euo pipefail -c "$cleanup_command" cleanup "$run_id" "$ENCODE_BENCHMARK_CLEAN_CONFIRM" "$sandbox_out/runs" "$sandbox_out"
	[ "$status" -eq 0 ]
	[ ! -e "$sandbox_out/runs/$run_id" ]
}

prepare_contention_source() {
	contention_app="$BATS_TEST_TMPDIR/contention-app"
	cp -R "$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app" "$contention_app"
	cat >"$contention_app/samples.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: encode-benchmark-samples
data:
  samples.yaml: |
    schemaVersion: 1
    runtime:
      image: docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb
    savingsSeed: 20260802
    qualityPanel:
      - id: z-4k-hdr
        cohort: hdr10
        path: /media/z-4k-hdr.mkv
        sizeBytes: 1
        width: 3840
        height: 2160
        sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        clips: {detail: '00:00:00.000'}
      - id: a-4k-hdr
        cohort: hdr10
        path: /media/a-4k-hdr.mkv
        sizeBytes: 1
        width: 3840
        height: 2160
        sha256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        clips: {detail: '00:00:00.000'}
      - id: c-1080-vc1
        cohort: vc1
        path: /media/c-1080-vc1.mkv
        sizeBytes: 1
        width: 1920
        height: 1080
        sha256: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
        clips: {detail: '00:00:00.000'}
      - id: b-1080-avc
        cohort: avc
        path: /media/b-1080-avc.mkv
        sizeBytes: 1
        width: 1920
        height: 1080
        sha256: dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
        clips: {detail: '00:00:00.000'}
      - id: d-dolby-vision
        cohort: dolby-vision
        path: /media/d-dolby-vision.mkv
        sizeBytes: 1
        width: 3840
        height: 2160
        sha256: eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
        detectionOnly: true
        clips: {}
    savingsPanel: []
    chosenSettings:
      avc: {globalQuality: 24, qualityRunId: 20260802T120000Z-aaaaaaaa}
      vc1: {globalQuality: 26, qualityRunId: 20260802T120000Z-aaaaaaaa}
      hdr10: {globalQuality: 22, qualityRunId: 20260802T120000Z-aaaaaaaa}
EOF
	export ENCODE_BENCHMARK_TEST_MODE=1
	export ENCODE_BENCHMARK_APP_DIR="$contention_app"
}

# Catches contention case selection drifting with panel row order, rendering
# the wrong worker cardinality, or sharing a node-bound immutable run identity.
@test "contention cases render deterministic worker runs under one dispatch group" {
	prepare_contention_source
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:contention-a'
	run_dispatch run contention-a
	[ "$status" -eq 0 ]
	[ "$(find "$STUB_CAPTURE_DIR" -maxdepth 1 -name 'Job-*.yaml' | wc -l | tr -d ' ')" -eq 1 ]
	job="$(job_capture)"
	run_id="$(yq -r '.metadata.labels."homelab-talos/benchmark-run"' "$job")"
	dispatch_id="$(yq -r '.metadata.labels."homelab-talos/benchmark-dispatch"' "$job")"
	[ "$dispatch_id" = "$run_id" ]
	[ "$(yq -r '.metadata.labels."homelab-talos/benchmark-worker"' "$job")" = 'worker-1' ]
	[ "$(yq -r '.spec.template.spec.containers[0].command | join(" ")' "$job")" = "/scripts/benchmark.sh contention $run_id a worker-1 a-4k-hdr" ]
	[[ "$output" == *"dispatch_id=$dispatch_id worker-1=$run_id"* ]]

	rm -f "$STUB_CAPTURE_DIR"/*.yaml "$STUB_CAPTURE_DIR/.count"
	: >"$STUB_CALLS"
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:contention-b'
	run_dispatch run contention-b
	[ "$status" -eq 0 ]
	[ "$(find "$STUB_CAPTURE_DIR" -maxdepth 1 -name 'Job-*.yaml' | wc -l | tr -d ' ')" -eq 2 ]
	mapfile -t jobs < <(find "$STUB_CAPTURE_DIR" -maxdepth 1 -name 'Job-*.yaml' -print | sort)
	commands="$BATS_TEST_TMPDIR/contention-commands"
	for contender in "${jobs[@]}"; do
		yq -r '[.metadata.labels."homelab-talos/benchmark-dispatch", .metadata.labels."homelab-talos/benchmark-worker", .metadata.labels."homelab-talos/benchmark-run", (.spec.template.spec.containers[0].command | join(" "))] | @tsv' "$contender"
	done | sort >"$commands"
	[ "$(wc -l <"$commands" | tr -d ' ')" -eq 2 ]
	[ "$(cut -f1 "$commands" | sort -u | wc -l | tr -d ' ')" -eq 1 ]
	[ "$(cut -f3 "$commands" | sort -u | wc -l | tr -d ' ')" -eq 2 ]
	dispatch_id="$(cut -f1 "$commands" | head -n 1)"
	worker_1_run="$(awk -F '\t' '$2 == "worker-1" {print $3}' "$commands")"
	worker_2_run="$(awk -F '\t' '$2 == "worker-2" {print $3}' "$commands")"
	[[ "$dispatch_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]]
	[[ "$worker_1_run" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]]
	[[ "$worker_2_run" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]]
	[ "$worker_1_run" != "$worker_2_run" ]
	rg -q "^$dispatch_id"$'\tworker-1\t'"$worker_1_run"$'\t/scripts/benchmark.sh contention '"$worker_1_run"' b worker-1 b-1080-avc$' "$commands"
	rg -q "^$dispatch_id"$'\tworker-2\t'"$worker_2_run"$'\t/scripts/benchmark.sh contention '"$worker_2_run"' b worker-2 c-1080-vc1$' "$commands"
	[[ "$output" == *"dispatch_id=$dispatch_id"* ]]
	[[ "$output" == *"worker-1=$worker_1_run"* ]]
	[[ "$output" == *"worker-2=$worker_2_run"* ]]
	for contender in "${jobs[@]}"; do
		assert_hardened_job "$contender"
		[ "$(yq -r '.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].labelSelector.matchExpressions[0].values[0]' "$contender")" = 'plex' ]
	done
}

# Catches an ambiguous single resume handle being reused by both B-D workers,
# or an ordered pair being parsed only after cluster mutation has started.
@test "two-worker contention resume requires an exact distinct ordered run pair" {
	prepare_contention_source
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:contention-b'
	worker_1_run='20260802T121500Z-11111111'
	worker_2_run='20260802T121500Z-22222222'

	run_dispatch run contention-b "$worker_1_run"
	[ "$status" -eq 64 ]
	assert_no_mutations

	run_dispatch run contention-b "$worker_1_run,$worker_1_run"
	[ "$status" -eq 64 ]
	assert_no_mutations

	run_dispatch run contention-b "$worker_1_run,../bad"
	[ "$status" -eq 64 ]
	assert_no_mutations

	run_dispatch run contention-b "$worker_1_run,$worker_2_run"
	[ "$status" -eq 0 ]
	[ "$(mutation_count)" -eq 2 ]
	mapfile -t jobs < <(find "$STUB_CAPTURE_DIR" -maxdepth 1 -name 'Job-*.yaml' -print | sort)
	[ "${#jobs[@]}" -eq 2 ]
	[ "$(yq -r '.metadata.labels."homelab-talos/benchmark-run"' "${jobs[0]}")" = "$worker_1_run" ]
	[ "$(yq -r '.metadata.labels."homelab-talos/benchmark-run"' "${jobs[1]}")" = "$worker_2_run" ]
	[ "$(yq -r '.metadata.labels."homelab-talos/benchmark-dispatch"' "${jobs[0]}")" = "$(yq -r '.metadata.labels."homelab-talos/benchmark-dispatch"' "${jobs[1]}")" ]
	[[ "$output" == *"worker-1=$worker_1_run"* ]]
	[[ "$output" == *"worker-2=$worker_2_run"* ]]
}

# Catches cluster mutation before the local committed panel proves every
# contention worker has an eligible sample and committed cohort setting.
@test "contention refuses absent eligible samples or chosen settings before mutation" {
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:contention-a'
	run_dispatch run contention-a
	[ "$status" -ne 0 ]
	[ "$output" = 'no eligible 3840x2160 HDR10 quality sample for contention case a' ]
	assert_no_mutations

	prepare_contention_source
	yq -i '.data."samples.yaml" |= (from_yaml | del(.chosenSettings.avc) | to_yaml)' "$contention_app/samples.yaml"
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:contention-b'
	run_dispatch run contention-b
	[ "$status" -ne 0 ]
	[ "$output" = 'no committed setting for contention sample cohort: avc' ]
	assert_no_mutations
}

# Catches dispatch inferring 4K/1080p from cohort labels instead of requiring
# the committed probe resolution for every selected contention worker.
@test "contention dispatch rejects missing or wrong exact resolution before mutation" {
	prepare_contention_source
	yq -i '.data."samples.yaml" |= (from_yaml | .qualityPanel[0].width = 1920 | .qualityPanel[1].width = 1920 | to_yaml)' "$contention_app/samples.yaml"
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:contention-a'
	run_dispatch run contention-a
	[ "$status" -ne 0 ]
	[ "$output" = 'no eligible 3840x2160 HDR10 quality sample for contention case a' ]
	assert_no_mutations

	yq -i '.data."samples.yaml" |= (from_yaml | .qualityPanel[0].width = 3840 | .qualityPanel[1].width = 3840 | del(.qualityPanel[2].height) | to_yaml)' "$contention_app/samples.yaml"
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:contention-b'
	run_dispatch run contention-b
	[ "$status" -ne 0 ]
	[ "$output" = 'fewer than two eligible 1920x1080 non-DV quality samples for contention case b' ]
	assert_no_mutations
}

write_results_fixtures() {
	local run_id="$1" image_id="$2"
	STUB_JOBS_JSON="$BATS_TEST_TMPDIR/jobs.json"
	STUB_PODS_JSON="$BATS_TEST_TMPDIR/pods.json"
	STUB_LOGS_FILE="$BATS_TEST_TMPDIR/logs.txt"
	export STUB_JOBS_JSON STUB_PODS_JSON STUB_LOGS_FILE
	cat >"$STUB_JOBS_JSON" <<EOF
{"apiVersion":"v1","items":[{"metadata":{"name":"encode-benchmark-capabilities-fixture","uid":"fixture-job-uid","labels":{"app.kubernetes.io/name":"encode-benchmark","homelab-talos/benchmark-run":"$run_id","homelab-talos/benchmark-mode":"capabilities"}},"status":{"conditions":[{"type":"Complete","status":"True"}],"succeeded":1,"failed":0,"startTime":"2026-08-02T12:00:00Z","completionTime":"2026-08-02T12:01:00Z"}}]}
EOF
	cat >"$STUB_PODS_JSON" <<EOF
{"apiVersion":"v1","items":[{"metadata":{"name":"encode-benchmark-capabilities-fixture-pod","labels":{"job-name":"encode-benchmark-capabilities-fixture","homelab-talos/benchmark-run":"$run_id"},"ownerReferences":[{"apiVersion":"batch/v1","kind":"Job","name":"encode-benchmark-capabilities-fixture","uid":"fixture-job-uid","controller":true,"blockOwnerDeletion":true}]},"spec":{"nodeName":"nuc2"},"status":{"phase":"Succeeded","containerStatuses":[{"name":"benchmark","imageID":"$image_id"}]}}]}
EOF
	cat >"$STUB_LOGS_FILE" <<'EOF'
{"status":"passed","uid":568,"hevcQsv":true,"realQsvEncode":true,"decoded":true,"libvmaf4k":true,"libx265":true,"nodeName":"nuc2","configuredImage":"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb","configuredImageDigest":"sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb","sourcePath":"/media/Secret Movie.mkv","source_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","credential":"dont-print-me"}
EOF
}

# Catches trusting benchmark-reported configured identity as runtime evidence;
# results must compare the completed pod's actual imageID and redact media evidence.
@test "results accepts matching actual imageID and prints only sanitized evidence" {
	run_id='20260802T120000Z-1234abcd'
	write_results_fixtures "$run_id" 'docker-pullable://docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -eq 0 ]
	[[ "$output" == *'phase=Complete succeeded=1 failed=0'* ]]
	[[ "$output" == *'node=nuc2'* ]]
	[[ "$output" == *'actual_image_id=docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'* ]]
	[[ "$output" == *"artifact_location=/out/runs/$run_id"* ]]
	[[ "$output" != *'/media/Secret Movie.mkv'* ]]
	[[ "$output" != *'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'* ]]
	[[ "$output" != *'dont-print-me'* ]]
	awk -F '\t' -v run_id="$run_id" '$1 == "kubectl" && $2 ~ ("homelab-talos/benchmark-run=" run_id) {selected=1} END {exit !selected}' "$STUB_CALLS"
	assert_no_mutations
}

# Catches accepting missing, malformed, or digest-mismatched kubelet imageID
# fields as verified capability evidence.
@test "results rejects missing malformed and mismatched actual imageID evidence" {
	run_id='20260802T120000Z-1234abcd'
	for image_id in \
		'' \
		'containerd://not-an-image-digest' \
		'docker-pullable://docker.io/linuxserver/ffmpeg@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; do
		write_results_fixtures "$run_id" "$image_id"
		run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
		[ "$status" -ne 0 ]
		[[ "$output" == *'actual image identity evidence rejected'* ]]
		assert_no_mutations
	done
}

# Catches capability evidence being accepted from an unfinished/failed Job or
# from a label-spoofed pod that is not the one completed pod controlled by the
# exact selected Job UID.
@test "capability results require one Complete Job and one Succeeded controlled pod" {
	run_id='20260802T120000Z-1234abcd'
	image_id='docker-pullable://docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'

	write_results_fixtures "$run_id" "$image_id"
	jq '.items[0].status = {active:1,startTime:"2026-08-02T12:00:00Z"}' "$STUB_JOBS_JSON" >"$STUB_JOBS_JSON.tmp"
	mv "$STUB_JOBS_JSON.tmp" "$STUB_JOBS_JSON"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -ne 0 ]
	[[ "$output" == *'capability result provenance rejected'* ]]

	write_results_fixtures "$run_id" "$image_id"
	jq '.items[0].status.conditions = [{type:"Failed",status:"True"}] | .items[0].status.failed = 1 | .items[0].status.succeeded = 0' "$STUB_JOBS_JSON" >"$STUB_JOBS_JSON.tmp"
	mv "$STUB_JOBS_JSON.tmp" "$STUB_JOBS_JSON"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -ne 0 ]
	[[ "$output" == *'capability result provenance rejected'* ]]

	write_results_fixtures "$run_id" "$image_id"
	jq '.items[0].status.phase = "Running"' "$STUB_PODS_JSON" >"$STUB_PODS_JSON.tmp"
	mv "$STUB_PODS_JSON.tmp" "$STUB_PODS_JSON"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -ne 0 ]
	[[ "$output" == *'capability result provenance rejected'* ]]

	write_results_fixtures "$run_id" "$image_id"
	printf '%s\n' '{"apiVersion":"v1","items":[]}' >"$STUB_PODS_JSON"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -ne 0 ]
	[[ "$output" == *'capability result provenance rejected'* ]]

	write_results_fixtures "$run_id" "$image_id"
	jq 'del(.items[0].metadata.uid)' "$STUB_JOBS_JSON" >"$STUB_JOBS_JSON.tmp"
	mv "$STUB_JOBS_JSON.tmp" "$STUB_JOBS_JSON"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -ne 0 ]
	[[ "$output" == *'capability result provenance rejected'* ]]

	write_results_fixtures "$run_id" "$image_id"
	jq 'del(.items[0].metadata.ownerReferences)' "$STUB_PODS_JSON" >"$STUB_PODS_JSON.tmp"
	mv "$STUB_PODS_JSON.tmp" "$STUB_PODS_JSON"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -ne 0 ]
	[[ "$output" == *'capability result provenance rejected'* ]]

	write_results_fixtures "$run_id" "$image_id"
	jq '.items[0].metadata.ownerReferences[0].uid = "spoofed-job-uid"' "$STUB_PODS_JSON" >"$STUB_PODS_JSON.tmp"
	mv "$STUB_PODS_JSON.tmp" "$STUB_PODS_JSON"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -ne 0 ]
	[[ "$output" == *'capability result provenance rejected'* ]]

	write_results_fixtures "$run_id" "$image_id"
	jq '.items += [.items[0]]' "$STUB_JOBS_JSON" >"$STUB_JOBS_JSON.tmp"
	mv "$STUB_JOBS_JSON.tmp" "$STUB_JOBS_JSON"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -ne 0 ]
	[[ "$output" == *'capability result provenance rejected'* ]]

	write_results_fixtures "$run_id" "$image_id"
	jq '.items += [.items[0]]' "$STUB_PODS_JSON" >"$STUB_PODS_JSON.tmp"
	mv "$STUB_PODS_JSON.tmp" "$STUB_PODS_JSON"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -ne 0 ]
	[[ "$output" == *'capability result provenance rejected'* ]]
	assert_no_mutations
}

# Catches preflight using allocatable ephemeral-storage as a proxy for current
# free NVMe, or treating the Plex node as eligible despite available GPU slots.
@test "preflight reports every node and requires non-Plex GPU plus 200Gi actual free NVMe" {
	STUB_PODS_JSON="$BATS_TEST_TMPDIR/plex-pods.json"
	STUB_NODES_JSON="$BATS_TEST_TMPDIR/nodes.json"
	STUB_PVC_JSON="$BATS_TEST_TMPDIR/pvc.json"
	STUB_KUSTOMIZATION_JSON="$BATS_TEST_TMPDIR/kustomization.json"
	STUB_SUMMARY_DIR="$BATS_TEST_TMPDIR/summaries"
	export STUB_PODS_JSON STUB_NODES_JSON STUB_PVC_JSON STUB_KUSTOMIZATION_JSON STUB_SUMMARY_DIR
	mkdir -p "$STUB_SUMMARY_DIR"
	cat >"$STUB_PODS_JSON" <<'EOF'
{"items":[{"metadata":{"name":"plex-0"},"spec":{"nodeName":"nuc1"},"status":{"phase":"Running"}}]}
EOF
	cat >"$STUB_NODES_JSON" <<'EOF'
{"items":[{"metadata":{"name":"nuc1"},"status":{"allocatable":{"gpu.intel.com/i915":"1"}}},{"metadata":{"name":"nuc2"},"status":{"allocatable":{"gpu.intel.com/i915":"1"}}},{"metadata":{"name":"nuc3"},"status":{"allocatable":{"gpu.intel.com/i915":"1"}}}]}
EOF
	cat >"$STUB_PVC_JSON" <<'EOF'
{"metadata":{"name":"media-data"},"status":{"phase":"Bound"}}
EOF
	cat >"$STUB_KUSTOMIZATION_JSON" <<'EOF'
{"metadata":{"name":"encode-benchmark"},"spec":{"suspend":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}
EOF
	printf '%s\n' '{"node":{"fs":{"availableBytes":536870912000}}}' >"$STUB_SUMMARY_DIR/nuc1.json"
	printf '%s\n' '{"node":{"fs":{"availableBytes":107374182400}}}' >"$STUB_SUMMARY_DIR/nuc2.json"
	printf '%s\n' '{"node":{"fs":{"availableBytes":322122547200}}}' >"$STUB_SUMMARY_DIR/nuc3.json"

	run "$PREFLIGHT" "$KUBECONFIG_FIXTURE"
	[ "$status" -eq 0 ]
	[[ "$output" == *'nuc1 FAIL plex-node'* ]]
	[[ "$output" == *'nuc2 FAIL free-nvme-below-200Gi'* ]]
	[[ "$output" == *'nuc3 PASS'* ]]
	assert_no_mutations
}

# Catches live verification accepting absent/unscheduled Plex, suspended/unready
# inert inputs, a standing benchmark workload, or a benchmark pod co-resident
# with Plex. Every query is read-only.
@test "verify requires scheduled Running Plex before proving pod separation" {
	VERIFY="$PROJECT_ROOT/scripts/verify/encode-benchmark.sh"
	STUB_KUSTOMIZATION_JSON="$BATS_TEST_TMPDIR/verify-kustomization.json"
	STUB_PRIORITYCLASS_JSON="$BATS_TEST_TMPDIR/priorityclass.json"
	STUB_CONFIGMAPS_JSON="$BATS_TEST_TMPDIR/configmaps.json"
	STUB_PROMETHEUSRULE_JSON="$BATS_TEST_TMPDIR/prometheusrule.json"
	STUB_PERSISTENT_JSON="$BATS_TEST_TMPDIR/persistent.json"
	STUB_PLEX_PODS_JSON="$BATS_TEST_TMPDIR/verify-plex-pods.json"
	STUB_BENCHMARK_PODS_JSON="$BATS_TEST_TMPDIR/verify-benchmark-pods.json"
	export STUB_KUSTOMIZATION_JSON STUB_PRIORITYCLASS_JSON STUB_CONFIGMAPS_JSON
	export STUB_PROMETHEUSRULE_JSON STUB_PERSISTENT_JSON STUB_PLEX_PODS_JSON STUB_BENCHMARK_PODS_JSON
	printf '%s\n' '{"spec":{"suspend":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}' >"$STUB_KUSTOMIZATION_JSON"
	printf '%s\n' '{"metadata":{"name":"encode-benchmark-background"},"value":-10}' >"$STUB_PRIORITYCLASS_JSON"
	printf '%s\n' '{"items":[{"metadata":{"name":"encode-benchmark-samples"}},{"metadata":{"name":"encode-benchmark-scripts-dd454g82km"}}]}' >"$STUB_CONFIGMAPS_JSON"
	printf '%s\n' '{"metadata":{"name":"encode-benchmark"}}' >"$STUB_PROMETHEUSRULE_JSON"
	printf '%s\n' '{"items":[]}' >"$STUB_PERSISTENT_JSON"
	printf '%s\n' '{"items":[{"metadata":{"name":"encode-benchmark-quality-fixture"},"spec":{"nodeName":"nuc3"},"status":{"phase":"Running"}}]}' >"$STUB_BENCHMARK_PODS_JSON"

	printf '%s\n' '{"items":[]}' >"$STUB_PLEX_PODS_JSON"
	run "$VERIFY" "$KUBECONFIG_FIXTURE"
	[ "$status" -ne 0 ]
	[[ "$output" == *'Plex has no Running pod with a scheduled node'* ]]
	assert_no_mutations

	printf '%s\n' '{"items":[{"metadata":{"name":"plex-0"},"spec":{},"status":{"phase":"Pending"}}]}' >"$STUB_PLEX_PODS_JSON"
	run "$VERIFY" "$KUBECONFIG_FIXTURE"
	[ "$status" -ne 0 ]
	[[ "$output" == *'Plex has no Running pod with a scheduled node'* ]]
	assert_no_mutations

	printf '%s\n' '{"items":[{"metadata":{"name":"plex-0"},"spec":{"nodeName":"nuc1"},"status":{"phase":"Running"}}]}' >"$STUB_PLEX_PODS_JSON"
	run "$VERIFY" "$KUBECONFIG_FIXTURE"
	[ "$status" -eq 0 ]
	[[ "$output" == *'encode-benchmark verification passed'* ]]
	awk -F '\t' '
		$1 == "kubectl" && $2 ~ / get configmaps / {
			queried=1
			if ($2 ~ / --selector /) bad=1
		}
		END {exit (!queried || bad)}
	' "$STUB_CALLS"
	assert_no_mutations

	printf '%s\n' '{"items":[{"metadata":{"name":"encode-benchmark-quality-fixture"},"spec":{"nodeName":"nuc1"},"status":{"phase":"Running"}}]}' >"$STUB_BENCHMARK_PODS_JSON"
	run "$VERIFY" "$KUBECONFIG_FIXTURE"
	[ "$status" -ne 0 ]
	[[ "$output" == *'benchmark pod is co-resident with Plex'* ]]
	assert_no_mutations
}
