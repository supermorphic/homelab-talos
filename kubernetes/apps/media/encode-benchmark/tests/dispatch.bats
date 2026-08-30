#!/usr/bin/env bats

setup() {
	PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)"
	DISPATCH="$PROJECT_ROOT/scripts/encode-benchmark/dispatch.sh"
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
		printf '%s\n' "${STUB_GIT_DIFF_PATH:-scripts/encode-benchmark/dispatch.sh}"
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

reset_cluster_stub_state() {
	rm -f -- "$STUB_CAPTURE_DIR"/*.yaml "$STUB_CAPTURE_DIR"/.count \
		"$STUB_CAPTURE_DIR"/.job-render-count "$STUB_CAPTURE_DIR"/.pod-sequence-* \
		"$STUB_CAPTURE_DIR"/unsafe-configmap-delete
	: >"$STUB_CALLS"
	unset STUB_API_SERVER STUB_COLLISION STUB_CONFIGMAP_CREATE_FAIL
	unset STUB_CONFIGMAP_REPLACE_BEFORE_DELETE STUB_HANDOFF_BAD_OWNER
	unset STUB_HANDOFF_EXTRA_OWNER STUB_HANDOFF_IMAGE_ID STUB_HANDOFF_IMAGE_MISSING
	unset STUB_HANDOFF_LOG_READY STUB_HANDOFF_POD_COUNT STUB_HANDOFF_POD_SEQUENCE
	unset STUB_JOB_CREATE_FAIL STUB_JOB_CREATE_FAIL_AT STUB_JOB_CREATE_RESPONSE_METADATA_BAD
	unset STUB_JOB_RENDER_FAIL_AT STUB_JOB_REPLACEMENT STUB_PERSISTED_EXTRA_OWNER
	unset STUB_PERSISTED_OWNER_BAD
}

write_results_fixtures() {
	local run_id="$1" image_id="$2"
	STUB_JOBS_JSON="$BATS_TEST_TMPDIR/jobs.json"
	STUB_PODS_JSON="$BATS_TEST_TMPDIR/pods.json"
	STUB_LOGS_FILE="$BATS_TEST_TMPDIR/logs.txt"
	STUB_IMAGE_EVIDENCE_DIR="$BATS_TEST_TMPDIR/image-evidence"
	export STUB_JOBS_JSON STUB_PODS_JSON STUB_LOGS_FILE STUB_IMAGE_EVIDENCE_DIR
	unset STUB_LOGS_DIR
	mkdir -p "$STUB_IMAGE_EVIDENCE_DIR"
	printf '%s\n' "{\"apiVersion\":\"v1\",\"items\":[{\"metadata\":{\"name\":\"encode-benchmark-capabilities-fixture\",\"uid\":\"fixture-job-uid\",\"labels\":{\"app.kubernetes.io/name\":\"encode-benchmark\",\"homelab-talos/benchmark-run\":\"$run_id\",\"homelab-talos/benchmark-mode\":\"capabilities\"},\"annotations\":{\"homelab-talos/image-evidence-configmap\":\"encode-benchmark-image-fixture\"}},\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"nuc2\"},\"containers\":[{\"name\":\"benchmark\",\"image\":\"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb\"}]}}},\"status\":{\"conditions\":[{\"type\":\"Complete\",\"status\":\"True\"}],\"succeeded\":1,\"failed\":0,\"startTime\":\"2026-08-02T12:00:00Z\",\"completionTime\":\"2026-08-02T12:01:00Z\"}}]}" >"$STUB_JOBS_JSON"
	printf '%s\n' "{\"apiVersion\":\"v1\",\"items\":[{\"metadata\":{\"name\":\"encode-benchmark-capabilities-fixture-pod\",\"labels\":{\"job-name\":\"encode-benchmark-capabilities-fixture\",\"homelab-talos/benchmark-run\":\"$run_id\"},\"ownerReferences\":[{\"apiVersion\":\"batch/v1\",\"kind\":\"Job\",\"name\":\"encode-benchmark-capabilities-fixture\",\"uid\":\"fixture-job-uid\",\"controller\":true,\"blockOwnerDeletion\":true}]},\"spec\":{\"nodeName\":\"nuc2\"},\"status\":{\"phase\":\"Succeeded\",\"containerStatuses\":[{\"name\":\"benchmark\",\"imageID\":\"$image_id\"}]}}]}" >"$STUB_PODS_JSON"
	printf '%s\n' '{"status":"passed","strategyId":"qsv-hevc-icq-v1","proofSchemaVersion":3,"initialization":"passed","initializationReason":"","renderNode":"/dev/dri/renderD128","drmDriver":"i915","selectedRateControl":"ICQ","telemetryStatus":"available","telemetryReason":"","videoBusyNanoseconds":800000000,"videoBusyPercent":40,"encodeFps":72,"encodeSpeed":1.25,"decode":"passed","vmaf":"passed","diagnosticCapabilities":{"traceHeaders":"passed","libvmaf":"passed","ssim":"passed","psnr":"passed","bestEffortTimestampTime":"passed","packetDurationTime":"passed","keyFrame":"passed","pictType":"passed"},"proofStatus":"passed","proofReasons":"","uid":568,"hevcQsv":true,"libx265":true,"nodeName":"nuc2","configuredImage":"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb","configuredImageDigest":"sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb","sourcePath":"/media/Secret Movie.mkv","source_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","credential":"dont-print-me"}' >"$STUB_LOGS_FILE"
	printf '%s\n' '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"encode-benchmark-image-fixture","ownerReferences":[{"apiVersion":"batch/v1","kind":"Job","name":"encode-benchmark-capabilities-fixture","uid":"fixture-job-uid","controller":true,"blockOwnerDeletion":true}]},"data":{"image.json":"{\"configuredImage\":\"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb\",\"dispatchedImage\":\"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb\",\"imageId\":\"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb\"}"}}' >"$STUB_IMAGE_EVIDENCE_DIR/encode-benchmark-image-fixture.json"
}

write_quality_results_fixtures() {
	local dispatch_id="$1" runtime_run_id="$2" image_id="$3"
	write_results_fixtures "$dispatch_id" "$image_id"
	jq --arg dispatch "$dispatch_id" '
		.items[0].metadata.name = "encode-benchmark-quality-literal" |
		.items[0].metadata.uid = "quality-job-uid-09" |
		.items[0].metadata.labels."homelab-talos/benchmark-mode" = "quality" |
		.items[0].metadata.labels."homelab-talos/benchmark-dispatch" = $dispatch |
		.items[0].spec.template.spec.containers[0].env = [{
			name:"BENCHMARK_DISPATCH_CORRELATION_ID",value:$dispatch
		}]' "$STUB_JOBS_JSON" >"$STUB_JOBS_JSON.tmp"
	mv "$STUB_JOBS_JSON.tmp" "$STUB_JOBS_JSON"
	jq '
		.items[0].metadata.name = "encode-benchmark-quality-literal-pod" |
		.items[0].metadata.labels."job-name" = "encode-benchmark-quality-literal" |
		.items[0].metadata.ownerReferences = [{apiVersion:"batch/v1",kind:"Job",
			name:"encode-benchmark-quality-literal",uid:"quality-job-uid-09",
			controller:true,blockOwnerDeletion:true}]' \
		"$STUB_PODS_JSON" >"$STUB_PODS_JSON.tmp"
	mv "$STUB_PODS_JSON.tmp" "$STUB_PODS_JSON"
	jq '
		.metadata.ownerReferences = [{apiVersion:"batch/v1",kind:"Job",
			name:"encode-benchmark-quality-literal",uid:"quality-job-uid-09",
			controller:true,blockOwnerDeletion:true}]' \
		"$STUB_IMAGE_EVIDENCE_DIR/encode-benchmark-image-fixture.json" \
		>"$STUB_IMAGE_EVIDENCE_DIR/evidence.tmp"
	mv "$STUB_IMAGE_EVIDENCE_DIR/evidence.tmp" \
		"$STUB_IMAGE_EVIDENCE_DIR/encode-benchmark-image-fixture.json"
	jq -n -c --arg dispatch "$dispatch_id" --arg runtime "$runtime_run_id" '{
		schemaVersion:2,strategyId:"qsv-hevc-icq-v1",status:"complete",
		dispatchId:$dispatch,runtimeRunId:$runtime,artifactLocation:("/out/runs/" + $runtime),
		cohorts:{
			avc:{status:"eligible",candidates:[{globalQuality:16,medianReductionPercent:35}]},
			vc1:{status:"no-verdict",candidates:[]},
			hdr10:{status:"no-go",candidates:[]}
		}
	}' >"$STUB_LOGS_FILE"
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

prepare_evidence_source() {
	evidence_app="$BATS_TEST_TMPDIR/evidence-app"
	if [[ ! -d "$evidence_app" ]]; then
		cp -R "$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app" "$evidence_app"
	fi
	export ENCODE_BENCHMARK_APP_DIR="$evidence_app"
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

# D01: A near-match confirmation must never reach either Job-creation path.
@test "capability and quality dispatch require exact mode-bound confirmations" {
	assert_guard_refuses ENCODE_BENCHMARK_CAPABILITIES_CONFIRM \
		'run:encode-benchmark:capability' capabilities
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	run_dispatch capabilities
	[ "$status" -eq 0 ]
	[ "$(mutation_count)" -eq 4 ]

	reset_cluster_stub_state
	unset ENCODE_BENCHMARK_CAPABILITIES_CONFIRM
	assert_guard_refuses ENCODE_BENCHMARK_RUN_CONFIRM \
		'run:encode-benchmark:quality:20260802T120000Z-deadbeef' \
		run quality 20260802T120000Z-deadbeef
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'
	run_dispatch run quality 20260802T120000Z-deadbeef
	[ "$status" -eq 0 ]
	[ "$(mutation_count)" -eq 2 ]
	job="$(job_capture)"
	[ "$(yq -r '.metadata.labels."homelab-talos/benchmark-run"' "$job")" = \
		'20260802T120000Z-deadbeef' ]
	[ "$(yq -r '.spec.template.spec.containers[0].command | join(" ")' "$job")" = \
		'/scripts/benchmark.sh quality 20260802T120000Z-deadbeef' ]
}

# D02: The gate recomputes every schema-3 prerequisite; proofStatus alone is not an oracle.
@test "quality dispatch requires one current semantically passing capability node" {
	local valid label mutation invalid
	valid="$(valid_capability_evidence)"
	run jq -e '
		.nodes | length == 1 and .[0] == {
			nodeName:"nuc1",strategyId:"qsv-hevc-icq-v1",proofSchemaVersion:3,
			initialization:"passed",initializationReason:"",renderNode:"/dev/dri/renderD128",
			drmDriver:"i915",selectedRateControl:"ICQ",telemetryStatus:"available",
			telemetryReason:"",videoBusyNanoseconds:800000000,videoBusyPercent:40,
			encodeFps:72,encodeSpeed:1.25,decode:"passed",vmaf:"passed",
			diagnosticCapabilities:{
				imageId:"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb",
				verifiedAt:"2026-08-14T18:00:00Z",traceHeaders:"passed",libvmaf:"passed",
				ssim:"passed",psnr:"passed",bestEffortTimestampTime:"passed",
				packetDurationTime:"passed",keyFrame:"passed",pictType:"passed"},
			proofStatus:"passed",proofReasons:"",verifiedAt:"2026-08-14T18:00:00Z",
			configuredImageDigest:"sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb",
			imageId:"docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb"
		}' <<<"$valid"
	[ "$status" -eq 0 ]
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'

	while IFS=$'\t' read -r label mutation; do
		invalid="$(jq -c "$mutation" <<<"$valid")"
		set_capability_evidence verified "$invalid"
		run_dispatch run quality
		[ "$status" -ne 0 ] || {
			echo "capability mutation passed: $label" >&3
			return 1
		}
		[[ "$output" == *'capability evidence'* ]]
		assert_no_mutations
	done <<'CASES'
schema	.nodes[0].proofSchemaVersion=2
strategy	.nodes[0].strategyId="qsv-hevc-la-icq-v1"
initialization	.nodes[0].initialization="failed"
render-node	del(.nodes[0].renderNode)
driver	.nodes[0].drmDriver="xe"
icq-binding	.nodes[0].selectedRateControl="LA-ICQ"
telemetry-status	.nodes[0].telemetryStatus="harness-blocked"
telemetry-work	.nodes[0].videoBusyNanoseconds=0
telemetry-progress	.nodes[0].encodeSpeed=0
decode	.nodes[0].decode="failed"
vmaf	.nodes[0].vmaf="failed"
configured-image	.nodes[0].configuredImageDigest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
running-image	.nodes[0].imageId="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
freshness	.nodes[0].diagnosticCapabilities.verifiedAt="2026-08-14T18:00:01Z"
diagnostic-image	.nodes[0].diagnosticCapabilities.imageId="sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
trace-headers	.nodes[0].diagnosticCapabilities.traceHeaders="failed"
libvmaf	del(.nodes[0].diagnosticCapabilities.libvmaf)
ssim	.nodes[0].diagnosticCapabilities.ssim=true
psnr	.nodes[0].diagnosticCapabilities.psnr="unknown"
best-effort-timestamp	.nodes[0].diagnosticCapabilities.bestEffortTimestampTime="failed"
packet-duration	.nodes[0].diagnosticCapabilities.packetDurationTime="failed"
key-frame	.nodes[0].diagnosticCapabilities.keyFrame="failed"
pict-type	.nodes[0].diagnosticCapabilities.pictType="failed"
diagnostic-expansion	.nodes[0].diagnosticCapabilities.unexpected="passed"
claimed-proof-only	.nodes[0].encodeSpeed=0 | .nodes[0].proofStatus="passed" | .nodes[0].proofReasons=""
CASES

	set_capability_evidence verified "$valid"
	run_dispatch run quality
	[ "$status" -eq 0 ]
	[ "$(mutation_count)" -eq 2 ]
}

# D03: Four independently located immutable identities and exact ownership form one chain.
@test "dispatch and results bind configured dispatched running and kubelet image identity" {
	local run_id expected_image label mutation target bad
	expected_image='docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'
	run_dispatch run quality 20260802T120000Z-deadbeef
	[ "$status" -eq 0 ]
	job="$(job_capture)"
	configmap="$(configmap_capture)"
	[ "$(yq -r '.spec.template.spec.containers[0].image' "$job")" = "$expected_image" ]
	run jq -e --arg image "$expected_image" '
		keys == ["configuredImage","dispatchedImage","imageId"] and
		.configuredImage == $image and .dispatchedImage == $image and .imageId == $image
	' <<<"$(yq -r '.data."image.json"' "$configmap")"
	[ "$status" -eq 0 ]

	run_id='20260802T120000Z-1234abcd'
	reset_cluster_stub_state
	write_results_fixtures "$run_id" "docker-pullable://$expected_image"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
	[ "$status" -eq 0 ]
	[[ "$output" == *"actual_image_id=$expected_image"* ]]
	assert_no_mutations

	while IFS=$'\t' read -r label target bad; do
		write_results_fixtures "$run_id" "docker-pullable://$expected_image"
		case "$target" in
		configured)
			jq --arg bad "$bad" '.items[0].spec.template.spec.containers[0].image=$bad' \
				"$STUB_JOBS_JSON" >"$STUB_JOBS_JSON.tmp"
			mv "$STUB_JOBS_JSON.tmp" "$STUB_JOBS_JSON"
			;;
		dispatched | running)
			field=dispatchedImage
			[[ "$target" != running ]] || field=imageId
			jq --arg field "$field" --arg bad "$bad" \
				'.data."image.json" |= (fromjson | .[$field]=$bad | tojson)' \
				"$STUB_IMAGE_EVIDENCE_DIR/encode-benchmark-image-fixture.json" \
				>"$STUB_IMAGE_EVIDENCE_DIR/evidence.tmp"
			mv "$STUB_IMAGE_EVIDENCE_DIR/evidence.tmp" \
				"$STUB_IMAGE_EVIDENCE_DIR/encode-benchmark-image-fixture.json"
			;;
		kubelet)
			jq --arg bad "containerd://$bad" '.items[0].status.containerStatuses[0].imageID=$bad' \
				"$STUB_PODS_JSON" >"$STUB_PODS_JSON.tmp"
			mv "$STUB_PODS_JSON.tmp" "$STUB_PODS_JSON"
			;;
		owner)
			jq '.metadata.ownerReferences[0].uid="foreign-owner-uid-03"' \
				"$STUB_IMAGE_EVIDENCE_DIR/encode-benchmark-image-fixture.json" \
				>"$STUB_IMAGE_EVIDENCE_DIR/evidence.tmp"
			mv "$STUB_IMAGE_EVIDENCE_DIR/evidence.tmp" \
				"$STUB_IMAGE_EVIDENCE_DIR/encode-benchmark-image-fixture.json"
			;;
		esac
		run "$RESULTS" "$KUBECONFIG_FIXTURE" "$run_id"
		[ "$status" -ne 0 ] || {
			echo "image chain mutation passed: $label" >&3
			return 1
		}
	done <<'CASES'
configured	configured	docker.io/linuxserver/ffmpeg@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
dispatched	dispatched	docker.io/linuxserver/ffmpeg@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
running	running	docker.io/linuxserver/ffmpeg@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
kubelet	kubelet	docker.io/linuxserver/ffmpeg@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
ownership	owner	unused
CASES
	assert_no_mutations
}

# D04: Every deployed input is checked by both mutating public recipes before dispatch.
@test "deployed-source drift refuses capability and quality before mutation" {
	local label path recipe
	export STUB_GIT_STALE=1
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'
	while IFS=$'\t' read -r label path; do
		export STUB_GIT_DIFF_PATH="$path"
		for recipe in encode-benchmark-capabilities encode-benchmark-quality; do
			run just --justfile "$PROJECT_ROOT/kubernetes/mod.just" "$recipe"
			[ "$status" -ne 0 ] || {
				echo "deployed drift passed: $label/$recipe" >&3
				return 1
			}
			assert_no_mutations
		done
	done <<'CASES'
scripts	scripts/encode-benchmark/dispatch.sh
samples	kubernetes/apps/media/encode-benchmark/app/samples.yaml
template	kubernetes/apps/media/encode-benchmark/templates/job.yaml
contract	kubernetes/apps/media/encode-benchmark/app/scripts/contract.sh
recipe	kubernetes/mod.just
CASES
}

# D08: Rollback uses API-returned ownership and UID preconditions and skips replacements.
@test "rollback deletes only current dispatch resources with UID preconditions" {
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	export STUB_HANDOFF_LOG_READY=0
	export STUB_CONFIGMAP_REPLACE_BEFORE_DELETE=1
	run_dispatch capabilities
	[ "$status" -ne 0 ]
	awk -F '\t' '
		$1 == "kubectl" && $2 ~ / delete job\// {
			jobs += 1; if ($2 !~ / --preconditions=uid=fixture-job-uid( |$)/) bad=1
		}
		$1 == "kubectl" && $2 ~ / delete configmap\// {
			configmaps += 1; if ($2 !~ / --preconditions=uid=fixture-configmap-uid( |$)/) bad=1
		}
		$1 == "kubectl" && $2 ~ / delete / && $2 !~ /encode-benchmark-(cap|image)-/ {foreign=1}
		END {exit !(jobs == 2 && configmaps == 1 && !bad && !foreign)}
	' "$STUB_CALLS"
	[ ! -e "$STUB_CAPTURE_DIR/unsafe-configmap-delete" ]

	reset_cluster_stub_state
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	export STUB_HANDOFF_LOG_READY=0
	export STUB_JOB_REPLACEMENT=1
	printf '%s\n' 'unrelated-resource' >"$STUB_CAPTURE_DIR/unrelated-resource"
	run_dispatch capabilities
	[ "$status" -ne 0 ]
	[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / delete job\// {count++} END {print count+0}' \
		"$STUB_CALLS")" -eq 0 ]
	[ "$(<"$STUB_CAPTURE_DIR/unrelated-resource")" = 'unrelated-resource' ]
}

# D09: Only one terminal owned quality chain may release one schema-2 bounded line.
@test "results returns one bounded authenticated quality completion" {
	local dispatch_id runtime_run_id image_id base label mutation
	dispatch_id='20260802T120000Z-1234abcd'
	runtime_run_id='20260802T120000Z-feedface'
	image_id='docker-pullable://docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	write_quality_results_fixtures "$dispatch_id" "$runtime_run_id" "$image_id"
	base="$BATS_TEST_TMPDIR/quality-completion-base.json"
	cp "$STUB_LOGS_FILE" "$base"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$dispatch_id"
	[ "$status" -eq 0 ]
	[ "$output" = "mode=quality phase=Complete dispatch_id=$dispatch_id runtime_run_id=$runtime_run_id artifact_location=/out/runs/$runtime_run_id avc=eligible:16@35 vc1=no-verdict: hdr10=no-go:" ]
	[ "$(awk 'END {print NR}' <<<"$output")" -eq 1 ]
	[[ "$output" != *'job='* && "$output" != *'image'* && "$output" != *'sha256:'* ]]
	[[ "$output" != *'sourcePath'* && "$output" != *'rawLog'* && "$output" != *'.mkv'* ]]
	assert_no_mutations

	while IFS=$'\t' read -r label mutation; do
		write_quality_results_fixtures "$dispatch_id" "$runtime_run_id" "$image_id"
		jq -c "$mutation" "$base" >"$STUB_LOGS_FILE"
		run "$RESULTS" "$KUBECONFIG_FIXTURE" "$dispatch_id"
		[ "$status" -ne 0 ] || {
			echo "completion mutation passed: $label" >&3
			return 1
		}
		[[ "$output" != mode=quality\ phase=Complete* ]]
	done <<'CASES'
schema	.schemaVersion=3
raw-path	.rawLog="/media/private-title.mkv"
evidence-path	.cohorts.avc.candidates[0].evidencePath="quality-evidence/raw.json"
missing-cohort	del(.cohorts.vc1)
duplicate-candidate	.cohorts.avc.candidates += [.cohorts.avc.candidates[0]]
invalid-setting	.cohorts.avc.candidates[0].globalQuality=17
foreign-runtime	.runtimeRunId="20260802T120000Z-eeeeeeee"
foreign-artifact	.artifactLocation="/out/runs/20260802T120000Z-eeeeeeee"
CASES

	for label in extra-job active-job foreign-owner wrong-image; do
		write_quality_results_fixtures "$dispatch_id" "$runtime_run_id" "$image_id"
		case "$label" in
		extra-job)
			jq '.items += [.items[0]]' "$STUB_JOBS_JSON" >"$STUB_JOBS_JSON.tmp"
			mv "$STUB_JOBS_JSON.tmp" "$STUB_JOBS_JSON"
			;;
		active-job)
			jq '.items[0].status={active:1}' "$STUB_JOBS_JSON" >"$STUB_JOBS_JSON.tmp"
			mv "$STUB_JOBS_JSON.tmp" "$STUB_JOBS_JSON"
			;;
		foreign-owner)
			jq '.items[0].metadata.ownerReferences[0].uid="foreign-quality-uid"' \
				"$STUB_PODS_JSON" >"$STUB_PODS_JSON.tmp"
			mv "$STUB_PODS_JSON.tmp" "$STUB_PODS_JSON"
			;;
		wrong-image)
			jq '.items[0].status.containerStatuses[0].imageID="containerd://docker.io/linuxserver/ffmpeg@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' \
				"$STUB_PODS_JSON" >"$STUB_PODS_JSON.tmp"
			mv "$STUB_PODS_JSON.tmp" "$STUB_PODS_JSON"
			;;
		esac
		run "$RESULTS" "$KUBECONFIG_FIXTURE" "$dispatch_id"
		if [[ "$label" == active-job ]]; then
			[ "$status" -eq 0 ]
		else
			[ "$status" -ne 0 ] || {
				echo "completion provenance mutation passed: $label" >&3
				return 1
			}
		fi
		[[ "$output" != mode=quality\ phase=Complete* ]]
	done
	assert_no_mutations
}

# D10: Invalid public inputs and retired surfaces stop before every API mutation.
@test "malformed identities arguments and retired entrypoints fail before mutation" {
	local label
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'

	while IFS=$'\t' read -r label command_line; do
		read -r -a arguments <<<"$command_line"
		case "$label" in
		collision) export STUB_COLLISION=1 ;;
		wrong-api) export STUB_API_SERVER='https://example.invalid:6443' ;;
		esac
		run_dispatch "${arguments[@]}"
		[ "$status" -ne 0 ] || {
			echo "malformed dispatch passed: $label" >&3
			return 1
		}
		assert_no_mutations
		unset STUB_COLLISION STUB_API_SERVER
	done <<'CASES'
traversal	run quality ../bad-run
impossible-utc	run quality 20260230T120000Z-deadbeef
wrong-mode	run savings
extra-argument	run quality 20260802T120000Z-deadbeef extra
wrong-action	cleanup
collision	run quality 20260802T120000Z-deadbeef
wrong-api	capabilities
CASES

	run env BENCHMARK_TEST_MODE=1 BENCHMARK_OUT="$BATS_TEST_TMPDIR/retired-out" \
		BENCHMARK_SCRATCH="$BATS_TEST_TMPDIR/retired-scratch" \
		BENCHMARK_SAMPLES_FILE="$BATS_TEST_TMPDIR/retired-samples.json" \
		"$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/benchmark.sh" diagnostic
	[ "$status" -eq 64 ]
	run "$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/probe.sh" \
		diagnostic-identity source 0 90
	[ "$status" -eq 64 ]
	run just --justfile "$PROJECT_ROOT/kubernetes/mod.just" encode-benchmark-diagnostic
	[ "$status" -ne 0 ]
	assert_no_mutations

	run env ENCODE_BENCHMARK_TEST_MODE=0 ENCODE_BENCHMARK_APP_DIR="$BATS_TEST_TMPDIR/foreign-app" \
		"$DISPATCH" "$KUBECONFIG_FIXTURE" capabilities
	[ "$status" -eq 64 ]
	run env BENCHMARK_TEST_MODE=0 BENCHMARK_OUT="$BATS_TEST_TMPDIR/foreign-out" \
		"$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/benchmark.sh" quality
	[ "$status" -eq 64 ]
	run env BENCHMARK_TEST_MODE=0 BENCHMARK_OUT="$BATS_TEST_TMPDIR/foreign-out" \
		"$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/runmeta.sh" create quality
	[ "$status" -eq 64 ]
	assert_no_mutations
}
