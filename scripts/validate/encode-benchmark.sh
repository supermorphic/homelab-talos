#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/media/encode-benchmark'
app="$base/app"
ks="$base/ks.yaml"
kustomization="$app/kustomization.yaml"
priority="$app/priorityclass.yaml"
samples="$app/samples.yaml"
# The rule lives in the media alerts application; placement and wiring belong to
# `just kube alerts-validate media`. The content contract stays here.
alerts='kubernetes/apps/media/alerts/app/encode-benchmark.yaml'
scaffold="$app/scripts/not-ready.sh"
contract="$app/scripts/contract.sh"
probe="$app/scripts/probe.sh"
census="$app/scripts/census.sh"
runmeta="$app/scripts/runmeta.sh"
benchmark="$app/scripts/benchmark.sh"
stills="$app/scripts/stills.sh"
template="$base/templates/job.yaml"
tests_dir="$base/tests"
contract_test="$tests_dir/source-contract.bats"
census_test="$tests_dir/census.bats"
runmeta_test="$tests_dir/runmeta.bats"
benchmark_test="$tests_dir/benchmark.bats"
stills_test="$tests_dir/stills.bats"
dispatch_test="$tests_dir/dispatch.bats"
selection_test="$tests_dir/selection.bats"
inventory='scripts/encode-benchmark/torrent-inventory.py'
preflight_helper='scripts/encode-benchmark/preflight.sh'
dispatch_helper='scripts/encode-benchmark/dispatch.sh'
results_helper='scripts/encode-benchmark/results.sh'
selection_helper='scripts/encode-benchmark/select-samples.sh'
live_verifier='scripts/verify/encode-benchmark.sh'
validator='scripts/validate/encode-benchmark.sh'
media_kustomization='kubernetes/apps/media/kustomization.yaml'
temp_dir="$(mktemp -d /tmp/homelab-talos-encode-benchmark-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT
render="$temp_dir/render.yaml"
conform="$temp_dir/conform.yaml"

fail() {
	echo "encode-benchmark validation failed: $*" >&2
	exit 1
}

assert_eq() {
	local actual="$1"
	local expected="$2"
	local contract="$3"
	[[ "$actual" == "$expected" ]] ||
		fail "$contract (expected '$expected', got '$actual')"
}

for file in \
	"$ks" \
	"$kustomization" \
	"$priority" \
	"$samples" \
	"$alerts" \
	"$contract" \
	"$probe" \
	"$census" \
	"$runmeta" \
	"$benchmark" \
	"$stills" \
	"$template" \
	"$contract_test" \
	"$census_test" \
	"$runmeta_test" \
	"$benchmark_test" \
	"$stills_test" \
	"$dispatch_test" \
	"$selection_test" \
	"$inventory" \
	"$preflight_helper" \
	"$dispatch_helper" \
	"$results_helper" \
	"$selection_helper" \
	"$live_verifier" \
	"$validator" \
	"$media_kustomization"; do
	[[ -f "$file" ]] || fail "missing required source: $file"
done
[[ ! -e "$scaffold" ]] || fail "$scaffold must be removed once all five scripts are real"
[[ -x "$contract" ]] || fail "$contract must be executable"
[[ -x "$probe" ]] || fail "$probe must be executable"
[[ -x "$census" ]] || fail "$census must be executable"
[[ -x "$runmeta" ]] || fail "$runmeta must be executable"
[[ -x "$benchmark" ]] || fail "$benchmark must be executable"
[[ -x "$stills" ]] || fail "$stills must be executable"
[[ -x "$inventory" ]] || fail "$inventory must be executable"
[[ -x "$preflight_helper" ]] || fail "$preflight_helper must be executable"
[[ -x "$dispatch_helper" ]] || fail "$dispatch_helper must be executable"
[[ -x "$results_helper" ]] || fail "$results_helper must be executable"
[[ -x "$selection_helper" ]] || fail "$selection_helper must be executable"
[[ -x "$live_verifier" ]] || fail "$live_verifier must be executable"

if rg -n 'not-ready[.]sh' "$kustomization" "$app/scripts"; then
	fail 'a not-ready scaffold mapping or implementation remains'
fi

