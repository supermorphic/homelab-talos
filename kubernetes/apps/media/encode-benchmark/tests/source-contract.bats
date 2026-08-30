#!/usr/bin/env bats

setup() {
	app='kubernetes/apps/media/encode-benchmark/app'
	contract="$app/scripts/contract.sh"
	samples="$app/samples.yaml"
	samples_json="$BATS_TEST_TMPDIR/samples.json"
	yq -r '.data."samples.json"' "$samples" >"$samples_json"
}

@test "embedded samples publish the exact ordered ICQ strategy contract" {
	run jq -e '
		.schemaVersion == 3 and
		.strategy == {
			id: "qsv-hevc-icq-v1",
			resultsSchemaVersion: 3,
			runManifestSchemaVersion: 2,
			capabilityProofSchemaVersion: 3,
			globalQualityCandidates: [16, 18, 20, 22, 24, 26, 28, 30]
		} and
		.runtime.capabilityStatus == "verified" and
		(.runtime.capabilityEvidence.nodes | length) == 2 and
		([.runtime.capabilityEvidence.nodes[].nodeName] == ["nuc1", "nuc3"]) and
		([.runtime.capabilityEvidence.nodes[] | .strategyId] | all(. == "qsv-hevc-icq-v1")) and
		([.runtime.capabilityEvidence.nodes[] | .proofSchemaVersion] | all(. == 3)) and
		([.runtime.capabilityEvidence.nodes[] | .initialization] | all(. == "passed")) and
		([.runtime.capabilityEvidence.nodes[] | .initializationReason] | all(. == "")) and
		([.runtime.capabilityEvidence.nodes[] | .renderNode] | all(. == "/dev/dri/renderD128")) and
		([.runtime.capabilityEvidence.nodes[] | .drmDriver] | all(. == "i915")) and
		([.runtime.capabilityEvidence.nodes[] | .selectedRateControl] | all(. == "ICQ")) and
		([.runtime.capabilityEvidence.nodes[] | .telemetryStatus] | all(. == "available")) and
		([.runtime.capabilityEvidence.nodes[] | .telemetryReason] | all(. == "")) and
		([.runtime.capabilityEvidence.nodes[] | .videoBusyNanoseconds] | all(. > 0)) and
		([.runtime.capabilityEvidence.nodes[] | .videoBusyPercent] | all(. > 0)) and
		([.runtime.capabilityEvidence.nodes[] | .encodeFps] | all(. > 0)) and
		([.runtime.capabilityEvidence.nodes[] | .encodeSpeed] | all(. > 0)) and
		([.runtime.capabilityEvidence.nodes[] | .decode] | all(. == "passed")) and
		([.runtime.capabilityEvidence.nodes[] | .vmaf] | all(. == "passed")) and
		([.runtime.capabilityEvidence.nodes[] | .proofStatus] | all(. == "passed")) and
		([.runtime.capabilityEvidence.nodes[] | .proofReasons] | all(. == "")) and
		([.runtime.capabilityEvidence.nodes[].verifiedAt] | all(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))) and
		([.runtime.capabilityEvidence.nodes[] | .configuredImageDigest] | all(. == "sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb")) and
		([.runtime.capabilityEvidence.nodes[] | .imageId] | all(. == "docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb"))
	' "$samples_json"
	[ "$status" -eq 0 ]
}

# Catches a committed capability record losing any exact runtime prerequisite
# needed by the retained quality evidence path.
@test "shared contract authorizes only exact passing quality diagnostic capabilities" {
	run bash -c 'source "$1"; contract_load "$2"; contract_passing_icq_nodes "$2"' \
		_ "$contract" "$samples_json"
	[ "$status" -eq 0 ]
	[ "$output" = $'nuc1\nnuc3' ]

	for mutation in \
		'.runtime.capabilityEvidence.nodes[0].diagnosticCapabilities.traceHeaders = "failed"' \
		'del(.runtime.capabilityEvidence.nodes[0].diagnosticCapabilities.libvmaf)' \
		'.runtime.capabilityEvidence.nodes[0].diagnosticCapabilities.ssim = true' \
		'.runtime.capabilityEvidence.nodes[0].diagnosticCapabilities.psnr = "unknown"' \
		'.runtime.capabilityEvidence.nodes[0].diagnosticCapabilities.bestEffortTimestampTime = "failed"' \
		'.runtime.capabilityEvidence.nodes[0].diagnosticCapabilities.packetDurationTime = "failed"' \
		'.runtime.capabilityEvidence.nodes[0].diagnosticCapabilities.keyFrame = "failed"' \
		'.runtime.capabilityEvidence.nodes[0].diagnosticCapabilities.pictType = "failed"' \
		'.runtime.capabilityEvidence.nodes[0].diagnosticCapabilities.unexpected = "passed"'; do
		candidate="$BATS_TEST_TMPDIR/diagnostic-$(printf '%s' "$mutation" | sha256sum | awk '{print $1}').json"
		jq "$mutation | .runtime.capabilityEvidence.nodes = [.runtime.capabilityEvidence.nodes[0]]" \
			"$samples_json" >"$candidate"
		run bash -c 'source "$1"; contract_load "$2"; contract_passing_icq_nodes "$2"' \
			_ "$contract" "$candidate"
		[ "$status" -eq 0 ]
		[ "$output" = '' ]
	done
}

