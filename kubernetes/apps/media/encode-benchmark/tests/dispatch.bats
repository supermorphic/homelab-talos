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
	uid="fixture-${kind,,}-uid-$count"
	printf '%s\n' "$uid" >"$capture.uid"
	printf '%s\n' "$uid" >"$STUB_CAPTURE_DIR/$kind-$name.yaml.uid"
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
	if [[ "${STUB_CONFIGMAP_REPLACE_BEFORE_DELETE:-0}" == '1' && "$*" == *' configmap/'* ]]; then
		resource=''
		for argument in "$@"; do [[ "$argument" == configmap/* ]] && resource="$argument"; done
		capture="$STUB_CAPTURE_DIR/ConfigMap-${resource#configmap/}.yaml"
		expected_uid="$(<"$capture.uid")"
		[[ "$*" == *" --preconditions=uid=$expected_uid"* ]] ||
			: >"$STUB_CAPTURE_DIR/unsafe-configmap-delete"
	fi
	[[ "$*" != *' secret/unrelated-resource-08'* ]] ||
		: >"$STUB_CAPTURE_DIR/unsafe-unrelated-delete"
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
	uid="$(<"$capture.uid")"
	live_job="$(RESOURCE_UID="$uid" yq -o=json -I=0 '.metadata.uid = strenv(RESOURCE_UID)' "$capture")"
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
			owner_uid="$(<"$job.uid")"
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
	if [[ -f "$capture.uid" ]]; then
		uid="$(<"$capture.uid")"
	else
		uid='fixture-configmap-uid'
	fi
	persisted="$(RESOURCE_UID="$uid" yq -o=json -I=0 '.metadata.uid = strenv(RESOURCE_UID)' "$capture")"
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
"$REAL_YQ" "$@"
status=$?
if ((status == 0)) && [[ -n "${JOB_NAME:-}" && -n "${STUB_RENDER_DISPATCH_IMAGE:-}" &&
	" $* " == *' -i '* ]]; then
	IMAGE="$STUB_RENDER_DISPATCH_IMAGE" "$REAL_YQ" -i \
		'.spec.template.spec.containers[0].image = strenv(IMAGE)' "${!#}"
fi
exit "$status"
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
		if [[ "${STUB_GIT_STALE:-0}" == '1' ]]; then
			shift 2
			[[ "${1:-}" == '--' ]] || exit 97
			shift
			for guarded in "$@"; do
				if [[ "${STUB_GIT_DIFF_PATH:-}" == "$guarded" ||
					"${STUB_GIT_DIFF_PATH:-}" == "$guarded/"* ]]; then
					exit 1
				fi
			done
		fi
		exit 0
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
	rm -f -- "$STUB_CAPTURE_DIR"/*.yaml "$STUB_CAPTURE_DIR"/*.yaml.uid "$STUB_CAPTURE_DIR"/.count \
		"$STUB_CAPTURE_DIR"/.job-render-count "$STUB_CAPTURE_DIR"/.pod-sequence-* \
		"$STUB_CAPTURE_DIR"/unsafe-configmap-delete "$STUB_CAPTURE_DIR"/unsafe-unrelated-delete
	: >"$STUB_CALLS"
	unset STUB_API_SERVER STUB_COLLISION STUB_CONFIGMAP_CREATE_FAIL
	unset STUB_CONFIGMAP_REPLACE_BEFORE_DELETE STUB_HANDOFF_BAD_OWNER
	unset STUB_HANDOFF_EXTRA_OWNER STUB_HANDOFF_IMAGE_ID STUB_HANDOFF_IMAGE_MISSING
	unset STUB_HANDOFF_LOG_READY STUB_HANDOFF_POD_COUNT STUB_HANDOFF_POD_SEQUENCE
	unset STUB_JOB_CREATE_FAIL STUB_JOB_CREATE_FAIL_AT STUB_JOB_CREATE_RESPONSE_METADATA_BAD
	unset STUB_JOB_RENDER_FAIL_AT STUB_JOB_REPLACEMENT STUB_PERSISTED_EXTRA_OWNER
	unset STUB_PERSISTED_OWNER_BAD STUB_RENDER_DISPATCH_IMAGE
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

create_capability_producer_stubs() {
	local capability_bin="$BATS_TEST_TMPDIR/capability-bin"
	mkdir -p "$capability_bin"
	cat >"$capability_bin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ffmpeg\t%s\n' "$*" >>"$CAPABILITY_COMMANDS"
case "$*" in
*'-hide_banner -encoders'*)
	printf '%s\n' ' V..... hevc_qsv Intel Quick Sync Video HEVC encoder'
	exit 0
	;;
*'-hide_banner -filters'*)
	printf '%s\n' \
		' ... libvmaf VV->V Calculate VMAF.' \
		' ... ssim VV->V Calculate SSIM.' \
		' ... psnr VV->V Calculate PSNR.'
	exit 0
	;;
*'-hide_banner -bsfs'*)
	printf '%s\n' 'trace_headers'
	exit 0
	;;
*'-version'*)
	printf '%s\n' 'ffmpeg version 8.1.2 bounded-fixture'
	exit 0
	;;
esac
if [[ "$*" == *'-c:v hevc_qsv'* ]]; then
	printf '%s\n' \
		'[hevc_qsv @ 0x2000] Runtime selected ratecontrol method: ICQ' \
		'frame= 150 fps=72.0 q=-0.0 size=1024KiB time=00:00:05.00 speed=1.25x' >&2
fi
last="${!#}"
if [[ "$last" != '-' && "$last" != '/dev/null' ]]; then
	mkdir -p "$(dirname "$last")"
	printf '%s\n' 'bounded capability media' >"$last"
fi
EOF
	cat >"$capability_bin/ffprobe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ffprobe\t%s\n' "$*" >>"$CAPABILITY_COMMANDS"
if [[ "${1:-}" == '-version' ]]; then
	printf '%s\n' 'ffprobe version 8.1.2 bounded-fixture'
	result=0
else
	printf '%s\n' '{"frames":[{"best_effort_timestamp_time":"0.000000","pkt_duration_time":"0.041667","key_frame":1,"pict_type":"I"}]}'
	result=0
fi
exit "$result"
EOF
	cat >"$capability_bin/id" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == '-u' ]]
printf '%s\n' '568'
EOF
	chmod +x "$capability_bin/ffmpeg" "$capability_bin/ffprobe" "$capability_bin/id"
	export PATH="$capability_bin:$PATH"
	export CAPABILITY_COMMANDS="$BATS_TEST_TMPDIR/capability-commands.tsv"
	: >"$CAPABILITY_COMMANDS"
}

produce_capability_evidence() {
	local benchmark samples
	benchmark="$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/benchmark.sh"
	samples="$BATS_TEST_TMPDIR/capability-samples.json"
	yq -r '.data."samples.json"' "$evidence_app/samples.yaml" >"$samples"
	create_capability_producer_stubs
	run env BENCHMARK_TEST_MODE=1 \
		BENCHMARK_OUT="$BATS_TEST_TMPDIR/capability-out" \
		BENCHMARK_SCRATCH="$BATS_TEST_TMPDIR/capability-scratch" \
		BENCHMARK_SAMPLES_FILE="$samples" \
		BENCHMARK_DISPATCH_IMAGE='docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb' \
		BENCHMARK_TEST_FDINFO_FIXTURE="$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/tests/fixtures/logs/drm-fdinfo-active.log" \
		NODE_NAME=nuc2 "$benchmark" capabilities
	[ "$status" -eq 0 ]
	CAPABILITY_PRODUCER_OUTPUT="$output"
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
	local producer valid label mutation invalid producer_run
	produce_capability_evidence
	producer="$CAPABILITY_PRODUCER_OUTPUT"
	run jq -e '
		keys == ["configuredImage","configuredImageDigest","decode","diagnosticCapabilities",
			"drmDriver","encodeFps","encodeSpeed","ffmpegVersion","ffprobeVersion","hevcQsv",
			"initialization","initializationReason","nodeName","proofReasons","proofSchemaVersion",
			"proofStatus","renderNode","selectedRateControl","status","strategyId","telemetryReason",
			"telemetryStatus","uid","videoBusyNanoseconds","videoBusyPercent","vmaf"] and
		.status == "passed" and .strategyId == "qsv-hevc-icq-v1" and
		.proofSchemaVersion == 3 and .uid == 568 and .initialization == "passed" and
		.initializationReason == "" and .renderNode == "/dev/dri/renderD128" and
		.drmDriver == "i915" and .selectedRateControl == "ICQ" and
		.telemetryStatus == "available" and .telemetryReason == "" and
		.videoBusyNanoseconds == 800000000 and .videoBusyPercent == 40 and
		.encodeFps == 72 and .encodeSpeed == 1.25 and .decode == "passed" and
		.vmaf == "passed" and .diagnosticCapabilities == {
			traceHeaders:"passed",libvmaf:"passed",ssim:"passed",psnr:"passed",
			bestEffortTimestampTime:"passed",packetDurationTime:"passed",
			keyFrame:"passed",pictType:"passed"} and
		.proofStatus == "passed" and .proofReasons == "" and .hevcQsv == true and
		.ffmpegVersion == "8.1.2" and .ffprobeVersion == "8.1.2" and
		.nodeName == "nuc2" and
		.configuredImage == "docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb" and
		.configuredImageDigest == "sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb"
	' <<<"$producer"
	[ "$status" -eq 0 ]
	run rg -F -- '-global_quality 16 -look_ahead 0 -extbrc 0' "$CAPABILITY_COMMANDS"
	[ "$status" -eq 0 ]
	run rg -F -- 'libvmaf=model=version=vmaf_4k_v0.6.1' "$CAPABILITY_COMMANDS"
	[ "$status" -eq 0 ]

	producer_run='20260802T120000Z-2222aaaa'
	write_results_fixtures "$producer_run" \
		'docker-pullable://docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	printf '%s\n' "$producer" >"$STUB_LOGS_FILE"
	run "$RESULTS" "$KUBECONFIG_FIXTURE" "$producer_run"
	[ "$status" -eq 0 ]
	[[ "$output" == *'capability_evidence={"nodeName":"nuc2","strategyId":"qsv-hevc-icq-v1","proofSchemaVersion":3'* ]]
	[[ "$output" != *'ffmpegVersion'* && "$output" != *'configuredImage"'* ]]
	STUB_PODS_JSON="$BATS_TEST_TMPDIR/default-pods.json"
	export STUB_PODS_JSON
	unset STUB_JOBS_JSON STUB_LOGS_FILE STUB_IMAGE_EVIDENCE_DIR

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
	local run_id expected_image label mutation target bad runtime_samples runtime_evidence
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

	while IFS=$'\t' read -r label target bad; do
		reset_cluster_stub_state
		export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'
		case "$target" in
		dispatched) export STUB_RENDER_DISPATCH_IMAGE="$bad" ;;
		running) export STUB_HANDOFF_IMAGE_MISSING=1 ;;
		kubelet) export STUB_HANDOFF_IMAGE_ID="containerd://$bad" ;;
		owner) export STUB_HANDOFF_BAD_OWNER=1 ;;
		esac
		run_dispatch run quality 20260802T120000Z-deadbeef
		[ "$status" -ne 0 ] || {
			echo "dispatch handoff mutation passed: $label" >&3
			return 1
		}
		run rg -n $'kubectl\t.* (exec|apply|patch) ' "$STUB_CALLS"
		[ "$status" -eq 1 ]
	done <<'CASES'
configured-dispatched	dispatched	docker.io/linuxserver/ffmpeg@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
running-handoff	running	unused
kubelet-image-id	kubelet	docker.io/linuxserver/ffmpeg@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
pod-owner	owner	unused
CASES

	runtime_samples="$BATS_TEST_TMPDIR/runtime-image-samples.json"
	yq -r '.data."samples.json"' "$evidence_app/samples.yaml" >"$runtime_samples"
	runtime_evidence="$BATS_TEST_TMPDIR/runtime-image.json"
	while IFS=$'\t' read -r label target bad; do
		jq -n --arg image "$expected_image" '{configuredImage:$image,dispatchedImage:$image,imageId:$image}' \
			>"$runtime_evidence"
		dispatch_image="$expected_image"
		case "$target" in
		configured) jq --arg bad "$bad" '.runtime.image=$bad' "$runtime_samples" >"$runtime_samples.tmp" && mv "$runtime_samples.tmp" "$runtime_samples" ;;
		dispatched) jq --arg bad "$bad" '.dispatchedImage=$bad' "$runtime_evidence" >"$runtime_evidence.tmp" && mv "$runtime_evidence.tmp" "$runtime_evidence" ;;
		running) jq --arg bad "$bad" '.imageId=$bad' "$runtime_evidence" >"$runtime_evidence.tmp" && mv "$runtime_evidence.tmp" "$runtime_evidence" ;;
		esac
		runtime_out="$BATS_TEST_TMPDIR/runtime-$label-out"
		runtime_scratch="$BATS_TEST_TMPDIR/runtime-$label-scratch"
		run env BENCHMARK_TEST_MODE=1 BENCHMARK_OUT="$runtime_out" \
			BENCHMARK_SCRATCH="$runtime_scratch" BENCHMARK_SAMPLES_FILE="$runtime_samples" \
			BENCHMARK_DISPATCH_IMAGE="$dispatch_image" BENCHMARK_RUNNING_IMAGE_FILE="$runtime_evidence" \
			BENCHMARK_RUNNING_IMAGE_WAIT_SECONDS=0 \
			"$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/benchmark.sh" quality
		[ "$status" -eq 65 ] || {
			echo "runtime image mutation did not fail closed: $label/$status" >&3
			return 1
		}
		[ ! -e "$runtime_out" ]
		[ ! -e "$runtime_scratch" ]
		# Restore the committed configured image before the next single-field case.
		jq --arg image "$expected_image" '.runtime.image=$image' "$runtime_samples" \
			>"$runtime_samples.tmp"
		mv "$runtime_samples.tmp" "$runtime_samples"
	done <<'CASES'
configured-runtime	configured	docker.io/linuxserver/ffmpeg@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
dispatched-runtime	dispatched	docker.io/linuxserver/ffmpeg@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
running-runtime	running	docker.io/linuxserver/ffmpeg@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
CASES

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
	local label path recipe action
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'
	while IFS=$'\t' read -r label path; do
		# The dispatcher itself intentionally has no Git guard. This control proves that
		# omitting the recipe guard would reach mutation for this same source case.
		for action in capabilities 'run quality 20260802T120000Z-deadbeef'; do
			reset_cluster_stub_state
			read -r -a arguments <<<"$action"
			run_dispatch "${arguments[@]}"
			[ "$status" -eq 0 ]
			[ "$(mutation_count)" -gt 0 ]
		done

		export STUB_GIT_DIFF_PATH="$path"
		export STUB_GIT_STALE=1
		for recipe in encode-benchmark-capabilities encode-benchmark-quality; do
			reset_cluster_stub_state
			export STUB_GIT_DIFF_PATH="$path" STUB_GIT_STALE=1
			run just --justfile "$PROJECT_ROOT/kubernetes/mod.just" "$recipe"
			[ "$status" -ne 0 ] || {
				echo "deployed drift passed: $label/$recipe" >&3
				return 1
			}
			assert_no_mutations
			run awk -F '\t' '$1 == "git" && $2 == "diff --quiet 1111111111111111111111111111111111111111 -- scripts/lib/rollout.sh kubernetes/mod.just scripts/encode-benchmark kubernetes/apps/media/encode-benchmark" {found=1} END {exit !found}' "$STUB_CALLS"
			[ "$status" -eq 0 ]
		done
	done <<'CASES'
scripts	scripts/encode-benchmark/dispatch.sh
samples	kubernetes/apps/media/encode-benchmark/app/samples.yaml
template	kubernetes/apps/media/encode-benchmark/templates/job.yaml
contract	kubernetes/apps/media/encode-benchmark/app/scripts/contract.sh
recipe	kubernetes/mod.just
CASES
}

# D05: Inspect the real dispatch render, raw octal projection, inert Flux inputs, and preflight floor.
@test "quality Job and preflight preserve the exact finite non-root GPU safety contract" {
	local app preflight captured rendered preflight_bin preflight_kubeconfig preflight_calls job_contract
	app="$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app"
	preflight="$PROJECT_ROOT/scripts/encode-benchmark/preflight.sh"
	reset_cluster_stub_state
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'
	run_dispatch run quality 20260802T120000Z-deadbeef
	[ "$status" -eq 0 ]
	captured="$(job_capture)"
	[ -f "$captured" ]
	[ "$(awk '/^[[:space:]]*defaultMode:/ {count++; if ($0 !~ /defaultMode: 0555$/) bad=1} END {if (count != 1 || bad) exit 1; print count}' "$captured")" -eq 1 ]
	run rg -n '^[[:space:]]*defaultMode: 555$' "$captured"
	[ "$status" -eq 1 ]
	run yq -o=json -I=0 '{
		"deadline":.spec.activeDeadlineSeconds,"backoff":.spec.backoffLimit,
		"ttl":.spec.ttlSecondsAfterFinished,"restart":.spec.template.spec.restartPolicy,
		"priority":.spec.template.spec.priorityClassName,
		"automount":.spec.template.spec.automountServiceAccountToken,
		"podSecurity":.spec.template.spec.securityContext,
		"containerSecurity":.spec.template.spec.containers[0].securityContext,
		"affinity":.spec.template.spec.affinity,
		"resources":.spec.template.spec.containers[0].resources,
		"mounts":[.spec.template.spec.containers[0].volumeMounts[] | select(.name != "media")],
		"volumes":[.spec.template.spec.volumes[] | select(.name != "media")]
	}' "$captured"
	[ "$status" -eq 0 ]
	job_contract="$output"
	run jq -e '(.volumes[2].configMap.name | test("^encode-benchmark-scripts-[a-z0-9]{10}$")) and
		(.volumes[4].configMap.name | test("^encode-benchmark-image-[0-9a-f]{12}$")) and
		(.volumes[2].configMap.name = "<run-owned-scripts>" |
		 .volumes[4].configMap.name = "<run-owned-image>" | . == {
		deadline:129600,backoff:0,ttl:86400,restart:"Never",
		priority:"encode-benchmark-background",automount:false,
		podSecurity:{runAsNonRoot:true,runAsUser:568,runAsGroup:568,fsGroup:568,
			fsGroupChangePolicy:"OnRootMismatch",seccompProfile:{type:"RuntimeDefault"}},
		containerSecurity:{allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]}},
		affinity:{podAntiAffinity:{requiredDuringSchedulingIgnoredDuringExecution:[{
			topologyKey:"kubernetes.io/hostname",labelSelector:{matchExpressions:[{
				key:"app.kubernetes.io/name",operator:"In",values:["plex"]}]}}]}},
		resources:{requests:{cpu:2,memory:"2Gi","ephemeral-storage":"105Gi","gpu.intel.com/i915":1},
			limits:{cpu:8,memory:"8Gi","ephemeral-storage":"110Gi","gpu.intel.com/i915":1}},
		mounts:[
			{name:"out",mountPath:"/out",subPath:"benchmark"},
			{name:"scratch",mountPath:"/scratch"},
			{name:"scripts",mountPath:"/scripts",readOnly:true},
			{name:"samples",mountPath:"/config/samples.json",subPath:"samples.json",readOnly:true},
			{name:"image-evidence",mountPath:"/provenance",readOnly:true}],
		volumes:[
			{name:"out",persistentVolumeClaim:{claimName:"media-data"}},
			{name:"scratch",emptyDir:{sizeLimit:"105Gi"}},
			{name:"scripts",configMap:{name:"<run-owned-scripts>",defaultMode:555}},
			{name:"samples",configMap:{name:"encode-benchmark-samples",items:[{key:"samples.json",path:"samples.json"}]}},
			{name:"image-evidence",configMap:{name:"<run-owned-image>",optional:true,
				items:[{key:"image.json",path:"image.json"}]}}]
	})' <<<"$output"
	[ "$status" -eq 0 ] || {
		echo "captured quality Job contract mismatch: $job_contract" >&3
		return 1
	}

	rendered="$BATS_TEST_TMPDIR/d05-rendered.yaml"
	run kustomize build "$app"
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" >"$rendered"
	[ "$(yq -N -r 'select(.kind == "Job") | .metadata.name' "$rendered")" = '' ]
	[ "$(yq -N -r 'select(.kind == "PriorityClass") | [.metadata.name,.value,.preemptionPolicy] | @tsv' "$rendered" | sed '/^$/d')" = $'encode-benchmark-background\t-10\tNever' ]
	[ "$(yq -N -r 'select(.kind == "ConfigMap") | .metadata.name' "$rendered" | wc -l | tr -d ' ')" -eq 2 ]

	preflight_bin="$BATS_TEST_TMPDIR/preflight-bin"
	preflight_kubeconfig="$BATS_TEST_TMPDIR/preflight-kubeconfig"
	preflight_calls="$BATS_TEST_TMPDIR/preflight-calls"
	mkdir -p "$preflight_bin"
	printf '%s\n' 'apiVersion: v1' >"$preflight_kubeconfig"
	: >"$preflight_calls"
	cat >"$preflight_bin/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$PREFLIGHT_CALLS"
case "$*" in
*' config view '*) printf '%s\n' 'https://192.168.90.20:6443' ;;
*' get pods --selector app.kubernetes.io/name=plex '*) printf '%s\n' '{"items":[{"spec":{"nodeName":"nuc-plex"},"status":{"phase":"Running"}}]}' ;;
*' get pvc media-data '*) printf '%s\n' '{"status":{"phase":"Bound"}}' ;;
*' get kustomization encode-benchmark '*) printf '%s\n' '{"spec":{"suspend":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}' ;;
*' get nodes '*) printf '%s\n' '{"items":[{"metadata":{"name":"nuc-plex"},"status":{"allocatable":{"gpu.intel.com/i915":"1"}}},{"metadata":{"name":"nuc-below"},"status":{"allocatable":{"gpu.intel.com/i915":"1"}}},{"metadata":{"name":"nuc-boundary"},"status":{"allocatable":{"gpu.intel.com/i915":"1"}}}]}' ;;
*' get pods --all-namespaces '*) printf '%s\n' '{"items":[]}' ;;
*'/nodes/nuc-plex/'*) printf '%s\n' '{"node":{"fs":{"availableBytes":123480309760}}}' ;;
*'/nodes/nuc-below/'*) printf '%s\n' '{"node":{"fs":{"availableBytes":123480309759}}}' ;;
*'/nodes/nuc-boundary/'*) printf '%s\n' '{"node":{"fs":{"availableBytes":123480309760}}}' ;;
*) echo "unexpected preflight call: $*" >&2; exit 97 ;;
esac
STUB
	chmod +x "$preflight_bin/kubectl"
	run env PATH="$preflight_bin:$PATH" PREFLIGHT_CALLS="$preflight_calls" \
		"$preflight" "$preflight_kubeconfig"
	[ "$status" -eq 0 ]
	[[ "$output" == *'nuc-plex FAIL plex-node'* ]]
	[[ "$output" == *'nuc-below FAIL free-nvme-below-115Gi'* ]]
	[[ "$output" == *'nuc-boundary PASS'* ]]
	[[ "$output" == *'eligible_nodes=1'* ]]
	run rg -n '(^| )(create|apply|patch|delete|exec)( |$)' "$preflight_calls"
	[ "$status" -eq 1 ]
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
			jobs += 1
			if ($2 ~ / --preconditions=uid=fixture-job-uid-1( |$)/) job1 += 1
			else if ($2 ~ / --preconditions=uid=fixture-job-uid-2( |$)/) job2 += 1
			else bad=1
		}
		$1 == "kubectl" && $2 ~ / delete configmap\// {
			configmaps += 1
			if ($2 ~ / --preconditions=uid=fixture-configmap-uid-3( |$)/) configmap3 += 1
			else bad=1
		}
		$1 == "kubectl" && $2 ~ / delete / && $2 !~ /encode-benchmark-(cap|image)-/ {foreign=1}
		END {exit !(jobs == 2 && job1 == 1 && job2 == 1 && configmaps == 1 &&
			configmap3 == 1 && !bad && !foreign)}
	' "$STUB_CALLS"
	[ ! -e "$STUB_CAPTURE_DIR/unsafe-configmap-delete" ]

	reset_cluster_stub_state
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	export STUB_HANDOFF_LOG_READY=0
	export STUB_JOB_REPLACEMENT=1
	printf '%s\n' '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"unrelated-resource-08","uid":"unrelated-resource-uid-08"}}' \
		>"$STUB_CAPTURE_DIR/Secret-unrelated-resource-08.yaml"
	run_dispatch capabilities
	[ "$status" -ne 0 ]
	[ "$(awk -F '\t' '$1 == "kubectl" && $2 ~ / delete job\// {count++} END {print count+0}' \
		"$STUB_CALLS")" -eq 0 ]
	run jq -e '.apiVersion == "v1" and .kind == "Secret" and
		.metadata.name == "unrelated-resource-08" and .metadata.uid == "unrelated-resource-uid-08"' \
		"$STUB_CAPTURE_DIR/Secret-unrelated-resource-08.yaml"
	[ "$status" -eq 0 ]
	[ ! -e "$STUB_CAPTURE_DIR/unsafe-unrelated-delete" ]
	run rg -F 'secret/unrelated-resource-08' "$STUB_CALLS"
	[ "$status" -eq 1 ]
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

	for label in extra-job extra-pod active-job foreign-owner wrong-image; do
		write_quality_results_fixtures "$dispatch_id" "$runtime_run_id" "$image_id"
		case "$label" in
		extra-job)
			jq '.items += [.items[0]]' "$STUB_JOBS_JSON" >"$STUB_JOBS_JSON.tmp"
			mv "$STUB_JOBS_JSON.tmp" "$STUB_JOBS_JSON"
			;;
		extra-pod)
			jq '.items += [.items[0]]' "$STUB_PODS_JSON" >"$STUB_PODS_JSON.tmp"
			mv "$STUB_PODS_JSON.tmp" "$STUB_PODS_JSON"
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
	local label surface seam expected_recipes actual_recipes expected_benchmark_actions
	local actual_benchmark_actions expected_benchmark_modes actual_benchmark_modes
	local expected_probe_actions actual_probe_actions expected_dispatch_actions actual_dispatch_actions
	local benchmark probe runmeta
	benchmark="$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/benchmark.sh"
	probe="$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/probe.sh"
	runmeta="$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/app/scripts/runmeta.sh"
	export ENCODE_BENCHMARK_CAPABILITIES_CONFIRM='run:encode-benchmark:capabilities'
	export ENCODE_BENCHMARK_RUN_CONFIRM='run:encode-benchmark:quality'

	expected_recipes=$'encode-benchmark-capabilities\nencode-benchmark-preflight\nencode-benchmark-quality\nencode-benchmark-results\nencode-benchmark-validate\nencode-benchmark-verify'
	actual_recipes="$(awk '
		/^encode-benchmark-[a-z0-9-]+([^:]*)?:/ {
			name=$1; sub(/:.*/, "", name); print name
		}
	' "$PROJECT_ROOT/kubernetes/mod.just" | LC_ALL=C sort)"
	[ "$actual_recipes" = "$expected_recipes" ]
	expected_benchmark_actions=$'commands\ndeclared-commands\ndrm-fdinfo-metrics\nencoder-commands\nicq-setting\nicq-settings\nqsv-proof\nquality-evidence-for-ranking\nquality-work-plan\nrank-quality-candidates\nrecord-quality-skips\nrecord-result\nresults-header\nrunning-image-evidence\nruntime-selection-is-icq\nvalidate-probes\nvmaf-stats'
	actual_benchmark_actions="$(awk '
		/^test_dispatch\(\)/ {in_function=1}
		in_function && /^[[:space:]]*case "\$action" in$/ {in_case=1; next}
		in_case && /^[[:space:]]*esac$/ {exit}
		in_case && /^[[:space:]]*[a-z][a-z0-9-]*\)$/ {
			action=$1; sub(/\)$/, "", action); print action
		}
	' "$benchmark" | LC_ALL=C sort)"
	[ "$actual_benchmark_actions" = "$expected_benchmark_actions" ]
	expected_benchmark_modes=$'capabilities\nquality'
	actual_benchmark_modes="$(awk '
		/^mode="\$1"$/ {in_main=1; next}
		in_main && /^case "\$mode" in$/ {in_case=1; next}
		in_case && /^esac$/ {exit}
		in_case && /^[a-z][a-z0-9-]*\)$/ {mode=$0; sub(/\)$/, "", mode); print mode}
	' "$benchmark" | LC_ALL=C sort)"
	[ "$actual_benchmark_modes" = "$expected_benchmark_modes" ]
	expected_probe_actions=$'quality-hdr-frame\nquality-hdr-normalize-oracle\nquality-hdr-stream\nquality-hdr-trace'
	actual_probe_actions="$(awk '
		/^case "\$\{1:-\}" in$/ {in_case=1; next}
		in_case && /^esac$/ {exit}
		in_case && /^[a-z][a-z0-9-]*\)$/ {action=$0; sub(/\)$/, "", action); print action}
	' "$probe" | LC_ALL=C sort)"
	[ "$actual_probe_actions" = "$expected_probe_actions" ]
	expected_dispatch_actions=$'capabilities\nrun'
	actual_dispatch_actions="$(awk '
		/^case "\$action" in$/ {in_case=1; next}
		in_case && /^esac$/ {exit}
		in_case && /^[a-z][a-z0-9-]*\)$/ {action=$0; sub(/\)$/, "", action); print action}
	' "$DISPATCH" | LC_ALL=C sort)"
	[ "$actual_dispatch_actions" = "$expected_dispatch_actions" ]

	for surface in diagnostic x265 finalist findings savings contention census selection stills cleanup bootstrap; do
		run env BENCHMARK_TEST_MODE=1 BENCHMARK_OUT="$BATS_TEST_TMPDIR/retired-out" \
			BENCHMARK_SCRATCH="$BATS_TEST_TMPDIR/retired-scratch" \
			BENCHMARK_SAMPLES_FILE="$BATS_TEST_TMPDIR/retired-samples.json" \
			"$benchmark" "$surface"
		[ "$status" -eq 64 ] || {
			echo "retired benchmark surface passed: $surface" >&3
			return 1
		}
		run "$probe" "$surface" extra
		[ "$status" -eq 64 ] || {
			echo "retired probe surface passed: $surface" >&3
			return 1
		}
		run_dispatch "$surface"
		[ "$status" -eq 64 ] || {
			echo "retired dispatch surface passed: $surface" >&3
			return 1
		}
		run just --justfile "$PROJECT_ROOT/kubernetes/mod.just" "encode-benchmark-$surface"
		[ "$status" -ne 0 ] || {
			echo "retired recipe surface passed: $surface" >&3
			return 1
		}
		assert_no_mutations
	done

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

	while IFS=$'\t' read -r seam value; do
		run env ENCODE_BENCHMARK_TEST_MODE=0 "$seam=$value" \
			"$DISPATCH" "$KUBECONFIG_FIXTURE" capabilities
		[ "$status" -eq 64 ] || {
			echo "dispatch test seam passed: $seam/$status" >&3
			return 1
		}
	done <<CASES