# Flux must reconcile only this suspended, inert child and must keep its dependency graph.
assert_eq "$(yq -r '.metadata.name' "$ks")" 'encode-benchmark' 'Flux child name'
assert_eq "$(yq -r '.metadata.namespace' "$ks")" 'flux-system' 'Flux child namespace'
assert_eq "$(yq -r '.spec.path' "$ks")" \
	'./kubernetes/apps/media/encode-benchmark/app' 'Flux child path'
assert_eq "$(yq -r '[.spec.dependsOn[].name] | join(",")' "$ks")" \
	'media-storage,intel-gpu-plugin,qbit-manage' \
	'Flux dependency order'
assert_eq "$(yq -r '.spec.interval' "$ks")" '1h' 'Flux interval'
assert_eq "$(yq -r '.spec.prune' "$ks")" 'true' 'Flux prune setting'
assert_eq "$(yq -r '.spec.retryInterval' "$ks")" '1m' 'Flux retry interval'
assert_eq "$(yq -r '.spec.sourceRef.kind' "$ks")" 'GitRepository' 'Flux source kind'
assert_eq "$(yq -r '.spec.sourceRef.name' "$ks")" 'flux-system' 'Flux source name'
assert_eq "$(yq -r '.spec.sourceRef.namespace' "$ks")" 'flux-system' 'Flux source namespace'
assert_eq "$(yq -r '.spec.timeout' "$ks")" '10m' 'Flux timeout'
assert_eq "$(yq -r '.spec.wait' "$ks")" 'true' 'Flux wait setting'
suspend_state="$(yq -r '.spec.suspend' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]] ||
	fail 'Flux spec.suspend must be an explicit boolean'

storage_index="$(yq -r '.resources | to_entries | .[] | select(.value == "./storage/ks.yaml") | .key' "$media_kustomization")"
benchmark_index="$(yq -r '.resources | to_entries | .[] | select(.value == "./encode-benchmark/ks.yaml") | .key' "$media_kustomization")"
[[ "$storage_index" != 'null' && "$benchmark_index" != 'null' ]] ||
	fail 'Flux child is not registered in the media Kustomization'
((benchmark_index == storage_index + 1)) ||
	fail 'Flux child must be registered immediately after media storage'

# The app render contains only inert inputs. The Job remains a parsed, non-reconciled template.
assert_eq "$(yq -r '[.resources[]] | join(",")' "$kustomization")" \
	'./priorityclass.yaml,./samples.yaml' 'inert app resources'
assert_eq "$(yq -r '.configMapGenerator | length' "$kustomization")" '1' \
	'scripts ConfigMap generator count'
assert_eq "$(yq -r '.configMapGenerator[0].name' "$kustomization")" \
	'encode-benchmark-scripts' 'scripts ConfigMap generator name'
expected_mappings='contract.sh=scripts/contract.sh,probe.sh=scripts/probe.sh,census.sh=scripts/census.sh,runmeta.sh=scripts/runmeta.sh,benchmark.sh=scripts/benchmark.sh,stills.sh=scripts/stills.sh'
assert_eq "$(yq -r '.configMapGenerator[0].files | join(",")' "$kustomization")" \
	"$expected_mappings" 'structural command mappings'
assert_eq "$(yq -r '.generatorOptions.labels."app.kubernetes.io/name"' "$kustomization")" \
	'encode-benchmark' 'generated ConfigMap app label'
if mise exec -- rg -l 'templates/job\.yaml' "$base" --glob 'kustomization.yaml' >/dev/null; then
	fail 'the render-only Job template is listed by a Kustomization'
fi

kustomize build "$app" >"$render"
cp "$render" "$conform"
printf '\n---\n' >>"$conform"
mise exec -- sed -n "1,\$p" "$template" >>"$conform"
kubeconform -strict -summary -ignore-missing-schemas "$conform"

[[ -z "$(yq -r 'select(.kind == "Job") | .metadata.name' "$render")" ]] ||
	fail 'the inert Flux render unexpectedly contains a Job'
rendered_kinds="$(yq -N -r '.kind' "$render" | sort | tr '\n' ',')"
assert_eq "$rendered_kinds" 'ConfigMap,ConfigMap,PriorityClass,' \
	'inert rendered resource kinds'