# Catches any changed or duplicated source region in the committed six-title
# panel before the benchmark spends GPU time on a non-comparable experiment.
@test "embedded quality panel is the exact six-title three-region experiment" {
	run jq -e '
		[.qualityPanel[] | select(.detectionOnly != true) | {id,clips}] == [
			{id:"vc1-fugitive",clips:{detail:"01:15:00.000",dark:"00:35:00.000",motion:"01:20:00.000"}},
			{id:"avc-clean-coco",clips:{detail:"00:10:00.000",dark:"00:45:00.000",motion:"00:05:00.000"}},
			{id:"avc-grain-memento",clips:{detail:"00:23:00.000",dark:"00:38:00.000",motion:"01:15:30.000"}},
			{id:"hdr10-clean-ministry",clips:{detail:"01:04:15.000",dark:"01:19:15.000",motion:"00:29:15.000"}},
			{id:"hdr10-grain-goodfellas",clips:{detail:"01:06:25.000",dark:"00:36:55.000",motion:"00:40:45.000"}},
			{id:"hdr10-motion-john-wick-2",clips:{detail:"01:04:50.000",dark:"00:06:30.000",motion:"01:38:00.000"}}
		] and
		([.qualityPanel[] | select(.detectionOnly != true) | .id] | (length == 6) and ((unique | length) == 6)) and
		([.qualityPanel[] | select(.detectionOnly != true) | .clips | keys] | all(. == ["dark","detail","motion"])) and
		([.qualityPanel[] | select(.detectionOnly != true) | .clips | [.dark,.detail,.motion] | unique | length] | all(. == 3))
	' "$samples_json"
	[ "$status" -eq 0 ]
}

@test "shared base contract accepts a minimal quality samples document" {
	minimal="$BATS_TEST_TMPDIR/minimal-quality.json"
	jq -n --argjson strategy "$(jq -c '.strategy' "$samples_json")" \
		--argjson quality_correction "$(jq -c '.qualityCorrection' "$samples_json")" '
		{
			schemaVersion: 3,
			strategy: $strategy,
			qualityCorrection: $quality_correction,
			runtime: {
				image: "docker.io/linuxserver/ffmpeg@sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb"
			},
			qualityPanel: []
		}
	' >"$minimal"

	run bash -c 'source "$1"; contract_load "$2"' _ "$contract" "$minimal"
	[ "$status" -eq 0 ]
}

# Catches accepting a configuration that has the right values but changes their
# order, cardinality, or integer representation, which would make benchmark
# evidence non-comparable across producers.
@test "shared contract rejects every non-canonical ICQ candidate list" {
	for mutation in \
		'.strategy.globalQualityCandidates = [18, 16, 20, 22, 24, 26, 28, 30]' \
		'.strategy.globalQualityCandidates = [16, 18, 20, 22, 24, 26, 28]' \
		'.strategy.globalQualityCandidates = [16, 18, 20, 22, 24, 26, 28, 28]' \
		'.strategy.globalQualityCandidates = [16, 18, 20, 22.5, 24, 26, 28, 30]' \
		'.strategy.globalQualityCandidates = [16, 18, 20, 22, 24, 26, 28, 30, 32]'; do
		candidate="$BATS_TEST_TMPDIR/$(printf '%s' "$mutation" | sha256sum | awk '{print $1}').json"
		jq "$mutation" "$samples_json" >"$candidate"
		run bash -c 'source "$1"; contract_load "$2"' _ "$contract" "$candidate"
		[ "$status" -eq 65 ]
	done
}

