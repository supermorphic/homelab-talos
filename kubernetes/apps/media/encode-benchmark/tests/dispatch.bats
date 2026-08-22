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
	printf '%s\n' '{"nodes":[{"nodeName":"nuc1","strategyId":"qsv-hevc-icq-v1","proofSchemaVersion":3,"initialization":"passed","initializationReason":"","renderNode":"/dev/dri/renderD128","drmDriver":"i915","selectedRateControl":"ICQ","telemetryStatus":"available","telemetryReason":"","videoBusyNanoseconds":800000000,"videoBusyPercent":40,"encodeFps":72,"encodeSpeed":1.25,"decode":"passed","vmaf":"passed","diagnosticCapabilities":{"imageId":"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb","verifiedAt":"2026-08-14T18:00:00Z","traceHeaders":"passed","libvmaf":"passed","ssim":"passed","psnr":"passed","bestEffortTimestampTime":"passed","packetDurationTime":"passed","keyFrame":"passed","pictType":"passed"},"proofStatus":"passed","proofReasons":"","verifiedAt":"2026-08-14T18:00:00Z","configuredImageDigest":"sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb","imageId":"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb"}]}'
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

# The evidence reader is a separate, bounded read-only Job.  This catches
# accidental reuse of the encode diagnostic selector, GPU/media mounts, a
# writable output volume, or node identity injection from the shared template.
@test "diagnostic evidence reader dispatch creates only a read-only collector Job" {
	assert_guard_refuses ENCODE_BENCHMARK_DIAGNOSTIC_EVIDENCE_CONFIRM \
		'run:encode-benchmark:diagnostic-evidence' evidence-reader

	export ENCODE_BENCHMARK_DIAGNOSTIC_EVIDENCE_CONFIRM='read:encode-benchmark:diagnostic-evidence:20260820T223425Z-082b3d38'
	run_dispatch evidence-reader
	[ "$status" -eq 0 ]
	[ "$(mutation_count)" -eq 1 ]
	job="$(job_capture)"
	[ "$(yq -r '.metadata.labels."homelab-talos/benchmark-mode"' "$job")" = 'diagnostic-evidence-reader' ]
	[ "$(yq -r '.metadata.labels."homelab-talos/benchmark-run"' "$job")" = '20260820T223425Z-082b3d38' ]
	panel_sha="$(
		source "$evidence_app/scripts/contract.sh"
		yq -e -r '.data."samples.json"' "$evidence_app/samples.yaml" >"$BATS_TEST_TMPDIR/reader-samples.json"
		contract_diagnostics_panel_sha256 "$BATS_TEST_TMPDIR/reader-samples.json"
	)"
	evidence_panel="$(
		source "$evidence_app/scripts/contract.sh"
		contract_diagnostics_evidence_panel_json "$BATS_TEST_TMPDIR/reader-samples.json"
	)"
	[ "$panel_sha" = 'sha256:2722def1986d9591db363063315b94e8faca78ace7c56a7b6a55c6c9b4889e6f' ]
	[ "$(yq -r '.spec.template.spec.containers[0].command | join(" ")' "$job")" = "/scripts/diagnostic-evidence.sh collect 20260820T223425Z-082b3d38 /evidence $panel_sha $evidence_panel" ]
	[ "$(yq -r '.spec.template.spec.containers[0].image' "$job")" = 'docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb' ]
	[ "$(yq -r '.spec.template.spec.containers[0].env | length' "$job")" = '0' ]
	[ "$(yq -r '.spec.template.spec.containers[0].volumeMounts | map(.name) | sort | join(",")' "$job")" = 'evidence,scripts' ]
	[ "$(yq -r '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "evidence") | [.mountPath,.subPath,.readOnly] | @tsv' "$job")" = $'/evidence\tbenchmark/runs/20260820T223425Z-082b3d38/diagnostics\ttrue' ]
	[ "$(yq -r '.spec.template.spec.volumes | map(.name) | sort | join(",")' "$job")" = 'evidence,scripts' ]
	[ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "evidence") | [.persistentVolumeClaim.claimName,.persistentVolumeClaim.readOnly] | @tsv' "$job")" = $'media-data\ttrue' ]
	[ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "evidence") | (has("persistentVolumeClaim") and (.persistentVolumeClaim | has("subPath") | not))' "$job")" = 'true' ]
	[ "$(yq -r '(.spec.template.spec.containers[0].resources.requests | has("gpu.intel.com/i915")) or (.spec.template.spec.containers[0].resources.limits | has("gpu.intel.com/i915"))' "$job")" = 'false' ]
}

# Results must not reuse the diagnostics result selector: this validates the
# collector's exact Job/Pod ownership and prints the one canonical JSON value
# from the controlled collector log unchanged.
write_canonical_collector_json() {
	local path="$1" run_id="$2"
	jq -n -S -c --arg run "$run_id" '
		def class: {schemaVersion:1,classification:"unresolved",reasons:["offset-best-tie"]};
		def frames($index): ["0","0.041667","0.083334","0.125001","0.166668"] | to_entries | map({frameIndex:($index - 2 + .key),bestEffortTimestamp:.value,packetDuration:"0.041667",keyFrame:false,pictureType:"P"});
		def vmaf_frames($index): [range($index - 2; $index + 3) | {frameIndex:.,vmaf:90}];
		def offsets: [range(-2; 3) | {offset:.,ssim:0.9,psnr:{kind:"finite",value:40}}];
		def setting($quality; $index): {globalQuality:$quality,status:"complete",reason:null,vmaf:{current:vmaf_frames($index),reset:vmaf_frames($index)},offsets:offsets,timeline:{zeroOffsetAligned:true,discontinuity:null}};
		def source($index): {decodedFrameCount:2160,stream:{startTime:"0",duration:"90",timeBase:"1/90000",averageFrameRate:"24/1"},frames:frames($index),sourceWindow:{status:"clean",issue:null}};
		def vmaf($sample; $clip; $index): {sampleId:$sample,clipId:$clip,observedFrameIndex:$index,status:"complete",sourceContinuity:source($index),settings:[setting(16;$index),setting(30;$index)],classification:class};
		def stream_oracle: {status:"null"};
		def pair_oracle: {status:"absent"};
		def normalized_pair($reason): {decoded:pair_oracle,trace:pair_oracle,authoritative:{status:"unresolved",reasons:[$reason]}};
		def hdr($sample): {sampleId:$sample,clipId:"detail",globalQuality:16,status:"complete",reason:null,normalizedOracle:{schemaVersion:1,source:{streamProbe:stream_oracle,windows:{beginning:normalized_pair("source-window-absent"),detail:normalized_pair("source-window-absent"),end:normalized_pair("source-window-absent")},authoritative:{status:"unresolved",reasons:["source-window-absent"]}},clip:normalized_pair("clip-window-absent"),encoded:normalized_pair("encoded-window-absent")},classification:{schemaVersion:1,classification:"unresolved-oracle",reasons:["source-window-absent"]}};
		{schemaVersion:1,strategyId:"qsv-hevc-icq-v1",mode:"diagnostic-evidence-reader",runId:$run,vmaf:[vmaf("avc-clean-coco";"motion";1641),vmaf("avc-grain-memento";"dark";523),vmaf("avc-grain-memento";"detail";370),vmaf("vc1-fugitive";"detail";781),vmaf("vc1-fugitive";"motion";798)],hdr:[hdr("hdr10-clean-ministry"),hdr("hdr10-grain-goodfellas"),hdr("hdr10-motion-john-wick-2")]}' >"$path"
}