scripts_name="$(yq -r 'select(.kind == "ConfigMap" and (.metadata.name | test("^encode-benchmark-scripts-"))) | .metadata.name' "$render")"
[[ "$scripts_name" =~ ^encode-benchmark-scripts-[a-z0-9]{10}$ ]] ||
	fail "rendered scripts ConfigMap is not hash-suffixed: $scripts_name"
scripts_keys="$(yq -r 'select(.kind == "ConfigMap" and (.metadata.name | test("^encode-benchmark-scripts-"))) | .data | keys | sort | join(",")' "$render")"
assert_eq "$scripts_keys" 'benchmark.sh,census.sh,contract.sh,probe.sh,runmeta.sh,stills.sh' \
	'rendered scripts ConfigMap command keys'

# Scheduling and alerting remain present even though execution is absent.
assert_eq "$(yq -r '.kind' "$priority")" 'PriorityClass' 'priority class kind'
assert_eq "$(yq -r '.metadata.name' "$priority")" \
	'encode-benchmark-background' 'priority class name'
assert_eq "$(yq -r '.value' "$priority")" '-10' 'background priority value'
assert_eq "$(yq -r '.globalDefault' "$priority")" 'false' 'global priority default'
assert_eq "$(yq -r '.preemptionPolicy' "$priority")" 'Never' 'preemption policy'

assert_eq "$(yq -r '.kind' "$alerts")" 'PrometheusRule' 'alert resource kind'
assert_eq "$(yq -r '.metadata.name' "$alerts")" 'encode-benchmark' 'alert resource name'
assert_eq "$(yq -r '.spec.groups[0].rules | length' "$alerts")" '2' 'alert rule count'
for alert in EncodeBenchmarkJobFailed EncodeBenchmarkJobCompleted; do
	rule="$(yq -o=json -I=0 ".spec.groups[0].rules[] | select(.alert == \"$alert\")" "$alerts")"
	[[ -n "$rule" ]] || fail "missing alert $alert"
	assert_eq "$(yq -p=json -r '.for' <<<"$rule")" '1m' "$alert hold time"
	assert_eq "$(yq -p=json -r '.labels.severity' <<<"$rule")" 'warning' "$alert severity"
	yq -p=json -r '[.annotations.summary, .annotations.description] | join(" ")' <<<"$rule" |
		rg -Fq '{{ $labels.job_name }}' || fail "$alert annotations must name the Job"
	yq -p=json -r '.annotations.description' <<<"$rule" |
		rg -Fq 'mise exec -- just kube encode-benchmark-results <run-id>' ||
		fail "$alert must direct the operator to the guarded results recipe"
done
failed_expr="$(yq -r '.spec.groups[0].rules[] | select(.alert == "EncodeBenchmarkJobFailed") | .expr' "$alerts" | tr -d '[:space:]')"
completed_expr="$(yq -r '.spec.groups[0].rules[] | select(.alert == "EncodeBenchmarkJobCompleted") | .expr' "$alerts" | tr -d '[:space:]')"
assert_eq "$failed_expr" \
	'kube_job_status_failed{namespace="media",job_name=~"encode-benchmark-.*"}>0' \
	'failed Job alert expression'
assert_eq "$completed_expr" \
	'kube_job_status_succeeded{namespace="media",job_name=~"encode-benchmark-.*"}>0' \
	'completed Job alert expression'

# Parse the embedded panel document and gate evidence before any source media is runnable.
samples_doc="$(yq -r '.data."samples.json"' "$samples")"
assert_eq "$(yq -r '.schemaVersion' <<<"$samples_doc")" '2' 'samples schema version'
jq -e '
	.schemaVersion == 2 and
	.strategy == {
		id: "qsv-hevc-icq-v1",
		resultsSchemaVersion: 2,
		runManifestSchemaVersion: 2,
		capabilityProofSchemaVersion: 3,
		globalQualityCandidates: [16, 18, 20, 22, 24, 26, 28, 30],
		x265: {initialCrfs: [18, 20, 22, 24], minimumCrf: 10, maximumCrf: 34, step: 2}
	}