# Catches a quality worker excluding a frame outside the closed source contract
# or treating an absent identity as an accepted empty response.
@test "shared contract returns only the four diagnosed VMAF exclusions" {
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

@test "shared contract admits only the canonical ICQ settings" {
	for setting in 16 18 30; do
		run bash -c 'source "$1"; contract_load "$2"; contract_is_icq_setting "$2" "$3"' \
			_ "$contract" "$samples_json" "$setting"
		[ "$status" -eq 0 ]
	done
	for setting in 14 17 32; do
		run bash -c 'source "$1"; contract_load "$2"; contract_is_icq_setting "$2" "$3"' \
			_ "$contract" "$samples_json" "$setting"
		[ "$status" -eq 1 ]
	done
}

# Catches a production break where the app Kustomization reconciles a benchmark
# Job automatically or loses the deliberately background-only scheduling class.
@test "Flux renders inert resources but no Job" {
	run kustomize build kubernetes/apps/media/encode-benchmark/app
	[ "$status" -eq 0 ]
	[ "$(yq -r 'select(.kind == "Job") | .metadata.name' <<<"$output")" = "" ]
	[ "$(yq -r 'select(.kind == "PriorityClass") | .value' <<<"$output")" = "-10" ]
}

# Catches a production break where the render-only Job can traverse the shared
# PVC outside the movies subtree or can mutate the movie library.
@test "template cannot see TV or downloads and movies are read-only" {
	template=kubernetes/apps/media/encode-benchmark/templates/job.yaml
	[ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "media") | .persistentVolumeClaim.claimName' "$template")" = media-data ]
	[ "$(yq -r '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "media") | .readOnly' "$template")" = true ]
	[ "$(yq -r '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "media") | .mountPath' "$template")" = /media ]
	[ "$(yq -r '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "media") | .subPath' "$template")" = media/movies ]
	! rg -n '/data|media/tv|downloads' "$template"
}

# Catches every rendered benchmark Job inheriting Kubernetes API credentials
# even though none of the runtime commands needs in-cluster API access.
@test "template disables automatic service account token mounting" {
	template=kubernetes/apps/media/encode-benchmark/templates/job.yaml
	[ "$(yq -r '.spec.template.spec.automountServiceAccountToken' "$template")" = false ]
}

# Catches a dispatcher-only image check that gives the benchmark process no
# immutable, read-only pre-work evidence to parse before GPU work starts.
@test "template projects optional running-image evidence read-only" {
	template=kubernetes/apps/media/encode-benchmark/templates/job.yaml
	[ "$(yq -r '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "image-evidence") | .mountPath' "$template")" = /provenance ]
	[ "$(yq -r '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "image-evidence") | .readOnly' "$template")" = true ]
	[ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "image-evidence") | .configMap.optional' "$template")" = true ]
	[ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "image-evidence") | .configMap.items[0] | [.key,.path] | @tsv' "$template")" = $'image.json\timage.json' ]
}

# One focused, independent projection protects the complete retained quality
# Job contract. Dispatch tests separately prove dynamic substitutions.
@test "template preserves the exact quality Job safety and projection contract" {
	template=kubernetes/apps/media/encode-benchmark/templates/job.yaml
	run yq -o=json -I=0 '
		{
			"ttl": .spec.ttlSecondsAfterFinished,
			"podSecurity": .spec.template.spec.securityContext,
			"containerSecurity": .spec.template.spec.containers[0].securityContext,
			"affinity": .spec.template.spec.affinity,
			"resources": .spec.template.spec.containers[0].resources,
			"outMount": (.spec.template.spec.containers[0].volumeMounts[] | select(.name == "out")),
			"outVolume": (.spec.template.spec.volumes[] | select(.name == "out")),
			"scratchMount": (.spec.template.spec.containers[0].volumeMounts[] | select(.name == "scratch")),
			"scratchVolume": (.spec.template.spec.volumes[] | select(.name == "scratch")),
			"scriptsMount": (.spec.template.spec.containers[0].volumeMounts[] | select(.name == "scripts")),
			"scriptsVolume": (.spec.template.spec.volumes[] | select(.name == "scripts")),
			"samplesMount": (.spec.template.spec.containers[0].volumeMounts[] | select(.name == "samples")),
			"samplesVolume": (.spec.template.spec.volumes[] | select(.name == "samples")),
			"imageEvidenceMount": (.spec.template.spec.containers[0].volumeMounts[] | select(.name == "image-evidence")),
			"imageEvidenceVolume": (.spec.template.spec.volumes[] | select(.name == "image-evidence"))
		}
	' "$template"
	[ "$status" -eq 0 ]
	run jq -e '
		. == {
			ttl:86400,
			podSecurity:{runAsNonRoot:true,runAsUser:568,runAsGroup:568,fsGroup:568,fsGroupChangePolicy:"OnRootMismatch",seccompProfile:{type:"RuntimeDefault"}},
			containerSecurity:{allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]}},
			affinity:{podAntiAffinity:{requiredDuringSchedulingIgnoredDuringExecution:[{topologyKey:"kubernetes.io/hostname",labelSelector:{matchExpressions:[{key:"app.kubernetes.io/name",operator:"In",values:["plex"]}]}}]}},
			resources:{requests:{cpu:2,memory:"2Gi","ephemeral-storage":"105Gi","gpu.intel.com/i915":1},limits:{cpu:8,memory:"8Gi","ephemeral-storage":"110Gi","gpu.intel.com/i915":1}},
			outMount:{name:"out",mountPath:"/out",subPath:"benchmark"},
			outVolume:{name:"out",persistentVolumeClaim:{claimName:"media-data"}},
			scratchMount:{name:"scratch",mountPath:"/scratch"},
			scratchVolume:{name:"scratch",emptyDir:{sizeLimit:"105Gi"}},
			scriptsMount:{name:"scripts",mountPath:"/scripts",readOnly:true},
			scriptsVolume:{name:"scripts",configMap:{name:"encode-benchmark-scripts-d6ddc44bm8",defaultMode:555}},
			samplesMount:{name:"samples",mountPath:"/config/samples.json",subPath:"samples.json",readOnly:true},
			samplesVolume:{name:"samples",configMap:{name:"encode-benchmark-samples",items:[{key:"samples.json",path:"samples.json"}]}},
			imageEvidenceMount:{name:"image-evidence",mountPath:"/provenance",readOnly:true},
			imageEvidenceVolume:{name:"image-evidence",configMap:{name:"encode-benchmark-image-template",optional:true,items:[{key:"image.json",path:"image.json"}]}}
		}
	' <<<"$output"
	[ "$status" -eq 0 ]
}