ENCODE_BENCHMARK_APP_DIR	$BATS_TEST_TMPDIR/foreign-app
ENCODE_BENCHMARK_HANDOFF_WAIT_SECONDS	0
ENCODE_BENCHMARK_NOW	20260802T120000Z
CASES

	for seam in BENCHMARK_OUT BENCHMARK_SCRATCH BENCHMARK_SAMPLES_FILE \
		BENCHMARK_TEST_QUALITY_PLAN_FILE BENCHMARK_RUNNING_IMAGE_FILE \
		BENCHMARK_RUNNING_IMAGE_WAIT_SECONDS BENCHMARK_RUNNING_IMAGE \
		BENCHMARK_TEST_SOURCE_PROBE BENCHMARK_TEST_OUTPUT_PROBE \
		BENCHMARK_TEST_FDINFO_FIXTURE BENCHMARK_TEST_INVALID_OUTPUT_MATCH \
		BENCHMARK_TEST_INVALID_OUTPUT_PROBE BENCHMARK_TEST_FAIL_RESULT_APPEND \
		BENCHMARK_TEST_QUALITY_EVIDENCE_COMPETITOR_SETTING \
		BENCHMARK_TEST_QUALITY_EVIDENCE_COMPETITOR_FILE; do
		run env BENCHMARK_TEST_MODE=0 "$seam=$BATS_TEST_TMPDIR/forbidden" "$benchmark" quality
		[ "$status" -eq 64 ] || {
			echo "benchmark test seam passed: $seam/$status" >&3
			return 1
		}
	done
	for seam in BENCHMARK_IDENTITY_FIXTURE BENCHMARK_NOW; do
		run env BENCHMARK_TEST_MODE=0 "$seam=$BATS_TEST_TMPDIR/forbidden" "$runmeta" create quality
		[ "$status" -eq 64 ] || {
			echo "runmeta test seam passed: $seam/$status" >&3
			return 1
		}
	done
	assert_no_mutations
}