write_collector_runtime_fixtures() {
	local run_id="$1" jobs_path="$2" pods_path="$3" job name pod_spec api_scripts_mode
	export ENCODE_BENCHMARK_DIAGNOSTIC_EVIDENCE_CONFIRM="read:encode-benchmark:diagnostic-evidence:$run_id"
	run_dispatch evidence-reader
	[ "$status" -eq 0 ]
	job="$(job_capture)"
	name="$(yq -r '.metadata.name' "$job")"
	api_scripts_mode=$((8#555))
	API_SCRIPTS_MODE="$api_scripts_mode" yq -o=json -I=0 '
		.metadata.uid = "fixture-job-uid" |
		(.spec.template.spec.volumes[] | select(.name == "scripts").configMap.defaultMode) = (strenv(API_SCRIPTS_MODE) | tonumber) |
		.status.conditions = [{"type":"Complete","status":"True"}] |
		.status.succeeded = 1 |
		.status.failed = 0
	' "$job" | jq -c '{items:[.]}' >"$jobs_path"
	pod_spec="$(API_SCRIPTS_MODE="$api_scripts_mode" yq -o=json -I=0 '(.spec.template.spec.volumes[] | select(.name == "scripts").configMap.defaultMode) = (strenv(API_SCRIPTS_MODE) | tonumber) | .spec.template.spec' "$job")"
	jq -n --arg name "$name" --arg run "$run_id" --argjson spec "$pod_spec" '
		{items:[{metadata:{name:($name + "-pod"),labels:{"app.kubernetes.io/name":"encode-benchmark","homelab-talos/benchmark-dispatch":$run,"homelab-talos/benchmark-run":$run,"homelab-talos/benchmark-mode":"diagnostic-evidence-reader","job-name":$name},ownerReferences:[{apiVersion:"batch/v1",kind:"Job",name:$name,uid:"fixture-job-uid",controller:true,blockOwnerDeletion:true}]},spec:$spec,status:{phase:"Succeeded",containerStatuses:[{name:"benchmark",imageID:"containerd://docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb"}]}}]}' >"$pods_path"
}

write_failed_collector_runtime_fixtures() {
	local run_id="$1" jobs_path="$2" pods_path="$3" job name pod_spec api_scripts_mode
	export ENCODE_BENCHMARK_DIAGNOSTIC_EVIDENCE_CONFIRM="read:encode-benchmark:diagnostic-evidence:$run_id"
	run_dispatch evidence-reader
	[ "$status" -eq 0 ]
	job="$(job_capture)"
	name="$(yq -r '.metadata.name' "$job")"
	api_scripts_mode=$((8#555))
	API_SCRIPTS_MODE="$api_scripts_mode" yq -o=json -I=0 '
		.metadata.uid = "fixture-job-uid" |
		(.spec.template.spec.volumes[] | select(.name == "scripts").configMap.defaultMode) = (strenv(API_SCRIPTS_MODE) | tonumber) |
		.status.conditions = [{"type":"Failed","status":"True","reason":"BackoffLimitExceeded"}] |
		.status.succeeded = 0 |
		.status.failed = 1
	' "$job" | jq -c '{items:[.]}' >"$jobs_path"
	pod_spec="$(API_SCRIPTS_MODE="$api_scripts_mode" yq -o=json -I=0 '(.spec.template.spec.volumes[] | select(.name == "scripts").configMap.defaultMode) = (strenv(API_SCRIPTS_MODE) | tonumber) | .spec.template.spec' "$job")"
	jq -n --arg name "$name" --arg run "$run_id" --argjson spec "$pod_spec" '
		{items:[{metadata:{name:($name + "-pod"),labels:{"app.kubernetes.io/name":"encode-benchmark","homelab-talos/benchmark-dispatch":$run,"homelab-talos/benchmark-run":$run,"homelab-talos/benchmark-mode":"diagnostic-evidence-reader","job-name":$name},ownerReferences:[{apiVersion:"batch/v1",kind:"Job",name:$name,uid:"fixture-job-uid",controller:true,blockOwnerDeletion:true}]},spec:$spec,status:{phase:"Failed",containerStatuses:[{name:"benchmark",imageID:"containerd://docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb",ready:false,restartCount:0,state:{terminated:{exitCode:65,reason:"Error"}}}]}}]}' >"$pods_path"
}

producer_fixed_failed_collector_lines() {
	awk '
		/^[[:space:]]*echo '\''[^'\'']+'\'' >&2$/ {
			line = $0
			sub(/^[[:space:]]*echo '\''/, "", line)
			sub(/'\'' >&2$/, "", line)
			if (line != "usage: diagnostic-evidence.sh collect <run-id> <evidence-root> <panel-sha256> <evidence-panel>") {
				print line
			}
		}
	' "$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/diagnostic-evidence.sh"
}

@test "kubectl log stub implements --tail using kubectl argument semantics" {
	STUB_LOGS_FILE="$BATS_TEST_TMPDIR/collector.log"
	export STUB_LOGS_FILE
	printf '%s\n%s\n' first second >"$STUB_LOGS_FILE"
	run kubectl --namespace media logs job/collector --container benchmark --tail=1
	[ "$status" -eq 0 ]
	[ "$output" = 'second' ]
}

@test "diagnostic evidence reader results require one terminal owned collector" {
	run_id='20260820T223425Z-082b3d38'
	job_name="encode-benchmark-evidence-reader-${run_id,,}"
	collector_json="$BATS_TEST_TMPDIR/collector.json"
	write_canonical_collector_json "$collector_json" "$run_id"
	STUB_JOBS_JSON="$BATS_TEST_TMPDIR/reader-jobs.json"
	STUB_BENCHMARK_PODS_JSON="$BATS_TEST_TMPDIR/reader-pods.json"
	STUB_LOGS_FILE="$collector_json"
	export STUB_JOBS_JSON STUB_BENCHMARK_PODS_JSON STUB_LOGS_FILE
	write_collector_runtime_fixtures "$run_id" "$STUB_JOBS_JSON" "$STUB_BENCHMARK_PODS_JSON"

	run "$PROJECT_ROOT/scripts/encode-benchmark/diagnostic-evidence-results.sh" "$KUBECONFIG_FIXTURE"
	[ "$status" -eq 0 ]
	[ "$output" = "$(cat "$collector_json")" ]
}

@test "diagnostic evidence reader returns canonical failed collector statuses for the full fixed vocabulary" {
	local line reason run_id
	local -a producer_lines
	local -A seen_reasons=()
	run_id='20260820T223425Z-082b3d38'
	STUB_JOBS_JSON="$BATS_TEST_TMPDIR/reader-jobs.json"
	STUB_BENCHMARK_PODS_JSON="$BATS_TEST_TMPDIR/reader-pods.json"
	STUB_LOGS_FILE="$BATS_TEST_TMPDIR/collector.log"
	export STUB_JOBS_JSON STUB_BENCHMARK_PODS_JSON STUB_LOGS_FILE
	write_failed_collector_runtime_fixtures "$run_id" "$STUB_JOBS_JSON" "$STUB_BENCHMARK_PODS_JSON"

	mapfile -t producer_lines < <(producer_fixed_failed_collector_lines)
	[ "${#producer_lines[@]}" -eq 16 ]

	for line in "${producer_lines[@]}"; do
		printf '%s\n' "$line" >"$STUB_LOGS_FILE"
		run "$PROJECT_ROOT/scripts/encode-benchmark/diagnostic-evidence-results.sh" "$KUBECONFIG_FIXTURE"
		[ "$status" -eq 0 ] || {
			echo "diagnostic evidence results rejected mapped failed collector line: $line" >&3
			return 1
		}
		[ "$(jq -c 'keys' <<<"$output")" = '["mode","reason","runId","schemaVersion","status","strategyId"]' ] || {
			echo "diagnostic evidence results returned the wrong failed collector shape for: $line" >&3
			return 1
		}
		[ "$(jq -r '.mode' <<<"$output")" = 'diagnostic-evidence-reader' ]
		[ "$(jq -r '.runId' <<<"$output")" = "$run_id" ]
		[ "$(jq -r '.schemaVersion' <<<"$output")" = '1' ]
		[ "$(jq -r '.status' <<<"$output")" = 'failed' ]
		[ "$(jq -r '.strategyId' <<<"$output")" = 'qsv-hevc-icq-v1' ]
		reason="$(jq -r '.reason' <<<"$output")"
		[[ "$reason" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || {
			echo "diagnostic evidence results returned an unsafe failed collector reason for: $line" >&3
			return 1
		}
		[[ -z "${seen_reasons[$reason]+x}" ]] || {
			echo "diagnostic evidence results collapsed distinct collector lines into one reason: $reason" >&3
			return 1
		}
		seen_reasons["$reason"]="$line"
		if [[ "$line" == 'VMAF diagnostic evidence violates its approved schema' ]]; then
			[ "$reason" = 'vmaf-diagnostic-evidence-schema-invalid' ] || {
				echo "diagnostic evidence results changed the VMAF schema exemplar mapping" >&3
				return 1
			}
		fi
	done
	[ "${#seen_reasons[@]}" -eq "${#producer_lines[@]}" ]
}

@test "diagnostic evidence reader rejects failed collector outputs outside the bounded failure contract" {
	local mutation expected run_id
	run_id='20260820T223425Z-082b3d38'
	STUB_JOBS_JSON="$BATS_TEST_TMPDIR/reader-jobs.json"
	STUB_BENCHMARK_PODS_JSON="$BATS_TEST_TMPDIR/reader-pods.json"
	STUB_LOGS_FILE="$BATS_TEST_TMPDIR/collector.log"
	export STUB_JOBS_JSON STUB_BENCHMARK_PODS_JSON STUB_LOGS_FILE
	printf '%s\n' 'VMAF diagnostic evidence violates its approved schema' >"$STUB_LOGS_FILE"
	write_failed_collector_runtime_fixtures "$run_id" "$STUB_JOBS_JSON" "$STUB_BENCHMARK_PODS_JSON"

	for mutation in complete-condition wrong-failure-reason pod-succeeded wrong-exit-code wrong-terminate-reason restarted usage-line jq-stderr tool-stderr unknown-line empty-line multiline oversized; do
		cp "$STUB_JOBS_JSON" "$BATS_TEST_TMPDIR/base-jobs.json"
		cp "$STUB_BENCHMARK_PODS_JSON" "$BATS_TEST_TMPDIR/base-pods.json"
		printf '%s\n' 'VMAF diagnostic evidence violates its approved schema' >"$STUB_LOGS_FILE"
		case "$mutation" in
		complete-condition)
			expected='diagnostic evidence result provenance rejected: Pod ownership or image identity is invalid'
			jq '.items[0].status.conditions = [{"type":"Complete","status":"True"}] | .items[0].status.succeeded = 1 | .items[0].status.failed = 0' "$BATS_TEST_TMPDIR/base-jobs.json" >"$STUB_JOBS_JSON"
			;;
		wrong-failure-reason)
			expected='diagnostic evidence result provenance rejected: Job is not the terminal collector'
			jq '.items[0].status.conditions[0].reason = "DeadlineExceeded"' "$BATS_TEST_TMPDIR/base-jobs.json" >"$STUB_JOBS_JSON"
			;;
		pod-succeeded)
			expected='diagnostic evidence result provenance rejected: Pod ownership or image identity is invalid'
			jq '.items[0].status.phase = "Succeeded"' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON"
			;;
		wrong-exit-code)
			expected='diagnostic evidence result provenance rejected: Pod ownership or image identity is invalid'
			jq '.items[0].status.containerStatuses[0].state.terminated.exitCode = 1' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON"
			;;
		wrong-terminate-reason)
			expected='diagnostic evidence result provenance rejected: Pod ownership or image identity is invalid'
			jq '.items[0].status.containerStatuses[0].state.terminated.reason = "Completed"' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON"
			;;
		restarted)
			expected='diagnostic evidence result provenance rejected: Pod ownership or image identity is invalid'
			jq '.items[0].status.containerStatuses[0].restartCount = 1 | .items[0].status.containerStatuses[0].lastState = {terminated:{exitCode:65,reason:"Error"}}' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON"
			;;
		usage-line)
			expected='diagnostic evidence failed result is not allowlisted'
			printf '%s\n' 'usage: diagnostic-evidence.sh collect <run-id> <evidence-root> <panel-sha256> <evidence-panel>' >"$STUB_LOGS_FILE"
			;;
		jq-stderr)
			expected='diagnostic evidence failed result is not allowlisted'
			printf '%s\n' 'jq: error (at /evidence/vmaf.json:17): Cannot index string with string "panel"' >"$STUB_LOGS_FILE"
			;;
		tool-stderr)
			expected='diagnostic evidence failed result is not allowlisted'
			printf '%s\n' 'find: /evidence: No such file or directory' >"$STUB_LOGS_FILE"
			;;
		unknown-line)
			expected='diagnostic evidence failed result is not allowlisted'
			printf '%s\n' 'diagnostic evidence leaked /media/private' >"$STUB_LOGS_FILE"
			;;
		empty-line)
			expected='diagnostic evidence failed result is not allowlisted'
			: >"$STUB_LOGS_FILE"
			;;
		multiline)
			expected='diagnostic evidence result is ambiguous'
			printf '%s\n%s\n' 'VMAF diagnostic evidence violates its approved schema' 'HDR diagnostic evidence violates its approved schema' >"$STUB_LOGS_FILE"
			;;
		oversized)
			expected='diagnostic evidence result exceeds its bounded size'
			jq -n --argjson length 65537 '{padding:("a" * $length)}' | tr -d '\n' >"$STUB_LOGS_FILE"
			;;
		esac

		run "$PROJECT_ROOT/scripts/encode-benchmark/diagnostic-evidence-results.sh" "$KUBECONFIG_FIXTURE"
		[ "$status" -ne 0 ] || {
			echo "diagnostic evidence results accepted invalid failed collector mutation: $mutation" >&3
			return 1
		}
		[ "$output" = "$expected" ] || {
			echo "diagnostic evidence results returned the wrong rejection for mutation: $mutation" >&3
			return 1
		}
		[[ "$output" != *'/media/private'* ]]
		cp "$BATS_TEST_TMPDIR/base-jobs.json" "$STUB_JOBS_JSON"
		cp "$BATS_TEST_TMPDIR/base-pods.json" "$STUB_BENCHMARK_PODS_JSON"
	done
}