# Catches a pre-work handoff that trusts one of the three image identities or
# waits forever for a missing projected ConfigMap.
@test "runtime requires configured dispatched and running image equality within its deadline" {
	benchmark="$app/scripts/benchmark.sh"
	digest='sha256:4a4ed3a9242b51ab7821c611b4101a6a7dd72517f7f19e3a7b1833cae5020ecb'
	image="docker.io/linuxserver/ffmpeg@$digest"
	evidence="$BATS_TEST_TMPDIR/image.json"
	jq -n --arg image "$image" '{configuredImage:$image,dispatchedImage:$image,imageId:$image}' >"$evidence"

	run env BENCHMARK_TEST_MODE=1 BENCHMARK_SAMPLES_FILE="$samples_json" \
		BENCHMARK_DISPATCH_IMAGE="$image" BENCHMARK_RUNNING_IMAGE_FILE="$evidence" \
		BENCHMARK_RUNNING_IMAGE_WAIT_SECONDS=0 "$benchmark" _test running-image-evidence
	[ "$status" -eq 0 ]
	[ "$output" = "running_image_evidence=accepted image_id=$image" ]

	jq --arg bad 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
		'.imageId = $bad' "$evidence" >"$evidence.tmp"
	mv "$evidence.tmp" "$evidence"
	run env BENCHMARK_TEST_MODE=1 BENCHMARK_SAMPLES_FILE="$samples_json" \
		BENCHMARK_DISPATCH_IMAGE="$image" BENCHMARK_RUNNING_IMAGE_FILE="$evidence" \
		BENCHMARK_RUNNING_IMAGE_WAIT_SECONDS=0 "$benchmark" _test running-image-evidence
	[ "$status" -ne 0 ]
	[[ "$output" == *'running image evidence is malformed or inconsistent'* ]]

	rm -f "$evidence"
	run env BENCHMARK_TEST_MODE=1 BENCHMARK_SAMPLES_FILE="$samples_json" \
		BENCHMARK_DISPATCH_IMAGE="$image" BENCHMARK_RUNNING_IMAGE_FILE="$evidence" \
		BENCHMARK_RUNNING_IMAGE_WAIT_SECONDS=0 "$benchmark" _test running-image-evidence
	[ "$status" -ne 0 ]
	[[ "$output" == *'timed out waiting for running image evidence'* ]]
}