' <<<"$samples_doc" >/dev/null || fail 'samples must publish the exact ICQ strategy contract'
assert_eq "$(yq -r '.savingsSeed' <<<"$samples_doc")" '20260802' 'savings selection seed'
runtime_image="$(yq -r '.runtime.image' <<<"$samples_doc")"
[[ "$runtime_image" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] ||
	fail "runtime image must use an immutable SHA-256 digest: $runtime_image"
capability_status="$(yq -r '.runtime.capabilityStatus' <<<"$samples_doc")"
[[ "$capability_status" == 'pending' || "$capability_status" == 'verified' ]] ||
	fail 'runtime capabilityStatus must be pending or verified'

quality_count="$(yq -r '.qualityPanel | length' <<<"$samples_doc")"
savings_count="$(yq -r '.savingsPanel | length' <<<"$samples_doc")"
if [[ "$capability_status" == 'verified' ]]; then
	configured_digest="${runtime_image##*@}"
	jq -e --arg digest "$configured_digest" '
		def reasons:
			[]
			+ (if .initialization == "passed" then [] else ["initialization"] end)
			+ (if .selectedRateControl == "LA-ICQ" then [] else ["rate-control"] end)
			+ (if .telemetryStatus == "available" and .videoBusyNanoseconds > 0 then [] else ["telemetry"] end)
			+ (if .encodeSpeed > 0 then [] else ["progress"] end)
			+ (if .decode == "passed" then [] else ["decode"] end)
			+ (if .vmaf == "passed" then [] else ["vmaf"] end);
		def expected_status:
			if .telemetryStatus != "available" then "harness-blocked"
			elif (reasons | length) == 0 then "passed"
			else "failed" end;
		def valid_node:
			type == "object" and
			(keys == ["configuredImageDigest","decode","encodeFps","encodeSpeed","imageId","initialization","nodeName","proofReasons","proofSchemaVersion","proofStatus","selectedRateControl","telemetryReason","telemetryStatus","verifiedAt","videoBusyNanoseconds","videoBusyPercent","vmaf"]) and
			.proofSchemaVersion == 2 and
			(.nodeName | type == "string" and test("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$")) and
			(.initialization == "passed" or .initialization == "failed") and
			(.selectedRateControl | type == "string") and
			(.telemetryStatus == "available" or .telemetryStatus == "harness-blocked") and
			(.telemetryReason | type == "string") and
			((.telemetryStatus == "available" and .telemetryReason == "") or
				(.telemetryStatus == "harness-blocked" and (.telemetryReason | length) > 0)) and
			(.videoBusyNanoseconds | type == "number" and . >= 0) and
			(.videoBusyPercent | type == "number" and . >= 0) and
			(.encodeFps | type == "number" and . >= 0) and
			(.encodeSpeed | type == "number" and . >= 0) and
			(.decode == "passed" or .decode == "failed") and
			(.vmaf == "passed" or .vmaf == "failed") and
			.proofStatus == expected_status and
			.proofReasons == (reasons | join(";")) and
			(.verifiedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
			.configuredImageDigest == $digest and
			(.imageId | type == "string" and test("^([^@[:space:]]+@)?sha256:[0-9a-f]{64}$") and (sub("^.*@"; "") == $digest));
		.runtime.capabilityEvidence
		| (keys == ["nodes"]) and
		  (.nodes | type == "array" and length > 0 and all(.[]; valid_node) and
			([.[].nodeName] | unique | length) == length)
	' <<<"$samples_doc" >/dev/null ||
		fail 'verified capability evidence must contain unique valid schema-v2 node records'
else
	jq -e '
		.runtime.capabilityEvidence |
		((has("nodes") | not) or (.nodes | type == "array" and length == 0))
	' <<<"$samples_doc" >/dev/null ||
		fail 'pending capability evidence must not claim schema-v2 node proof'
fi

declare -A seen_sample_ids=()
validate_sample() {
	local sample_json="$1"
	local panel="$2"
	local sample_id cohort path size width height sha
	sample_id="$(yq -p=json -r '.id // ""' <<<"$sample_json")"
	cohort="$(yq -p=json -r '.cohort // ""' <<<"$sample_json")"
	path="$(yq -p=json -r '.path // ""' <<<"$sample_json")"
	size="$(yq -p=json -r '.sizeBytes // 0' <<<"$sample_json")"
	width="$(yq -p=json -r '.width // 0' <<<"$sample_json")"
	height="$(yq -p=json -r '.height // 0' <<<"$sample_json")"
	sha="$(yq -p=json -r '.sha256 // ""' <<<"$sample_json")"

	[[ "$sample_id" =~ ^[a-z0-9][a-z0-9._-]*$ ]] ||
		fail "$panel sample has an invalid id: $sample_id"
	[[ -z "${seen_sample_ids[$sample_id]:-}" ]] ||
		fail "sample id is duplicated across panels: $sample_id"
	seen_sample_ids[$sample_id]=1
	[[ "$cohort" =~ ^(avc|vc1|hdr10|dolby-vision)$ ]] ||
		fail "$sample_id has an unsupported cohort: $cohort"
	[[ "$path" =~ ^/media/.+ ]] ||
		fail "$sample_id path must be an absolute descendant of /media/: $path"
	[[ ! "$path" =~ (^|/)\.\.(/|$) ]] ||
		fail "$sample_id path must not escape /media with '..': $path"
	[[ "$size" =~ ^[1-9][0-9]*$ ]] || fail "$sample_id sizeBytes must be positive"
	[[ "$width" =~ ^[1-9][0-9]*$ ]] || fail "$sample_id width must be positive"
	[[ "$height" =~ ^[1-9][0-9]*$ ]] || fail "$sample_id height must be positive"
	[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || fail "$sample_id sha256 must contain 64 lowercase hex characters"
}

if ((quality_count != 0)); then
	assert_eq "$quality_count" '7' 'quality panel sample count'
	detection_count=0
	while IFS= read -r sample_json; do
		validate_sample "$sample_json" 'qualityPanel'
		sample_id="$(yq -p=json -r '.id' <<<"$sample_json")"
		cohort="$(yq -p=json -r '.cohort' <<<"$sample_json")"
		detection_only="$(yq -p=json -r '.detectionOnly // false' <<<"$sample_json")"
		if [[ "$detection_only" == 'true' ]]; then
			((detection_count += 1))
			assert_eq "$cohort" 'dolby-vision' "$sample_id detection-only cohort"
			assert_eq "$(yq -p=json -r '.clips | length' <<<"$sample_json")" '0' \
				"$sample_id detection-only clips"
			continue
		fi
		[[ "$cohort" != 'dolby-vision' ]] ||
			fail "$sample_id Dolby Vision source must be detection-only"
		assert_eq "$(yq -p=json -r '.clips | length' <<<"$sample_json")" '3' \
			"$sample_id quality clip count"
		clip_keys="$(yq -p=json -r '.clips | keys | sort | join(",")' <<<"$sample_json")"
		assert_eq "$clip_keys" 'dark,detail,motion' "$sample_id quality clip names"
		timestamps="$(yq -p=json -r '.clips | [.detail, .dark, .motion] | .[]' <<<"$sample_json")"
		while IFS= read -r timestamp; do
			[[ "$timestamp" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}$ ]] ||
				fail "$sample_id has an invalid clip timestamp: $timestamp"
		done <<<"$timestamps"
		assert_eq "$(sort -u <<<"$timestamps" | wc -l | tr -d ' ')" '3' \
			"$sample_id distinct quality clip timestamps"
	done < <(yq -o=json -I=0 '.qualityPanel[]' <<<"$samples_doc")
	assert_eq "$detection_count" '1' 'detection-only Dolby Vision sample count'
fi

if ((savings_count != 0)); then
	while IFS= read -r sample_json; do
		validate_sample "$sample_json" 'savingsPanel'
		assert_eq "$(yq -p=json -r '.detectionOnly // false' <<<"$sample_json")" 'false' \
			'savings sample detection-only setting'
		cohort="$(yq -p=json -r '.cohort' <<<"$sample_json")"
		[[ "$cohort" =~ ^(avc|vc1|hdr10)$ ]] ||
			fail "savingsPanel contains a non-major cohort: $cohort"
	done < <(yq -o=json -I=0 '.savingsPanel[]' <<<"$samples_doc")
	for cohort in avc vc1 hdr10; do
		cohort_count="$(yq -r "[.savingsPanel[] | select(.cohort == \"$cohort\")] | length" <<<"$samples_doc")"
		((cohort_count >= 6 && cohort_count <= 10)) ||
			fail "savingsPanel must contain about eight $cohort samples (accepted range 6-10; got $cohort_count)"
	done
fi

# The template is valid, tightly scoped, non-root, non-preempting, and bounded.
assert_eq "$(yq -r '.apiVersion' "$template")" 'batch/v1' 'Job API version'
assert_eq "$(yq -r '.kind' "$template")" 'Job' 'Job template kind'
assert_eq "$(yq -r '.metadata.name' "$template")" \
	'encode-benchmark-template' 'Job template name'
assert_eq "$(yq -r '.metadata.namespace' "$template")" 'media' 'Job template namespace'
for label in metadata.labels spec.template.metadata.labels; do
	assert_eq "$(yq -r ".$label.\"app.kubernetes.io/name\"" "$template")" \
		'encode-benchmark' "$label app label"
	assert_eq "$(yq -r ".$label.\"homelab-talos/benchmark-dispatch\"" "$template")" \
		'template' "$label dispatch label"
	assert_eq "$(yq -r ".$label.\"homelab-talos/benchmark-run\"" "$template")" \
		'template' "$label run label"
	assert_eq "$(yq -r ".$label.\"homelab-talos/benchmark-mode\"" "$template")" \
		'template' "$label mode label"
