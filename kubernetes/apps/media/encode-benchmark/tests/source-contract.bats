#!/usr/bin/env bats

setup() {
	PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)"
	app='kubernetes/apps/media/encode-benchmark/app'
	contract="$app/scripts/contract.sh"
	benchmark="$app/scripts/benchmark.sh"
	preflight="$PROJECT_ROOT/scripts/encode-benchmark/preflight.sh"
	template="$PROJECT_ROOT/kubernetes/apps/media/encode-benchmark/templates/job.yaml"
	fixtures='kubernetes/apps/media/encode-benchmark/tests/fixtures'
	samples="$app/samples.yaml"
	samples_json="$BATS_TEST_TMPDIR/samples.json"
	yq -r '.data."samples.json"' "$samples" >"$samples_json"
	export BENCHMARK_TEST_MODE=1
	export BENCHMARK_SAMPLES_FILE="$samples_json"
}

# D05: Parse the shipped Job and exercise the exact preflight boundary independently.
@test "quality Job and preflight preserve the exact finite non-root GPU safety contract" {
	local rendered stub_bin kubeconfig calls
	rendered="$BATS_TEST_TMPDIR/rendered.yaml"
	run kustomize build "$app"
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" >"$rendered"
	[ "$(yq -N -r 'select(.kind == "Job") | .metadata.name' "$rendered")" = '' ]
	[ "$(yq -N -r 'select(.kind == "PriorityClass") | [.metadata.name,.value,.preemptionPolicy] | @tsv' "$rendered" | sed '/^$/d')" = \
		$'encode-benchmark-background\t-10\tNever' ]
	[ "$(yq -N -r 'select(.kind == "ConfigMap") | .metadata.name' "$rendered" | wc -l | tr -d ' ')" -eq 2 ]

	run yq -o=json -I=0 '{
		"deadline": .spec.activeDeadlineSeconds,
		"backoff": .spec.backoffLimit,
		"ttl": .spec.ttlSecondsAfterFinished,
		"restart": .spec.template.spec.restartPolicy,
		"priority": .spec.template.spec.priorityClassName,
		"automount": .spec.template.spec.automountServiceAccountToken,
		"podSecurity": .spec.template.spec.securityContext,
		"containerSecurity": .spec.template.spec.containers[0].securityContext,
		"affinity": .spec.template.spec.affinity,
		"resources": .spec.template.spec.containers[0].resources,
		"mounts": [.spec.template.spec.containers[0].volumeMounts[] | select(.name != "media")],
		"volumes": [.spec.template.spec.volumes[] | select(.name != "media")]
	}' "$template"
	[ "$status" -eq 0 ]
	run jq -e '. == {
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
			{name:"scripts",configMap:{name:"encode-benchmark-scripts-d6ddc44bm8",defaultMode:555}},
			{name:"samples",configMap:{name:"encode-benchmark-samples",items:[{key:"samples.json",path:"samples.json"}]}},
			{name:"image-evidence",configMap:{name:"encode-benchmark-image-template",optional:true,
				items:[{key:"image.json",path:"image.json"}]}}]
	}' <<<"$output"
	[ "$status" -eq 0 ]

	stub_bin="$BATS_TEST_TMPDIR/preflight-bin"
	kubeconfig="$BATS_TEST_TMPDIR/preflight-kubeconfig"
	calls="$BATS_TEST_TMPDIR/preflight-calls"
	mkdir -p "$stub_bin"
	printf '%s\n' 'apiVersion: v1' >"$kubeconfig"
	: >"$calls"
	cat >"$stub_bin/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$PREFLIGHT_CALLS"
case "$*" in
*' config view '*) printf '%s\n' 'https://192.168.90.20:6443' ;;
*' get pods --selector app.kubernetes.io/name=plex '*)
	printf '%s\n' '{"items":[{"spec":{"nodeName":"nuc-plex"},"status":{"phase":"Running"}}]}' ;;
*' get pvc media-data '*) printf '%s\n' '{"status":{"phase":"Bound"}}' ;;
*' get kustomization encode-benchmark '*)
	printf '%s\n' '{"spec":{"suspend":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}' ;;
*' get nodes '*)
	printf '%s\n' '{"items":[{"metadata":{"name":"nuc-plex"},"status":{"allocatable":{"gpu.intel.com/i915":"1"}}},{"metadata":{"name":"nuc-below"},"status":{"allocatable":{"gpu.intel.com/i915":"1"}}},{"metadata":{"name":"nuc-boundary"},"status":{"allocatable":{"gpu.intel.com/i915":"1"}}}]}' ;;
*' get pods --all-namespaces '*) printf '%s\n' '{"items":[]}' ;;
*'/nodes/nuc-plex/'*) printf '%s\n' '{"node":{"fs":{"availableBytes":123480309760}}}' ;;
*'/nodes/nuc-below/'*) printf '%s\n' '{"node":{"fs":{"availableBytes":123480309759}}}' ;;
*'/nodes/nuc-boundary/'*) printf '%s\n' '{"node":{"fs":{"availableBytes":123480309760}}}' ;;
*) echo "unexpected preflight call: $*" >&2; exit 97 ;;
esac
STUB
	chmod +x "$stub_bin/kubectl"
	run env PATH="$stub_bin:$PATH" PREFLIGHT_CALLS="$calls" "$preflight" "$kubeconfig"
	[ "$status" -eq 0 ]
	[[ "$output" == *'nuc-plex FAIL plex-node'* ]]
	[[ "$output" == *'nuc-below FAIL free-nvme-below-115Gi'* ]]
	[[ "$output" == *'nuc-boundary PASS'* ]]
	[[ "$output" == *'eligible_nodes=1'* ]]
	run rg -n '(^| )(create|apply|patch|delete|exec)( |$)' "$calls"
	[ "$status" -eq 1 ]
}