# Catches quality moving the repeated node proof after source hashing.
@test "GPU proof precedes quality source or run work" {
	benchmark="$app/scripts/benchmark.sh"
	fixture_root="$BATS_TEST_DIRNAME/fixtures/logs"
	stub_bin="$BATS_TEST_TMPDIR/order-bin"
	order_log="$BATS_TEST_TMPDIR/order.log"
	mode_samples="$BATS_TEST_TMPDIR/order-samples.json"
	media="$BATS_TEST_TMPDIR/source.mkv"
	out="$BATS_TEST_TMPDIR/out"
	scratch="$BATS_TEST_TMPDIR/scratch"
	mkdir -p "$stub_bin" "$out/runs" "$scratch"
	printf 'fixture' >"$media"
	jq --arg path "$media" '
		(.qualityPanel[] | .path) = $path |
		(.qualityPanel[] | .sizeBytes) = 7 |
		(.qualityPanel[] | .sha256) = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	' "$samples_json" >"$mode_samples"

	cat >"$stub_bin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ffmpeg\t%s\n' "$*" >>"$BENCHMARK_ORDER_LOG"
case "$*" in
*'-hide_banner -encoders'*) printf '%s\n' ' V..... hevc_qsv'; exit 0 ;;
*'-hide_banner -filters'*) printf '%s\n' ' ... libvmaf'; exit 0 ;;
*'-version'*) printf '%s\n' 'ffmpeg version 8.1.2 fixture'; exit 0 ;;
esac
if [[ "$*" == *'nullsrc=size=16x16:rate=1'* ]]; then
	sed -n '1,$p' "$BENCHMARK_CAPABILITY_INITIALIZATION_FIXTURE" >&2
elif [[ "$*" == *'-c:v hevc_qsv'* ]]; then
	sed -n '1,$p' "$BENCHMARK_CAPABILITY_ENCODE_FIXTURE" >&2
fi
last="${!#}"
if [[ "$last" != '-' && "$last" != '/dev/null' ]]; then
	mkdir -p "$(dirname "$last")"
	printf fixture >"$last"
fi
EOF
	cat >"$stub_bin/ffprobe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ffprobe\t%s\n' "$*" >>"$BENCHMARK_ORDER_LOG"
[[ "${1:-}" == '-version' ]] || exit 97
printf '%s\n' 'ffprobe version 8.1.2 fixture'
EOF
	cat >"$stub_bin/id" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == '-u' ]] || exit 97
printf '%s\n' 568
EOF
	cat >"$stub_bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sha256sum\t%s\n' "$*" >>"$BENCHMARK_ORDER_LOG"
printf '%064d  %s\n' 0 "${1:-stdin}"
EOF
	chmod +x "$stub_bin/ffmpeg" "$stub_bin/ffprobe" "$stub_bin/id" "$stub_bin/sha256sum"
	image="$(jq -r '.runtime.image' "$mode_samples")"
	export BENCHMARK_ORDER_LOG="$order_log"
	export BENCHMARK_CAPABILITY_ENCODE_FIXTURE="$fixture_root/qsv-icq.log"
	export BENCHMARK_CAPABILITY_INITIALIZATION_FIXTURE="$fixture_root/qsv-init-success-no-phrase.log"
	export BENCHMARK_TEST_FDINFO_FIXTURE="$fixture_root/drm-fdinfo-active.log"

	: >"$order_log"
	run env PATH="$stub_bin:$PATH" BENCHMARK_TEST_MODE=1 BENCHMARK_OUT="$out" \
		BENCHMARK_SCRATCH="$scratch" BENCHMARK_SAMPLES_FILE="$mode_samples" \
		BENCHMARK_DISPATCH_IMAGE="$image" BENCHMARK_RUNNING_IMAGE="$image" \
		BENCHMARK_ORDER_LOG="$order_log" NODE_NAME=nuc1 \
		BENCHMARK_CAPABILITY_ENCODE_FIXTURE="$BENCHMARK_CAPABILITY_ENCODE_FIXTURE" \
		BENCHMARK_CAPABILITY_INITIALIZATION_FIXTURE="$BENCHMARK_CAPABILITY_INITIALIZATION_FIXTURE" \
		BENCHMARK_TEST_FDINFO_FIXTURE="$BENCHMARK_TEST_FDINFO_FIXTURE" "$benchmark" quality
	[ "$status" -ne 0 ]
	[[ "$output" == *'sample hash mismatch'* ]]
	awk -F '\t' '
		$1 == "ffmpeg" {proof = NR}
		$1 == "sha256sum" && !hash {hash = NR}
		END {exit !(proof > 0 && hash > proof)}
	' "$order_log"
	[ "$(find "$out/runs" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 0 ]
}