done
assert_eq "$(yq -r '.spec.backoffLimit' "$template")" '0' 'Job retry limit'
assert_eq "$(yq -r '.spec.ttlSecondsAfterFinished' "$template")" '86400' 'Job TTL'
assert_eq "$(yq -r '.spec.activeDeadlineSeconds' "$template")" '129600' 'Job deadline'
pod='.spec.template.spec'
container="$pod.containers[0]"
assert_eq "$(yq -r "$pod.priorityClassName" "$template")" \
	'encode-benchmark-background' 'Job priority class'
assert_eq "$(yq -r "$pod.automountServiceAccountToken" "$template")" \
	'false' 'Job service account token automount'
assert_eq "$(yq -r "$pod.restartPolicy" "$template")" 'Never' 'Job restart policy'
assert_eq "$(yq -r "$pod.containers | length" "$template")" '1' 'Job container count'
assert_eq "$(yq -r "$container.name" "$template")" 'benchmark' 'Job container name'
assert_eq "$(yq -r "$container.image" "$template")" "$runtime_image" 'Job runtime image'
assert_eq "$(yq -r "$container.command | join(\" \" )" "$template")" \
	'/scripts/benchmark.sh template' 'Job command'
assert_eq "$(yq -r "$container.env[] | select(.name == \"NODE_NAME\") | .valueFrom.fieldRef.fieldPath" "$template")" \
	'spec.nodeName' 'Job NODE_NAME source'