@test "diagnostic evidence reader binds every VMAF row to the committed observed frame" {
	run_id='20260820T223425Z-082b3d38'
	collector_json="$BATS_TEST_TMPDIR/collector.json"
	write_canonical_collector_json "$collector_json" "$run_id"
	jq -S -c '
		.vmaf |= map(
			.observedFrameIndex += 1 |
			.sourceContinuity.frames |= map(.frameIndex += 1) |
			.settings |= map(.vmaf.current |= map(.frameIndex += 1) | .vmaf.reset |= map(.frameIndex += 1)))
	' "$collector_json" >"$BATS_TEST_TMPDIR/shifted.json"
	mv "$BATS_TEST_TMPDIR/shifted.json" "$collector_json"
	STUB_JOBS_JSON="$BATS_TEST_TMPDIR/reader-jobs.json"
	STUB_BENCHMARK_PODS_JSON="$BATS_TEST_TMPDIR/reader-pods.json"
	STUB_LOGS_FILE="$collector_json"
	export STUB_JOBS_JSON STUB_BENCHMARK_PODS_JSON STUB_LOGS_FILE
	write_collector_runtime_fixtures "$run_id" "$STUB_JOBS_JSON" "$STUB_BENCHMARK_PODS_JSON"

	run "$PROJECT_ROOT/scripts/encode-benchmark/diagnostic-evidence-results.sh" "$KUBECONFIG_FIXTURE"
	[ "$status" -eq 65 ]
	[ "$output" = 'diagnostic evidence result schema rejected' ]
}

@test "diagnostic evidence reader admits only exact producer classifier failure overrides" {
	local case_name run_id collector_json
	run_id='20260820T223425Z-082b3d38'
	collector_json="$BATS_TEST_TMPDIR/collector.json"
	STUB_JOBS_JSON="$BATS_TEST_TMPDIR/reader-jobs.json"
	STUB_BENCHMARK_PODS_JSON="$BATS_TEST_TMPDIR/reader-pods.json"
	STUB_LOGS_FILE="$collector_json"
	export STUB_JOBS_JSON STUB_BENCHMARK_PODS_JSON STUB_LOGS_FILE
	write_collector_runtime_fixtures "$run_id" "$STUB_JOBS_JSON" "$STUB_BENCHMARK_PODS_JSON"

	for case_name in vmaf hdr; do
		write_canonical_collector_json "$collector_json" "$run_id"
		case "$case_name" in
		vmaf)
			jq -S -c '.vmaf[0] |= (.status = "harness-blocked" | .classification = {schemaVersion:1,classification:"unresolved",reasons:["classification-failed"]})' "$collector_json" >"$BATS_TEST_TMPDIR/classifier-failed.json"
			;;
		hdr)
			jq -S -c '.hdr[0] |= (.status = "harness-blocked" | .reason = "HDR-classification-failed" | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["classification-failed"]})' "$collector_json" >"$BATS_TEST_TMPDIR/classifier-failed.json"
			;;
		esac
		mv "$BATS_TEST_TMPDIR/classifier-failed.json" "$collector_json"

		run "$PROJECT_ROOT/scripts/encode-benchmark/diagnostic-evidence-results.sh" "$KUBECONFIG_FIXTURE"
		[ "$status" -eq 0 ] || {
			echo "diagnostic evidence results rejected exact producer classifier failure override: $case_name" >&3
			return 1
		}
	done
}

@test "diagnostic evidence reader results accept producer-shaped null partial projections" {
	run_id='20260820T223425Z-082b3d38'
	collector_json="$BATS_TEST_TMPDIR/collector.json"
	write_canonical_collector_json "$collector_json" "$run_id"
	jq -S -c '
		.vmaf[0] |= (
			.status = "failed" |
			.settings |= map(
				.status = "failed" | .reason = "decode-failed" |
				.vmaf = {current:[],reset:[]} |
				.offsets |= map(.ssim = null | .psnr = null) |
				.timeline = {zeroOffsetAligned:false,discontinuity:null}) |
			.classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]}) |
		.hdr[0] |= (
			.status = "harness-blocked" | .reason = "HDR-oracle-normalization-failed" |
			.normalizedOracle = null |
			.classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]})
	' "$collector_json" >"$BATS_TEST_TMPDIR/partial.json"
	mv "$BATS_TEST_TMPDIR/partial.json" "$collector_json"
	STUB_JOBS_JSON="$BATS_TEST_TMPDIR/reader-jobs.json"
	STUB_BENCHMARK_PODS_JSON="$BATS_TEST_TMPDIR/reader-pods.json"
	STUB_LOGS_FILE="$collector_json"
	export STUB_JOBS_JSON STUB_BENCHMARK_PODS_JSON STUB_LOGS_FILE
	write_collector_runtime_fixtures "$run_id" "$STUB_JOBS_JSON" "$STUB_BENCHMARK_PODS_JSON"

	run "$PROJECT_ROOT/scripts/encode-benchmark/diagnostic-evidence-results.sh" "$KUBECONFIG_FIXTURE"
	[ "$status" -eq 0 ]
	[ "$output" = "$(cat "$collector_json")" ]
}

