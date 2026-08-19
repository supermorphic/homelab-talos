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
	if [[ -n "${STUB_LOGS_DIR:-}" ]]; then
		resource=''
		for argument in "$@"; do
			if [[ "$argument" == job/* ]]; then resource="${argument#job/}"; fi
		done
		sed -n '1,$p' "$STUB_LOGS_DIR/$resource.log"
	elif [[ -n "${STUB_LOGS_FILE:-}" ]]; then
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

if contains get "$@" && [[ "$*" == *' job/'* ]]; then
	resource=''
	for argument in "$@"; do
		if [[ "$argument" == job/* ]]; then resource="$argument"; fi
	done
	name="${resource#job/}"
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

# Catches a findings dispatch that starts a Job before the exact validated input
# object is owned and mounted read-only, or that retains a GPU/media mount.
@test "findings dispatch suspends a metadata-only Job until owned inputs persist" {
	inputs="$BATS_TEST_TMPDIR/findings-inputs.json"
	jq -n '{schemaVersion:1,strategyId:"qsv-hevc-icq-v1",quality:{runId:"20260815T120000Z-aaaaaaaa",resultsSha256:("sha256:" + ("a" * 64)),candidatesSha256:("sha256:" + ("b" * 64))},x265:[],savings:null,contention:null}' >"$inputs"
	chmod 0644 "$inputs"
	input_mode_before="$(stat -c '%a' "$inputs" 2>/dev/null || stat -f '%Lp' "$inputs")"
	export ENCODE_BENCHMARK_FINDINGS_CONFIRM='run:encode-benchmark:findings'
	run_dispatch findings "$inputs"
	[ "$status" -eq 0 ]
	input_mode_after="$(stat -c '%a' "$inputs" 2>/dev/null || stat -f '%Lp' "$inputs")"
	[ "$input_mode_after" = "$input_mode_before" ]
	! awk -F '\t' -v path="$inputs" '$1 == "chmod" && index($2, path) { found = 1 } END { exit found }' "$STUB_CALLS"
	job="$(job_capture)"
	configmap="$(configmap_capture)"
	[ "$(yq -r '.spec.suspend' "$job")" = true ]
	[ "$(yq -r '.spec.template.spec.containers[0].resources.requests."gpu.intel.com/i915" // ""' "$job")" = '' ]
	[ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "media") | .name' "$job")" = '' ]
	[ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "findings-inputs") | .configMap.defaultMode' "$job")" = 384 ]
	[ "$(yq -r '.metadata.ownerReferences[0].kind' "$configmap")" = Job ]
	[ "$(yq -r '.data."findings-inputs.json" | from_json | .schemaVersion' "$configmap")" = 1 ]
	awk -F '\t' '$1 == "kubectl" && $2 ~ / patch job\/encode-benchmark-findings-/ { found = 1 } END { exit !found }' "$STUB_CALLS"
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

prepare_deployed_diagnostics_contract() {
	local deployed_samples="$BATS_TEST_TMPDIR/deployed-diagnostics-samples.json"
	yq -e -r '.data."samples.json"' "$evidence_app/samples.yaml" >"$deployed_samples"
	write_deployed_samples_configmap "$deployed_samples"
}

tamper_deployed_diagnostics_contract() {
	local jq_filter="$1"
	local deployed_samples="$BATS_TEST_TMPDIR/deployed-diagnostics-samples.json"
	jq "$jq_filter" "$deployed_samples" >"$deployed_samples.tmp"
	mv -f -- "$deployed_samples.tmp" "$deployed_samples"
	write_deployed_samples_configmap "$deployed_samples"
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
	printf '%s\n' '{"nodes":[{"nodeName":"nuc1","strategyId":"qsv-hevc-icq-v1","proofSchemaVersion":3,"initialization":"passed","initializationReason":"","renderNode":"/dev/dri/renderD128","drmDriver":"i915","selectedRateControl":"ICQ","telemetryStatus":"available","telemetryReason":"","videoBusyNanoseconds":800000000,"videoBusyPercent":40,"encodeFps":72,"encodeSpeed":1.25,"decode":"passed","vmaf":"passed","proofStatus":"passed","proofReasons":"","verifiedAt":"2026-08-14T18:00:00Z","configuredImageDigest":"sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb","imageId":"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb"}]}'
}

two_passing_capability_nodes() {
	jq -c '.nodes += [(.nodes[0] | .nodeName = "nuc3")]' <<<"$(valid_capability_evidence)"
}

valid_chosen_record() {
	local cohort="$1" state="$2" setting="${3:-22}" sample hdr
	case "$cohort" in
	avc) sample='avc-grain-memento'; hdr='not-applicable' ;;
	vc1) sample='vc1-fugitive'; hdr='not-applicable' ;;
	hdr10) sample='hdr10-grain-goodfellas'; hdr='passed' ;;
	esac
	jq -n -c --arg state "$state" --arg sample "$sample" --arg hdr "$hdr" --argjson setting "$setting" '
		{
			strategyId:"qsv-hevc-icq-v1", qualityRunId:"20260815T120000Z-aaaaaaaa",
			qualityResultsSha256:("sha256:" + ("a" * 64)),
			candidateEvidenceSha256:("sha256:" + ("b" * 64)), globalQuality:$setting,
			state:$state,
			cropReview:{status:"passed",reviewedAt:"2026-08-15T12:00:00Z",clips:[{sampleId:$sample,clipId:"detail",result:"passed"}]},
			finalistReview:(if $state == "final" then {
				status:"passed",finalistRunId:"20260815T140000Z-bbbbbbbb",sampleId:$sample,
				resultsSha256:("sha256:" + ("c" * 64)),reviewedAt:"2026-08-15T14:00:00Z",
				checklist:{directPlay:"passed",hdrHandling:$hdr,motionArtifacts:"passed",grainRetention:"passed",banding:"passed",blocking:"passed"}
			} else null end), rejectedSettings:[]
		}'
}

set_dispatch_chosen_record() {
	local cohort="$1" state="$2" setting="${3:-22}" record
	record="$(valid_chosen_record "$cohort" "$state" "$setting")"
	CHOSEN_COHORT="$cohort" CHOSEN_RECORD="$record" yq -i '
		.data."samples.json" |= (from_yaml | .chosenSettings[strenv(CHOSEN_COHORT)] = (strenv(CHOSEN_RECORD) | from_json) | to_json)
	' "$evidence_app/samples.yaml"
}

# Catches any confirmation branch that treats an absent, empty, or merely
# similar capability token as authority to create a cluster resource.
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
@test "contention rollback never deletes replacement Jobs" {
	prepare_contention_source
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:contention-b'
	export STUB_HANDOFF_LOG_READY=0
	export STUB_JOB_REPLACEMENT=1
	run_dispatch run contention-b living-room-player a-4k-hdr
	[ "$status" -ne 0 ]
	[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / delete job\// {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 0 ]
}

# Catches single-Job rollback deleting a same-name replacement after handoff
# failure.
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

# Catches a mode-specific bypass that validates evidence only for quality while
# savings, finalist, or contention can still create an expensive Job.
@test "all expensive modes refuse pending capability evidence before create" {
	prepare_evidence_source
	set_capability_evidence pending '{"nodes":[]}'
	set_dispatch_chosen_record avc provisional 22
	set_dispatch_chosen_record vc1 final 26
	set_dispatch_chosen_record hdr10 final 22
	run_id='20260802T120000Z-1234abcd'

	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'
	run_dispatch run quality
	[ "$status" -ne 0 ]
	[[ "$output" == *'capability evidence'* ]]

	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:savings'
	run_dispatch run savings "$run_id"
	[ "$status" -ne 0 ]
	[[ "$output" == *'capability evidence'* ]]

	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:finalist'
	export ENCODE_BENCHMARK_FINALIST_CONFIRM="copy:encode-benchmark:$run_id:avc-grain-memento"
	run_dispatch run finalist "$run_id" avc-grain-memento
	[ "$status" -ne 0 ]
	[[ "$output" == *'capability evidence'* ]]

	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:contention-a'
	run_dispatch run contention-a living-room-player a-4k-hdr
	[ "$status" -ne 0 ]
	[[ "$output" == *'capability evidence'* ]]
	assert_no_mutations
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
	[ "$(mutation_count)" -eq 2 ]
	job="$(job_capture)"
	assert_hardened_job "$job"
	run_id="$(yq -r '.metadata.labels."homelab-talos/benchmark-run"' "$job")"
	[[ "$run_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]]
	[ "$(yq -r '.spec.template.metadata.labels."homelab-talos/benchmark-run"' "$job")" = "$run_id" ]
	[ "$(yq -r '.spec.template.spec.containers[0].command | join(" ")' "$job")" = "/scripts/benchmark.sh quality $run_id" ]
	[[ "$output" == *"run_id=$run_id"* ]]
}

# Catches diagnostics remaining unreachable behind the generic run-mode allowlist
# or using the generic confirmation path instead of its dedicated operator gate.
@test "diagnostics requires the exact confirmation before creating a Job" {
	prepare_deployed_diagnostics_contract
	assert_guard_refuses ENCODE_BENCHMARK_DIAGNOSTICS_CONFIRM run:encode-benchmark:quality run diagnostics

	export ENCODE_BENCHMARK_DIAGNOSTICS_CONFIRM='run:encode-benchmark:diagnostics'
	run_dispatch run diagnostics
	[ "$status" -eq 0 ]
	[ "$(mutation_count)" -eq 2 ]
	[ "$(find "$STUB_CAPTURE_DIR" -maxdepth 1 -name 'Job-*.yaml' | wc -l | tr -d ' ')" -eq 1 ]
	job="$(job_capture)"
	assert_hardened_job "$job"
	[ "$(yq -r '.spec.activeDeadlineSeconds' "$job")" = '14400' ]
	run_id="$(yq -r '.metadata.labels."homelab-talos/benchmark-run"' "$job")"
	[ "$(yq -r '.spec.template.spec.containers[0].command | join(" ")' "$job")" = "/scripts/benchmark.sh diagnostics $run_id" ]
	[ "$(yq -r '.spec.template.spec.automountServiceAccountToken' "$job")" = 'false' ]
	[ "$(yq -r '.spec.template.spec.securityContext.runAsNonRoot' "$job")" = 'true' ]
	[ "$(yq -r '.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].labelSelector.matchExpressions[0].values[0]' "$job")" = 'plex' ]
	[ "$(yq -r '.spec.template.spec.containers[0].resources.requests."gpu.intel.com/i915"' "$job")" = '1' ]
	[ "$(yq -r '.spec.template.spec.containers[0].resources.limits."gpu.intel.com/i915"' "$job")" = '1' ]
	[ "$(yq -r '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "media") | .readOnly' "$job")" = 'true' ]
	[ "$(yq -r '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "out") | .mountPath' "$job")" = '/out' ]
	assert_call_precedes_first_create ' get configmap/encode-benchmark-samples '
}

# Catches diagnostics accepting a caller-supplied run id in labels/output while
# dropping it from the runtime command, which would make runmeta create a
# different artifact directory than dispatch announced.
@test "diagnostics dispatch propagates an exact caller supplied run id into the runtime command" {
	prepare_deployed_diagnostics_contract
	export ENCODE_BENCHMARK_DIAGNOSTICS_CONFIRM='run:encode-benchmark:diagnostics'
	run_id='20260820T120000Z-feedbeef'

	run_dispatch run diagnostics "$run_id"
	[ "$status" -eq 0 ]
	job="$(job_capture)"
	[ "$(yq -r '.metadata.labels."homelab-talos/benchmark-run"' "$job")" = "$run_id" ]
	[ "$(yq -r '.spec.template.spec.containers[0].command | join(" ")' "$job")" = "/scripts/benchmark.sh diagnostics $run_id" ]
	[[ "$output" == *"run_id=$run_id"* ]]
}

# Catches diagnostics dispatch trusting stale or drifted deployed scope instead of
# proving the live samples ConfigMap still matches the committed accepted decision.
@test "diagnostics requires passing capability evidence and a matching deployed contract before create" {
	prepare_deployed_diagnostics_contract
	export ENCODE_BENCHMARK_DIAGNOSTICS_CONFIRM='run:encode-benchmark:diagnostics'

	set_capability_evidence pending '{"nodes":[]}'
	run_dispatch run diagnostics
	[ "$status" -ne 0 ]
	[[ "$output" == *'capability evidence'* ]]
	assert_no_mutations

	set_capability_evidence verified "$(valid_capability_evidence)"
	tamper_deployed_diagnostics_contract '.diagnostics.acceptedFindingsSha256 = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
	run_dispatch run diagnostics
	[ "$status" -ne 0 ]
	[[ "$output" == *'accepted findings digest'* ]]
	assert_no_mutations

	prepare_deployed_diagnostics_contract
	tamper_deployed_diagnostics_contract '.diagnostics.decisionSha256 = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
	run_dispatch run diagnostics
	[ "$status" -ne 0 ]
	[[ "$output" == *'decision digest'* ]]
	assert_no_mutations

	prepare_deployed_diagnostics_contract
	tamper_deployed_diagnostics_contract '.diagnostics.vmafSettings = [16, 28]'
	run_dispatch run diagnostics
	[ "$status" -ne 0 ]
	[[ "$output" == *'diagnostics contract is missing or malformed'* ]]
	assert_no_mutations
}

# Catches diagnostics resume or selector parsing that could mutate historical
# quality/findings artifacts or widen the fixed contract beyond its sealed panel.
@test "diagnostics rejects historical run ids and extra positional arguments before mutation" {
	prepare_deployed_diagnostics_contract
	export ENCODE_BENCHMARK_DIAGNOSTICS_CONFIRM='run:encode-benchmark:diagnostics'
	quality_run_id="$(yq -e -r '.data."samples.json" | from_json | .diagnostics.historicalQualityRunId' "$evidence_app/samples.yaml")"
	findings_run_id="$(yq -e -r '.data."samples.json" | from_json | .diagnostics.historicalFindingsRunId' "$evidence_app/samples.yaml")"

	for args in \
		"$quality_run_id" \
		"$findings_run_id" \
		'20260820T120000Z-feedbeef avc-grain-memento' \
		'20260820T120000Z-feedbeef 30' \
		'20260820T120000Z-feedbeef findings'; do
		run_dispatch run diagnostics $args
		[ "$status" -ne 0 ]
		assert_no_mutations
	done
}

# Catches the CPU reference path inheriting GPU resources or the QSV capability
# gate, losing its exact sample/node confirmation, or dropping established Job
# mounts, security, and Plex separation while pinning the selected node.
@test "x265 dispatch renders both reference titles as confirmed node-bound CPU-only Jobs" {
	set_dispatch_chosen_record avc final 22
	set_dispatch_chosen_record hdr10 final 22
	set_capability_evidence pending '{"nodes":[]}'
	cat >"$STUB_NODES_JSON" <<'EOF'
{"items":[{"metadata":{"name":"nuc1"},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"nuc3"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}
EOF
	printf '%s\n' '{"items":[]}' >"$STUB_PODS_JSON"
	run_id='20260815T130000Z-bbbbbbbb'
	for sample_id in avc-grain-memento hdr10-grain-goodfellas; do
		rm -f -- "$STUB_CAPTURE_DIR"/*
		: >"$STUB_CALLS"
		export ENCODE_BENCHMARK_X265_CONFIRM="run:encode-benchmark:x265:$sample_id:nuc3"
		run_dispatch run x265 "$sample_id" nuc3 "$run_id"
		[ "$status" -eq 0 ]
		dispatch_output="$output"
		[ "$(mutation_count)" -eq 2 ]
		job="$(job_capture)"
		[ "$(yq -r '.spec.activeDeadlineSeconds' "$job")" = '216000' ]
		[ "$(yq -o=json -I=0 '.spec.template.spec.nodeSelector' "$job")" = '{"kubernetes.io/hostname":"nuc3"}' ]
		[ "$(yq -r '.spec.template.spec.containers[0].resources.requests."gpu.intel.com/i915" // "absent"' "$job")" = 'absent' ]
		[ "$(yq -r '.spec.template.spec.containers[0].resources.limits."gpu.intel.com/i915" // "absent"' "$job")" = 'absent' ]
		[ "$(yq -r '.spec.template.spec.containers[0].volumeMounts | map(.name) | sort | join(" ")' "$job")" = 'image-evidence media out samples scratch scripts' ]
		[ "$(yq -r '.spec.template.spec.volumes | map(.name) | sort | join(" ")' "$job")" = 'image-evidence media out samples scratch scripts' ]
		run yq -e '
			.spec.template.spec.automountServiceAccountToken == false and
			.spec.template.spec.securityContext.runAsNonRoot == true and
			.spec.template.spec.securityContext.runAsUser == 568 and
			.spec.template.spec.securityContext.runAsGroup == 568 and
			.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation == false and
			(.spec.template.spec.containers[0].securityContext.capabilities.drop | length) == 1 and
			.spec.template.spec.containers[0].securityContext.capabilities.drop[0] == "ALL" and
			.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].labelSelector.matchExpressions[0].key == "app.kubernetes.io/name" and
			.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].labelSelector.matchExpressions[0].operator == "In" and
			(.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].labelSelector.matchExpressions[0].values | length) == 1 and
			.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].labelSelector.matchExpressions[0].values[0] == "plex"
		' "$job"
		[ "$status" -eq 0 ]
		[ "$(yq -r '.spec.template.spec.containers[0].command | join(" ")' "$job")" = "/scripts/benchmark.sh x265 $run_id $sample_id" ]
		[[ "$dispatch_output" == *"run_id=$run_id"* ]]
	done
}

# Catches unsafe, absent, unready, or Plex-hosting nodes reaching collision
# checks or resource creation, and catches a merely mode-bound confirmation.
@test "x265 node and exact confirmation are validated before mutation" {
	set_dispatch_chosen_record avc final 22
	for node_case in unsafe absent unready plex; do
		: >"$STUB_CALLS"
		printf '%s\n' '{"items":[]}' >"$STUB_PODS_JSON"
		case "$node_case" in
		unsafe)
			node='../nuc3'
			printf '%s\n' '{"items":[]}' >"$STUB_NODES_JSON"
			;;
		absent)
			node='nuc3'
			printf '%s\n' '{"items":[{"metadata":{"name":"nuc1"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}' >"$STUB_NODES_JSON"
			;;
		unready)
			node='nuc3'
			printf '%s\n' '{"items":[{"metadata":{"name":"nuc3"},"status":{"conditions":[{"type":"Ready","status":"False"}]}}]}' >"$STUB_NODES_JSON"
			;;
		plex)
			node='nuc3'
			printf '%s\n' '{"items":[{"metadata":{"name":"nuc3"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}' >"$STUB_NODES_JSON"
			printf '%s\n' '{"items":[{"metadata":{"namespace":"media","labels":{"app.kubernetes.io/name":"plex"}},"spec":{"nodeName":"nuc3"},"status":{"phase":"Running"}}]}' >"$STUB_PODS_JSON"
			;;
		esac
		export ENCODE_BENCHMARK_X265_CONFIRM="run:encode-benchmark:x265:avc-grain-memento:$node"
		run_dispatch run x265 avc-grain-memento "$node"
		[ "$status" -ne 0 ]
		assert_no_mutations
	done

	printf '%s\n' '{"items":[{"metadata":{"name":"nuc3"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}' >"$STUB_NODES_JSON"
	printf '%s\n' '{"items":[]}' >"$STUB_PODS_JSON"
	export ENCODE_BENCHMARK_X265_CONFIRM='run:encode-benchmark:x265'
	run_dispatch run x265 avc-grain-memento nuc3
	[ "$status" -ne 0 ]
	assert_no_mutations
}

# Catches a generated host correlation being persisted as the quality run ID.
# The runtime is the first component with the complete immutable identity, so it
# must turn the dispatched correlation into the manifest-bound run ID before
# that run can authorize a chosen setting.
@test "generated quality dispatch becomes a runtime identity bound chosen upstream" {
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

	results="$BENCHMARK_OUT/runs/$runtime_run_id/results.csv"
	printf '%s\n' \
		'run_id,panel,sample_id,cohort,source_sha256,clip_id,encoder,requested_setting,selected_rate_control,status,attempt,input_bytes,output_bytes,reduction_percent,input_bit_rate,output_bit_rate,wall_seconds,encode_fps,encode_speed,vmaf_harmonic_mean,vmaf_1pct_low,ssim,gpu_busy_percent,qsv_proof,validation_codec,validation_duration,validation_resolution,validation_frame_rate,validation_bit_depth,validation_hdr,validation_audio_tracks,validation_subtitle_tracks,validation_chapters,validation_failures,log_path,output_disposition,strategy_id,qsv_initialization,video_busy_nanoseconds' \
		"$runtime_run_id,quality,avc-grain-memento,avc,aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,detail,qsv,22,ICQ,passed,1,1000,600,40,8000,4800,10,30,1,96,92,0.99,50,passed,passed,passed,passed,passed,passed,passed,passed,passed,passed,,logs/fixture.log,discarded,qsv-hevc-icq-v1,passed,800000000" \
		>"$results"
	results_digest="sha256:$(sha256sum "$results" | awk '{print $1}')"
	candidates="$BENCHMARK_OUT/runs/$runtime_run_id/quality-candidates.json"
	jq -n -c --arg run "$runtime_run_id" --arg digest "$results_digest" '{
		schemaVersion:1,strategyId:"qsv-hevc-icq-v1",qualityRunId:$run,
		resultsSchemaVersion:2,resultsSha256:$digest,
		cohorts:{avc:{status:"eligible",expectedClipCount:1,
			candidates:[{globalQuality:22,medianReductionPercent:40}]}}
	}' >"$candidates"
	candidate_digest="sha256:$(sha256sum "$candidates" | awk '{print $1}')"
	record="$(valid_chosen_record avc provisional 22 | jq -c \
		--arg run "$runtime_run_id" --arg results "$results_digest" --arg candidates "$candidate_digest" \
		'.qualityRunId = $run | .qualityResultsSha256 = $results | .candidateEvidenceSha256 = $candidates')"
	jq --argjson record "$record" '.chosenSettings.avc = $record' \
		"$BENCHMARK_SAMPLES_FILE" >"$BENCHMARK_SAMPLES_FILE.tmp"
	mv -f -- "$BENCHMARK_SAMPLES_FILE.tmp" "$BENCHMARK_SAMPLES_FILE"

	run "$evidence_app/scripts/benchmark.sh" _test chosen-upstream avc provisional
	[ "$status" -eq 0 ]
	[ "$(jq -r '.selectedSettings[0].qualityRunId' <<<"$output")" = "$runtime_run_id" ]
}

# Catches a finalist dispatch that forwards an unbound copy approval into the
# pod, where a successful full-title encode could otherwise persist output.
@test "finalist requires exact run and sample copy confirmation" {
	run_id='20260802T120000Z-1234abcd'
	sample_id='avc-grain-memento'
	set_dispatch_chosen_record avc provisional 22
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:finalist'
	assert_guard_refuses ENCODE_BENCHMARK_FINALIST_CONFIRM wrong:finalist \
		run finalist "$run_id" "$sample_id"

	export ENCODE_BENCHMARK_FINALIST_CONFIRM="copy:encode-benchmark:$run_id:$sample_id"
	run_dispatch run finalist "$run_id" "$sample_id"
	[ "$status" -eq 0 ]
	[ "$(mutation_count)" -eq 2 ]
}

# Catches state or title checks that happen after Job creation, and catches a
# finalized or exhausted cohort being treated as permission to create another finalist.
@test "finalist dispatch accepts only the provisional cohort finalist before mutation" {
	run_id='20260802T120000Z-1234abcd'
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:finalist'

	for state in final rejected; do
		set_dispatch_chosen_record avc "$state" 22
		export ENCODE_BENCHMARK_FINALIST_CONFIRM="copy:encode-benchmark:$run_id:avc-grain-memento"
		run_dispatch run finalist "$run_id" avc-grain-memento
		[ "$status" -ne 0 ]
		assert_no_mutations
	done

	set_dispatch_chosen_record avc provisional 22
	export ENCODE_BENCHMARK_FINALIST_CONFIRM="copy:encode-benchmark:$run_id:avc-clean-coco"
	run_dispatch run finalist "$run_id" avc-clean-coco
	[ "$status" -ne 0 ]
	assert_no_mutations
}

# Catches provisional visual evidence authorizing downstream work before Plex
# review, or malformed chosen records reaching any mocked cluster mutation.
@test "downstream dispatch requires final chosen settings before mutation" {
	run_id='20260802T120000Z-1234abcd'
	set_dispatch_chosen_record hdr10 provisional 22
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:savings'
	run_dispatch run savings "$run_id"
	[ "$status" -ne 0 ]
	assert_no_mutations

	set_dispatch_chosen_record avc provisional 24
	set_dispatch_chosen_record vc1 final 26
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:contention-b'
	run_dispatch run contention-b living-room-player a-4k-hdr
	[ "$status" -ne 0 ]
	assert_no_mutations

	CHOSEN_RECORD="$(valid_chosen_record avc final 24 | jq -c 'del(.cropReview)')" yq -i '
		.data."samples.json" |= (from_yaml | .chosenSettings.avc = (strenv(CHOSEN_RECORD) | from_json) | to_json)
	' "$evidence_app/samples.yaml"
	run_dispatch run contention-b living-room-player a-4k-hdr
	[ "$status" -ne 0 ]
	assert_no_mutations
}

# Catches any downstream dispatcher accepting a setting that the shared ICQ
# candidate source excludes, after it has reached a mocked cluster mutation.
@test "finalist dispatch rejects every out-of-range ICQ setting before mutation" {
	run_id='20260802T120000Z-1234abcd'
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:finalist'
	export ENCODE_BENCHMARK_FINALIST_CONFIRM="copy:encode-benchmark:$run_id:avc-grain-memento"
	for setting in 14 17 32; do
		set_dispatch_chosen_record avc provisional "$setting"
		run_dispatch run finalist "$run_id" avc-grain-memento
		[ "$status" -ne 0 ]
		assert_no_mutations
	done
}

# Catches savings authorization that accepts a claimed final decision without
# validating its full review evidence, or starts a Job when no cohort is final.
@test "savings dispatch fails closed for malformed and absent final cohorts" {
	run_id='20260802T120000Z-1234abcd'
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:savings'
	CHOSEN_RECORD="$(valid_chosen_record hdr10 final 22 | jq -c 'del(.finalistReview.checklist)')" yq -i '
		.data."samples.json" |= (from_yaml | .chosenSettings.hdr10 = (strenv(CHOSEN_RECORD) | from_json) | to_json)
	' "$evidence_app/samples.yaml"
	run_dispatch run savings "$run_id"
	[ "$status" -ne 0 ]
	assert_no_mutations

	CHOSEN_RECORD="$(valid_chosen_record hdr10 provisional 22)" yq -i '
		.data."samples.json" |= (from_yaml | .chosenSettings = {"hdr10":(strenv(CHOSEN_RECORD) | from_json)} | to_json)
	' "$evidence_app/samples.yaml"
	run_dispatch run savings "$run_id"
	[ "$status" -ne 0 ]
	[[ "$output" == *'no final chosen setting authorizes savings'* ]]
	assert_no_mutations
}

# Catches authorizing a valid AVC final before rejecting a malformed final
# claim for another canonical cohort.
@test "savings dispatch rejects mixed valid and malformed claimed-final cohorts" {
	run_id='20260802T120000Z-1234abcd'
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:savings'
	set_dispatch_chosen_record avc final 22
	CHOSEN_RECORD="$(valid_chosen_record hdr10 final 22 | jq -c 'del(.finalistReview.checklist)')" yq -i '
		.data."samples.json" |= (from_yaml | .chosenSettings.hdr10 = (strenv(CHOSEN_RECORD) | from_json) | to_json)
	' "$evidence_app/samples.yaml"

	run_dispatch run savings "$run_id"
	[ "$status" -ne 0 ]
	assert_no_mutations
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

# Catches the operator interface swapping the sample/node/run ordering or
# bypassing the single deployed-source guard before entering dispatch.
@test "x265 Just interface preserves sample node and optional exact run identity" {
	set_dispatch_chosen_record avc final 22
	printf '%s\n' '{"items":[{"metadata":{"name":"nuc3"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}' >"$STUB_NODES_JSON"
	printf '%s\n' '{"items":[]}' >"$STUB_PODS_JSON"
	run_id='20260815T130000Z-bbbbbbbb'
	export ENCODE_BENCHMARK_X265_CONFIRM='run:encode-benchmark:x265:avc-grain-memento:nuc3'

	run just --justfile "$PROJECT_ROOT/kubernetes/mod.just" \
		kubeconfig="$KUBECONFIG_FIXTURE" encode-benchmark-x265 \
		avc-grain-memento nuc3 "$run_id"
	[ "$status" -eq 0 ]
	job="$(job_capture)"
	[ "$(yq -r '.metadata.labels."homelab-talos/benchmark-run"' "$job")" = "$run_id" ]
	[ "$(yq -r '.spec.template.spec.containers[0].command | join(" ")' "$job")" = "/scripts/benchmark.sh x265 $run_id avc-grain-memento" ]

	rm -f -- "$STUB_CAPTURE_DIR"/*
	: >"$STUB_CALLS"
	export STUB_GIT_STALE=1
	run just --justfile "$PROJECT_ROOT/kubernetes/mod.just" \
		kubeconfig="$KUBECONFIG_FIXTURE" encode-benchmark-x265 \
		avc-grain-memento nuc3 "$run_id"
	[ "$status" -ne 0 ]
	assert_no_mutations
}

# Catches the dedicated operator entrypoint dropping deployed-source checks,
# widening arity beyond one optional run ID, or obscuring the exact confirmation.
@test "diagnostics Just interface routes only an optional run id through the dedicated guard" {
	prepare_deployed_diagnostics_contract
	export ENCODE_BENCHMARK_DIAGNOSTICS_CONFIRM='run:encode-benchmark:diagnostics'

	run just --justfile "$PROJECT_ROOT/kubernetes/mod.just" \
		kubeconfig="$KUBECONFIG_FIXTURE" encode-benchmark-diagnostics
	[ "$status" -eq 0 ]
	job="$(job_capture)"
	run_id="$(yq -r '.metadata.labels."homelab-talos/benchmark-run"' "$job")"
	[ "$(yq -r '.spec.template.spec.containers[0].command | join(" ")' "$job")" = "/scripts/benchmark.sh diagnostics $run_id" ]

	rm -f -- "$STUB_CAPTURE_DIR"/*
	: >"$STUB_CALLS"
	unset ENCODE_BENCHMARK_DIAGNOSTICS_CONFIRM
	run just --justfile "$PROJECT_ROOT/kubernetes/mod.just" \
		kubeconfig="$KUBECONFIG_FIXTURE" encode-benchmark-diagnostics
	[ "$status" -ne 0 ]
	[[ "$output" == *'ENCODE_BENCHMARK_DIAGNOSTICS_CONFIRM'* ]]
	assert_no_mutations

	run just --justfile "$PROJECT_ROOT/kubernetes/mod.just" \
		kubeconfig="$KUBECONFIG_FIXTURE" encode-benchmark-diagnostics \
		20260820T120000Z-feedbeef avc-grain-memento
	[ "$status" -ne 0 ]
	assert_no_mutations

	export STUB_GIT_STALE=1
	run just --justfile "$PROJECT_ROOT/kubernetes/mod.just" \
		kubeconfig="$KUBECONFIG_FIXTURE" encode-benchmark-diagnostics
	[ "$status" -ne 0 ]
	assert_no_mutations
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
  samples.json: |
    {
      "schemaVersion": 2,
      "strategy": {
        "id": "qsv-hevc-icq-v1",
        "resultsSchemaVersion": 2,
        "runManifestSchemaVersion": 2,
        "capabilityProofSchemaVersion": 3,
        "globalQualityCandidates": [16, 18, 20, 22, 24, 26, 28, 30],
        "x265": {
          "initialCrfs": [18, 20, 22, 24],
          "minimumCrf": 10,
          "maximumCrf": 34,
          "step": 2
        }
      },
      "runtime": {
        "image": "docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb"
      },
      "savingsSeed": 20260802,
      "qualityPanel": [
        {
          "id": "z-4k-hdr",
          "cohort": "hdr10",
          "path": "/media/z-4k-hdr.mkv",
          "sizeBytes": 1,
          "width": 3840,
          "height": 2160,
          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "clips": {
            "detail": "00:00:00.000"
          }
        },
        {
          "id": "a-4k-hdr",
          "cohort": "hdr10",
          "path": "/media/a-4k-hdr.mkv",
          "sizeBytes": 1,
          "width": 3840,
          "height": 2160,
          "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "clips": {
            "detail": "00:00:00.000"
          }
        },
        {
          "id": "c-1080-vc1",
          "cohort": "vc1",
          "path": "/media/c-1080-vc1.mkv",
          "sizeBytes": 1,
          "width": 1920,
          "height": 1080,
          "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
          "clips": {
            "detail": "00:00:00.000"
          }
        },
        {
          "id": "b-1080-avc",
          "cohort": "avc",
          "path": "/media/b-1080-avc.mkv",
          "sizeBytes": 1,
          "width": 1920,
          "height": 1080,
          "sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
          "clips": {
            "detail": "00:00:00.000"
          }
        },
        {
          "id": "d-dolby-vision",
          "cohort": "dolby-vision",
          "path": "/media/d-dolby-vision.mkv",
          "sizeBytes": 1,
          "width": 3840,
          "height": 2160,
          "sha256": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
          "detectionOnly": true,
          "clips": {}
        }
      ],
      "savingsPanel": [],
      "chosenSettings": {
        "avc": {
          "globalQuality": 24,
          "qualityRunId": "20260802T120000Z-aaaaaaaa"
        },
        "vc1": {
          "globalQuality": 26,
          "qualityRunId": "20260802T120000Z-aaaaaaaa"
        },
        "hdr10": {
          "globalQuality": 22,
          "qualityRunId": "20260802T120000Z-aaaaaaaa"
        }
      }
    }
EOF
	export ENCODE_BENCHMARK_TEST_MODE=1
	export ENCODE_BENCHMARK_APP_DIR="$contention_app"
	evidence_app="$contention_app"
	set_dispatch_chosen_record avc final 24
	set_dispatch_chosen_record vc1 final 26
	set_dispatch_chosen_record hdr10 final 22
	set_capability_evidence verified "$(two_passing_capability_nodes)"
}

# Catches contention case selection drifting with panel row order, rendering
# the wrong worker cardinality, or sharing a node-bound immutable run identity.
@test "contention cases render deterministic worker runs under one dispatch group" {
	prepare_contention_source
	set_dispatch_chosen_record avc final 16
	set_dispatch_chosen_record vc1 final 18
	set_dispatch_chosen_record hdr10 final 30
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:contention-a'
	run_dispatch run contention-a living-room-player a-4k-hdr
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
	run_dispatch run contention-b living-room-player a-4k-hdr
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

	run_dispatch run contention-b living-room-player a-4k-hdr "$worker_1_run"
	[ "$status" -eq 64 ]
	assert_no_mutations

	run_dispatch run contention-b living-room-player a-4k-hdr "$worker_1_run,$worker_1_run"
	[ "$status" -eq 64 ]
	assert_no_mutations

	run_dispatch run contention-b living-room-player a-4k-hdr "$worker_1_run,../bad"
	[ "$status" -eq 64 ]
	assert_no_mutations

	run_dispatch run contention-b living-room-player a-4k-hdr "$worker_1_run,$worker_2_run"
	[ "$status" -eq 0 ]
	[ "$(mutation_count)" -eq 4 ]
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
	prepare_contention_source
	yq -i '.data."samples.json" |= (from_yaml | .qualityPanel = [] | to_json)' "$contention_app/samples.yaml"
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:contention-a'
	run_dispatch run contention-a living-room-player a-4k-hdr
	[ "$status" -ne 0 ]
	[ "$output" = 'no eligible 3840x2160 HDR10 quality sample for contention case a' ]
	assert_no_mutations

	prepare_contention_source
	yq -i '.data."samples.json" |= (from_yaml | del(.chosenSettings.avc) | to_json)' "$contention_app/samples.yaml"
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:contention-b'
	run_dispatch run contention-b living-room-player a-4k-hdr
	[ "$status" -ne 0 ]
	[ "$output" = 'no final setting for contention sample cohort: avc' ]
	assert_no_mutations
}

# Catches dispatch inferring 4K/1080p from cohort labels instead of requiring
# the committed probe resolution for every selected contention worker.
@test "contention dispatch rejects missing or wrong exact resolution before mutation" {
	prepare_contention_source
	yq -i '.data."samples.json" |= (from_yaml | .qualityPanel[0].width = 1920 | .qualityPanel[1].width = 1920 | to_json)' "$contention_app/samples.yaml"
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:contention-a'
	run_dispatch run contention-a living-room-player a-4k-hdr
	[ "$status" -ne 0 ]
	[ "$output" = 'no eligible 3840x2160 HDR10 quality sample for contention case a' ]
	assert_no_mutations

	yq -i '.data."samples.json" |= (from_yaml | .qualityPanel[0].width = 3840 | .qualityPanel[1].width = 3840 | del(.qualityPanel[2].height) | to_json)' "$contention_app/samples.yaml"
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:contention-b'
	run_dispatch run contention-b living-room-player a-4k-hdr
	[ "$status" -ne 0 ]
	[ "$output" = 'fewer than two eligible 1920x1080 non-DV quality samples for contention case b' ]
	assert_no_mutations
}

# Catches contention dispatch creating work before it binds the operator's
# playback identity and pins each two-worker Job to a separate committed,
# still-eligible capability node.
@test "contention dispatch binds playback identity and distinct passing nodes before Job creation" {
	prepare_contention_source
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:contention-b'

	run_dispatch run contention-b living-room-player a-4k-hdr
	[ "$status" -eq 0 ]
	mapfile -t jobs < <(find "$STUB_CAPTURE_DIR" -maxdepth 1 -name 'Job-*.yaml' -print | sort)
	[ "${#jobs[@]}" -eq 2 ]
	[ "$(yq -r '.spec.template.spec.nodeSelector."kubernetes.io/hostname"' "${jobs[0]}")" != \
		"$(yq -r '.spec.template.spec.nodeSelector."kubernetes.io/hostname"' "${jobs[1]}")" ]
	for job in "${jobs[@]}"; do
		[ "$(yq -r '.spec.template.spec.containers[0].env[] | select(.name == "BENCHMARK_PLEX_CLIENT_DEVICE") | .value' "$job")" = 'living-room-player' ]
		[ "$(yq -r '.spec.template.spec.containers[0].env[] | select(.name == "BENCHMARK_PLAYBACK_SAMPLE_ID") | .value' "$job")" = 'a-4k-hdr' ]
	done
}

# Catches a malformed operator label, non-UHD playback identity, or one-node
# contention evidence being accepted far enough to create a Job.
@test "contention dispatch fails closed for invalid playback identity or insufficient nodes" {
	prepare_contention_source
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:contention-b'
	run_dispatch run contention-b 'Living Room' a-4k-hdr
	[ "$status" -ne 0 ]
	assert_no_mutations

	run_dispatch run contention-b living-room-player b-1080-avc
	[ "$status" -ne 0 ]
	assert_no_mutations

	set_capability_evidence verified "$(valid_capability_evidence)"
	run_dispatch run contention-b living-room-player a-4k-hdr
	[ "$status" -ne 0 ]
	assert_no_mutations

	prepare_contention_source
	set_capability_evidence verified "$(two_passing_capability_nodes | jq 'del(.nodes[1].videoBusyPercent)')"
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:contention-b'
	run_dispatch run contention-b living-room-player a-4k-hdr
	[ "$status" -ne 0 ]
	assert_no_mutations
}

write_results_fixtures() {
	local run_id="$1" image_id="$2"
	STUB_JOBS_JSON="$BATS_TEST_TMPDIR/jobs.json"
	STUB_PODS_JSON="$BATS_TEST_TMPDIR/pods.json"
	STUB_LOGS_FILE="$BATS_TEST_TMPDIR/logs.txt"
	STUB_IMAGE_EVIDENCE_DIR="$BATS_TEST_TMPDIR/image-evidence"
	export STUB_JOBS_JSON STUB_PODS_JSON STUB_LOGS_FILE STUB_IMAGE_EVIDENCE_DIR
	mkdir -p "$STUB_IMAGE_EVIDENCE_DIR"
	cat >"$STUB_JOBS_JSON" <<EOF
{"apiVersion":"v1","items":[{"metadata":{"name":"encode-benchmark-capabilities-fixture","uid":"fixture-job-uid","labels":{"app.kubernetes.io/name":"encode-benchmark","homelab-talos/benchmark-run":"$run_id","homelab-talos/benchmark-mode":"capabilities"},"annotations":{"homelab-talos/image-evidence-configmap":"encode-benchmark-image-fixture"}},"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"nuc2"},"containers":[{"name":"benchmark","image":"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb"}]}}},"status":{"conditions":[{"type":"Complete","status":"True"}],"succeeded":1,"failed":0,"startTime":"2026-08-02T12:00:00Z","completionTime":"2026-08-02T12:01:00Z"}}]}
EOF
	cat >"$STUB_PODS_JSON" <<EOF
{"apiVersion":"v1","items":[{"metadata":{"name":"encode-benchmark-capabilities-fixture-pod","labels":{"job-name":"encode-benchmark-capabilities-fixture","homelab-talos/benchmark-run":"$run_id"},"ownerReferences":[{"apiVersion":"batch/v1","kind":"Job","name":"encode-benchmark-capabilities-fixture","uid":"fixture-job-uid","controller":true,"blockOwnerDeletion":true}]},"spec":{"nodeName":"nuc2"},"status":{"phase":"Succeeded","containerStatuses":[{"name":"benchmark","imageID":"$image_id"}]}}]}
EOF
	cat >"$STUB_LOGS_FILE" <<'EOF'
{"status":"passed","strategyId":"qsv-hevc-icq-v1","proofSchemaVersion":3,"initialization":"passed","initializationReason":"","renderNode":"/dev/dri/renderD128","drmDriver":"i915","selectedRateControl":"ICQ","telemetryStatus":"available","telemetryReason":"","videoBusyNanoseconds":800000000,"videoBusyPercent":40,"encodeFps":72,"encodeSpeed":1.25,"decode":"passed","vmaf":"passed","proofStatus":"passed","proofReasons":"","uid":568,"hevcQsv":true,"libx265":true,"nodeName":"nuc2","configuredImage":"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb","configuredImageDigest":"sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb","sourcePath":"/media/Secret Movie.mkv","source_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","credential":"dont-print-me"}
EOF
	cat >"$STUB_IMAGE_EVIDENCE_DIR/encode-benchmark-image-fixture.json" <<EOF
{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"encode-benchmark-image-fixture","ownerReferences":[{"apiVersion":"batch/v1","kind":"Job","name":"encode-benchmark-capabilities-fixture","uid":"fixture-job-uid","controller":true,"blockOwnerDeletion":true}]},"data":{"image.json":"{\"configuredImage\":\"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb\",\"dispatchedImage\":\"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb\",\"imageId\":\"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb\"}"}}
EOF
}

write_multi_node_results_fixtures() {
	local run_id="$1" image_id="$2"
	local lower_run="${run_id,,}"
	STUB_JOBS_JSON="$BATS_TEST_TMPDIR/jobs-multi.json"
	STUB_PODS_JSON="$BATS_TEST_TMPDIR/pods-multi.json"
	STUB_LOGS_DIR="$BATS_TEST_TMPDIR/logs-multi"
	STUB_IMAGE_EVIDENCE_DIR="$BATS_TEST_TMPDIR/image-evidence-multi"
	export STUB_JOBS_JSON STUB_PODS_JSON STUB_LOGS_DIR STUB_IMAGE_EVIDENCE_DIR
	unset STUB_LOGS_FILE
	mkdir -p "$STUB_LOGS_DIR" "$STUB_IMAGE_EVIDENCE_DIR"
	jq -n --arg run "$run_id" --arg lower "$lower_run" '{apiVersion:"v1",items:["nuc1","nuc3"] | map({
		metadata:{name:("encode-benchmark-capabilities-" + $lower + "-node-" + .),uid:("uid-" + .),labels:{"app.kubernetes.io/name":"encode-benchmark","homelab-talos/benchmark-run":$run,"homelab-talos/benchmark-mode":"capabilities"},annotations:{"homelab-talos/image-evidence-configmap":("encode-benchmark-image-" + .)}},
		spec:{template:{spec:{nodeSelector:{"kubernetes.io/hostname":.},containers:[{name:"benchmark",image:"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb"}]}}},
		status:{conditions:[{type:"Complete",status:"True"}],succeeded:1,failed:0,startTime:"2026-08-14T18:00:00Z",completionTime:"2026-08-14T18:01:00Z"}
	})}' >"$STUB_JOBS_JSON"
	jq -n --arg run "$run_id" --arg lower "$lower_run" --arg image "$image_id" '{apiVersion:"v1",items:["nuc1","nuc3"] | map({
		metadata:{name:("capability-pod-" + .),labels:{"job-name":("encode-benchmark-capabilities-" + $lower + "-node-" + .)},ownerReferences:[{apiVersion:"batch/v1",kind:"Job",name:("encode-benchmark-capabilities-" + $lower + "-node-" + .),uid:("uid-" + .),controller:true,blockOwnerDeletion:true}]},
		spec:{nodeName:.},status:{phase:"Succeeded",containerStatuses:[{name:"benchmark",imageID:$image}]}
	})}' >"$STUB_PODS_JSON"
	for node in nuc1 nuc3; do
		printf '%s\n' "{\"status\":\"passed\",\"strategyId\":\"qsv-hevc-icq-v1\",\"proofSchemaVersion\":3,\"initialization\":\"passed\",\"initializationReason\":\"\",\"renderNode\":\"/dev/dri/renderD128\",\"drmDriver\":\"i915\",\"selectedRateControl\":\"ICQ\",\"telemetryStatus\":\"available\",\"telemetryReason\":\"\",\"videoBusyNanoseconds\":800000000,\"videoBusyPercent\":40,\"encodeFps\":72,\"encodeSpeed\":1.25,\"decode\":\"passed\",\"vmaf\":\"passed\",\"proofStatus\":\"passed\",\"proofReasons\":\"\",\"uid\":568,\"hevcQsv\":true,\"libx265\":true,\"nodeName\":\"$node\",\"configuredImageDigest\":\"sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb\",\"sourcePath\":\"/media/Secret Movie.mkv\"}" \
			>"$STUB_LOGS_DIR/encode-benchmark-capabilities-$lower_run-node-$node.log"
		jq -n --arg node "$node" --arg run "$run_id" '{apiVersion:"v1",kind:"ConfigMap",metadata:{name:("encode-benchmark-image-" + $node),ownerReferences:[{apiVersion:"batch/v1",kind:"Job",name:("encode-benchmark-capabilities-" + ($run|ascii_downcase) + "-node-" + $node),uid:("uid-" + $node),controller:true,blockOwnerDeletion:true}]},data:{"image.json":"{\"configuredImage\":\"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb\",\"dispatchedImage\":\"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb\",\"imageId\":\"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb\"}"}}' >"$STUB_IMAGE_EVIDENCE_DIR/encode-benchmark-image-$node.json"
	done
}

write_diagnostics_results_fixture() {
	local run_id="$1" pod_phase="$2" terminal_message="${3:-}"
	STUB_BENCHMARK_PODS_JSON="$BATS_TEST_TMPDIR/diagnostic-pods.json"
	unset STUB_JOBS_JSON STUB_PODS_JSON STUB_LOGS_FILE STUB_LOGS_DIR STUB_IMAGE_EVIDENCE_DIR
	export STUB_BENCHMARK_PODS_JSON
	jq -n -c --arg run "$run_id" --arg phase "$pod_phase" --arg message "$terminal_message" '
		{
			apiVersion:"v1",
			items:[{
				metadata:{
					name:"encode-benchmark-diagnostics-fixture-pod",
					labels:{
						"app.kubernetes.io/name":"encode-benchmark",
						"homelab-talos/benchmark-run":$run,
						"homelab-talos/benchmark-mode":"diagnostics",
						"job-name":"encode-benchmark-diagnostics-fixture"
					},
					ownerReferences:[{
						apiVersion:"batch/v1",kind:"Job",name:"encode-benchmark-diagnostics-fixture",
						uid:"fixture-job-uid",controller:true,blockOwnerDeletion:true
					}]
				},
				spec:{nodeName:"nuc2"},
				status:{
					phase:$phase,
					containerStatuses:[{
						name:"benchmark",
						state:(if $message == "" then
							(if $phase == "Running" or $phase == "Pending" then {running:{startedAt:"2026-08-19T12:00:00Z"}} else {terminated:{exitCode:0,reason:"Completed"}} end)
						else
							{terminated:{
								exitCode:(if $phase == "Succeeded" then 0 else 1 end),
								reason:(if $phase == "Succeeded" then "Completed" else "Error" end),
								finishedAt:"2026-08-19T12:05:00Z",
								message:$message
							}}
						end)
					}]
				}
			}]
		}
	' >"$STUB_BENCHMARK_PODS_JSON"
}

write_diagnostics_summary_fixture() {
	local run_id="$1" status="$2" destination="$3"
	jq -n -c --arg run "$run_id" --arg status "$status" '{
		schemaVersion:1,
		strategyId:"qsv-hevc-icq-v1",
		mode:"diagnostics",
		runId:$run,
		status:$status,
		vmaf:{
			total:5,
			entries:[
				{sampleId:"avc-grain-memento",clipId:"detail",status:"complete",classification:"unresolved",reasons:["offset-best-tie"],evidence:"vmaf/avc-grain-memento/detail/evidence.json"},
				{sampleId:"avc-grain-memento",clipId:"motion",status:"complete",classification:"unresolved",reasons:["offset-best-tie"],evidence:"vmaf/avc-grain-memento/motion/evidence.json"},
				{sampleId:"vc1-fugitive",clipId:"detail",status:"complete",classification:"unresolved",reasons:["offset-best-tie"],evidence:"vmaf/vc1-fugitive/detail/evidence.json"},
				{sampleId:"hdr10-grain-goodfellas",clipId:"detail",status:"complete",classification:"unresolved",reasons:["offset-best-tie"],evidence:"vmaf/hdr10-grain-goodfellas/detail/evidence.json"},
				{sampleId:"hdr10-motion-john-wick-2",clipId:"detail",status:"complete",classification:"unresolved",reasons:["offset-best-tie"],evidence:"vmaf/hdr10-motion-john-wick-2/detail/evidence.json"}
			]
		},
		hdr:{
			total:3,
			entries:[
				{sampleId:"hdr10-clean-ministry",status:"complete",classification:"preserved",reasons:["source-clip-encoded-metadata-agree"],evidence:"hdr/hdr10-clean-ministry/evidence.json"},
				{sampleId:"hdr10-grain-goodfellas",status:"complete",classification:"preserved",reasons:["source-clip-encoded-metadata-agree"],evidence:"hdr/hdr10-grain-goodfellas/evidence.json"},
				{sampleId:"hdr10-motion-john-wick-2",status:"complete",classification:"preserved",reasons:["source-clip-encoded-metadata-agree"],evidence:"hdr/hdr10-motion-john-wick-2/evidence.json"}
			]
		}
	}' >"$destination"
}

produce_diagnostics_terminal_message() {
	local status="$1" run_id="$2" summary="$3" termination="$4" samples_json
	samples_json="$BATS_TEST_TMPDIR/diagnostic-samples.json"
	yq -r '.data."samples.json"' \
		"$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/samples.yaml" >"$samples_json"
	BENCHMARK_TEST_MODE=1 \
	BENCHMARK_SAMPLES_FILE="$samples_json" \
	BENCHMARK_TERMINATION_LOG_PATH="$termination" \
		"$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/benchmark.sh" \
		_test diagnostic-terminal "$status" "$run_id" "$summary"
}

write_diagnostics_vmaf_case_summary_fixture() {
	local run_id="$1" case_id="$2" destination="$3"
	local fixture expected classification reasons
	fixture="$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/tests/fixtures/encode-benchmark/diagnostic-vmaf-cases.json"
	expected="$(jq -e -c --arg id "$case_id" '.cases[] | select(.id == $id) | .expected' "$fixture")" || return
	classification="$(jq -r '.classification' <<<"$expected")" || return
	reasons="$(jq -c '.reasons' <<<"$expected")" || return
	jq -n -c --arg run "$run_id" --arg classification "$classification" --argjson reasons "$reasons" '{
		schemaVersion:1,
		strategyId:"qsv-hevc-icq-v1",
		mode:"diagnostics",
		runId:$run,
		status:"complete",
		vmaf:{
			total:5,
			entries:[
				{sampleId:"avc-grain-memento",clipId:"detail",status:"complete",classification:$classification,reasons:$reasons,evidence:"vmaf/avc-grain-memento/detail/evidence.json"},
				{sampleId:"avc-grain-memento",clipId:"motion",status:"complete",classification:$classification,reasons:$reasons,evidence:"vmaf/avc-grain-memento/motion/evidence.json"},
				{sampleId:"vc1-fugitive",clipId:"detail",status:"complete",classification:$classification,reasons:$reasons,evidence:"vmaf/vc1-fugitive/detail/evidence.json"},
				{sampleId:"hdr10-grain-goodfellas",clipId:"detail",status:"complete",classification:$classification,reasons:$reasons,evidence:"vmaf/hdr10-grain-goodfellas/detail/evidence.json"},
				{sampleId:"hdr10-motion-john-wick-2",clipId:"detail",status:"complete",classification:$classification,reasons:$reasons,evidence:"vmaf/hdr10-motion-john-wick-2/detail/evidence.json"}
			]
		},
		hdr:{
			total:3,
			entries:[
				{sampleId:"hdr10-clean-ministry",status:"complete",classification:"preserved",reasons:["source-clip-encoded-metadata-agree"],evidence:"hdr/hdr10-clean-ministry/evidence.json"},
				{sampleId:"hdr10-grain-goodfellas",status:"complete",classification:"preserved",reasons:["source-clip-encoded-metadata-agree"],evidence:"hdr/hdr10-grain-goodfellas/evidence.json"},
				{sampleId:"hdr10-motion-john-wick-2",status:"complete",classification:"preserved",reasons:["source-clip-encoded-metadata-agree"],evidence:"hdr/hdr10-motion-john-wick-2/evidence.json"}
			]
		}
	}' >"$destination"
}

write_diagnostics_hdr_case_summary_fixture() {
	local run_id="$1" case_id="$2" destination="$3"
	local fixture expected classification reasons
	fixture="$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/tests/fixtures/encode-benchmark/diagnostic-hdr-cases.json"
	expected="$(jq -e -c --arg id "$case_id" '.cases[] | select(.id == $id) | .expected' "$fixture")" || return
	classification="$(jq -r '.classification' <<<"$expected")" || return
	reasons="$(jq -c '.reasons' <<<"$expected")" || return
	jq -n -c --arg run "$run_id" --arg classification "$classification" --argjson reasons "$reasons" '{
		schemaVersion:1,
		strategyId:"qsv-hevc-icq-v1",
		mode:"diagnostics",
		runId:$run,
		status:"complete",
		vmaf:{
			total:5,
			entries:[
				{sampleId:"avc-grain-memento",clipId:"detail",status:"complete",classification:"unresolved",reasons:["offset-best-tie"],evidence:"vmaf/avc-grain-memento/detail/evidence.json"},
				{sampleId:"avc-grain-memento",clipId:"motion",status:"complete",classification:"unresolved",reasons:["offset-best-tie"],evidence:"vmaf/avc-grain-memento/motion/evidence.json"},
				{sampleId:"vc1-fugitive",clipId:"detail",status:"complete",classification:"unresolved",reasons:["offset-best-tie"],evidence:"vmaf/vc1-fugitive/detail/evidence.json"},
				{sampleId:"hdr10-grain-goodfellas",clipId:"detail",status:"complete",classification:"unresolved",reasons:["offset-best-tie"],evidence:"vmaf/hdr10-grain-goodfellas/detail/evidence.json"},
				{sampleId:"hdr10-motion-john-wick-2",clipId:"detail",status:"complete",classification:"unresolved",reasons:["offset-best-tie"],evidence:"vmaf/hdr10-motion-john-wick-2/detail/evidence.json"}
			]
		},
		hdr:{
			total:3,
			entries:[
				{sampleId:"hdr10-clean-ministry",status:"complete",classification:$classification,reasons:$reasons,evidence:"hdr/hdr10-clean-ministry/evidence.json"},
				{sampleId:"hdr10-grain-goodfellas",status:"complete",classification:$classification,reasons:$reasons,evidence:"hdr/hdr10-grain-goodfellas/evidence.json"},
				{sampleId:"hdr10-motion-john-wick-2",status:"complete",classification:$classification,reasons:$reasons,evidence:"hdr/hdr10-motion-john-wick-2/evidence.json"}
			]
		}
	}' >"$destination"
}

write_diagnostics_custom_summary_fixture() {
	local run_id="$1" vmaf_classification="$2" vmaf_reasons_json="$3" hdr_classification="$4" hdr_reasons_json="$5" destination="$6"
	jq -n -c \
		--arg run "$run_id" \
		--arg vmaf_classification "$vmaf_classification" \
		--arg hdr_classification "$hdr_classification" \
		--argjson vmaf_reasons "$vmaf_reasons_json" \
		--argjson hdr_reasons "$hdr_reasons_json" '{
		schemaVersion:1,
		strategyId:"qsv-hevc-icq-v1",
		mode:"diagnostics",
		runId:$run,
		status:"complete",
		vmaf:{
			total:5,
			entries:[
				{sampleId:"avc-grain-memento",clipId:"detail",status:"complete",classification:$vmaf_classification,reasons:$vmaf_reasons,evidence:"vmaf/avc-grain-memento/detail/evidence.json"},
				{sampleId:"avc-grain-memento",clipId:"motion",status:"complete",classification:$vmaf_classification,reasons:$vmaf_reasons,evidence:"vmaf/avc-grain-memento/motion/evidence.json"},
				{sampleId:"vc1-fugitive",clipId:"detail",status:"complete",classification:$vmaf_classification,reasons:$vmaf_reasons,evidence:"vmaf/vc1-fugitive/detail/evidence.json"},
				{sampleId:"hdr10-grain-goodfellas",clipId:"detail",status:"complete",classification:$vmaf_classification,reasons:$vmaf_reasons,evidence:"vmaf/hdr10-grain-goodfellas/detail/evidence.json"},
				{sampleId:"hdr10-motion-john-wick-2",clipId:"detail",status:"complete",classification:$vmaf_classification,reasons:$vmaf_reasons,evidence:"vmaf/hdr10-motion-john-wick-2/detail/evidence.json"}
			]
		},
		hdr:{
			total:3,
			entries:[
				{sampleId:"hdr10-clean-ministry",status:"complete",classification:$hdr_classification,reasons:$hdr_reasons,evidence:"hdr/hdr10-clean-ministry/evidence.json"},
				{sampleId:"hdr10-grain-goodfellas",status:"complete",classification:$hdr_classification,reasons:$hdr_reasons,evidence:"hdr/hdr10-grain-goodfellas/evidence.json"},
				{sampleId:"hdr10-motion-john-wick-2",status:"complete",classification:$hdr_classification,reasons:$hdr_reasons,evidence:"hdr/hdr10-motion-john-wick-2/evidence.json"}
			]
		}
	}' >"$destination"
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

# Catches losing diagnostic evidence because the capability command correctly
# exits nonzero for semantic failure or a blocked telemetry oracle.
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

# Catches requiring the benchmark-image ConfigMap from census results even
# though census intentionally does not use the pre-work benchmark handoff.
@test "results do not require benchmark-image handoff for census" {
	run_id='20260802T120000Z-1234abcd'
	image_id='docker-pullable://docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	write_results_fixtures "$run_id" "$image_id"
	jq '.items[0].metadata.name = "encode-benchmark-census-fixture" |
		.items[0].metadata.labels."homelab-talos/benchmark-mode" = "census" |
		del(.items[0].metadata.annotations."homelab-talos/image-evidence-configmap") |
		del(.items[0].spec.template.spec.nodeSelector)' "$STUB_JOBS_JSON" >"$STUB_JOBS_JSON.tmp"
	mv "$STUB_JOBS_JSON.tmp" "$STUB_JOBS_JSON"
	jq '.items[0].metadata.labels."job-name" = "encode-benchmark-census-fixture" |
		.items[0].metadata.ownerReferences[0].name = "encode-benchmark-census-fixture"' \
		"$STUB_PODS_JSON" >"$STUB_PODS_JSON.tmp"
	mv "$STUB_PODS_JSON.tmp" "$STUB_PODS_JSON"
	printf '%s\n' "$run_id" >"$STUB_LOGS_FILE"

	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -eq 0 ]
	[[ "$output" == *'mode=census'* ]]
	[[ "$output" == *'summary=run-complete'* ]]
	! awk -F '\t' '$1 == "kubectl" && $2 ~ / get configmap\// {found=1} END {exit !found}' "$STUB_CALLS"
	assert_no_mutations
}

# Catches treating an explicit quality run's plain exact runtime ID as if it
# were a generated dispatch mapping. Generated Jobs must still require their
# strict JSON mapping, while explicit Jobs report their selected run directly.
@test "results verifies generated and explicit quality completion paths" {
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
		schemaVersion:1,strategyId:"qsv-hevc-icq-v1",status:"complete",
		dispatchId:$dispatch,runtimeRunId:$runtime,artifactLocation:("/out/runs/" + $runtime)
	}' >"$STUB_LOGS_FILE"

	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$dispatch_id"
	[ "$status" -eq 0 ]
	[[ "$output" == *"dispatch_id=$dispatch_id runtime_run_id=$runtime_run_id"* ]]
	[[ "$output" == *"artifact_location=/out/runs/$runtime_run_id"* ]]
	[[ "$output" != *'no-sanitized-summary'* ]]
	[[ "$output" != *"artifact_location=/out/runs/$dispatch_id"* ]]

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
	[[ "$output" == *"dispatch_id=$explicit_run_id runtime_run_id=$explicit_run_id"* ]]
	[[ "$output" == *"artifact_location=/out/runs/$explicit_run_id"* ]]
}

# Catches diagnostics result collection widening into multi-query pod/job/log
# inspection or leaking an unsanitized terminal JSON payload.
@test "results sanitize diagnostics terminal summaries through one pod query" {
	run_id='20260819T120000Z-feedbeef'
	summary="$BATS_TEST_TMPDIR/diagnostic-summary.json"
	termination="$BATS_TEST_TMPDIR/diagnostic-termination.json"
	write_diagnostics_summary_fixture "$run_id" complete "$summary"
	for case_data in \
		'Succeeded|complete|complete' \
		'Failed|harness-blocked|harness-blocked' \
		'Failed|failed|failed'; do
		IFS='|' read -r pod_phase summary_status producer_status <<<"$case_data"
		: >"$STUB_CALLS"
		write_diagnostics_summary_fixture "$run_id" "$producer_status" "$summary"
		terminal_message="$(produce_diagnostics_terminal_message "$producer_status" "$run_id" "$summary" "$termination")"
		[ "$(<"$termination")" = "$terminal_message" ]
		[ "$(LC_ALL=C printf '%s' "$terminal_message" | wc -c | tr -d '[:space:]')" -lt 3072 ]
		write_diagnostics_results_fixture "$run_id" "$pod_phase" "$terminal_message"

		run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
		[ "$status" -eq 0 ]
		[ "$output" = "mode=diagnostics phase=$pod_phase run_id=$run_id artifact_location=/out/runs/$run_id/diagnostics status=$summary_status vmaf_total=5 vmaf_encoder_output_defect=0 vmaf_temporal_alignment_defect=0 vmaf_unresolved=5 vmaf_vmaf_measurement_defect=0 vmaf_reasons=offset-best-tie hdr_total=3 hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=3 hdr_source_probe_defect=0 hdr_unresolved_oracle=0 hdr_reasons=source-clip-encoded-metadata-agree" ]
		[[ "$output" != *'job/'* && "$output" != *'/media/'* ]]
		[[ "$output" != *'node='* && "$output" != *'nodeName'* && "$output" != *'sourcePath'* ]]
		[[ "$output" != *'stderr'* && "$output" != *'terminated'* ]]
		[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / get pods / && index($2, "app.kubernetes.io/name=encode-benchmark") {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 1 ]
		[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / get jobs / {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 0 ]
		[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / logs / {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 0 ]
	done
}

# Catches an active diagnostics collector trying to parse a terminal payload or
# widening back out to jobs/logs before the pod is terminal.
@test "results keep active diagnostics output terse and single-query" {
	run_id='20260819T120000Z-feedbeef'
	write_diagnostics_results_fixture "$run_id" Running

	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -eq 0 ]
	[ "$output" = "mode=diagnostics phase=Running run_id=$run_id status=active" ]
	[[ "$output" != *'summary='* && "$output" != *'no-sanitized-summary'* && "$output" != *'/out/runs/'* ]]
	[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / get pods / {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 1 ]
	[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / get jobs / {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 0 ]
	[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / logs / {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 0 ]
}

@test "results consume every documented diagnostics classifier reason through the terminal transport" {
	run_id='20260819T120000Z-feedbeef'
	termination="$BATS_TEST_TMPDIR/diagnostic-transport.json"

	for case_id in \
		temporal-alignment \
		encoder-output \
		vmaf-measurement \
		unresolved-disagreement \
		unresolved-tie \
		unresolved-missing-window \
		unresolved-incomplete-setting \
		unresolved-one-setting; do
		summary="$BATS_TEST_TMPDIR/$case_id-vmaf-summary.json"
		write_diagnostics_vmaf_case_summary_fixture "$run_id" "$case_id" "$summary"
		terminal_message="$(produce_diagnostics_terminal_message complete "$run_id" "$summary" "$termination")"
		[ "$(<"$termination")" = "$terminal_message" ]
		write_diagnostics_results_fixture "$run_id" Succeeded "$terminal_message"

		expected_classification="$(jq -r --arg id "$case_id" '.cases[] | select(.id == $id) | .expected.classification' \
			"$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/tests/fixtures/encode-benchmark/diagnostic-vmaf-cases.json")"
		expected_reasons="$(jq -r --arg id "$case_id" '.cases[] | select(.id == $id) | .expected.reasons | sort | join(",")' \
			"$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/tests/fixtures/encode-benchmark/diagnostic-vmaf-cases.json")"
		case "$expected_classification" in
		encoder-output-defect)
			vmaf_counts='vmaf_encoder_output_defect=5 vmaf_temporal_alignment_defect=0 vmaf_unresolved=0 vmaf_vmaf_measurement_defect=0'
			;;
		temporal-alignment-defect)
			vmaf_counts='vmaf_encoder_output_defect=0 vmaf_temporal_alignment_defect=5 vmaf_unresolved=0 vmaf_vmaf_measurement_defect=0'
			;;
		unresolved)
			vmaf_counts='vmaf_encoder_output_defect=0 vmaf_temporal_alignment_defect=0 vmaf_unresolved=5 vmaf_vmaf_measurement_defect=0'
			;;
		vmaf-measurement-defect)
			vmaf_counts='vmaf_encoder_output_defect=0 vmaf_temporal_alignment_defect=0 vmaf_unresolved=0 vmaf_vmaf_measurement_defect=5'
			;;
		*) false ;;
		esac

		run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
		[ "$status" -eq 0 ]
		[ "$output" = "mode=diagnostics phase=Succeeded run_id=$run_id artifact_location=/out/runs/$run_id/diagnostics status=complete vmaf_total=5 $vmaf_counts vmaf_reasons=$expected_reasons hdr_total=3 hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=3 hdr_source_probe_defect=0 hdr_unresolved_oracle=0 hdr_reasons=source-clip-encoded-metadata-agree" ]
	done

	for case_id in \
		source-probe-defect \
		clip-boundary-defect \
		encoder-output-defect \
		preserved \
		unresolved-source-null \
		unresolved-source-absent \
		unresolved-source-malformed \
		unresolved-source-conflict; do
		summary="$BATS_TEST_TMPDIR/$case_id-hdr-summary.json"
		write_diagnostics_hdr_case_summary_fixture "$run_id" "$case_id" "$summary"
		terminal_message="$(produce_diagnostics_terminal_message complete "$run_id" "$summary" "$termination")"
		[ "$(<"$termination")" = "$terminal_message" ]
		write_diagnostics_results_fixture "$run_id" Succeeded "$terminal_message"

		expected_classification="$(jq -r --arg id "$case_id" '.cases[] | select(.id == $id) | .expected.classification' \
			"$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/tests/fixtures/encode-benchmark/diagnostic-hdr-cases.json")"
		expected_reasons="$(jq -r --arg id "$case_id" '.cases[] | select(.id == $id) | .expected.reasons | sort | join(",")' \
			"$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/tests/fixtures/encode-benchmark/diagnostic-hdr-cases.json")"
		case "$expected_classification" in
		clip-boundary-defect)
			hdr_counts='hdr_clip_boundary_defect=3 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=0'
			;;
		encoder-output-defect)
			hdr_counts='hdr_clip_boundary_defect=0 hdr_encoder_output_defect=3 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=0'
			;;
		preserved)
			hdr_counts='hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=3 hdr_source_probe_defect=0 hdr_unresolved_oracle=0'
			;;
		source-probe-defect)
			hdr_counts='hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=3 hdr_unresolved_oracle=0'
			;;
		unresolved-oracle)
			hdr_counts='hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3'
			;;
		*) false ;;
		esac

		run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
		[ "$status" -eq 0 ]
		[ "$output" = "mode=diagnostics phase=Succeeded run_id=$run_id artifact_location=/out/runs/$run_id/diagnostics status=complete vmaf_total=5 vmaf_encoder_output_defect=0 vmaf_temporal_alignment_defect=0 vmaf_unresolved=5 vmaf_vmaf_measurement_defect=0 vmaf_reasons=offset-best-tie hdr_total=3 $hdr_counts hdr_reasons=$expected_reasons" ]
	done
}

@test "results consume the full literal diagnostics reason matrix through the terminal transport" {
	run_id='20260819T120000Z-feedbeef'
	termination="$BATS_TEST_TMPDIR/diagnostic-transport-matrix.json"
	literal_vmaf_reasons='[]'

	while IFS='|' read -r classification reasons expected_reasons vmaf_counts; do
		literal_vmaf_reasons="$(jq -c --argjson reasons "$reasons" '. + $reasons | unique | sort' <<<"$literal_vmaf_reasons")"
		summary="$BATS_TEST_TMPDIR/vmaf-matrix-$(printf '%s' "$classification|$reasons" | sha256sum | awk '{print $1}').json"
		write_diagnostics_custom_summary_fixture "$run_id" "$classification" "$reasons" preserved '["source-clip-encoded-metadata-agree"]' "$summary"
		terminal_message="$(produce_diagnostics_terminal_message complete "$run_id" "$summary" "$termination")"
		[ "$(<"$termination")" = "$terminal_message" ]
		write_diagnostics_results_fixture "$run_id" Succeeded "$terminal_message"

		run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
		[ "$status" -eq 0 ]
		[ "$output" = "mode=diagnostics phase=Succeeded run_id=$run_id artifact_location=/out/runs/$run_id/diagnostics status=complete vmaf_total=5 $vmaf_counts vmaf_reasons=$expected_reasons hdr_total=3 hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=3 hdr_source_probe_defect=0 hdr_unresolved_oracle=0 hdr_reasons=source-clip-encoded-metadata-agree" ]
	done <<'EOF'
temporal-alignment-defect|["nonzero-ssim-psnr-offset-agreement","timeline-discontinuity-at-offset","pts-reset-clears-vmaf-zero"]|nonzero-ssim-psnr-offset-agreement,pts-reset-clears-vmaf-zero,timeline-discontinuity-at-offset|vmaf_encoder_output_defect=0 vmaf_temporal_alignment_defect=5 vmaf_unresolved=0 vmaf_vmaf_measurement_defect=0
encoder-output-defect|["zero-offset-timeline-agreement","target-frame-local-metric-minimum","source-window-clean"]|source-window-clean,target-frame-local-metric-minimum,zero-offset-timeline-agreement|vmaf_encoder_output_defect=5 vmaf_temporal_alignment_defect=0 vmaf_unresolved=0 vmaf_vmaf_measurement_defect=0
vmaf-measurement-defect|["zero-offset-timeline-agreement","independent-metrics-not-target-minimum","vmaf-only-exact-zero"]|independent-metrics-not-target-minimum,vmaf-only-exact-zero,zero-offset-timeline-agreement|vmaf_encoder_output_defect=0 vmaf_temporal_alignment_defect=0 vmaf_unresolved=0 vmaf_vmaf_measurement_defect=5
unresolved|["classification-predicate-not-met"]|classification-predicate-not-met|vmaf_encoder_output_defect=0 vmaf_temporal_alignment_defect=0 vmaf_unresolved=5 vmaf_vmaf_measurement_defect=0
unresolved|["incomplete-setting-evidence"]|incomplete-setting-evidence|vmaf_encoder_output_defect=0 vmaf_temporal_alignment_defect=0 vmaf_unresolved=5 vmaf_vmaf_measurement_defect=0
unresolved|["missing-offset-window"]|missing-offset-window|vmaf_encoder_output_defect=0 vmaf_temporal_alignment_defect=0 vmaf_unresolved=5 vmaf_vmaf_measurement_defect=0
unresolved|["offset-best-tie"]|offset-best-tie|vmaf_encoder_output_defect=0 vmaf_temporal_alignment_defect=0 vmaf_unresolved=5 vmaf_vmaf_measurement_defect=0
unresolved|["one-setting-evidence"]|one-setting-evidence|vmaf_encoder_output_defect=0 vmaf_temporal_alignment_defect=0 vmaf_unresolved=5 vmaf_vmaf_measurement_defect=0
unresolved|["ssim-psnr-offset-disagreement"]|ssim-psnr-offset-disagreement|vmaf_encoder_output_defect=0 vmaf_temporal_alignment_defect=0 vmaf_unresolved=5 vmaf_vmaf_measurement_defect=0
unresolved|["assigned-node-capability-rejected"]|assigned-node-capability-rejected|vmaf_encoder_output_defect=0 vmaf_temporal_alignment_defect=0 vmaf_unresolved=5 vmaf_vmaf_measurement_defect=0
unresolved|["classification-failed"]|classification-failed|vmaf_encoder_output_defect=0 vmaf_temporal_alignment_defect=0 vmaf_unresolved=5 vmaf_vmaf_measurement_defect=0
unresolved|["diagnostic-preflight-rejected"]|diagnostic-preflight-rejected|vmaf_encoder_output_defect=0 vmaf_temporal_alignment_defect=0 vmaf_unresolved=5 vmaf_vmaf_measurement_defect=0
unresolved|["incomplete-or-failed-evidence"]|incomplete-or-failed-evidence|vmaf_encoder_output_defect=0 vmaf_temporal_alignment_defect=0 vmaf_unresolved=5 vmaf_vmaf_measurement_defect=0
unresolved|["post-run-identity-drift"]|post-run-identity-drift|vmaf_encoder_output_defect=0 vmaf_temporal_alignment_defect=0 vmaf_unresolved=5 vmaf_vmaf_measurement_defect=0
unresolved|["runmeta-create-failed"]|runmeta-create-failed|vmaf_encoder_output_defect=0 vmaf_temporal_alignment_defect=0 vmaf_unresolved=5 vmaf_vmaf_measurement_defect=0
unresolved|["running-image-evidence-rejected"]|running-image-evidence-rejected|vmaf_encoder_output_defect=0 vmaf_temporal_alignment_defect=0 vmaf_unresolved=5 vmaf_vmaf_measurement_defect=0
unresolved|["runtime-pre-encode-gate-rejected"]|runtime-pre-encode-gate-rejected|vmaf_encoder_output_defect=0 vmaf_temporal_alignment_defect=0 vmaf_unresolved=5 vmaf_vmaf_measurement_defect=0
EOF
	contract_vmaf_reasons="$(bash -c '
		source "$1"
		contract_diagnostics_terminal_vmaf_reason_classes_json | jq -c "keys | sort"
	' _ "$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/contract.sh")"
	[ "$literal_vmaf_reasons" = "$contract_vmaf_reasons" ]

	literal_hdr_reasons='[]'
	while IFS='|' read -r classification reasons expected_reasons hdr_counts; do
		literal_hdr_reasons="$(jq -c --argjson reasons "$reasons" '. + $reasons | unique | sort' <<<"$literal_hdr_reasons")"
		summary="$BATS_TEST_TMPDIR/hdr-matrix-$(printf '%s' "$classification|$reasons" | sha256sum | awk '{print $1}').json"
		write_diagnostics_custom_summary_fixture "$run_id" unresolved '["offset-best-tie"]' "$classification" "$reasons" "$summary"
		terminal_message="$(produce_diagnostics_terminal_message complete "$run_id" "$summary" "$termination")"
		[ "$(<"$termination")" = "$terminal_message" ]
		write_diagnostics_results_fixture "$run_id" Succeeded "$terminal_message"

		run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
		[ "$status" -eq 0 ]
		[ "$output" = "mode=diagnostics phase=Succeeded run_id=$run_id artifact_location=/out/runs/$run_id/diagnostics status=complete vmaf_total=5 vmaf_encoder_output_defect=0 vmaf_temporal_alignment_defect=0 vmaf_unresolved=5 vmaf_vmaf_measurement_defect=0 vmaf_reasons=offset-best-tie hdr_total=3 $hdr_counts hdr_reasons=$expected_reasons" ]
	done <<'EOF'
source-probe-defect|["authoritative-source-metadata","stream-probe-null"]|authoritative-source-metadata,stream-probe-null|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=3 hdr_unresolved_oracle=0
clip-boundary-defect|["authoritative-source-metadata","clip-metadata-changed"]|authoritative-source-metadata,clip-metadata-changed|hdr_clip_boundary_defect=3 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=0
encoder-output-defect|["source-and-clip-metadata-agree","encoded-metadata-changed"]|encoded-metadata-changed,source-and-clip-metadata-agree|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=3 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=0
preserved|["source-clip-encoded-metadata-agree"]|source-clip-encoded-metadata-agree|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=3 hdr_source_probe_defect=0 hdr_unresolved_oracle=0
unresolved-oracle|["source-stream-probe-absent"]|source-stream-probe-absent|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3
unresolved-oracle|["source-stream-probe-malformed"]|source-stream-probe-malformed|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3
unresolved-oracle|["source-stream-probe-conflict"]|source-stream-probe-conflict|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3
unresolved-oracle|["source-window-null"]|source-window-null|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3
unresolved-oracle|["source-window-absent"]|source-window-absent|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3
unresolved-oracle|["source-window-malformed"]|source-window-malformed|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3
unresolved-oracle|["source-window-conflict"]|source-window-conflict|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3
unresolved-oracle|["clip-window-null"]|clip-window-null|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3
unresolved-oracle|["clip-window-absent"]|clip-window-absent|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3
unresolved-oracle|["clip-window-malformed"]|clip-window-malformed|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3
unresolved-oracle|["encoded-window-null"]|encoded-window-null|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3
unresolved-oracle|["encoded-window-absent"]|encoded-window-absent|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3
unresolved-oracle|["encoded-window-malformed"]|encoded-window-malformed|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3
unresolved-oracle|["decoded-trace-disagreement"]|decoded-trace-disagreement|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3
unresolved-oracle|["assigned-node-capability-rejected"]|assigned-node-capability-rejected|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3
unresolved-oracle|["classification-failed"]|classification-failed|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3
unresolved-oracle|["diagnostic-preflight-rejected"]|diagnostic-preflight-rejected|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3
unresolved-oracle|["incomplete-or-failed-evidence"]|incomplete-or-failed-evidence|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3
unresolved-oracle|["post-run-identity-drift"]|post-run-identity-drift|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3
unresolved-oracle|["runmeta-create-failed"]|runmeta-create-failed|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3
unresolved-oracle|["running-image-evidence-rejected"]|running-image-evidence-rejected|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3
unresolved-oracle|["runtime-pre-encode-gate-rejected"]|runtime-pre-encode-gate-rejected|hdr_clip_boundary_defect=0 hdr_encoder_output_defect=0 hdr_preserved=0 hdr_source_probe_defect=0 hdr_unresolved_oracle=3
EOF
	contract_hdr_reasons="$(bash -c '
		source "$1"
		contract_diagnostics_terminal_hdr_reason_classes_json | jq -c "keys | sort"
	' _ "$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/contract.sh")"
	[ "$literal_hdr_reasons" = "$contract_hdr_reasons" ]
}

# Catches malformed diagnostics terminal output echoing raw pod data or quietly
# flowing into downstream summary parsing.
@test "results fail closed for missing malformed and mismatched diagnostics terminal summaries" {
	run_id='20260819T120000Z-feedbeef'
	for case_data in \
		'' \
		'not-json' \
		'{"schemaVersion":1,"strategyId":"qsv-hevc-icq-v1","mode":"diagnostics","status":"active","runId":"20260819T120000Z-feedbeef","artifactLocation":"/out/runs/20260819T120000Z-feedbeef/diagnostics","vmaf":{"total":5,"encoder-output-defect":0,"temporal-alignment-defect":0,"unresolved":5,"vmaf-measurement-defect":0,"reasons":["offset-best-tie"]},"hdr":{"total":3,"clip-boundary-defect":0,"encoder-output-defect":0,"preserved":3,"source-probe-defect":0,"unresolved-oracle":0,"reasons":["source-clip-encoded-metadata-agree"]}}' \
		'{"schemaVersion":2,"strategyId":"qsv-hevc-icq-v1","mode":"diagnostics","status":"complete","runId":"20260819T120000Z-feedbeef","artifactLocation":"/out/runs/20260819T120000Z-feedbeef/diagnostics","vmaf":{"total":5,"encoder-output-defect":0,"temporal-alignment-defect":0,"unresolved":5,"vmaf-measurement-defect":0,"reasons":["offset-best-tie"]},"hdr":{"total":3,"clip-boundary-defect":0,"encoder-output-defect":0,"preserved":3,"source-probe-defect":0,"unresolved-oracle":0,"reasons":["source-clip-encoded-metadata-agree"]}}' \
		'{"schemaVersion":1,"strategyId":"wrong-strategy","mode":"diagnostics","status":"complete","runId":"20260819T120000Z-feedbeef","artifactLocation":"/out/runs/20260819T120000Z-feedbeef/diagnostics","vmaf":{"total":5,"encoder-output-defect":0,"temporal-alignment-defect":0,"unresolved":5,"vmaf-measurement-defect":0,"reasons":["offset-best-tie"]},"hdr":{"total":3,"clip-boundary-defect":0,"encoder-output-defect":0,"preserved":3,"source-probe-defect":0,"unresolved-oracle":0,"reasons":["source-clip-encoded-metadata-agree"]}}'; do
		: >"$STUB_CALLS"
		write_diagnostics_results_fixture "$run_id" Succeeded "$case_data"
		run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
		[ "$status" -ne 0 ]
		[[ "$output" == 'no-sanitized-summary' || "$output" == terminal-summary-schema-error:* ]]
		if [[ -n "$case_data" ]]; then
			[[ "$output" != *"$case_data"* ]]
		fi
		[[ "$output" != *'/media/'* && "$output" != *'/out/runs/'* && "$output" != *'nodeName'* ]]
		[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / get pods / {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 1 ]
		[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / logs / {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 0 ]
	done
}

@test "results fail closed for diagnostics terminal reason vocabulary violations" {
	run_id='20260819T120000Z-feedbeef'
	summary="$BATS_TEST_TMPDIR/diagnostic-summary.json"
	termination="$BATS_TEST_TMPDIR/diagnostic-termination.json"
	write_diagnostics_summary_fixture "$run_id" complete "$summary"
	terminal_message="$(produce_diagnostics_terminal_message complete "$run_id" "$summary" "$termination")"

	for mutation in \
		'.vmaf.reasons = ["unknown-reason"]' \
		'.hdr.reasons = ["unknown-reason"]'; do
		case_terminal="$BATS_TEST_TMPDIR/$(printf '%s' "$mutation" | sha256sum | awk '{print $1}').json"
		jq -c "$mutation" <<<"$terminal_message" >"$case_terminal"
		write_diagnostics_results_fixture "$run_id" Failed "$(<"$case_terminal")"

		run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
		[ "$status" -ne 0 ]
		[ "$output" = 'terminal-summary-schema-error:unknown-reason' ]
		[[ "$output" != *'/media/'* && "$output" != *'nodeName'* ]]
	done
}

@test "results fail closed for diagnostics terminal aggregate limits size and incompatible reason pairings" {
	run_id='20260819T120000Z-feedbeef'
	summary="$BATS_TEST_TMPDIR/diagnostic-summary.json"
	termination="$BATS_TEST_TMPDIR/diagnostic-termination.json"
	write_diagnostics_summary_fixture "$run_id" complete "$summary"
	terminal_message="$(produce_diagnostics_terminal_message complete "$run_id" "$summary" "$termination")"

	for mutation in \
		'.vmaf.reasons = ["classification-failed","classification-predicate-not-met","incomplete-or-failed-evidence","incomplete-setting-evidence","missing-offset-window","offset-best-tie","one-setting-evidence","post-run-identity-drift","ssim-psnr-offset-disagreement"] | .hdr.preserved = 0 | .hdr["unresolved-oracle"] = 3 | .hdr.reasons = ["clip-window-absent","clip-window-malformed","clip-window-null","decoded-trace-disagreement","encoded-window-absent","encoded-window-malformed","encoded-window-null","source-stream-probe-absent"]' \
		'.vmaf.unresolved = 5 | .vmaf["encoder-output-defect"] = 0 | .vmaf.reasons = ["source-window-clean"]' ; do
		case_terminal="$BATS_TEST_TMPDIR/limit-$(printf '%s' "$mutation" | sha256sum | awk '{print $1}').json"
		jq -c "$mutation" <<<"$terminal_message" >"$case_terminal"
		write_diagnostics_results_fixture "$run_id" Failed "$(<"$case_terminal")"
		run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
		[ "$status" -ne 0 ]
		if [[ "$mutation" == *'source-stream-probe-absent'* ]]; then
			[ "$output" = 'terminal-summary-schema-error:too-many-reasons' ]
		else
			[ "$output" = 'terminal-summary-schema-error:wrong-vmaf-counts' ]
		fi
	done

	case_terminal="$BATS_TEST_TMPDIR/overlong-terminal.json"
	jq -c '.vmaf.reasons = ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]' \
		<<<"$terminal_message" >"$case_terminal"
	write_diagnostics_results_fixture "$run_id" Failed "$(<"$case_terminal")"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -ne 0 ]
	[ "$output" = 'terminal-summary-schema-error:reason-too-long' ]

	case_terminal="$BATS_TEST_TMPDIR/oversized-terminal.json"
	printf '%3073s%s' '' "$terminal_message" >"$case_terminal"
	write_diagnostics_results_fixture "$run_id" Failed "$(<"$case_terminal")"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -ne 0 ]
	[[ "$output" == 'terminal-summary-schema-error:raw-message-too-large' ]]

	case_terminal="$BATS_TEST_TMPDIR/oversized-multibyte-terminal.json"
	canonical_bytes="$(LC_ALL=C printf '%s' "$terminal_message" | wc -c | tr -d '[:space:]')"
	padding=$((3072 - canonical_bytes - 1))
	{
		printf '\357\273\277'
		printf '%*s' "$padding" ''
		printf '%s' "$terminal_message"
	} >"$case_terminal"
	raw_terminal_message="$(<"$case_terminal")"
	[ "$(LC_ALL=C wc -c <"$case_terminal" | tr -d '[:space:]')" -gt 3072 ]
	character_count="$(LC_ALL=C.UTF-8 bash -c 'printf "%s" "${#1}"' _ "$raw_terminal_message")"
	[ "$character_count" -le 3072 ]
	jq -e -c . "$case_terminal" >/dev/null
	write_diagnostics_results_fixture "$run_id" Failed "$raw_terminal_message"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -ne 0 ]
	[ "$output" = 'terminal-summary-schema-error:raw-message-too-large' ]
}

@test "diagnostic terminal producer rejects invalid status unknown excess and oversized reason payloads" {
	run_id='20260819T120000Z-feedbeef'
	summary="$BATS_TEST_TMPDIR/diagnostic-summary.json"
	termination="$BATS_TEST_TMPDIR/diagnostic-termination.json"
	samples_json="$BATS_TEST_TMPDIR/diagnostic-samples.json"
	write_diagnostics_summary_fixture "$run_id" complete "$summary"
	yq -r '.data."samples.json"' \
		"$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/samples.yaml" >"$samples_json"

	run env \
		BENCHMARK_TEST_MODE=1 \
		BENCHMARK_SAMPLES_FILE="$samples_json" \
		BENCHMARK_TERMINATION_LOG_PATH="$termination" \
		"$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/benchmark.sh" \
		_test diagnostic-terminal active "$run_id" "$summary"
	[ "$status" -eq 65 ]

	jq '.vmaf.entries[0].reasons = ["unknown-reason"]' "$summary" >"$BATS_TEST_TMPDIR/diagnostic-summary-unknown.json"
	run env \
		BENCHMARK_TEST_MODE=1 \
		BENCHMARK_SAMPLES_FILE="$samples_json" \
		BENCHMARK_TERMINATION_LOG_PATH="$termination" \
		"$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/benchmark.sh" \
		_test diagnostic-terminal complete "$run_id" "$BATS_TEST_TMPDIR/diagnostic-summary-unknown.json"
	[ "$status" -eq 65 ]
	[ "$output" = 'terminal-summary-schema-error:unknown-reason' ]

	jq '.vmaf.entries[0].reasons = ["classification-predicate-not-met","incomplete-setting-evidence","missing-offset-window","offset-best-tie"] |
		.vmaf.entries[1].reasons = ["one-setting-evidence","ssim-psnr-offset-disagreement"] |
		.hdr.entries[0].classification = "unresolved-oracle" |
		.hdr.entries[0].reasons = ["clip-window-null","clip-window-absent","clip-window-malformed","decoded-trace-disagreement","encoded-window-null","encoded-window-absent"] |
		.hdr.entries[1].classification = "unresolved-oracle" |
		.hdr.entries[1].reasons = ["encoded-window-malformed","source-stream-probe-absent","source-stream-probe-conflict","source-stream-probe-malformed","source-window-absent","source-window-conflict"] |
		.hdr.entries[2].classification = "unresolved-oracle" |
		.hdr.entries[2].reasons = ["source-window-malformed","source-window-null"]' \
		"$summary" >"$BATS_TEST_TMPDIR/diagnostic-summary-excess.json"
	run env \
		BENCHMARK_TEST_MODE=1 \
		BENCHMARK_SAMPLES_FILE="$samples_json" \
		BENCHMARK_TERMINATION_LOG_PATH="$termination" \
		"$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/benchmark.sh" \
		_test diagnostic-terminal complete "$run_id" "$BATS_TEST_TMPDIR/diagnostic-summary-excess.json"
	[ "$status" -eq 65 ]

	jq '.vmaf.entries[0].reasons = ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]' \
		"$summary" >"$BATS_TEST_TMPDIR/diagnostic-summary-overlong.json"
	run env \
		BENCHMARK_TEST_MODE=1 \
		BENCHMARK_SAMPLES_FILE="$samples_json" \
		BENCHMARK_TERMINATION_LOG_PATH="$termination" \
		"$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/benchmark.sh" \
		_test diagnostic-terminal complete "$run_id" "$BATS_TEST_TMPDIR/diagnostic-summary-overlong.json"
	[ "$status" -eq 65 ]
	[ "$output" = 'terminal-summary-schema-error:reason-too-long' ]

	jq '.hdr.entries[0].classification = "preserved" | .hdr.entries[0].reasons = ["encoded-window-null"]' \
		"$summary" >"$BATS_TEST_TMPDIR/diagnostic-summary-incompatible.json"
	run env \
		BENCHMARK_TEST_MODE=1 \
		BENCHMARK_SAMPLES_FILE="$samples_json" \
		BENCHMARK_TERMINATION_LOG_PATH="$termination" \
		"$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/benchmark.sh" \
		_test diagnostic-terminal complete "$run_id" "$BATS_TEST_TMPDIR/diagnostic-summary-incompatible.json"
	[ "$status" -eq 65 ]

	run env \
		BENCHMARK_TEST_MODE=1 \
		BENCHMARK_SAMPLES_FILE="$samples_json" \
		BENCHMARK_TERMINATION_LOG_PATH="$termination" \
		BENCHMARK_TERMINATION_LOG_MAX_BYTES=64 \
		"$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/benchmark.sh" \
		_test diagnostic-terminal complete "$run_id" "$summary"
	[ "$status" -eq 65 ]
}

@test "results fail closed on mixed diagnostics pod provenance after one query" {
	run_id='20260819T120000Z-feedbeef'
	summary="$BATS_TEST_TMPDIR/diagnostic-summary.json"
	termination="$BATS_TEST_TMPDIR/diagnostic-termination.json"
	write_diagnostics_summary_fixture "$run_id" complete "$summary"
	terminal_message="$(produce_diagnostics_terminal_message complete "$run_id" "$summary" "$termination")"
	STUB_BENCHMARK_PODS_JSON="$BATS_TEST_TMPDIR/diagnostic-pods-mixed.json"
	export STUB_BENCHMARK_PODS_JSON
	jq -n -c --arg run "$run_id" --arg message "$terminal_message" '{
		apiVersion:"v1",
		items:[
			{
				metadata:{
					name:"encode-benchmark-diagnostics-fixture-pod",
					labels:{
						"app.kubernetes.io/name":"encode-benchmark",
						"homelab-talos/benchmark-run":$run,
						"homelab-talos/benchmark-mode":"diagnostics",
						"job-name":"encode-benchmark-diagnostics-fixture"
					}
				},
				status:{phase:"Succeeded",containerStatuses:[{name:"benchmark",state:{terminated:{message:$message}}}]}
			},
			{
				metadata:{
					name:"encode-benchmark-quality-fixture-pod",
					labels:{
						"app.kubernetes.io/name":"encode-benchmark",
						"homelab-talos/benchmark-run":$run,
						"homelab-talos/benchmark-mode":"quality",
						"job-name":"encode-benchmark-quality-fixture"
					}
				},
				spec:{nodeName:"nuc3"},
				status:{phase:"Succeeded"}
			}
		]
	}' >"$STUB_BENCHMARK_PODS_JSON"
	: >"$STUB_CALLS"

	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -ne 0 ]
	[ "$output" = "diagnostic result provenance rejected: expected one canonical diagnostics pod for run $run_id" ]
	[[ "$output" != *'nuc3'* && "$output" != *'/media/'* && "$output" != *'/out/runs/'* ]]
	[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / get pods / {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 1 ]
	[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / get jobs / {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 0 ]
	[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / logs / {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 0 ]
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