assert_eq "$(yq -r "$container.securityContext.allowPrivilegeEscalation" "$template")" \
	'false' 'container privilege escalation'
assert_eq "$(yq -r "$container.securityContext.capabilities.drop | join(\",\")" "$template")" \
	'ALL' 'container dropped capabilities'
for contract in \
	'runAsNonRoot=true' \
	'runAsUser=568' \
	'runAsGroup=568' \
	'fsGroup=568' \
	'fsGroupChangePolicy=OnRootMismatch' \
	'seccompProfile.type=RuntimeDefault'; do
	key="${contract%%=*}"
	expected="${contract#*=}"
	assert_eq "$(yq -r "$pod.securityContext.$key" "$template")" "$expected" \
		"pod securityContext $key"
done

anti_affinity="$pod.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0]"
assert_eq "$(yq -r "$anti_affinity.topologyKey" "$template")" \
	'kubernetes.io/hostname' 'Plex anti-affinity topology'
match="$anti_affinity.labelSelector.matchExpressions[0]"
assert_eq "$(yq -r "$match.key" "$template")" 'app.kubernetes.io/name' \
	'Plex anti-affinity label'
assert_eq "$(yq -r "$match.operator" "$template")" 'In' 'Plex anti-affinity operator'
assert_eq "$(yq -r "$match.values | join(\",\")" "$template")" 'plex' \
	'Plex anti-affinity value'

