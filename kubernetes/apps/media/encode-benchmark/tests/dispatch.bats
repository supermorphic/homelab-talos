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
	export ENCODE_BENCHMARK_HANDOFF_WAIT_SECONDS=0
	create_cluster_stubs
	STUB_NODES_JSON="$BATS_TEST_TMPDIR/default-nodes.json"
	STUB_PODS_JSON="$BATS_TEST_TMPDIR/default-pods.json"
	export STUB_NODES_JSON STUB_PODS_JSON
	cat >"$STUB_NODES_JSON" <<'EOF'
{"items":[{"metadata":{"name":"nuc1"},"status":{"allocatable":{"gpu.intel.com/i915":"1"}}},{"metadata":{"name":"nuc2"},"status":{"allocatable":{"gpu.intel.com/i915":"1"}}},{"metadata":{"name":"nuc3"},"status":{"allocatable":{"gpu.intel.com/i915":"1"}}}]}
EOF
	cat >"$STUB_PODS_JSON" <<'EOF'
{"items":[{"metadata":{"name":"plex-0","namespace":"media","labels":{"app.kubernetes.io/name":"plex"}},"spec":{"nodeName":"nuc2","containers":[{"name":"plex","resources":{"requests":{"gpu.intel.com/i915":"0"}}}]},"status":{"phase":"Running"}}]}
EOF
	prepare_evidence_source
	set_capability_evidence verified "$(valid_capability_evidence)"
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
	echo 'unexpected kubectl exec in encode-benchmark test' >&2
	exit 98
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
	if [[ "$kind" == 'Job' && ("${STUB_JOB_CREATE_FAIL:-0}" == '1' ||
		"${STUB_JOB_CREATE_FAIL_AT:-0}" == "$count") ]]; then
		exit 25
	fi
	uid='fixture-job-uid'
	[[ "$kind" != 'ConfigMap' ]] || uid='fixture-configmap-uid'
	created="$(RESOURCE_UID="$uid" yq -o=json -I=0 '.metadata.uid = strenv(RESOURCE_UID)' "$capture")"
	if [[ "${STUB_JOB_CREATE_RESPONSE_METADATA_BAD:-0}" == '1' && "$kind" == 'Job' ]]; then
		created="$(yq -p=json -o=json -I=0 '.metadata.labels."homelab-talos/benchmark-dispatch" = "20260802T120000Z-deadbeef"' <<<"$created")"
	fi
	printf '%s\n' "$created"
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
	if [[ "${STUB_CONFIGMAP_REPLACE_BEFORE_DELETE:-0}" == '1' && "$*" == *' configmap/'* &&
		"$*" != *' --preconditions=uid=fixture-configmap-uid'* ]]; then
		: >"$STUB_CAPTURE_DIR/unsafe-configmap-delete"
	fi
	printf '%s\n' 'job.batch/fixture deleted'
	exit 0
fi