@test "diagnostic evidence reader rejects an unreachable post-run VMAF acquisition shape" {
	run_id='20260820T223425Z-082b3d38'
	collector_json="$BATS_TEST_TMPDIR/collector.json"
	write_canonical_collector_json "$collector_json" "$run_id"
	jq -S -c '
		.vmaf[0] |= (
			.status = "harness-blocked" |
			.settings |= map(.status = "harness-blocked" | .reason = "post-run-identity-drift") |
			.settings[0].vmaf.current = [] |
			.classification = {schemaVersion:1,classification:"unresolved",reasons:["post-run-identity-drift"]})
	' "$collector_json" >"$BATS_TEST_TMPDIR/post-run.json"
	mv "$BATS_TEST_TMPDIR/post-run.json" "$collector_json"
	STUB_JOBS_JSON="$BATS_TEST_TMPDIR/reader-jobs.json"
	STUB_BENCHMARK_PODS_JSON="$BATS_TEST_TMPDIR/reader-pods.json"
	STUB_LOGS_FILE="$collector_json"
	export STUB_JOBS_JSON STUB_BENCHMARK_PODS_JSON STUB_LOGS_FILE
	write_collector_runtime_fixtures "$run_id" "$STUB_JOBS_JSON" "$STUB_BENCHMARK_PODS_JSON"

	run "$PROJECT_ROOT/scripts/encode-benchmark/diagnostic-evidence-results.sh" "$KUBECONFIG_FIXTURE"
	[ "$status" -eq 65 ]
	[ "$output" = 'diagnostic evidence result schema rejected' ]
}

@test "diagnostic evidence reader accepts the reachable acquisition projection matrix" {
	local case_name run_id collector_json
	run_id='20260820T223425Z-082b3d38'
	collector_json="$BATS_TEST_TMPDIR/collector.json"
	STUB_JOBS_JSON="$BATS_TEST_TMPDIR/reader-jobs.json"
	STUB_BENCHMARK_PODS_JSON="$BATS_TEST_TMPDIR/reader-pods.json"
	STUB_LOGS_FILE="$collector_json"
	export STUB_JOBS_JSON STUB_BENCHMARK_PODS_JSON STUB_LOGS_FILE
	write_collector_runtime_fixtures "$run_id" "$STUB_JOBS_JSON" "$STUB_BENCHMARK_PODS_JSON"

	for case_name in vmaf-source-null vmaf-current vmaf-reset vmaf-first-ssim vmaf-final-psnr vmaf-failed-dominates vmaf-post-reset vmaf-post-final-psnr hdr-failed hdr-normalization hdr-conflict hdr-ok-rationals hdr-post-null hdr-post-complete; do
		write_canonical_collector_json "$collector_json" "$run_id"
		case "$case_name" in
		vmaf-source-null)
			jq -S -c '.vmaf[0] |= (.status = "harness-blocked" | .sourceContinuity = null | .settings |= map(.status = "harness-blocked" | .reason = "source-clip-unavailable" | .vmaf = {current:[],reset:[]} | .offsets |= map(.ssim = null | .psnr = null) | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]})' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		vmaf-current)
			jq -S -c '.vmaf[0] |= (.status = "harness-blocked" | .settings |= map(.status = "harness-blocked" | .reason = "missing-current-vmaf" | .vmaf = {current:[],reset:[]} | .offsets |= map(.ssim = null | .psnr = null) | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]})' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		vmaf-reset)
			jq -S -c '.vmaf[0] |= (.status = "harness-blocked" | .settings |= map(.status = "harness-blocked" | .reason = "missing-reset-vmaf" | .vmaf.reset = [] | .offsets |= map(.ssim = null | .psnr = null) | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]})' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		vmaf-first-ssim)
			jq -S -c '.vmaf[0] |= (.status = "harness-blocked" | .settings |= map(.status = "harness-blocked" | .reason = "missing-ssim-metric" | .offsets |= map(.ssim = null | .psnr = null) | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]})' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		vmaf-final-psnr)
			jq -S -c '.vmaf[0] |= (.status = "harness-blocked" | .settings |= map(.status = "harness-blocked" | .reason = "missing-psnr-metric" | .offsets[4].psnr = null | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]})' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		vmaf-failed-dominates)
			jq -S -c '.vmaf[0] |= (.status = "failed" | .settings[0] |= (.status = "failed" | .reason = "encode-failed" | .vmaf = {current:[],reset:[]} | .offsets |= map(.ssim = null | .psnr = null) | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .settings[1] |= (.status = "harness-blocked" | .reason = "missing-reset-vmaf" | .vmaf.reset = [] | .offsets |= map(.ssim = null | .psnr = null) | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]})' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		vmaf-post-reset)
			jq -S -c '.vmaf[0] |= (.status = "harness-blocked" | .settings |= map(.status = "harness-blocked" | .reason = "post-run-identity-drift" | .vmaf.reset = [] | .offsets |= map(.ssim = null | .psnr = null) | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["post-run-identity-drift"]})' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		vmaf-post-final-psnr)
			jq -S -c '.vmaf[0] |= (.status = "harness-blocked" | .settings |= map(.status = "harness-blocked" | .reason = "post-run-identity-drift" | .offsets[4].psnr = null | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["post-run-identity-drift"]})' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		hdr-failed)
			jq -S -c '.hdr[0] |= (.status = "failed" | .reason = "decode-failed" | .normalizedOracle = null | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]})' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		hdr-normalization)
			jq -S -c '.hdr[0] |= (.status = "harness-blocked" | .reason = "HDR-oracle-normalization-failed" | .normalizedOracle = null | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]})' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		hdr-conflict)
			jq -S -c '
				def first: {
					masteringDisplay:{displayPrimaries:{red:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}},green:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}},blue:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}}},whitePoint:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}},luminance:{min:{numerator:1,denominator:2},max:{numerator:1,denominator:2}}},maxCLL:{numerator:1,denominator:2},maxFALL:{numerator:1,denominator:2}};
				def second: first | .masteringDisplay.displayPrimaries.red.x = {numerator:1,denominator:3};
				.hdr[0] |= (
					.status = "harness-blocked" | .reason = "conflicting-HDR-oracle" |
					.normalizedOracle.source.windows.beginning = {
						decoded:{status:"ok",metadata:first},trace:{status:"ok",metadata:second},
						authoritative:{status:"unresolved",reasons:["decoded-trace-disagreement"]}} |
					.normalizedOracle.source.authoritative = {status:"unresolved",reasons:["decoded-trace-disagreement"]} |
					.classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]})
			' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		hdr-ok-rationals)
			jq -S -c '
				def metadata: {
					masteringDisplay:{
						displayPrimaries:{
							red:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}},
							green:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}},
							blue:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}}},
						whitePoint:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}},
						luminance:{min:{numerator:1,denominator:2},max:{numerator:1,denominator:2}}},
					maxCLL:{numerator:1,denominator:2},maxFALL:{numerator:1,denominator:2}};
				.hdr[0].normalizedOracle.source.windows.beginning = {
					decoded:{status:"ok",metadata:metadata},trace:{status:"ok",metadata:metadata},
					authoritative:{status:"ok",metadata:metadata}}
			' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		hdr-post-null)
			jq -S -c '.hdr[0] |= (.status = "harness-blocked" | .reason = "post-run-identity-drift" | .normalizedOracle = null | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["post-run-identity-drift"]})' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		hdr-post-complete)
			jq -S -c '.hdr[0] |= (.status = "harness-blocked" | .reason = "post-run-identity-drift" | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["post-run-identity-drift"]})' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		esac
		mv "$BATS_TEST_TMPDIR/projected.json" "$collector_json"

		run "$PROJECT_ROOT/scripts/encode-benchmark/diagnostic-evidence-results.sh" "$KUBECONFIG_FIXTURE"
		[ "$status" -eq 0 ] || {
			echo "diagnostic evidence results rejected reachable acquisition projection: $case_name" >&3
			return 1
		}
	done
}

