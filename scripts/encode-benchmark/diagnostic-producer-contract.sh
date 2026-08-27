#!/usr/bin/env bash
# Side-effect-free validation for a terminal diagnostic producer Job and Pod.
# Callers fetch the objects and supply the committed image, node, and scripts
# identities. This file performs no cluster or filesystem reads.

diagnostic_producer_failed_phase_supported() {
	[[ "$1" == '20260826T014246Z-373a665e' ]]
}

diagnostic_producer_validate() {
	local jobs_json="$1" pods_json="$2" run_id="$3" expected_node="$4"
	local configured_image="$5" current_scripts="$6" image_configmap="$7"
	local expected_scripts="$current_scripts"
	local job_condition='Complete' pod_phase='Succeeded' exit_code=0 exit_reason='Completed'
	local payload_string payload payload_bytes schema_reason

	if diagnostic_producer_failed_phase_supported "$run_id"; then
		expected_scripts='encode-benchmark-scripts-cfcdgkg5c7'
		job_condition='Failed'
		pod_phase='Failed'
		exit_code=2
		exit_reason='Error'
	fi
	payload_string="$(jq -e -n -c \
		--argjson jobs "$jobs_json" --argjson pods "$pods_json" \
		--arg run "$run_id" --arg name "encode-benchmark-diagnostics-${run_id,,}" \
		--arg node "$expected_node" --arg image "$configured_image" \
		--arg scripts "$expected_scripts" --arg image_configmap "$image_configmap" \
		--arg job_condition "$job_condition" \
		--arg pod_phase "$pod_phase" --arg exit_reason "$exit_reason" --argjson exit_code "$exit_code" \
		'
		def own_labels($mode):
			.metadata.labels."app.kubernetes.io/name" == "encode-benchmark" and
			.metadata.labels."homelab-talos/benchmark-dispatch" == $run and
			.metadata.labels."homelab-talos/benchmark-run" == $run and
			.metadata.labels."homelab-talos/benchmark-mode" == $mode;
		def pod_security:
			.automountServiceAccountToken == false and .restartPolicy == "Never" and
			.priorityClassName == "encode-benchmark-background" and
			.securityContext == {runAsNonRoot:true,runAsUser:568,runAsGroup:568,fsGroup:568,fsGroupChangePolicy:"OnRootMismatch",seccompProfile:{type:"RuntimeDefault"}} and
			(.hostNetwork // false) == false and (.hostPID // false) == false and (.hostIPC // false) == false and
			(.shareProcessNamespace // false) == false and
			((.initContainers // []) | type == "array" and length == 0) and
			((.ephemeralContainers // []) | type == "array" and length == 0) and
			(.serviceAccountName // "default") == "default";
		def benchmark_container:
			.name == "benchmark" and .image == $image and
			.command == ["/scripts/benchmark.sh","diagnostics",$run] and
			(.args // []) == [] and (has("envFrom") | not) and (has("volumeDevices") | not) and
			(.env | type == "array" and length == 2 and
			 ([.[] | select(.name == "NODE_NAME" and .valueFrom.fieldRef.fieldPath == "spec.nodeName" and ((.valueFrom.fieldRef.apiVersion // "v1") == "v1"))] | length) == 1 and
			 ([.[] | select(.name == "BENCHMARK_DISPATCH_IMAGE" and .value == $image)] | length) == 1) and
			.securityContext == {allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]}} and
			.resources == {requests:{cpu:"2",memory:"2Gi","ephemeral-storage":"105Gi","gpu.intel.com/i915":"1"},limits:{cpu:"8",memory:"8Gi","ephemeral-storage":"110Gi","gpu.intel.com/i915":"1"}} and
			(.volumeMounts | type == "array" and length == 6 and
			 ([.[] | select(.name == "media" and .mountPath == "/media" and .subPath == "media/movies" and .readOnly == true)] | length) == 1 and
			 ([.[] | select(.name == "out" and .mountPath == "/out" and .subPath == "benchmark" and (.readOnly // false) == false)] | length) == 1 and
			 ([.[] | select(.name == "scratch" and .mountPath == "/scratch" and (.readOnly // false) == false)] | length) == 1 and
			 ([.[] | select(.name == "scripts" and .mountPath == "/scripts" and .readOnly == true)] | length) == 1 and
			 ([.[] | select(.name == "samples" and .mountPath == "/config/samples.json" and .subPath == "samples.json" and .readOnly == true)] | length) == 1 and
			 ([.[] | select(.name == "image-evidence" and .mountPath == "/provenance" and .readOnly == true)] | length) == 1);
		def benchmark_volumes:
			type == "array" and length == 6 and
			([.[] | select(.name == "media" and .persistentVolumeClaim.claimName == "media-data" and (.persistentVolumeClaim.readOnly // false) == false)] | length) == 1 and
			([.[] | select(.name == "out" and .persistentVolumeClaim.claimName == "media-data" and (.persistentVolumeClaim.readOnly // false) == false)] | length) == 1 and
			([.[] | select(.name == "scratch" and .emptyDir.sizeLimit == "105Gi" and ((.emptyDir | keys) == ["sizeLimit"]))] | length) == 1 and
			([.[] | select(.name == "scripts" and .configMap.name == $scripts and .configMap.defaultMode == 365)] | length) == 1 and
			([.[] | select(.name == "samples" and .configMap.name == "encode-benchmark-samples" and .configMap.items == [{key:"samples.json",path:"samples.json"}])] | length) == 1 and
			([.[] | select(.name == "image-evidence" and .configMap.name == $image_configmap and .configMap.optional == true and .configMap.items == [{key:"image.json",path:"image.json"}])] | length) == 1;
		def job_terminal:
			((.status.active // 0) == 0) and
			(if $job_condition == "Complete" then
				([.status.conditions[]? | select(.type == "Complete" and .status == "True")] | length) == 1 and
				([.status.conditions[]? | select(.type == "Failed" and .status == "True")] | length) == 0 and
				.status.succeeded == 1 and (.status.failed // 0) == 0
			else
				([.status.conditions[]? | select(.type == "Complete" and .status == "True")] | length) == 0 and
				([.status.conditions[]? | select(.type == "Failed" and .status == "True" and .reason == "BackoffLimitExceeded")] | length) == 1 and
				(.status.succeeded // 0) == 0 and .status.failed == 1
			end);
		def job_contract:
			.apiVersion == "batch/v1" and .kind == "Job" and
			.metadata.name == $name and .metadata.namespace == "media" and
			(.metadata.uid | type == "string" and length > 0) and own_labels("diagnostics") and
			.metadata.annotations."homelab-talos/benchmark-owned" == "true" and
			.metadata.annotations."homelab-talos/scripts-configmap" == $scripts and
			.metadata.annotations."homelab-talos/image-evidence-configmap" == $image_configmap and
			([(.spec.template.metadata.annotations // {}) | keys[] | select(test("apparmor|seccomp"; "i"))] | length) == 0 and
			.spec.backoffLimit == 0 and .spec.ttlSecondsAfterFinished == 86400 and .spec.activeDeadlineSeconds == 28800 and
			(.spec.template | own_labels("diagnostics")) and
			.spec.template.spec.nodeSelector == {"kubernetes.io/hostname":$node} and
			.spec.template.spec.affinity == {podAntiAffinity:{requiredDuringSchedulingIgnoredDuringExecution:[{topologyKey:"kubernetes.io/hostname",labelSelector:{matchExpressions:[{key:"app.kubernetes.io/name",operator:"In",values:["plex"]}]}}]}} and
			(.spec.template.spec | pod_security) and
			(.spec.template.spec.containers | type == "array" and length == 1 and (.[] | benchmark_container)) and
			(.spec.template.spec.volumes | benchmark_volumes) and job_terminal;
		def exact_owner($uid):
			.metadata.ownerReferences | type == "array" and length == 1 and
			.[0] == {apiVersion:"batch/v1",kind:"Job",name:$name,uid:$uid,controller:true,blockOwnerDeletion:true};
		def image_matches:
			.status.containerStatuses[0].imageID as $raw |
			($raw | type == "string") and
			($raw | sub("^(docker-pullable|containerd)://"; "")) as $normalized |
			($normalized | test("^([^[:space:]@]+@)?sha256:[0-9a-f]{64}$")) and
			($normalized == $image or $normalized == ($image | split("@") | .[1]));
		def pod_contract($uid):
			.apiVersion == "v1" and .kind == "Pod" and .metadata.namespace == "media" and
			(.metadata.name | startswith($name + "-")) and own_labels("diagnostics") and
			.metadata.labels."job-name" == $name and exact_owner($uid) and
			([(.metadata.annotations // {}) | keys[] | select(test("apparmor|seccomp"; "i"))] | length) == 0 and
			.spec.nodeName == $node and .spec.nodeSelector == {"kubernetes.io/hostname":$node} and
			(.spec | pod_security) and
			(.spec.containers | type == "array" and length == 1 and (.[] | benchmark_container)) and
			(.spec.volumes | benchmark_volumes) and .status.phase == $pod_phase and
			(.status.containerStatuses | type == "array" and length == 1 and .[0].name == "benchmark" and
			 .[0].image == $image and .[0].ready == false and .[0].restartCount == 0 and
			 ((.[0].lastState // {}) == {}) and (.[0].state | type == "object" and keys == ["terminated"]) and
			 .[0].state.terminated.exitCode == $exit_code and .[0].state.terminated.reason == $exit_reason and
			 (.[0].state.terminated.message | type == "string")) and image_matches;
		$jobs.items | select(type == "array" and length == 1) | .[0] as $job |
		$pods.items | select(type == "array" and length == 1) | .[0] as $pod |
		select($job | job_contract) |
		select($pod | pod_contract($job.metadata.uid)) |
		$pod.status.containerStatuses[0].state.terminated.message
	')" || return 65

	payload_bytes="$(jq -e -r 'utf8bytelength' <<<"$payload_string" 2>/dev/null)" || {
		printf 'termination-invalid\n'
		return 65
	}
	[[ "$payload_bytes" =~ ^[0-9]+$ && "$payload_bytes" -le "$CONTRACT_DIAGNOSTIC_TERMINAL_MAX_BYTES" ]] || {
		printf 'termination-invalid\n'
		return 65
	}
	payload="$(jq -e -r '. as $raw | ($raw | fromjson | tojson) as $canonical | select($canonical == $raw) | $canonical' \
		<<<"$payload_string" 2>/dev/null)" || {
		printf 'termination-invalid\n'
		return 65
	}
	schema_reason="$(contract_diagnostics_terminal_schema_reason "$payload" "$run_id" '' "/out/runs/$run_id/diagnostics")" || {
		printf 'termination-invalid\n'
		return 65
	}
	[[ -z "$schema_reason" ]] || {
		printf 'termination-invalid\n'
		return 65
	}
	printf '%s\n' "$payload"
}