if contains logs "$@"; then
	if [[ "$*" == *' pod/'* ]]; then
		[[ "${STUB_HANDOFF_LOG_READY:-1}" == '1' ]] && printf '%s\n' 'running_image_evidence=accepted'
		exit 0
	fi
	log_path=''
	if [[ -n "${STUB_LOGS_DIR:-}" ]]; then
		resource=''
		for argument in "$@"; do
			if [[ "$argument" == job/* ]]; then resource="${argument#job/}"; fi
		done
		log_path="$STUB_LOGS_DIR/$resource.log"
	elif [[ -n "${STUB_LOGS_FILE:-}" ]]; then
		log_path="$STUB_LOGS_FILE"
	fi
	if [[ -n "$log_path" ]]; then
		tail_count="$(argument_after --tail "$@" || true)"
		for argument in "$@"; do
			[[ "$argument" == --tail=* ]] && tail_count="${argument#--tail=}"
		done
		if [[ -n "$tail_count" ]]; then
			[[ "$tail_count" =~ ^[0-9]+$ ]] || exit 64
			tail -n "$tail_count" "$log_path"
		else
			sed -n '1,$p' "$log_path"
		fi
	fi
	exit 0
fi

if contains get "$@" && contains jobs "$@"; then
	if [[ "$*" == *'homelab-talos/benchmark-run='* && "${STUB_COLLISION:-0}" == '1' ]]; then
		printf '%s\n' '{"apiVersion":"v1","items":[{"metadata":{"name":"existing-run"}}]}'
	elif [[ "$*" == *'homelab-talos/benchmark-run='* && -n "${STUB_RUN_JOBS_JSON:-}" ]]; then
		sed -n '1,$p' "$STUB_RUN_JOBS_JSON"
	elif [[ -n "${STUB_JOBS_JSON:-}" ]]; then
		sed -n '1,$p' "$STUB_JOBS_JSON"
	else
		printf '%s\n' '{"apiVersion":"v1","items":[]}'
	fi
	exit 0
fi

if contains get "$@" && [[ "$*" == *' job/'* ]]; then
	resource=''
	for argument in "$@"; do
		if [[ "$argument" == job/* ]]; then resource="$argument"; fi
	done
	name="${resource#job/}"
	if [[ "$name" == encode-benchmark-evidence-reader-* ]]; then
		[[ "${STUB_READER_NAME_QUERY_FAIL:-0}" != '1' ]] || exit 27
		if [[ -n "${STUB_READER_NAME_JOB_JSON:-}" ]]; then
			sed -n '1,$p' "$STUB_READER_NAME_JOB_JSON"
		fi
		exit 0
	fi
	capture="$STUB_CAPTURE_DIR/Job-$name.yaml"
	live_job="$(yq -o=json -I=0 '.metadata.uid = "fixture-job-uid"' "$capture")"
	if [[ "${STUB_JOB_REPLACEMENT:-0}" == '1' ]]; then
		live_job="$(yq -p=json -o=json -I=0 '.metadata.uid = "replacement-job-uid"' <<<"$live_job")"
	fi
	printf '%s\n' "$live_job"
	exit 0
fi

if contains get "$@" && contains pods "$@"; then
	if [[ "$*" == *'job-name='* ]]; then
		selector="$(argument_after --selector "$@")"
		job_name="${selector#job-name=}"
		job="$STUB_CAPTURE_DIR/Job-$job_name.yaml"
		sequence_step=0
		if [[ "${STUB_HANDOFF_POD_SEQUENCE:-0}" == '1' ]]; then
			sequence_file="$STUB_CAPTURE_DIR/.pod-sequence-$job_name"
			[[ ! -f "$sequence_file" ]] || read -r sequence_step <"$sequence_file"
			sequence_step=$((sequence_step + 1))
			printf '%s\n' "$sequence_step" >"$sequence_file"
		fi
		if [[ "${STUB_HANDOFF_POD_COUNT:-1}" == '0' || "$sequence_step" == '1' ]]; then
			printf '%s\n' '{"apiVersion":"v1","items":[]}'
		else
			image="$(yq -r '.spec.template.spec.containers[] | select(.name == "benchmark") | .image' "$job")"
			if [[ "${STUB_HANDOFF_IMAGE_MISSING:-0}" == '1' ]]; then
				image_id=''
			else
				image_id="${STUB_HANDOFF_IMAGE_ID:-containerd://$image}"
			fi
			owner_uid='fixture-job-uid'
			[[ "${STUB_HANDOFF_BAD_OWNER:-0}" != '1' ]] || owner_uid='spoofed-owner-uid'
			jq -n -c --arg job "$job_name" --arg uid "$owner_uid" --arg image "$image_id" \
				--argjson pending "$( [[ "$sequence_step" == '2' ]] && printf true || printf false )" \
				--argjson extra "$( [[ "${STUB_HANDOFF_EXTRA_OWNER:-0}" == '1' ]] && printf true || printf false )" '
				{apiVersion:"v1",items:[{
					metadata:{name:($job + "-pod"),labels:{"job-name":$job},ownerReferences:
						([{apiVersion:"batch/v1",kind:"Job",name:$job,uid:$uid,controller:true,blockOwnerDeletion:true}] +
						(if $extra then [{apiVersion:"v1",kind:"ConfigMap",name:"foreign-owner",uid:"foreign-owner-uid",controller:false,blockOwnerDeletion:false}] else [] end))},
					status:({phase:(if $pending then "Pending" else "Running" end)} +
						(if $pending then {} else {containerStatuses:[{name:"benchmark",imageID:$image}]} end))
				}]}'
		fi
	elif [[ "$*" == *'app.kubernetes.io/name=encode-benchmark'* && -n "${STUB_BENCHMARK_PODS_JSON:-}" ]]; then
		benchmark_pods_source="$STUB_BENCHMARK_PODS_JSON"
		sed -n '1,$p' "$benchmark_pods_source"
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
	if [[ ! -f "$capture" && -n "${STUB_IMAGE_EVIDENCE_DIR:-}" ]]; then
		capture="$STUB_IMAGE_EVIDENCE_DIR/$name.json"
	fi
	persisted="$(yq -o=json -I=0 '.metadata.uid = "fixture-configmap-uid"' "$capture")"
	if [[ "${STUB_PERSISTED_OWNER_BAD:-0}" == '1' ]]; then
		persisted="$(yq -p=json -o=json -I=0 '.metadata.ownerReferences[0].uid = "spoofed-owner-uid"' <<<"$persisted")"
	fi
	if [[ "${STUB_PERSISTED_EXTRA_OWNER:-0}" == '1' ]]; then
		persisted="$(yq -p=json -o=json -I=0 '.metadata.ownerReferences += [{"apiVersion":"v1","kind":"ConfigMap","name":"foreign-owner","uid":"foreign-owner-uid","controller":false,"blockOwnerDeletion":false}]' <<<"$persisted")"
	fi
	printf '%s\n' "$persisted"
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
if [[ -n "${JOB_NAME:-}" && "${STUB_JOB_RENDER_FAIL_AT:-0}" != '0' ]]; then
	count_file="$STUB_CAPTURE_DIR/.job-render-count"
	count=0
	[[ ! -f "$count_file" ]] || read -r count <"$count_file"
	count=$((count + 1))
	printf '%s\n' "$count" >"$count_file"
	if [[ "$count" == "$STUB_JOB_RENDER_FAIL_AT" ]]; then
		exit 30
	fi
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

# Shared mutation-count and confirmation helpers for guarded dispatch tests.
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

prepare_evidence_source() {
	evidence_app="$BATS_TEST_TMPDIR/evidence-app"
	if [[ ! -d "$evidence_app" ]]; then
		cp -R "$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app" "$evidence_app"
	fi
	export ENCODE_BENCHMARK_APP_DIR="$evidence_app"
}

write_deployed_samples_configmap() {
	local samples_json="$1"
	DEPLOYED_SAMPLES_JSON="$samples_json" yq -n '
		.apiVersion = "v1" |
		.kind = "ConfigMap" |
		.metadata.name = "encode-benchmark-samples" |
		.metadata.namespace = "media" |
		.data."samples.json" = load_str(strenv(DEPLOYED_SAMPLES_JSON))
	' >"$STUB_CAPTURE_DIR/ConfigMap-encode-benchmark-samples.yaml"
}

assert_call_precedes_first_create() {
	local pattern="$1"
	awk -F '\t' -v pattern="$pattern" '
		$1 == "kubectl" && $2 ~ /(^| )create( |$)/ && first_create == 0 { first_create = NR }
		$1 == "kubectl" && $2 ~ pattern && first_match == 0 { first_match = NR }
		END { exit !(first_match > 0 && (first_create == 0 || first_match < first_create)) }
	' "$STUB_CALLS"
}

set_capability_evidence() {
	local status="$1" evidence="$2"
	CAPABILITY_STATUS="$status" CAPABILITY_EVIDENCE="$evidence" yq -i '
		.data."samples.json" |= (
			from_yaml |
			.runtime.capabilityStatus = strenv(CAPABILITY_STATUS) |
			.runtime.capabilityEvidence = (strenv(CAPABILITY_EVIDENCE) | from_json) |
			to_json
		)
	' "$evidence_app/samples.yaml"
}

valid_capability_evidence() {
	printf '%s\n' '{"nodes":[{"nodeName":"nuc1","strategyId":"qsv-hevc-icq-v1","proofSchemaVersion":3,"initialization":"passed","initializationReason":"","renderNode":"/dev/dri/renderD128","drmDriver":"i915","selectedRateControl":"ICQ","telemetryStatus":"available","telemetryReason":"","videoBusyNanoseconds":800000000,"videoBusyPercent":40,"encodeFps":72,"encodeSpeed":1.25,"decode":"passed","vmaf":"passed","diagnosticCapabilities":{"imageId":"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb","verifiedAt":"2026-08-14T18:00:00Z","traceHeaders":"passed","libvmaf":"passed","ssim":"passed","psnr":"passed","bestEffortTimestampTime":"passed","packetDurationTime":"passed","keyFrame":"passed","pictType":"passed"},"proofStatus":"passed","proofReasons":"","verifiedAt":"2026-08-14T18:00:00Z","configuredImageDigest":"sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb","imageId":"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb"}]}'
}

two_passing_capability_nodes() {
	jq -c '.nodes += [(.nodes[0] | .nodeName = "nuc3")]' <<<"$(valid_capability_evidence)"
}

@test "capabilities requires the exact confirmation before creating a Job" {
	assert_guard_refuses ENCODE_BENCHMARK_CAPABILITIES_CONFIRM wrong:capabilities capabilities

	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	run_dispatch capabilities
	[ "$status" -eq 0 ]
	[ "$(mutation_count)" -eq 4 ]
}

# Catches capability dispatch proving only a scheduler-selected node instead of
# every currently eligible non-Plex node with a free i915 slot.
@test "capability dispatch creates one deterministic targeted Job per eligible node" {
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	run_dispatch capabilities
	[ "$status" -eq 0 ]
	[ "$(find "$STUB_CAPTURE_DIR" -maxdepth 1 -name 'Job-*.yaml' | wc -l | tr -d ' ')" -eq 2 ]

	for node in nuc1 nuc3; do
		job="$(find "$STUB_CAPTURE_DIR" -maxdepth 1 -name "Job-*-node-$node.yaml" -print)"
		[ -n "$job" ]
		[ "$(yq -r '.spec.template.spec.nodeSelector."kubernetes.io/hostname"' "$job")" = "$node" ]
		name="$(yq -r '.metadata.name' "$job")"
		[ "${#name}" -le 63 ]
		[[ "$name" =~ ^encode-benchmark-cap-20260802t120000z-[0-9a-f]{8}-node-$node$ ]]
	done
	[[ "$output" == *'nodes=nuc1 nuc3'* ]]
}

# Catches truncation that either exceeds the Job controller label limit or maps
# two long node names with the same prefix to one capability Job name.
@test "capability dispatch bounds and disambiguates long node Job names" {
	label="$(printf 'a%.0s' {1..59})"
	tail="$(printf 'b%.0s' {1..53})"
	first_node="$label.$label.$label.${tail}alpha"
	second_node="$label.$label.$label.${tail}bravo"
	jq -n --arg first "$first_node" --arg second "$second_node" '{items:[$first,$second] | map({metadata:{name:.},status:{allocatable:{"gpu.intel.com/i915":"1"}}})}' \
		>"$STUB_NODES_JSON"
	printf '%s\n' '{"items":[]}' >"$STUB_PODS_JSON"
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	run_dispatch capabilities
	[ "$status" -eq 0 ]
	mapfile -t jobs < <(find "$STUB_CAPTURE_DIR" -maxdepth 1 -name 'Job-*.yaml' -print | sort)
	[ "${#jobs[@]}" -eq 2 ]

	first_name="$(yq -r '.metadata.name' "${jobs[0]}")"
	second_name="$(yq -r '.metadata.name' "${jobs[1]}")"
	[ "${#first_name}" -le 63 ]
	[ "${#second_name}" -le 63 ]
	[ "$first_name" != "$second_name" ]
	[ "$(yq -r '.spec.template.spec.nodeSelector."kubernetes.io/hostname"' "${jobs[0]}")" != \
		"$(yq -r '.spec.template.spec.nodeSelector."kubernetes.io/hostname"' "${jobs[1]}")" ]
}

# Catches creating an earlier node Job before every later node manifest has
# rendered successfully, which would leave a partial dispatch on local failure.
@test "capability dispatch renders every node before the first create" {
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	export STUB_JOB_RENDER_FAIL_AT=2
	run_dispatch capabilities
	[ "$status" -ne 0 ]
	assert_no_mutations
}

# Catches broad rollback that deletes pre-existing Jobs or the failed create
# target instead of only Jobs successfully created by this dispatch.
@test "partial per-node capability create deletes only Jobs created by that dispatch" {
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	export STUB_JOB_CREATE_FAIL_AT=2
	run_dispatch capabilities
	[ "$status" -ne 0 ]
	awk -F '\t' '$1 == "kubectl" && $2 ~ / delete job\/encode-benchmark-cap-.*-node-nuc1 / {found=1} END {exit !found}' "$STUB_CALLS"
	! awk -F '\t' '$1 == "kubectl" && $2 ~ / delete job\/encode-benchmark-cap-.*-node-nuc3 / {found=1} END {exit !found}' "$STUB_CALLS"
}

# Catches a dispatcher that starts benchmark work from its configured image
# alone instead of binding one exact controlled pod's kubelet imageID through a
# run-owned, mounted ConfigMap before the runtime proceeds.
@test "dispatch completes the owned running-image handoff before benchmark work" {
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	run_dispatch capabilities
	[ "$status" -eq 0 ]

	for node in nuc1 nuc3; do
		job="$(find "$STUB_CAPTURE_DIR" -maxdepth 1 -name "Job-*-node-$node.yaml" -print)"
		name="$(yq -r '.metadata.name' "$job")"
		configmap_name="$(yq -r '.metadata.annotations."homelab-talos/image-evidence-configmap"' "$job")"
		configmap="$STUB_CAPTURE_DIR/ConfigMap-$configmap_name.yaml"
		[ -f "$configmap" ]
		[ "$(yq -r '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "image-evidence") | [.mountPath,.readOnly] | @tsv' "$job")" = $'/provenance\ttrue' ]
		[ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "image-evidence") | [.configMap.name,.configMap.optional,.configMap.items[0].key,.configMap.items[0].path] | @tsv' "$job")" = "$configmap_name"$'\ttrue\timage.json\timage.json' ]
		[ "$(yq -r '.metadata.ownerReferences[0] | [.apiVersion,.kind,.name,.uid,.controller,.blockOwnerDeletion] | @tsv' "$configmap")" = $'batch/v1\tJob\t'"$name"$'\tfixture-job-uid\ttrue\ttrue' ]
		run jq -e '
			keys == ["configuredImage","dispatchedImage","imageId"] and
			.configuredImage == "docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb" and
			.dispatchedImage == .configuredImage and .imageId == .configuredImage
		' <<<"$(yq -r '.data."image.json"' "$configmap")"
		[ "$status" -eq 0 ]
	done
	awk -F '\t' '
		$1 == "kubectl" && $2 ~ / create / && $2 ~ /encode-benchmark-cap-/ {jobs += 1; next}
		$1 == "kubectl" && $2 ~ / get pods / && jobs == 2 {pod = 1; next}
		$1 == "kubectl" && $2 ~ / create / && $2 ~ /encode-benchmark-image-/ && pod {configmap = 1; next}
		$1 == "kubectl" && $2 ~ / logs pod\// && configmap {accepted = 1}
		END {exit !(jobs == 2 && accepted)}
	' "$STUB_CALLS"
}

# Catches an unbounded or fail-open pre-work wait and rollback that leaks
# sibling Jobs or evidence ConfigMaps from the same multi-Job dispatch.
@test "running-image handoff failures roll back only resources created by that dispatch" {
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	export STUB_HANDOFF_LOG_READY=0
	run_dispatch capabilities
	[ "$status" -ne 0 ]
	[[ "$output" == *'running image evidence handoff timed out'* ]]
	for node in nuc1 nuc3; do
		awk -F '\t' -v node="$node" '$1 == "kubectl" && $2 ~ (" delete job/encode-benchmark-cap-.*-node-" node " ") {found=1} END {exit !found}' "$STUB_CALLS"
	done
	[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / delete configmap\/encode-benchmark-image-/ {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 1 ]
	awk -F '\t' '$1 == "kubectl" && $2 ~ / delete / && $2 !~ /encode-benchmark-(cap|image)-/ {found=1} END {exit found}' "$STUB_CALLS"
}

# Catches the capability rollback path deleting a foreign Job that replaced a
# successfully created same-name object before a later create failed.
@test "capability rollback never deletes a replacement Job" {
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	export STUB_JOB_CREATE_FAIL_AT=2
	export STUB_JOB_REPLACEMENT=1
	run_dispatch capabilities
	[ "$status" -ne 0 ]
	[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / delete job\// {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 0 ]
}

# Catches rollback deriving dispatch/run ownership only from the local manifest
# instead of the API server's captured create response.
@test "rollback requires exact captured create-response metadata" {
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	export STUB_JOB_CREATE_FAIL_AT=2
	export STUB_JOB_CREATE_RESPONSE_METADATA_BAD=1
	run_dispatch capabilities
	[ "$status" -ne 0 ]
	[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / delete job\// {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 0 ]
}

# Catches multi-worker rollback deleting foreign same-name replacement Jobs.
@test "single Job rollback never deletes a replacement Job" {
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'
	export STUB_HANDOFF_LOG_READY=0
	export STUB_JOB_REPLACEMENT=1
	run_dispatch run quality
	[ "$status" -ne 0 ]
	[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / delete job\// {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 0 ]
}

# Catches a read/delete replacement race by requiring the API server to apply
# the captured UID as an atomic delete precondition for both resource kinds.
@test "rollback deletes Jobs and ConfigMaps with atomic UID preconditions" {
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	export STUB_HANDOFF_LOG_READY=0
	export STUB_CONFIGMAP_REPLACE_BEFORE_DELETE=1
	run_dispatch capabilities
	[ "$status" -ne 0 ]
	awk -F '\t' '
		$1 == "kubectl" && $2 ~ / delete job\// {jobs += 1; if ($2 !~ / --preconditions=uid=fixture-job-uid( |$)/) bad=1}
		$1 == "kubectl" && $2 ~ / delete configmap\// {configmaps += 1; if ($2 !~ / --preconditions=uid=fixture-configmap-uid( |$)/) bad=1}
		END {exit !(jobs == 2 && configmaps == 1 && !bad)}
	' "$STUB_CALLS"
	[ ! -e "$STUB_CAPTURE_DIR/unsafe-configmap-delete" ]
}

# Catches stopping at the first controlled Pending pod before kubelet has
# populated its benchmark container status and immutable imageID.
@test "handoff polls zero pods then Pending status until imageID is populated" {
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'
	export ENCODE_BENCHMARK_HANDOFF_WAIT_SECONDS=4
	export STUB_HANDOFF_POD_SEQUENCE=1
	run_dispatch run quality
	[ "$status" -eq 0 ]
	[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / get pods / && $2 ~ /job-name=/ {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 3 ]
	awk -F '\t' '
		$1 == "kubectl" && $2 ~ / get pods / && $2 ~ /job-name=/ {pod_gets += 1; next}
		$1 == "kubectl" && $2 ~ / create / && $2 ~ /encode-benchmark-image-/ {created=1; if (pod_gets == 3) ordered=1}
		END {exit !(created && ordered)}
	' "$STUB_CALLS"
}

# Catches accepting one matching controller reference while ignoring a second
# foreign owner on the controlled pod or persisted handoff ConfigMap.
@test "handoff requires exactly one complete owner reference" {
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'
	export STUB_HANDOFF_EXTRA_OWNER=1
	run_dispatch run quality
	[ "$status" -ne 0 ]
	[ "$(find "$STUB_CAPTURE_DIR" -maxdepth 1 -name 'ConfigMap-*.yaml' | wc -l | tr -d ' ')" -eq 0 ]

	rm -f "$STUB_CAPTURE_DIR"/Job-*.yaml "$STUB_CAPTURE_DIR"/ConfigMap-*.yaml "$STUB_CAPTURE_DIR"/create-*.yaml "$STUB_CAPTURE_DIR"/.count
	: >"$STUB_CALLS"
	unset STUB_HANDOFF_EXTRA_OWNER
	export STUB_PERSISTED_EXTRA_OWNER=1
	run_dispatch run quality
	[ "$status" -ne 0 ]
	[[ "$output" == *'persisted-ownership'* ]]
}

# Catches losing the deterministic ConfigMap name when create reports failure
# after the API server might already have persisted the submitted object.
@test "ConfigMap create failure rolls back every possibly persisted handoff resource" {
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	export STUB_CONFIGMAP_CREATE_FAIL=1
	run_dispatch capabilities
	[ "$status" -ne 0 ]
	[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / delete configmap\/encode-benchmark-image-/ {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 1 ]
	for node in nuc1 nuc3; do
		awk -F '\t' -v node="$node" '$1 == "kubectl" && $2 ~ (" delete job/encode-benchmark-cap-.*-node-" node " ") {found=1} END {exit !found}' "$STUB_CALLS"
	done
	awk -F '\t' '$1 == "kubectl" && $2 ~ / delete / && $2 !~ /encode-benchmark-(cap|image)-/ {found=1} END {exit found}' "$STUB_CALLS"
}

# Catches ambiguous create cleanup deleting a deterministic same-name object
# that the API server reports with ownership outside this dispatch.
@test "ConfigMap failure never deletes evidence without exact dispatch ownership" {
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	export STUB_CONFIGMAP_CREATE_FAIL=1
	export STUB_PERSISTED_OWNER_BAD=1
	run_dispatch capabilities
	[ "$status" -ne 0 ]
	[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / delete configmap\// {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 0 ]
	for node in nuc1 nuc3; do
		awk -F '\t' -v node="$node" '$1 == "kubectl" && $2 ~ (" delete job/encode-benchmark-cap-.*-node-" node " ") {found=1} END {exit !found}' "$STUB_CALLS"
	done
}

# Catches trusting a label-selected pod, a missing imageID, or a different
# immutable digest before creating the evidence ConfigMap.
@test "running-image handoff rejects wrong ownership and image identity" {
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	for failure in owner missing mismatch; do
		unset STUB_HANDOFF_BAD_OWNER STUB_HANDOFF_IMAGE_ID STUB_HANDOFF_IMAGE_MISSING
		case "$failure" in
		owner) export STUB_HANDOFF_BAD_OWNER=1 ;;
		missing) export STUB_HANDOFF_IMAGE_MISSING=1 ;;
		mismatch) export STUB_HANDOFF_IMAGE_ID='containerd://docker.io/linuxserver/ffmpeg@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;;
		esac
		run_dispatch capabilities
		[ "$status" -ne 0 ]
		if [[ "$failure" == 'missing' ]]; then
			[[ "$output" == *'running image evidence handoff timed out'* ]]
		else
			[[ "$output" == *'running image evidence handoff rejected'* ]]
		fi
		[ "$(find "$STUB_CAPTURE_DIR" -maxdepth 1 -name 'ConfigMap-*.yaml' | wc -l | tr -d ' ')" -eq 0 ]
		rm -f "$STUB_CAPTURE_DIR"/Job-*.yaml "$STUB_CAPTURE_DIR"/create-*.yaml "$STUB_CAPTURE_DIR"/.count
		: >"$STUB_CALLS"
	done
}

# Catches dispatch trusting capabilityStatus or proofStatus without recomputing
# every versioned field and matching it to the configured immutable image.
@test "expensive dispatch requires one current semantically valid capability node" {
	prepare_evidence_source
	valid="$(valid_capability_evidence)"
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'

	set_capability_evidence pending '{"digestResolvable":true,"hevcQsv":true,"realQsvEncode":true}'
	run_dispatch run quality
	[ "$status" -ne 0 ]
	[[ "$output" == *'capability evidence'* ]]
	assert_no_mutations

	for invalid in \
		"$(jq -c '.nodes[0].initialization="failed" | .nodes[0].proofStatus="failed" | .nodes[0].proofReasons="initialization"' <<<"$valid")" \
		"$(jq -c '.nodes[0].telemetryStatus="harness-blocked" | .nodes[0].proofStatus="harness-blocked" | .nodes[0].proofReasons="telemetry"' <<<"$valid")" \
		"$(jq -c '.nodes[0].proofSchemaVersion=2' <<<"$valid")" \
		"$(jq -c '.nodes[0].strategyId="qsv-hevc-la-icq-v1"' <<<"$valid")" \
		"$(jq -c '.nodes[0].selectedRateControl="LA-ICQ" | .nodes[0].proofStatus="failed" | .nodes[0].proofReasons="rate-control"' <<<"$valid")" \
		"$(jq -c 'del(.nodes[0].renderNode)' <<<"$valid")" \
		"$(jq -c '.nodes[0].drmDriver="xe"' <<<"$valid")" \
		"$(jq -c '.nodes[0].configuredImageDigest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' <<<"$valid")" \
		"$(jq -c '.nodes[0].imageId="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' <<<"$valid")" \
		"$(jq -c '.nodes[0].videoBusyNanoseconds=0 | .nodes[0].proofStatus="failed" | .nodes[0].proofReasons="telemetry"' <<<"$valid")" \
		"$(jq -c '.nodes[0].encodeSpeed=0' <<<"$valid")"; do
		set_capability_evidence verified "$invalid"
		run_dispatch run quality
		[ "$status" -ne 0 ]
		[[ "$output" == *'capability evidence'* ]]
		assert_no_mutations
	done

	set_capability_evidence verified "$valid"
	run_dispatch run quality
	[ "$status" -eq 0 ]
	[ "$(mutation_count)" -eq 2 ]
}

# Catches the quality run bypassing its exact operator confirmation.
@test "run requires the exact mode-bound confirmation before creating a Job" {
	assert_guard_refuses ENCODE_BENCHMARK_RUN_CONFIRM wrong:quality run quality

	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'
	run_dispatch run quality
	[ "$status" -eq 0 ]
	[ "$(mutation_count)" -eq 2 ]
	job="$(job_capture)"
	assert_hardened_job "$job"
	run_id="$(yq -r '.metadata.labels."homelab-talos/benchmark-run"' "$job")"
	[[ "$run_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]]
	[ "$(yq -r '.spec.template.metadata.labels."homelab-talos/benchmark-run"' "$job")" = "$run_id" ]
	[ "$(yq -r '.spec.template.spec.containers[0].command | join(" ")' "$job")" = "/scripts/benchmark.sh quality $run_id" ]
	[[ "$output" == *"run_id=$run_id"* ]]
}

# Catches a generated dispatch ID failing to become the runtime quality identity.
@test "generated quality dispatch becomes the runtime quality identity" {
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'
	run_dispatch run quality
	[ "$status" -eq 0 ]
	job="$(job_capture)"
	dispatch_id="$(yq -r '.metadata.labels."homelab-talos/benchmark-dispatch"' "$job")"
	command_run_id="$(yq -r '.spec.template.spec.containers[0].command[2]' "$job")"
	correlation_env="$(yq -r '.spec.template.spec.containers[0].env[]? |
		select(.name == "BENCHMARK_DISPATCH_CORRELATION_ID") | .value' "$job")"
	[ "$command_run_id" = "$dispatch_id" ]
	[ "$correlation_env" = "$dispatch_id" ]

	export BENCHMARK_TEST_MODE=1
	export BENCHMARK_OUT="$BATS_TEST_TMPDIR/runtime-out"
	export BENCHMARK_SAMPLES_FILE="$BATS_TEST_TMPDIR/runtime-samples.json"
	export BENCHMARK_IDENTITY_FIXTURE="$BATS_TEST_DIRNAME/fixtures/manifests/identity.json"
	export BENCHMARK_DISPATCH_CORRELATION_ID="$correlation_env"
	mkdir -p "$BENCHMARK_OUT/runs"
	yq -r '.data."samples.json"' "$evidence_app/samples.yaml" >"$BENCHMARK_SAMPLES_FILE"

	run "$evidence_app/scripts/runmeta.sh" create quality "$command_run_id"
	[ "$status" -eq 0 ]
	runtime_run_id="$output"
	[ "${runtime_run_id%-*}" = "${dispatch_id%-*}" ]
	manifest="$BENCHMARK_OUT/runs/$runtime_run_id/manifest.json"
	[ -f "$manifest" ]
	identity_suffix="$(jq -S -c 'del(.createdAt)' "$manifest" | sha256sum | awk '{print substr($1, 1, 8)}')"
	[ "${runtime_run_id##*-}" = "$identity_suffix" ]

}
# Catches malformed quality dispatch inputs reaching a cluster mutation.
@test "malformed dispatch inputs are refused before every mutation" {
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'
	run_dispatch run 'QUALITY'
	[ "$status" -ne 0 ]
	assert_no_mutations

	run_dispatch run quality '../bad-run'
	[ "$status" -ne 0 ]
	assert_no_mutations
}

# Catches regex-only UTC checks accepting impossible supplied and generated
# dates before cluster calls or resource creation.
@test "dispatch rejects impossible UTC run timestamps before every mutation" {
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'
	for invalid in \
		20261302T120000Z-1234abcd \
		20260230T120000Z-1234abcd \
		20260802T250000Z-1234abcd; do
		run_dispatch run quality "$invalid"
		[ "$status" -ne 0 ]
		[[ "$output" == *"invalid run id: $invalid"* ]]
		assert_no_mutations
	done

	for invalid in 20261302T120000Z 20260230T120000Z 20260802T250000Z; do
		export ENCODE_BENCHMARK_NOW="$invalid"
		run_dispatch run quality
		[ "$status" -ne 0 ]
		[[ "$output" == *"invalid benchmark timestamp: $invalid"* ]]
		assert_no_mutations
	done
}

# Catches recipes that consult deployed-source drift only after dispatch. The
# PATH stub makes a stale origin/main comparison observable without Git or API access.
@test "deployed-source drift refuses capabilities and quality before dispatch" {
	export STUB_GIT_STALE=1
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'

	for recipe in \
		encode-benchmark-capabilities \
		encode-benchmark-quality; do
		read -r -a arguments <<<"$recipe"
		run just --justfile "$PROJECT_ROOT/kubernetes/mod.just" "${arguments[@]}"
		[ "$status" -ne 0 ]
		assert_no_mutations
	done
}

# Catches the operator interface swapping the sample/node/run ordering or
# bypassing the single deployed-source guard before entering dispatch.
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
	expected_image="$(yq -r '.data."samples.json" | from_yaml | .runtime.image' "$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/samples.yaml")"

	[ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "scripts") | .configMap.name' "$job")" = "$expected_scripts" ]
	[ "$(yq -r '.spec.template.spec.containers[0].image' "$job")" = "$expected_image" ]
	[ "$(yq -r '.spec.template.spec.containers[0].command | join(" ")' "$job")" = '/scripts/benchmark.sh capabilities' ]
	[ "$(yq -r '[.spec.template.spec.volumes[].name] | sort | join(",")' "$job")" = 'image-evidence,samples,scratch,scripts' ]
	[ "$(yq -r '.spec.activeDeadlineSeconds' "$job")" = '900' ]
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

# Catches result output leaking unsanitized capability evidence.
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
	[[ "$output" == *'capability_evidence={"nodeName":"nuc2","strategyId":"qsv-hevc-icq-v1","proofSchemaVersion":3'* ]]
	awk -F '\t' -v run_id="$run_id" '$1 == "kubectl" && $2 ~ ("homelab-talos/benchmark-run=" run_id) {selected=1} END {exit !selected}' "$STUB_CALLS"
	assert_no_mutations
}

# Catches a collector that assumes one capability Job per dispatch or merges
# node provenance into one scheduler-selected result.
@test "results emits one sanitized capability evidence record per targeted node" {
	run_id='20260802T120000Z-1234abcd'
	image_id='docker-pullable://docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	write_multi_node_results_fixtures "$run_id" "$image_id"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -eq 0 ]
	[ "$(grep -c '^capability_evidence=' <<<"$output")" -eq 2 ]
	[[ "$output" == *'"nodeName":"nuc1"'* ]]
	[[ "$output" == *'"nodeName":"nuc3"'* ]]
	[[ "$output" == *'"verifiedAt":"2026-08-14T18:01:00Z"'* ]]
	[[ "$output" == *'"imageId":"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb"'* ]]
	[[ "$output" != *'/media/Secret Movie.mkv'* ]]
	assert_no_mutations
}

# Catches losing capability evidence when its command exits nonzero for a
# semantic failure or a blocked telemetry oracle.
@test "results sanitizes terminal failed and harness-blocked capability proofs" {
	run_id='20260802T120000Z-1234abcd'
	image_id='docker-pullable://docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'

	write_results_fixtures "$run_id" "$image_id"
	jq '.items[0].status.conditions = [{type:"Failed",status:"True",lastTransitionTime:"2026-08-14T18:01:30Z"}] | del(.items[0].status.completionTime) | .items[0].status.failed = 1 | .items[0].status.succeeded = 0' \
		"$STUB_JOBS_JSON" >"$STUB_JOBS_JSON.tmp"
	mv "$STUB_JOBS_JSON.tmp" "$STUB_JOBS_JSON"
	jq '.items[0].status.phase = "Failed"' "$STUB_PODS_JSON" >"$STUB_PODS_JSON.tmp"
	mv "$STUB_PODS_JSON.tmp" "$STUB_PODS_JSON"
	jq -c '.status="failed" | .initialization="failed" | .proofStatus="failed" | .proofReasons="initialization"' \
		"$STUB_LOGS_FILE" >"$STUB_LOGS_FILE.tmp"
	mv "$STUB_LOGS_FILE.tmp" "$STUB_LOGS_FILE"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -eq 0 ]
	[[ "$output" == *'"proofStatus":"failed","proofReasons":"initialization"'* ]]
	[[ "$output" == *'"verifiedAt":"2026-08-14T18:01:30Z"'* ]]
	[[ "$output" != *'Error: no matches found'* ]]

	write_results_fixtures "$run_id" "$image_id"
	jq '.items[0].status.conditions = [{type:"Failed",status:"True",lastTransitionTime:"2026-08-14T18:01:30Z"}] | del(.items[0].status.completionTime) | .items[0].status.failed = 1 | .items[0].status.succeeded = 0' \
		"$STUB_JOBS_JSON" >"$STUB_JOBS_JSON.tmp"
	mv "$STUB_JOBS_JSON.tmp" "$STUB_JOBS_JSON"
	jq '.items[0].status.phase = "Failed"' "$STUB_PODS_JSON" >"$STUB_PODS_JSON.tmp"
	mv "$STUB_PODS_JSON.tmp" "$STUB_PODS_JSON"
	jq -c '.status="harness-blocked" | .telemetryStatus="harness-blocked" | .telemetryReason="malformed-video-counter" | .videoBusyNanoseconds=0 | .videoBusyPercent=0 | .proofStatus="harness-blocked" | .proofReasons="telemetry"' \
		"$STUB_LOGS_FILE" >"$STUB_LOGS_FILE.tmp"
	mv "$STUB_LOGS_FILE.tmp" "$STUB_LOGS_FILE"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -eq 0 ]
	[[ "$output" == *'"proofStatus":"harness-blocked","proofReasons":"telemetry"'* ]]
	assert_no_mutations
}

# Catches accepting legacy schema/mode evidence or trusting a claimed reason
# list instead of recomputing the schema-v3 semantic result.
@test "results rejects legacy and semantically contradictory capability proofs" {
	run_id='20260802T120000Z-1234abcd'
	image_id='docker-pullable://docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	for mutation in \
		'.proofSchemaVersion=2' \
		'.selectedRateControl="LA-ICQ"' \
		'.renderNode="/dev/dri/renderD129"' \
		'.videoBusyNanoseconds=0' \
		'.encodeSpeed=0' \
		'.proofReasons="decode"'; do
		write_results_fixtures "$run_id" "$image_id"
		jq -c "$mutation" "$STUB_LOGS_FILE" >"$STUB_LOGS_FILE.tmp"
		mv "$STUB_LOGS_FILE.tmp" "$STUB_LOGS_FILE"
		run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
		[ "$status" -ne 0 ]
		[[ "$output" == *'capability result schema rejected'* ]]
		assert_no_mutations
	done
}

# Catches a collector that compares the live kubelet image only with local
# source while ignoring the exact Job-owned pre-work evidence or dispatched
# image recorded in the Job.
@test "results binds configured dispatched handoff and live image digests" {
	run_id='20260802T120000Z-1234abcd'
	image_id='docker-pullable://docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'

	write_results_fixtures "$run_id" "$image_id"
	jq '.items[0].spec.template.spec.containers[0].image = "docker.io/linuxserver/ffmpeg@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$STUB_JOBS_JSON" >"$STUB_JOBS_JSON.tmp"
	mv "$STUB_JOBS_JSON.tmp" "$STUB_JOBS_JSON"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -ne 0 ]
	[[ "$output" == *'pre-work image identity evidence rejected'* ]]

	write_results_fixtures "$run_id" "$image_id"
	jq '.metadata.ownerReferences[0].uid = "spoofed-owner-uid"' "$STUB_IMAGE_EVIDENCE_DIR/encode-benchmark-image-fixture.json" >"$STUB_IMAGE_EVIDENCE_DIR/evidence.tmp"
	mv "$STUB_IMAGE_EVIDENCE_DIR/evidence.tmp" "$STUB_IMAGE_EVIDENCE_DIR/encode-benchmark-image-fixture.json"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -ne 0 ]
	[[ "$output" == *'pre-work image identity evidence rejected'* ]]

	write_results_fixtures "$run_id" "$image_id"
	jq '.data."image.json" |= (fromjson | .imageId = "docker.io/linuxserver/ffmpeg@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" | tojson)' "$STUB_IMAGE_EVIDENCE_DIR/encode-benchmark-image-fixture.json" >"$STUB_IMAGE_EVIDENCE_DIR/evidence.tmp"
	mv "$STUB_IMAGE_EVIDENCE_DIR/evidence.tmp" "$STUB_IMAGE_EVIDENCE_DIR/encode-benchmark-image-fixture.json"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -ne 0 ]
	[[ "$output" == *'pre-work image identity evidence rejected'* ]]
	assert_no_mutations
}

# Catches result collection accepting one matching controller owner while a
# second owner entry leaves the pod or evidence ConfigMap provenance ambiguous.
@test "results require exactly one complete owner reference" {
	run_id='20260802T120000Z-1234abcd'
	image_id='docker-pullable://docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	extra_owner='{"apiVersion":"v1","kind":"ConfigMap","name":"foreign-owner","uid":"foreign-owner-uid","controller":false,"blockOwnerDeletion":false}'

	write_results_fixtures "$run_id" "$image_id"
	jq --argjson owner "$extra_owner" '.items[0].metadata.ownerReferences += [$owner]' \
		"$STUB_PODS_JSON" >"$STUB_PODS_JSON.tmp"
	mv "$STUB_PODS_JSON.tmp" "$STUB_PODS_JSON"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -ne 0 ]
	[[ "$output" == *'capability result provenance rejected'* ]]

	write_results_fixtures "$run_id" "$image_id"
	jq --argjson owner "$extra_owner" '.metadata.ownerReferences += [$owner]' \
		"$STUB_IMAGE_EVIDENCE_DIR/encode-benchmark-image-fixture.json" >"$STUB_IMAGE_EVIDENCE_DIR/evidence.tmp"
	mv "$STUB_IMAGE_EVIDENCE_DIR/evidence.tmp" "$STUB_IMAGE_EVIDENCE_DIR/encode-benchmark-image-fixture.json"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -ne 0 ]
	[[ "$output" == *'pre-work image identity evidence rejected'* ]]
	assert_no_mutations
}

# Catches quality result collection accepting an unbounded completion payload.
@test "results prints one bounded authenticated quality completion line" {
	dispatch_id='20260802T120000Z-1234abcd'
	runtime_run_id='20260802T120000Z-feedface'
	image_id='docker-pullable://docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	write_results_fixtures "$dispatch_id" "$image_id"
	jq '.items[0].metadata.name = "encode-benchmark-quality-fixture" |
		.items[0].metadata.labels."homelab-talos/benchmark-mode" = "quality" |
		.items[0].metadata.labels."homelab-talos/benchmark-dispatch" = $dispatch |
		.items[0].spec.template.spec.containers[0].env = [{
			name:"BENCHMARK_DISPATCH_CORRELATION_ID",value:$dispatch
		}]' \
		--arg dispatch "$dispatch_id" "$STUB_JOBS_JSON" >"$STUB_JOBS_JSON.tmp"
	mv "$STUB_JOBS_JSON.tmp" "$STUB_JOBS_JSON"
	jq '.items[0].metadata.labels."job-name" = "encode-benchmark-quality-fixture" |
		.items[0].metadata.ownerReferences[0].name = "encode-benchmark-quality-fixture"' \
		"$STUB_PODS_JSON" >"$STUB_PODS_JSON.tmp"
	mv "$STUB_PODS_JSON.tmp" "$STUB_PODS_JSON"
	jq '.metadata.ownerReferences[0].name = "encode-benchmark-quality-fixture"' \
		"$STUB_IMAGE_EVIDENCE_DIR/encode-benchmark-image-fixture.json" >"$STUB_IMAGE_EVIDENCE_DIR/evidence.tmp"
	mv "$STUB_IMAGE_EVIDENCE_DIR/evidence.tmp" "$STUB_IMAGE_EVIDENCE_DIR/encode-benchmark-image-fixture.json"
	jq -n -c --arg dispatch "$dispatch_id" --arg runtime "$runtime_run_id" '{
		schemaVersion:2,strategyId:"qsv-hevc-icq-v1",status:"complete",
		dispatchId:$dispatch,runtimeRunId:$runtime,artifactLocation:("/out/runs/" + $runtime)
		,cohorts:{
			avc:{status:"eligible",candidates:[
				{globalQuality:16,medianReductionPercent:35},
				{globalQuality:24,medianReductionPercent:25}]},
			vc1:{status:"no-verdict",candidates:[]},
			hdr10:{status:"no-go",candidates:[]}
		}
	}' >"$STUB_LOGS_FILE"

	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$dispatch_id"
	[ "$status" -eq 0 ]
	[ "$output" = "mode=quality phase=Complete dispatch_id=$dispatch_id runtime_run_id=$runtime_run_id artifact_location=/out/runs/$runtime_run_id avc=eligible:16@35,24@25 vc1=no-verdict: hdr10=no-go:" ]
	[ "$(awk 'END { print NR }' <<<"$output")" -eq 1 ]
	[[ "$output" != *'job='* ]]
	[[ "$output" != *'image'* ]]
	[[ "$output" != *'sha256:'* ]]
	[[ "$output" != *'no-sanitized-summary'* ]]
	[[ "$output" != *'sampleId'* ]]
	[[ "$output" != *'sourcePath'* ]]
	[[ "$output" != *'rawLog'* ]]
	[[ "$output" != *'frames'* ]]
	[[ "$output" != *'.mkv'* ]]
	[[ "$output" != *'quality-evidence'* ]]

	# The generated marker must never admit the explicit plain-ID form.
	printf '%s\n' "$dispatch_id" >"$STUB_LOGS_FILE"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$dispatch_id"
	[ "$status" -ne 0 ]
	[[ "$output" == *'quality completion record rejected'* ]]

	explicit_run_id='20260802T120000Z-abcdef12'
	write_results_fixtures "$explicit_run_id" "$image_id"
	jq '.items[0].metadata.name = "encode-benchmark-quality-fixture" |
		.items[0].metadata.labels."homelab-talos/benchmark-mode" = "quality"' \
		"$STUB_JOBS_JSON" >"$STUB_JOBS_JSON.tmp"
	mv "$STUB_JOBS_JSON.tmp" "$STUB_JOBS_JSON"
	jq '.items[0].metadata.labels."job-name" = "encode-benchmark-quality-fixture" |
		.items[0].metadata.ownerReferences[0].name = "encode-benchmark-quality-fixture"' \
		"$STUB_PODS_JSON" >"$STUB_PODS_JSON.tmp"
	mv "$STUB_PODS_JSON.tmp" "$STUB_PODS_JSON"
	jq '.metadata.ownerReferences[0].name = "encode-benchmark-quality-fixture"' \
		"$STUB_IMAGE_EVIDENCE_DIR/encode-benchmark-image-fixture.json" >"$STUB_IMAGE_EVIDENCE_DIR/evidence.tmp"
	mv "$STUB_IMAGE_EVIDENCE_DIR/evidence.tmp" "$STUB_IMAGE_EVIDENCE_DIR/encode-benchmark-image-fixture.json"
	printf '%s\n' "$explicit_run_id" >"$STUB_LOGS_FILE"

	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$explicit_run_id"
	[ "$status" -eq 0 ]
	[[ "$output" == job=encode-benchmark-quality-fixture\ mode=quality\ phase=Complete* ]]
	[[ "$output" == *'configured_image_digest=sha256:'* ]]
	[[ "$output" == *"dispatch_id=$explicit_run_id runtime_run_id=$explicit_run_id"* ]]
	[[ "$output" == *$'\n'"artifact_location=/out/runs/$explicit_run_id" ]]
}

# Catches schema widening, path transport, ambiguous settings, non-finite
# reductions, and foreign runtime identities before any bounded values print.
@test "quality completion rejects unbounded malformed and incorrectly bound records" {
	dispatch_id='20260802T120000Z-1234abcd'
	runtime_run_id='20260802T120000Z-feedface'
	image_id='docker-pullable://docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	write_results_fixtures "$dispatch_id" "$image_id"
	jq '.items[0].metadata.name = "encode-benchmark-quality-fixture" |
		.items[0].metadata.labels."homelab-talos/benchmark-mode" = "quality" |
		.items[0].metadata.labels."homelab-talos/benchmark-dispatch" = $dispatch |
		.items[0].spec.template.spec.containers[0].env = [{
			name:"BENCHMARK_DISPATCH_CORRELATION_ID",value:$dispatch
		}]' --arg dispatch "$dispatch_id" "$STUB_JOBS_JSON" >"$STUB_JOBS_JSON.tmp"
	mv "$STUB_JOBS_JSON.tmp" "$STUB_JOBS_JSON"
	jq '.items[0].metadata.labels."job-name" = "encode-benchmark-quality-fixture" |
		.items[0].metadata.ownerReferences[0].name = "encode-benchmark-quality-fixture"' \
		"$STUB_PODS_JSON" >"$STUB_PODS_JSON.tmp"
	mv "$STUB_PODS_JSON.tmp" "$STUB_PODS_JSON"
	jq '.metadata.ownerReferences[0].name = "encode-benchmark-quality-fixture"' \
		"$STUB_IMAGE_EVIDENCE_DIR/encode-benchmark-image-fixture.json" >"$STUB_IMAGE_EVIDENCE_DIR/evidence.tmp"
	mv "$STUB_IMAGE_EVIDENCE_DIR/evidence.tmp" "$STUB_IMAGE_EVIDENCE_DIR/encode-benchmark-image-fixture.json"
	base="$BATS_TEST_TMPDIR/quality-completion-base.json"
	jq -n -c --arg dispatch "$dispatch_id" --arg runtime "$runtime_run_id" '{
		schemaVersion:2,strategyId:"qsv-hevc-icq-v1",status:"complete",
		dispatchId:$dispatch,runtimeRunId:$runtime,artifactLocation:("/out/runs/" + $runtime),
		cohorts:{
			avc:{status:"eligible",candidates:[{globalQuality:16,medianReductionPercent:35}]},
			vc1:{status:"no-verdict",candidates:[]},
			hdr10:{status:"no-go",candidates:[]}
		}
	}' >"$base"

	for mutation in \
		'.rawLog="encoder details"' \
		'.cohorts.avc.sourcePath="/media/private.mkv"' \
		'.cohorts.avc.candidates[0].evidencePath="quality-evidence/raw.json"' \
		'del(.cohorts.vc1)' \
		'.cohorts.avc.candidates += [.cohorts.avc.candidates[0]]' \
		'.cohorts.avc.candidates[0].globalQuality=17' \
		'.runtimeRunId="20260802T120000Z-eeeeeeee"' \
		'.artifactLocation="/out/runs/20260802T120000Z-eeeeeeee"' \
		'.runtimeRunId="20260803T120000Z-eeeeeeee" | .artifactLocation="/out/runs/20260803T120000Z-eeeeeeee"'; do
		jq -c "$mutation" "$base" >"$STUB_LOGS_FILE"
		run "$RESULTS" "$KUBECONFIG_FIXTURE" "$dispatch_id"
		[ "$status" -ne 0 ]
		[[ "$output" == *'quality completion record rejected'* ]]
		run grep -q '^mode=quality phase=Complete ' <<<"$output"
		[ "$status" -eq 1 ]
	done

	sed 's/"medianReductionPercent":35/"medianReductionPercent":1e999/' "$base" >"$STUB_LOGS_FILE"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$dispatch_id"
	[ "$status" -ne 0 ]
	[[ "$output" == *'quality completion record rejected'* ]]
	run grep -q '^mode=quality phase=Complete ' <<<"$output"
	[ "$status" -eq 1 ]

	# An authenticated completion record cannot print success when the Pod's
	# immutable image identity does not match the committed runtime digest.
	jq '.items[0].status.containerStatuses[0].imageID =
		"docker-pullable://docker.io/linuxserver/ffmpeg@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
		"$STUB_PODS_JSON" >"$STUB_PODS_JSON.tmp"
	mv "$STUB_PODS_JSON.tmp" "$STUB_PODS_JSON"
	printf '%s\n' "$(<"$base")" >"$STUB_LOGS_FILE"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$dispatch_id"
	[ "$status" -ne 0 ]
	run grep -q '^mode=quality phase=Complete ' <<<"$output"
	[ "$status" -eq 1 ]
	[[ "$output" != *' artifact_location='* ]]
	[[ "$output" != *' avc='* ]]
}

# Catches result collection accepting a missing, malformed, or mismatched
# kubelet image identity.
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
@test "preflight reports every node and requires non-Plex GPU plus 115Gi actual free NVMe" {
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
	printf '%s\n' '{"node":{"fs":{"availableBytes":146081611776}}}' >"$STUB_SUMMARY_DIR/nuc1.json"
	printf '%s\n' '{"node":{"fs":{"availableBytes":107374182400}}}' >"$STUB_SUMMARY_DIR/nuc2.json"
	printf '%s\n' '{"node":{"fs":{"availableBytes":148751507456}}}' >"$STUB_SUMMARY_DIR/nuc3.json"

	run "$PREFLIGHT" "$KUBECONFIG_FIXTURE"
	[ "$status" -eq 0 ]
	[[ "$output" == *'nuc1 FAIL plex-node'* ]]
	[[ "$output" == *'nuc2 FAIL free-nvme-below-115Gi'* ]]
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

# Catches a preflight floor that can never be satisfied. The shipped floor was
# 200Gi against an EPHEMERAL partition Talos caps at 150GiB, so preflight could
# not pass on any node at any time. Deriving the ceiling from talconfig.yaml
# rather than restating it keeps the two from drifting apart again.
@test "preflight free-space floor is satisfiable within the configured EPHEMERAL partition" {
	floor="$(rg -o '^minimum_available_bytes=([0-9]+)$' --replace '$1' "$PREFLIGHT")"
	[ -n "$floor" ]

	capacity_gib="$(yq -r '
		.. | select(has("name")) | select(.name == "EPHEMERAL") | .provisioning.maxSize
	' "$PROJECT_ROOT/talos/talconfig.yaml" | head -n 1)"
	[ -n "$capacity_gib" ]
	capacity_bytes=$((${capacity_gib%GiB} * 1024 * 1024 * 1024))

	# Strictly below capacity, or the check is unsatisfiable by construction.
	[ "$floor" -lt "$capacity_bytes" ]

	# Allocatable is materially below the raw partition, so a floor that only just
	# fits the partition still cannot leave room for a schedulable Job.
	scratch="$(yq -r '
		.spec.template.spec.containers[0].resources.requests."ephemeral-storage"
	' "$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/templates/job.yaml")"
	scratch_bytes=$((${scratch%Gi} * 1024 * 1024 * 1024))
	[ "$scratch_bytes" -le "$floor" ]
}