@test "diagnostic evidence reader rejects the impossible acquisition projection matrix" {
	local case_name run_id collector_json
	run_id='20260820T223425Z-082b3d38'
	collector_json="$BATS_TEST_TMPDIR/collector.json"
	STUB_JOBS_JSON="$BATS_TEST_TMPDIR/reader-jobs.json"
	STUB_BENCHMARK_PODS_JSON="$BATS_TEST_TMPDIR/reader-pods.json"
	STUB_LOGS_FILE="$collector_json"
	export STUB_JOBS_JSON STUB_BENCHMARK_PODS_JSON STUB_LOGS_FILE
	write_collector_runtime_fixtures "$run_id" "$STUB_JOBS_JSON" "$STUB_BENCHMARK_PODS_JSON"

	for case_name in post-reset-with-offsets post-offset-hole post-null-source-with-metrics normal-reset-with-offsets wrong-top-merge complete-null-hdr failed-retained-hdr normalization-retained-hdr conflict-null-hdr conflict-without-conflict; do
		write_canonical_collector_json "$collector_json" "$run_id"
		case "$case_name" in
		post-reset-with-offsets)
			jq -S -c '.vmaf[0] |= (.status = "harness-blocked" | .settings |= map(.status = "harness-blocked" | .reason = "post-run-identity-drift" | .vmaf.reset = []) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["post-run-identity-drift"]})' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		post-offset-hole)
			jq -S -c '.vmaf[0] |= (.status = "harness-blocked" | .settings |= map(.status = "harness-blocked" | .reason = "post-run-identity-drift" | .offsets[1] = {offset:-1,ssim:null,psnr:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["post-run-identity-drift"]})' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		post-null-source-with-metrics)
			jq -S -c '.vmaf[0] |= (.status = "harness-blocked" | .sourceContinuity = null | .settings |= map(.status = "harness-blocked" | .reason = "post-run-identity-drift") | .classification = {schemaVersion:1,classification:"unresolved",reasons:["post-run-identity-drift"]})' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		normal-reset-with-offsets)
			jq -S -c '.vmaf[0] |= (.status = "harness-blocked" | .settings |= map(.status = "harness-blocked" | .reason = "missing-reset-vmaf" | .vmaf.reset = [] | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]})' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		wrong-top-merge)
			jq -S -c '.vmaf[0] |= (.status = "harness-blocked" | .settings[0] |= (.status = "failed" | .reason = "decode-failed" | .vmaf = {current:[],reset:[]} | .offsets |= map(.ssim = null | .psnr = null) | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]})' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		complete-null-hdr)
			jq -S -c '.hdr[0].normalizedOracle = null' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		failed-retained-hdr)
			jq -S -c '.hdr[0] |= (.status = "failed" | .reason = "encode-failed" | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]})' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		normalization-retained-hdr)
			jq -S -c '.hdr[0] |= (.status = "harness-blocked" | .reason = "HDR-oracle-normalization-failed" | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]})' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		conflict-null-hdr)
			jq -S -c '.hdr[0] |= (.status = "harness-blocked" | .reason = "conflicting-HDR-oracle" | .normalizedOracle = null | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]})' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		conflict-without-conflict)
			jq -S -c '.hdr[0] |= (.status = "harness-blocked" | .reason = "conflicting-HDR-oracle" | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]})' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		esac
		mv "$BATS_TEST_TMPDIR/projected.json" "$collector_json"

		run "$PROJECT_ROOT/scripts/encode-benchmark/diagnostic-evidence-results.sh" "$KUBECONFIG_FIXTURE"
		[ "$status" -eq 65 ] || {
			echo "diagnostic evidence results accepted impossible acquisition projection: $case_name" >&3
			return 1
		}
	done
}

@test "diagnostic evidence reader rejects projected HDR frame and trace null oracles" {
	local accepted='' mutation run_id collector_json
	run_id='20260820T223425Z-082b3d38'
	collector_json="$BATS_TEST_TMPDIR/collector.json"
	STUB_JOBS_JSON="$BATS_TEST_TMPDIR/reader-jobs.json"
	STUB_BENCHMARK_PODS_JSON="$BATS_TEST_TMPDIR/reader-pods.json"
	STUB_LOGS_FILE="$collector_json"
	export STUB_JOBS_JSON STUB_BENCHMARK_PODS_JSON STUB_LOGS_FILE
	write_collector_runtime_fixtures "$run_id" "$STUB_JOBS_JSON" "$STUB_BENCHMARK_PODS_JSON"

	for mutation in decoded-null trace-null; do
		write_canonical_collector_json "$collector_json" "$run_id"
		case "$mutation" in
		decoded-null)
			jq -S -c '.hdr[0].normalizedOracle.source.windows.beginning.decoded = {status:"null"}' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		trace-null)
			jq -S -c '.hdr[0].normalizedOracle.clip.trace = {status:"null"}' "$collector_json" >"$BATS_TEST_TMPDIR/projected.json"
			;;
		esac
		mv "$BATS_TEST_TMPDIR/projected.json" "$collector_json"

		run "$PROJECT_ROOT/scripts/encode-benchmark/diagnostic-evidence-results.sh" "$KUBECONFIG_FIXTURE"
		if [ "$status" -eq 0 ]; then
			accepted="${accepted}${accepted:+ }$mutation"
		else
			[ "$status" -eq 65 ]
			[ "$output" = 'diagnostic evidence result schema rejected' ]
		fi
	done
	[ -z "$accepted" ] || {
		echo "diagnostic evidence results accepted producer-impossible projected HDR mutations: $accepted" >&3
		return 1
	}
}