# D06: The only source library projection is the read-only movies subtree.
@test "quality source visibility is one read-only movies mount" {
	run yq -o=json -I=0 '{
		"mounts":[.spec.template.spec.containers[0].volumeMounts[] |
			select(.name == "media" or (.mountPath | test("^/(media|tv|downloads|data)(/|$)")))],
		"volumes":[.spec.template.spec.volumes[] | select(.name == "media")]
	}' "$template"
	[ "$status" -eq 0 ]
	[ "$output" = '{"mounts":[{"name":"media","mountPath":"/media","subPath":"media/movies","readOnly":true}],"volumes":[{"name":"media","persistentVolumeClaim":{"claimName":"media-data"}}]}' ]
}

@test "shared contract returns only the four diagnosed VMAF exclusions" {
	run jq -e '
		.qualityCorrection.vmafMeasurementDefects == [
			{sampleId:"avc-clean-coco",clipId:"motion",frameIndex:1641},
			{sampleId:"avc-grain-memento",clipId:"dark",frameIndex:523},
			{sampleId:"avc-grain-memento",clipId:"detail",frameIndex:370},
			{sampleId:"vc1-fugitive",clipId:"motion",frameIndex:798}
		]
	' "$samples_json"
	[ "$status" -eq 0 ] || {
		echo "deployed correction array differs from the literal four-entry contract" >&3
		return 1
	}

	for identity in \
		'avc-clean-coco motion 1641' \
		'avc-grain-memento dark 523' \
		'avc-grain-memento detail 370' \
		'vc1-fugitive motion 798'; do
		read -r sample_id clip_id frame_index <<<"$identity"
		run bash -c 'source "$1"; contract_load "$2"; contract_quality_vmaf_exclusion "$2" "$3" "$4"' \
			_ "$contract" "$samples_json" "$sample_id" "$clip_id"
		[ "$status" -eq 0 ]
		[ "$output" = "$frame_index" ]
	done

	for identity in \
		'avc-clean-coco detail' \
		'vc1-fugitive detail' \
		'avc-* motion' \
		'missing-title motion'; do
		read -r sample_id clip_id <<<"$identity"
		run bash -c 'source "$1"; contract_load "$2"; contract_quality_vmaf_exclusion "$2" "$3" "$4"' \
			_ "$contract" "$samples_json" "$sample_id" "$clip_id"
		[ "$status" -eq 1 ]
		[ "$output" = "" ]
	done
}

@test "quality contract admits exactly eight ICQ settings" {
	run bash -c 'source "$1"; contract_load "$2"; printf "%s\n" "$CONTRACT_ICQ_SETTINGS"' \
		_ "$contract" "$samples_json"
	[ "$status" -eq 0 ]
	[ "$output" = '16 18 20 22 24 26 28 30' ]

	for setting in 16 18 20 22 24 26 28 30; do
		run bash -c 'source "$1"; contract_load "$2"; contract_is_icq_setting "$2" "$3"' \
			_ "$contract" "$samples_json" "$setting"
		[ "$status" -eq 0 ]
	done
	for setting in 14 15 17 19 21 23 25 27 29 31 32 -1 null; do
		run bash -c 'source "$1"; contract_load "$2"; contract_is_icq_setting "$2" "$3"' \
			_ "$contract" "$samples_json" "$setting"
		[ "$status" -eq 1 ]
	done

	run "$benchmark" _test runtime-selection-is-icq ICQ
	[ "$status" -eq 0 ]
	for selection in LA-ICQ LA_ICQ CQP CBR VBR AVBR QVBR unknown; do
		run "$benchmark" _test runtime-selection-is-icq "$selection"
		[ "$status" -eq 1 ] || {
			echo "runtime admitted non-ICQ selection: $selection" >&3
			return 1
		}
	done
	run "$benchmark" _test qsv-proof 0 \
		"$fixtures/logs/qsv-requested-la-fallback-cqp.log" \
		"$fixtures/logs/drm-fdinfo-active.log" 2160
	[ "$status" -eq 0 ]
	[ "$(jq -r '.selected_rate_control + ":" + .qsv_proof' <<<"$output")" = 'CQP:failed' ]

	for mutation in \
		'.strategy.globalQualityCandidates = [18, 16, 20, 22, 24, 26, 28, 30]' \
		'.strategy.globalQualityCandidates = [16, 18, 20, 22, 24, 26, 28]' \
		'.strategy.globalQualityCandidates = [16, 18, 20, 22, 24, 26, 28, 28]' \
		'.strategy.globalQualityCandidates = [16, 18, 20, 22.5, 24, 26, 28, 30]' \
		'.strategy.globalQualityCandidates = [16, 18, 20, 22, 24, 26, 28, 30, 32]'; do
		candidate="$BATS_TEST_TMPDIR/$(printf '%s' "$mutation" | sha256sum | awk '{print $1}').json"
		jq "$mutation" "$samples_json" >"$candidate"
		run bash -c 'source "$1"; contract_load "$2"' _ "$contract" "$candidate"
		[ "$status" -eq 65 ] || {
			echo "contract accepted non-canonical case: $mutation" >&3
			return 1
		}
	done
}

# Catches a production break where the app Kustomization reconciles a benchmark
# Job automatically or loses the deliberately background-only scheduling class.