for resource in \
	'requests|cpu|2' \
	'requests|memory|2Gi' \
	'requests|ephemeral-storage|105Gi' \
	'requests|gpu.intel.com/i915|1' \
	'limits|cpu|8' \
	'limits|memory|8Gi' \
	'limits|ephemeral-storage|110Gi' \
	'limits|gpu.intel.com/i915|1'; do
	IFS='|' read -r scope key expected <<<"$resource"
	assert_eq "$(yq -r "$container.resources.$scope.\"$key\"" "$template")" "$expected" \
		"Job resource $scope.$key"
done

assert_eq "$(yq -r "$pod.volumes[] | select(.name == \"media\") | .persistentVolumeClaim.claimName" "$template")" \
	'media-data' 'media PVC'
assert_eq "$(yq -r "$pod.volumes[] | select(.name == \"out\") | .persistentVolumeClaim.claimName" "$template")" \
	'media-data' 'output PVC'
assert_eq "$(yq -r "$pod.volumes[] | select(.name == \"scratch\") | .emptyDir.sizeLimit" "$template")" \
	'105Gi' 'scratch size limit'
template_scripts_name="$(yq -r "$pod.volumes[] | select(.name == \"scripts\") | .configMap.name" "$template")"
[[ "$template_scripts_name" =~ ^encode-benchmark-scripts-[a-z0-9]{10}$ ]] ||
	fail 'Job scripts volume must name a hash-suffixed scripts ConfigMap placeholder'
assert_eq "$(yq -r "$pod.volumes[] | select(.name == \"scripts\") | .configMap.defaultMode" "$template")" \
	'0555' 'scripts ConfigMap defaultMode 0555'
assert_eq "$(yq -r "$pod.volumes[] | select(.name == \"samples\") | .configMap.name" "$template")" \
	'encode-benchmark-samples' 'samples ConfigMap name'
assert_eq "$(yq -r "$pod.volumes[] | select(.name == \"samples\") | .configMap.items[0].key" "$template")" \
	'samples.json' 'samples ConfigMap key'

assert_mount() {
	local name="$1"
	local path="$2"
	local subpath="$3"
	local readonly="$4"
	local mount
	mount="$(yq -o=json -I=0 "$container.volumeMounts[] | select(.name == \"$name\")" "$template")"
	[[ -n "$mount" ]] || fail "missing $name volume mount"
	assert_eq "$(yq -p=json -r '.mountPath' <<<"$mount")" "$path" "$name mount path"
	assert_eq "$(yq -p=json -r '.subPath // ""' <<<"$mount")" "$subpath" "$name subPath"
	assert_eq "$(yq -p=json -r '.readOnly // false' <<<"$mount")" "$readonly" "$name readOnly"
}
assert_mount media /media media/movies true
assert_mount out /out benchmark false
assert_mount scratch /scratch '' false
assert_mount scripts /scripts '' true
assert_mount samples /config/samples.json samples.json true

if rg -n '/data|media/tv|downloads' "$app/scripts" "$template"; then
	fail 'benchmark scripts or Job template can access forbidden TV/download paths'
fi

# Use only the pinned toolchain for all executable source checks and run every Bats contract.
mapfile -t shell_sources < <(find "$app/scripts" -type f -name '*.sh' -print | sort)
shell_sources+=(
	"$preflight_helper"
	"$dispatch_helper"
	"$results_helper"
	"$selection_helper"
	"$live_verifier"
	"$validator"
)
shfmt -d "${shell_sources[@]}"
shellcheck --external-sources "${shell_sources[@]}"
mapfile -t bats_files < <(find "$tests_dir" -type f -name '*.bats' -print | sort)
(("${#bats_files[@]}" > 0)) || fail 'no encode-benchmark Bats contracts found'
bats "${bats_files[@]}"

echo "encode-benchmark sources passed validation: Flux suspend=$suspend_state, no reconciled Job, six tested runtime scripts, guarded render/read helpers, actual image evidence, safe media mounts, and offline contracts."