@test "diagnostic evidence reader results reject invalid ownership image phase and ambiguous output" {
	run_id='20260820T223425Z-082b3d38'
	job_name="encode-benchmark-evidence-reader-${run_id,,}"
	collector_json="$BATS_TEST_TMPDIR/collector.json"
	write_canonical_collector_json "$collector_json" "$run_id"
	STUB_JOBS_JSON="$BATS_TEST_TMPDIR/reader-jobs.json"
	STUB_BENCHMARK_PODS_JSON="$BATS_TEST_TMPDIR/reader-pods.json"
	STUB_LOGS_FILE="$collector_json"
	export STUB_JOBS_JSON STUB_BENCHMARK_PODS_JSON STUB_LOGS_FILE
	write_collector_runtime_fixtures "$run_id" "$STUB_JOBS_JSON" "$STUB_BENCHMARK_PODS_JSON"

	for mutation in job-owner pod-owner wrong-image nonterminal job-name wrong-command wrong-scripts-annotation \
		wrong-scripts-volume writable-evidence forbidden-volume forbidden-env forbidden-gpu token-enabled extra-container \
		weakened-run-as-non-root weakened-container-security added-capabilities init-container \
		pod-init-container pod-extra-container pod-forbidden-env pod-forbidden-env-from pod-volume-device \
		pod-token-enabled pod-writable-evidence pod-resource-drift \
		pod-forbidden-volume pod-weakened-run-as-non-root pod-weakened-container-security \
		pod-privileged pod-container-run-as-user pod-container-run-as-non-root \
		pod-container-read-only-root pod-container-seccomp-unconfined \
		pod-host-network pod-host-pid pod-host-ipc pod-share-process pod-ephemeral-container \
		pod-supplemental-groups pod-apparmor-unconfined pod-seccomp-unconfined pod-security-annotation \
		ambiguous-output forbidden-nested \
		forbidden-setting-reason forbidden-classification-reason forbidden-timeline-kind \
		forbidden-frame-string forbidden-authoritative-reason \
		missing-source-frame duplicate-source-frame wrong-source-frame \
		missing-current-vmaf duplicate-reset-vmaf wrong-current-vmaf \
		missing-offset duplicate-offset wrong-offset complete-row-failed-setting \
		complete-null-source complete-null-normalized failed-null-source failed-row-harness-setting \
		failed-hdr-normalized harness-hdr-failed-reason \
		false-vmaf-complete-class false-hdr-complete-class \
		noncomplete-vmaf-causal noncomplete-hdr-causal; do
		cp "$STUB_JOBS_JSON" "$BATS_TEST_TMPDIR/base-jobs.json"
		cp "$STUB_BENCHMARK_PODS_JSON" "$BATS_TEST_TMPDIR/base-pods.json"
		cp "$collector_json" "$BATS_TEST_TMPDIR/base-output.json"
		case "$mutation" in
		job-owner) jq 'del(.items[0].metadata.annotations."homelab-talos/benchmark-owned")' "$BATS_TEST_TMPDIR/base-jobs.json" >"$STUB_JOBS_JSON" ;;
		pod-owner) jq '.items[0].metadata.ownerReferences[0].uid = "wrong"' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		wrong-image) jq '.items[0].status.containerStatuses[0].imageID = "containerd://sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		nonterminal) jq '.items[0].status.conditions = [] | .items[0].status.succeeded = 0' "$BATS_TEST_TMPDIR/base-jobs.json" >"$STUB_JOBS_JSON" ;;
		job-name) jq '.items[0].metadata.name = "encode-benchmark-evidence-reader-20260821t223425z-082b3d38"' "$BATS_TEST_TMPDIR/base-jobs.json" >"$STUB_JOBS_JSON"; jq '.items[0].metadata.ownerReferences[0].name = "encode-benchmark-evidence-reader-20260821t223425z-082b3d38"' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		wrong-command) jq '.items[0].spec.template.spec.containers[0].command = ["/scripts/benchmark.sh","quality"]' "$BATS_TEST_TMPDIR/base-jobs.json" >"$STUB_JOBS_JSON" ;;
		wrong-scripts-annotation) jq '.items[0].metadata.annotations."homelab-talos/scripts-configmap" = "encode-benchmark-scripts-aaaaaaaaaa"' "$BATS_TEST_TMPDIR/base-jobs.json" >"$STUB_JOBS_JSON" ;;
		wrong-scripts-volume) jq '.items[0].spec.template.spec.volumes[] |= if .name == "scripts" then .configMap.name = "encode-benchmark-scripts-aaaaaaaaaa" else . end' "$BATS_TEST_TMPDIR/base-jobs.json" >"$STUB_JOBS_JSON" ;;
		writable-evidence) jq '.items[0].spec.template.spec.containers[0].volumeMounts[] |= if .name == "evidence" then .readOnly = false else . end' "$BATS_TEST_TMPDIR/base-jobs.json" >"$STUB_JOBS_JSON" ;;
		forbidden-volume) jq '.items[0].spec.template.spec.containers[0].volumeMounts += [{name:"media",mountPath:"/media",readOnly:true}] | .items[0].spec.template.spec.volumes += [{name:"media",persistentVolumeClaim:{claimName:"media-data"}}]' "$BATS_TEST_TMPDIR/base-jobs.json" >"$STUB_JOBS_JSON" ;;
		forbidden-env) jq '.items[0].spec.template.spec.containers[0].env = [{name:"NODE_NAME",valueFrom:{fieldRef:{fieldPath:"spec.nodeName"}}}]' "$BATS_TEST_TMPDIR/base-jobs.json" >"$STUB_JOBS_JSON" ;;
		forbidden-gpu) jq '.items[0].spec.template.spec.containers[0].resources.requests."gpu.intel.com/i915" = 1' "$BATS_TEST_TMPDIR/base-jobs.json" >"$STUB_JOBS_JSON" ;;
		token-enabled) jq '.items[0].spec.template.spec.automountServiceAccountToken = true' "$BATS_TEST_TMPDIR/base-jobs.json" >"$STUB_JOBS_JSON" ;;
		extra-container) jq '.items[0].spec.template.spec.containers += [{name:"sidecar",image:"example.invalid/sidecar@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]' "$BATS_TEST_TMPDIR/base-jobs.json" >"$STUB_JOBS_JSON" ;;
		weakened-run-as-non-root) jq '.items[0].spec.template.spec.securityContext.runAsNonRoot = false' "$BATS_TEST_TMPDIR/base-jobs.json" >"$STUB_JOBS_JSON" ;;
		weakened-container-security) jq '.items[0].spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation = true' "$BATS_TEST_TMPDIR/base-jobs.json" >"$STUB_JOBS_JSON" ;;
		added-capabilities) jq '.items[0].spec.template.spec.containers[0].securityContext.capabilities.add = ["NET_ADMIN"]' "$BATS_TEST_TMPDIR/base-jobs.json" >"$STUB_JOBS_JSON" ;;
		init-container) jq '.items[0].spec.template.spec.initContainers = [{name:"setup",image:"example.invalid/setup@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]' "$BATS_TEST_TMPDIR/base-jobs.json" >"$STUB_JOBS_JSON" ;;
		pod-init-container) jq '.items[0].spec.initContainers = [{name:"setup",image:"example.invalid/setup@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-extra-container) jq '.items[0].spec.containers += [{name:"sidecar",image:"example.invalid/sidecar@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-forbidden-env) jq '.items[0].spec.containers[0].env = [{name:"NODE_NAME",valueFrom:{fieldRef:{fieldPath:"spec.nodeName"}}}]' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-forbidden-env-from) jq '.items[0].spec.containers[0].envFrom = [{configMapRef:{name:"injected"}}]' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-volume-device) jq '.items[0].spec.containers[0].volumeDevices = [{name:"device",devicePath:"/dev/injected"}]' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-token-enabled) jq '.items[0].spec.automountServiceAccountToken = true' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-writable-evidence) jq '.items[0].spec.containers[0].volumeMounts[] |= if .name == "evidence" then .readOnly = false else . end' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-resource-drift) jq '.items[0].spec.containers[0].resources.limits.cpu = "1"' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-forbidden-volume) jq '.items[0].spec.containers[0].volumeMounts += [{name:"media",mountPath:"/media",readOnly:true}] | .items[0].spec.volumes += [{name:"media",persistentVolumeClaim:{claimName:"media-data"}}]' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-weakened-run-as-non-root) jq '.items[0].spec.securityContext.runAsNonRoot = false' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-weakened-container-security) jq '.items[0].spec.containers[0].securityContext.allowPrivilegeEscalation = true' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-privileged) jq '.items[0].spec.containers[0].securityContext.privileged = true' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-container-run-as-user) jq '.items[0].spec.containers[0].securityContext.runAsUser = 0' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-container-run-as-non-root) jq '.items[0].spec.containers[0].securityContext.runAsNonRoot = false' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-container-read-only-root) jq '.items[0].spec.containers[0].securityContext.readOnlyRootFilesystem = false' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-container-seccomp-unconfined) jq '.items[0].spec.containers[0].securityContext.seccompProfile = {type:"Unconfined"}' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-host-network) jq '.items[0].spec.hostNetwork = true' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-host-pid) jq '.items[0].spec.hostPID = true' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-host-ipc) jq '.items[0].spec.hostIPC = true' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-share-process) jq '.items[0].spec.shareProcessNamespace = true' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-ephemeral-container) jq '.items[0].spec.ephemeralContainers = [{name:"debug",image:"example.invalid/debug@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",securityContext:{privileged:true}}]' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-supplemental-groups) jq '.items[0].spec.securityContext.supplementalGroups = [0]' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-apparmor-unconfined) jq '.items[0].spec.securityContext.appArmorProfile = {type:"Unconfined"}' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-seccomp-unconfined) jq '.items[0].spec.securityContext.seccompProfile = {type:"Unconfined"}' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		pod-security-annotation) jq '.items[0].metadata.annotations."container.apparmor.security.beta.kubernetes.io/benchmark" = "unconfined"' "$BATS_TEST_TMPDIR/base-pods.json" >"$STUB_BENCHMARK_PODS_JSON" ;;
		ambiguous-output) printf '%s\n%s\n' "$(cat "$BATS_TEST_TMPDIR/base-output.json")" "$(cat "$BATS_TEST_TMPDIR/base-output.json")" >"$collector_json" ;;
		forbidden-nested) jq -S -c '.vmaf[0].settings = {artifactPath:"unexpected"}' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		forbidden-setting-reason) jq -S -c '.vmaf[0].settings[0].reason = "/media/private"' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		forbidden-classification-reason) jq -S -c '.vmaf[0].classification.reasons = ["credential-fragment"]' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		forbidden-timeline-kind) jq -S -c '.vmaf[0].settings[0].timeline.discontinuity = {kind:"credential-fragment",offset:1}' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		forbidden-frame-string) jq -S -c '.vmaf[0].sourceContinuity.stream.startTime = "/out/private"' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		forbidden-authoritative-reason) jq -S -c '.hdr[0].normalizedOracle.source.authoritative.reasons = ["credential-fragment"]' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		missing-source-frame) jq -S -c '.vmaf[0].sourceContinuity.frames |= .[0:4]' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		duplicate-source-frame) jq -S -c '.vmaf[0].sourceContinuity.frames[4] = .vmaf[0].sourceContinuity.frames[0]' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		wrong-source-frame) jq -S -c '.vmaf[0].sourceContinuity.frames[4].frameIndex = (.vmaf[0].observedFrameIndex + 3)' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		missing-current-vmaf) jq -S -c '.vmaf[0].settings[0].vmaf.current |= .[0:4]' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		duplicate-reset-vmaf) jq -S -c '.vmaf[0].settings[0].vmaf.reset[4] = .vmaf[0].settings[0].vmaf.reset[0]' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		wrong-current-vmaf) jq -S -c '.vmaf[0].settings[0].vmaf.current[4].frameIndex = (.vmaf[0].observedFrameIndex + 3)' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		missing-offset) jq -S -c '.vmaf[0].settings[0].offsets |= .[0:4]' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		duplicate-offset) jq -S -c '.vmaf[0].settings[0].offsets[4] = .vmaf[0].settings[0].offsets[3]' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		wrong-offset) jq -S -c '.vmaf[0].settings[0].offsets[4].offset = 3' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		complete-row-failed-setting) jq -S -c '.vmaf[0].settings[0] |= (.status = "failed" | .reason = "decode-failed" | .vmaf.current = [] | .vmaf.reset = [] | .offsets = [])' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		complete-null-source) jq -S -c '.vmaf[0].sourceContinuity = null' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		complete-null-normalized) jq -S -c '.hdr[0].normalizedOracle = null' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		failed-null-source) jq -S -c '
			.vmaf[0] |= (
				.status = "failed" | .sourceContinuity = null |
				.settings |= map(.status = "failed" | .reason = "decode-failed" | .vmaf = {current:[],reset:[]} | .offsets |= map(.ssim = null | .psnr = null) | .timeline = {zeroOffsetAligned:false,discontinuity:null}) |
				.classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-or-failed-evidence"]})
		' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		failed-row-harness-setting) jq -S -c '
			.vmaf[0] |= (
				.status = "failed" |
				.settings |= map(.status = "harness-blocked" | .reason = "missing-current-vmaf" | .vmaf = {current:[],reset:[]} | .offsets |= map(.ssim = null | .psnr = null) | .timeline = {zeroOffsetAligned:false,discontinuity:null}) |
				.classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-or-failed-evidence"]})
		' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		failed-hdr-normalized) jq -S -c '.hdr[0] |= (.status = "failed" | .reason = "encode-failed" | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]})' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		harness-hdr-failed-reason) jq -S -c '.hdr[0] |= (.status = "harness-blocked" | .reason = "decode-failed" | .normalizedOracle = null | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]})' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		false-vmaf-complete-class) jq -S -c '.vmaf[0].classification = {schemaVersion:1,classification:"encoder-output-defect",reasons:["current-reset-stable","zero-offset-aligned","icq-correlated-quality-loss"]}' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		false-hdr-complete-class) jq -S -c '.hdr[0].classification = {schemaVersion:1,classification:"source-probe-defect",reasons:["source-conflict-before-encode"]}' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		noncomplete-vmaf-causal) jq -S -c '
			.vmaf[0] |= (
				.status = "failed" |
				.settings |= map(.status = "failed" | .reason = "decode-failed" | .vmaf = {current:[],reset:[]} | .offsets |= map(.ssim = null | .psnr = null) | .timeline = {zeroOffsetAligned:false,discontinuity:null}) |
				.classification = {schemaVersion:1,classification:"vmaf-measurement-defect",reasons:["vmaf-only-exact-zero"]})
		' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		noncomplete-hdr-causal) jq -S -c '
			.hdr[0] |= (
				.status = "failed" | .reason = "decode-failed" | .normalizedOracle = null |
				.classification = {schemaVersion:1,classification:"preserved",reasons:["source-clip-encoded-metadata-agree"]})
		' "$BATS_TEST_TMPDIR/base-output.json" >"$collector_json" ;;
		esac
		run "$PROJECT_ROOT/scripts/encode-benchmark/diagnostic-evidence-results.sh" "$KUBECONFIG_FIXTURE"
		[ "$status" -ne 0 ] || {
			echo "diagnostic evidence results accepted invalid mutation: $mutation" >&3
			return 1
		}
		cp "$BATS_TEST_TMPDIR/base-jobs.json" "$STUB_JOBS_JSON"
		cp "$BATS_TEST_TMPDIR/base-pods.json" "$STUB_BENCHMARK_PODS_JSON"
		cp "$BATS_TEST_TMPDIR/base-output.json" "$collector_json"
	done
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

