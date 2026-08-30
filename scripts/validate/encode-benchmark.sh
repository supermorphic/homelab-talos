#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

app='kubernetes/apps/media/encode-benchmark/app'
package='kubernetes/apps/media/encode-benchmark'
tests_dir="$package/tests"
contract="$app/scripts/contract.sh"
samples="$app/samples.yaml"
template="$package/templates/job.yaml"

fail() {
	echo "encode-benchmark validation failed: $*" >&2
	exit 1
}

required_files=(
	"$contract"
	"$app/scripts/probe.sh"
	"$app/scripts/runmeta.sh"
	"$app/scripts/benchmark.sh"
	"$app/scripts/quality-evidence.sh"
	"$samples"
	"$app/kustomization.yaml"
	"$app/priorityclass.yaml"
	"$template"
	"$package/ks.yaml"
	'scripts/encode-benchmark/dispatch.sh'
	'scripts/encode-benchmark/preflight.sh'
	'scripts/encode-benchmark/results.sh'
	'scripts/verify/encode-benchmark.sh'
	"$tests_dir/retirement.bats"
	"$tests_dir/quality-evidence.bats"
)
for path in "${required_files[@]}"; do
	[[ -f "$path" ]] || fail "missing required source: $path"
done

for path in "$app"/scripts/*.sh scripts/encode-benchmark/*.sh scripts/verify/encode-benchmark.sh; do
	[[ -x "$path" ]] || fail "$path must be executable"
done

samples_document="$(mktemp "${TMPDIR:-/tmp}/encode-benchmark-samples.XXXXXX")"
rendered="$(mktemp "${TMPDIR:-/tmp}/encode-benchmark-rendered.XXXXXX")"
trap 'rm -f -- "$samples_document" "$rendered"' EXIT
yq -e -r '.data."samples.json"' "$samples" >"$samples_document"
jq -e . "$samples_document" >/dev/null

# shellcheck disable=SC1090
source "$contract"
contract_load "$samples_document" || fail 'samples violate the shared quality contract'

jq -e '
	keys == ["qualityCorrection","qualityPanel","runtime","schemaVersion","strategy"] and
	.schemaVersion == 3 and
	.strategy == {
		id:"qsv-hevc-icq-v1",resultsSchemaVersion:3,runManifestSchemaVersion:2,
		capabilityProofSchemaVersion:3,globalQualityCandidates:[16,18,20,22,24,26,28,30]
	} and
	.qualityCorrection == {
		schemaVersion:1,diagnosticRunId:"20260829T020752Z-43984d8d",
		vmafMeasurementDefects:[
			{sampleId:"avc-clean-coco",clipId:"motion",frameIndex:1641},
			{sampleId:"avc-grain-memento",clipId:"dark",frameIndex:523},
			{sampleId:"avc-grain-memento",clipId:"detail",frameIndex:370},
			{sampleId:"vc1-fugitive",clipId:"motion",frameIndex:798}
		]
	} and
	([.qualityPanel[] | select((.detectionOnly // false) == false)] | length) == 6 and
	([.qualityPanel[] | select((.detectionOnly // false) == true)] |
		map({id,cohort,clips})) == [{id:"dolby-vision-sisu",cohort:"dolby-vision",clips:{}}] and
	all(.qualityPanel[] | select((.detectionOnly // false) == false);
		(.id | type == "string") and
		(.cohort == "avc" or .cohort == "vc1" or .cohort == "hdr10") and
		(.path | startswith("/media/")) and
		(.sizeBytes | type == "number" and . > 0 and floor == .) and
		(.sha256 | test("^[0-9a-f]{64}$")) and
		(.clips | keys == ["dark","detail","motion"]) and
		all(.clips[]; test("^[0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{3}$"))) and
	([.qualityPanel[] | .id] | unique | length) == (.qualityPanel | length) and
	([.runtime.requiredCommands[]] | unique | length) == (.runtime.requiredCommands | length) and
	(.runtime.image | test("^[^@[:space:]]+@sha256:[0-9a-f]{64}$")) and
	.runtime.capabilityStatus == "verified" and
	(.runtime.capabilityEvidence.nodes | type == "array" and length > 0)
' "$samples_document" >/dev/null || fail 'samples do not define the exact fixed quality population'

[[ -n "$(contract_passing_icq_nodes "$samples_document")" ]] ||
	fail 'samples do not contain a passing schema-3 ICQ capability node'

kustomize build "$app" >"$rendered"
[[ "$(yq -N -r 'select(.kind == "Job") | .metadata.name' "$rendered")" == '' ]] ||
	fail 'Flux render must remain inert and contain no Job'
actual_mappings="$(yq -r '.configMapGenerator[] | select(.name == "encode-benchmark-scripts") |
	.files | join(",")' "$app/kustomization.yaml")"
expected_mappings='contract.sh=scripts/contract.sh,probe.sh=scripts/probe.sh,runmeta.sh=scripts/runmeta.sh,benchmark.sh=scripts/benchmark.sh,quality-evidence.sh=scripts/quality-evidence.sh'
[[ "$actual_mappings" == "$expected_mappings" ]] || fail 'rendered script mappings are not the exact quality surface'

yq -e '
	.spec.backoffLimit == 0 and .spec.activeDeadlineSeconds == 129600 and
	.spec.template.spec.automountServiceAccountToken == false and
	.spec.template.spec.restartPolicy == "Never" and
	.spec.template.spec.priorityClassName == "encode-benchmark-background" and
	.spec.template.spec.securityContext.runAsNonRoot == true and
	.spec.template.spec.securityContext.runAsUser == 568 and
	.spec.template.spec.securityContext.runAsGroup == 568 and
	.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation == false and
	.spec.template.spec.containers[0].securityContext.capabilities.drop == ["ALL"] and
	.spec.template.spec.containers[0].resources.requests."gpu.intel.com/i915" == 1 and
	.spec.template.spec.containers[0].resources.requests."ephemeral-storage" == "105Gi" and
	.spec.template.spec.containers[0].resources.limits."ephemeral-storage" == "110Gi" and
	([.spec.template.spec.containers[0].volumeMounts[] |
		select(.name == "media" and .mountPath == "/media" and .subPath == "media/movies" and .readOnly == true)] | length) == 1 and
	([.spec.template.spec.containers[0].volumeMounts[] |
		select(.mountPath == "/tv" or .mountPath == "/downloads")] | length) == 0
' "$template" >/dev/null || fail 'Job template violates the retained quality safety boundary'

mapfile -t shell_sources < <(
	find "$app/scripts" scripts/encode-benchmark -maxdepth 1 -type f -name '*.sh' -print
	printf '%s\n' scripts/validate/encode-benchmark.sh scripts/verify/encode-benchmark.sh
)
shellcheck "${shell_sources[@]}"
shfmt -d "${shell_sources[@]}"

mapfile -t bats_files < <(find "$tests_dir" -type f -name '*.bats' -print | LC_ALL=C sort)
((${#bats_files[@]} > 0)) || fail 'no encode-benchmark Bats contracts found'
bats "${bats_files[@]}"

echo 'encode-benchmark sources passed validation: fixed quality panel, five rendered scripts, inert Flux resources, guarded capability and quality interfaces, and safe workload boundaries.'