# Catches diagnostics using a generic QSV proof as a substitute for image-bound
# diagnostic oracle proof.  Each missing item must stop before the first API
# resource create, while the complete proof remains dispatchable.
@test "diagnostics requires image-bound trace metric and frame-field proof before create" {
	prepare_deployed_diagnostics_contract
	export ENCODE_BENCHMARK_DIAGNOSTICS_CONFIRM='run:encode-benchmark:diagnostics'
	proof="$(jq -c '.nodes[0].diagnosticCapabilities = {
		imageId:.nodes[0].imageId,verifiedAt:.nodes[0].verifiedAt,
		traceHeaders:"passed",libvmaf:"passed",ssim:"passed",psnr:"passed",
		bestEffortTimestampTime:"passed",packetDurationTime:"passed",
		keyFrame:"passed",pictType:"passed"
	}' <<<"$(valid_capability_evidence)")"

	for missing in traceHeaders libvmaf ssim psnr bestEffortTimestampTime packetDurationTime keyFrame pictType; do
		set_capability_evidence verified "$(jq -c --arg missing "$missing" 'del(.nodes[0].diagnosticCapabilities[$missing])' <<<"$proof")"
		run_dispatch run diagnostics
		[ "$status" -ne 0 ]
		assert_no_mutations
	done

	set_capability_evidence verified "$proof"
	run_dispatch run diagnostics
	[ "$status" -eq 0 ]
	[ "$(mutation_count)" -eq 2 ]
}

# Catches the diagnostic selector returning the final rejected generic-QSV node's
# status after it has already emitted an earlier eligible node.
@test "diagnostics dispatch accepts an eligible node before an ineligible sorted node" {
	prepare_deployed_diagnostics_contract
	export ENCODE_BENCHMARK_DIAGNOSTICS_CONFIRM='run:encode-benchmark:diagnostics'
	evidence="$(jq -c '.nodes += [(.nodes[0] | .nodeName = "nuc3" | del(.diagnosticCapabilities))]' <<<"$(valid_capability_evidence)")"
	set_capability_evidence verified "$evidence"

	run_dispatch run diagnostics
	[ "$status" -eq 0 ]
	[ "$(mutation_count)" -eq 2 ]
	[ "$(yq -r '.spec.template.spec.nodeSelector."kubernetes.io/hostname"' "$(job_capture)")" = 'nuc1' ]
}

# Catches the reciprocal order: generic QSV evidence must not hide a later
# diagnostic-capable node when generic nodes sort first.
@test "diagnostics dispatch accepts an eligible node after an ineligible sorted node" {
	prepare_deployed_diagnostics_contract
	export ENCODE_BENCHMARK_DIAGNOSTICS_CONFIRM='run:encode-benchmark:diagnostics'
	evidence="$(jq -c '.nodes[0].nodeName = "nuc3" | .nodes += [(.nodes[0] | .nodeName = "nuc1" | del(.diagnosticCapabilities))]' <<<"$(valid_capability_evidence)")"
	set_capability_evidence verified "$evidence"

	run_dispatch run diagnostics
	[ "$status" -eq 0 ]
	[ "$(mutation_count)" -eq 2 ]
	[ "$(yq -r '.spec.template.spec.nodeSelector."kubernetes.io/hostname"' "$(job_capture)")" = 'nuc3' ]
}

# Catches selector failure bypassing the bounded diagnostics-specific no-evidence
# response when normal QSV nodes exist but none has the required proof.
@test "diagnostics reports bounded missing evidence when no node is diagnostically eligible" {
	prepare_deployed_diagnostics_contract
	export ENCODE_BENCHMARK_DIAGNOSTICS_CONFIRM='run:encode-benchmark:diagnostics'
	evidence="$(jq -c '.nodes += [(.nodes[0] | .nodeName = "nuc3")] | .nodes[].diagnosticCapabilities |= del(.)' <<<"$(valid_capability_evidence)")"
	set_capability_evidence verified "$evidence"

	run_dispatch run diagnostics
	[ "$status" -eq 65 ]
	[ "$output" = 'diagnostic capability evidence is missing malformed stale or bound to another image' ]
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
{"status":"passed","strategyId":"qsv-hevc-icq-v1","proofSchemaVersion":3,"initialization":"passed","initializationReason":"","renderNode":"/dev/dri/renderD128","drmDriver":"i915","selectedRateControl":"ICQ","telemetryStatus":"available","telemetryReason":"","videoBusyNanoseconds":800000000,"videoBusyPercent":40,"encodeFps":72,"encodeSpeed":1.25,"decode":"passed","vmaf":"passed","diagnosticCapabilities":{"traceHeaders":"passed","libvmaf":"passed","ssim":"passed","psnr":"passed","bestEffortTimestampTime":"passed","packetDurationTime":"passed","keyFrame":"passed","pictType":"passed"},"proofStatus":"passed","proofReasons":"","uid":568,"hevcQsv":true,"libx265":true,"nodeName":"nuc2","configuredImage":"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb","configuredImageDigest":"sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb","sourcePath":"/media/Secret Movie.mkv","source_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","credential":"dont-print-me"}
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
		printf '%s\n' "{\"status\":\"passed\",\"strategyId\":\"qsv-hevc-icq-v1\",\"proofSchemaVersion\":3,\"initialization\":\"passed\",\"initializationReason\":\"\",\"renderNode\":\"/dev/dri/renderD128\",\"drmDriver\":\"i915\",\"selectedRateControl\":\"ICQ\",\"telemetryStatus\":\"available\",\"telemetryReason\":\"\",\"videoBusyNanoseconds\":800000000,\"videoBusyPercent\":40,\"encodeFps\":72,\"encodeSpeed\":1.25,\"decode\":\"passed\",\"vmaf\":\"passed\",\"diagnosticCapabilities\":{\"traceHeaders\":\"passed\",\"libvmaf\":\"passed\",\"ssim\":\"passed\",\"psnr\":\"passed\",\"bestEffortTimestampTime\":\"passed\",\"packetDurationTime\":\"passed\",\"keyFrame\":\"passed\",\"pictType\":\"passed\"},\"proofStatus\":\"passed\",\"proofReasons\":\"\",\"uid\":568,\"hevcQsv\":true,\"libx265\":true,\"nodeName\":\"$node\",\"configuredImageDigest\":\"sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb\",\"sourcePath\":\"/media/Secret Movie.mkv\"}" \
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

write_diagnostics_results_fixture_from_file() {
	local run_id="$1" pod_phase="$2" terminal_message_file="$3"
	STUB_BENCHMARK_PODS_JSON="$BATS_TEST_TMPDIR/diagnostic-pods.json"
	unset STUB_JOBS_JSON STUB_PODS_JSON STUB_LOGS_FILE STUB_LOGS_DIR STUB_IMAGE_EVIDENCE_DIR
	export STUB_BENCHMARK_PODS_JSON
	jq -n -c --arg run "$run_id" --arg phase "$pod_phase" --rawfile message "$terminal_message_file" '
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
						state:{terminated:{
							exitCode:(if $phase == "Succeeded" then 0 else 1 end),
							reason:(if $phase == "Succeeded" then "Completed" else "Error" end),
							finishedAt:"2026-08-19T12:05:00Z",
							message:$message
						}}
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

# Catches extracting the Pod termination message through command substitution,
# which removes trailing line feeds before the raw byte-limit check.
@test "results count exact diagnostics Pod message bytes including trailing line feeds" {
	run_id='20260819T120000Z-feedbeef'
	summary="$BATS_TEST_TMPDIR/diagnostic-summary.json"
	termination="$BATS_TEST_TMPDIR/diagnostic-termination.json"
	write_diagnostics_summary_fixture "$run_id" complete "$summary"
	terminal_message="$(produce_diagnostics_terminal_message complete "$run_id" "$summary" "$termination")"
	canonical_bytes="$(LC_ALL=C printf '%s' "$terminal_message" | wc -c | tr -d '[:space:]')"

	case_terminal="$BATS_TEST_TMPDIR/exact-limit-with-trailing-lf.json"
	{
		printf '%*s' "$((3072 - canonical_bytes - 1))" ''
		printf '%s\n' "$terminal_message"
	} >"$case_terminal"
	[ "$(LC_ALL=C wc -c <"$case_terminal" | tr -d '[:space:]')" -eq 3072 ]
	write_diagnostics_results_fixture_from_file "$run_id" Succeeded "$case_terminal"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -eq 0 ]
	[[ "$output" == "mode=diagnostics phase=Succeeded run_id=$run_id "* ]]

	case_terminal="$BATS_TEST_TMPDIR/over-limit-with-trailing-lf.json"
	{
		printf '%*s' "$((3072 - canonical_bytes))" ''
		printf '%s\n' "$terminal_message"
	} >"$case_terminal"
	[ "$(LC_ALL=C wc -c <"$case_terminal" | tr -d '[:space:]')" -eq 3073 ]
	write_diagnostics_results_fixture_from_file "$run_id" Failed "$case_terminal"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -ne 0 ]
	[ "$output" = 'terminal-summary-schema-error:raw-message-too-large' ]

	case_terminal="$BATS_TEST_TMPDIR/over-limit-with-multiple-trailing-lfs.json"
	{
		printf '%*s' "$((3072 - canonical_bytes))" ''
		printf '%s\n\n\n' "$terminal_message"
	} >"$case_terminal"
	[ "$(LC_ALL=C wc -c <"$case_terminal" | tr -d '[:space:]')" -eq 3075 ]
	write_diagnostics_results_fixture_from_file "$run_id" Failed "$case_terminal"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -ne 0 ]
	[ "$output" = 'terminal-summary-schema-error:raw-message-too-large' ]
}

# Catches validating only the canonical payload and then appending an
# unvalidated line-feed byte to the Kubernetes termination-log file.
@test "diagnostic terminal producer writes only bounded canonical JSON bytes" {
	run_id='20260819T120000Z-feedbeef'
	summary="$BATS_TEST_TMPDIR/diagnostic-summary.json"
	termination="$BATS_TEST_TMPDIR/diagnostic-termination.json"
	canonical="$BATS_TEST_TMPDIR/diagnostic-terminal-canonical.json"
	samples_json="$BATS_TEST_TMPDIR/diagnostic-samples.json"
	write_diagnostics_summary_fixture "$run_id" complete "$summary"
	yq -r '.data."samples.json"' \
		"$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/samples.yaml" >"$samples_json"

	run env \
		BENCHMARK_TEST_MODE=1 \
		BENCHMARK_SAMPLES_FILE="$samples_json" \
		BENCHMARK_TERMINATION_LOG_PATH="$termination" \
		"$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/benchmark.sh" \
		_test diagnostic-terminal complete "$run_id" "$summary"
	[ "$status" -eq 0 ]
	printf '%s' "$output" | jq -e -S -j -c . >"$canonical"
	cmp -s "$canonical" "$termination"
	[ "$(LC_ALL=C wc -c <"$termination" | tr -d '[:space:]')" -le 3072 ]
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

@test "results allow only a dispatch-bound reader owned by the deterministic reader Job beside diagnostics" {
	local run_id='20260820T223425Z-082b3d38' reader_job reader_pod reader_job_json summary termination terminal_message case_name readers
	reader_job='encode-benchmark-evidence-reader-20260820t223425z-082b3d38'
	reader_pod="$(jq -n -c --arg run "$run_id" --arg job "$reader_job" '{
		metadata:{name:($job + "-pod"),labels:{
			"app.kubernetes.io/name":"encode-benchmark",
			"homelab-talos/benchmark-dispatch":$run,
			"homelab-talos/benchmark-run":$run,
			"homelab-talos/benchmark-mode":"diagnostic-evidence-reader",
			"job-name":$job
		},ownerReferences:[{apiVersion:"batch/v1",kind:"Job",name:$job,uid:"reader-job-uid",controller:true,blockOwnerDeletion:true}]},
		status:{phase:"Succeeded"}
	}')"
	reader_job_json="$(jq -n -c --arg run "$run_id" --arg job "$reader_job" '{items:[{metadata:{name:$job,uid:"reader-job-uid",labels:{"app.kubernetes.io/name":"encode-benchmark","homelab-talos/benchmark-dispatch":$run,"homelab-talos/benchmark-run":$run,"homelab-talos/benchmark-mode":"diagnostic-evidence-reader"}}}]}')"
	summary="$BATS_TEST_TMPDIR/diagnostic-summary.json"
	termination="$BATS_TEST_TMPDIR/diagnostic-termination.json"
	write_diagnostics_summary_fixture "$run_id" complete "$summary"
	terminal_message="$(produce_diagnostics_terminal_message complete "$run_id" "$summary" "$termination")"
	STUB_BENCHMARK_PODS_JSON="$BATS_TEST_TMPDIR/diagnostic-pods-reader-coexistence.json"
	STUB_JOBS_JSON="$BATS_TEST_TMPDIR/diagnostic-reader-jobs.json"
	export STUB_BENCHMARK_PODS_JSON STUB_JOBS_JSON
	printf '%s\n' "$reader_job_json" >"$STUB_JOBS_JSON"

	for case_name in zero one missing-dispatch wrong-dispatch wrong-owner-uid duplicate spoofed mislabeled other-mode; do
		case "$case_name" in
		zero) readers='[]' ;;
		one) readers="[$reader_pod]" ;;
		missing-dispatch) readers="[$(jq -c 'del(.metadata.labels."homelab-talos/benchmark-dispatch")' <<<"$reader_pod")]" ;;
		wrong-dispatch) readers="[$(jq -c '.metadata.labels."homelab-talos/benchmark-dispatch" = "20260820T223425Z-deadbeef"' <<<"$reader_pod")]" ;;
		wrong-owner-uid) readers="[$(jq -c '.metadata.ownerReferences[0].uid = "plausible-other-job-uid"' <<<"$reader_pod")]" ;;
		duplicate) readers="[$reader_pod,$(jq -c '.metadata.name += "-duplicate"' <<<"$reader_pod")]" ;;
		spoofed) readers="[$(jq -c 'del(.metadata.ownerReferences)' <<<"$reader_pod")]" ;;
		mislabeled) readers="[$(jq -c '.metadata.labels."job-name" = "encode-benchmark-evidence-reader-spoofed"' <<<"$reader_pod")]" ;;
		other-mode) readers="[$(jq -c '.metadata.labels."homelab-talos/benchmark-mode" = "quality"' <<<"$reader_pod")]" ;;
		esac
		jq -n -c --arg run "$run_id" --arg message "$terminal_message" --argjson readers "$readers" '{
			items:([{
				metadata:{name:"encode-benchmark-diagnostics-fixture-pod",labels:{
					"app.kubernetes.io/name":"encode-benchmark",
					"homelab-talos/benchmark-run":$run,
					"homelab-talos/benchmark-mode":"diagnostics",
					"job-name":"encode-benchmark-diagnostics-fixture"
				}},
				status:{phase:"Succeeded",containerStatuses:[{name:"benchmark",state:{terminated:{message:$message}}}]}
			}] + $readers)
		}' >"$STUB_BENCHMARK_PODS_JSON"
		: >"$STUB_CALLS"
		run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
		if [[ "$case_name" == 'zero' || "$case_name" == 'one' ]]; then
			[ "$status" -eq 0 ]
			[[ "$output" == 'mode=diagnostics phase=Succeeded '* ]]
		else
			[ "$status" -ne 0 ]
			[ "$output" = "diagnostic result provenance rejected: expected one canonical diagnostics pod for run $run_id" ]
		fi
		[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / get pods / {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 1 ]
		if [[ "$case_name" != 'zero' && "$case_name" != 'duplicate' && "$case_name" != 'other-mode' ]]; then
			[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / get jobs / {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 1 ]
		else
			[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / get jobs / {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 0 ]
		fi
		[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / logs / {count += 1} END {print count + 0}' "$STUB_CALLS")" -eq 0 ]
	done
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
