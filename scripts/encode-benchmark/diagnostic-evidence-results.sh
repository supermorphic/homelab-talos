#!/usr/bin/env bash
# Read the bounded collector result without opening any retained artifact.
set -euo pipefail

if (($# != 1)); then
	echo 'usage: diagnostic-evidence-results.sh <kubeconfig>' >&2
	exit 64
fi

readonly RUN_ID='20260820T223425Z-082b3d38'
readonly MODE='diagnostic-evidence-reader'
readonly MAX_BYTES=65536
kubeconfig="$1"
namespace='media'
expected_api='https://192.168.90.20:6443'
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../.." && pwd)"
samples_source="$repository_root/kubernetes/apps/media/encode-benchmark/app/samples.yaml"

[[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2; exit 1; }
api_server="$(kubectl --kubeconfig "$kubeconfig" config view --minify --output jsonpath='{.clusters[0].cluster.server}')"
[[ "$api_server" == "$expected_api" ]] || { echo "Refusing diagnostic evidence results: kubeconfig targets $api_server, not $expected_api." >&2; exit 1; }
configured_image="$(yq -e -r '.data."samples.json" | from_json | .runtime.image | select(test("^[^@[:space:]]+@sha256:[0-9a-f]{64}$"))' "$samples_source")"
selector="app.kubernetes.io/name=encode-benchmark,homelab-talos/benchmark-run=$RUN_ID,homelab-talos/benchmark-mode=$MODE"
jobs="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get jobs --selector "$selector" --output json)"
[[ "$(jq -r '.items | length' <<<"$jobs")" == '1' ]] || { echo 'diagnostic evidence result provenance rejected: expected one collector Job' >&2; exit 1; }
job="$(jq -c '.items[0]' <<<"$jobs")"
name="$(jq -e -r '.metadata.name | select(test("^encode-benchmark-evidence-reader-[0-9]{8}t[0-9]{6}z-[0-9a-f]{8}$"))' <<<"$job")" || exit 65
uid="$(jq -e -r '.metadata.uid | select(type == "string" and length > 0)' <<<"$job")" || exit 65
jq -e --arg run "$RUN_ID" --arg mode "$MODE" --arg image "$configured_image" '
	.metadata.labels."app.kubernetes.io/name" == "encode-benchmark" and
	.metadata.labels."homelab-talos/benchmark-run" == $run and .metadata.labels."homelab-talos/benchmark-mode" == $mode and
	.metadata.annotations."homelab-talos/benchmark-owned" == "true" and
	([.spec.template.spec.containers[] | select(.name == "benchmark") | .image] == [$image]) and
	([.status.conditions[]? | select(.type == "Complete" and .status == "True")] | length == 1) and
	(.status.succeeded == 1 and (.status.failed // 0) == 0)
' <<<"$job" >/dev/null || { echo 'diagnostic evidence result provenance rejected: Job is not the terminal collector' >&2; exit 1; }

pods="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get pods --selector "$selector" --output json)"
[[ "$(jq -r '.items | length' <<<"$pods")" == '1' ]] || { echo 'diagnostic evidence result provenance rejected: expected one collector Pod' >&2; exit 1; }
pod="$(jq -c '.items[0]' <<<"$pods")"
jq -e --arg name "$name" --arg uid "$uid" --arg image "$configured_image" '
	.status.phase == "Succeeded" and
	(.metadata.ownerReferences | type == "array" and length == 1 and .[0].apiVersion == "batch/v1" and .[0].kind == "Job" and .[0].name == $name and .[0].uid == $uid and .[0].controller == true and .[0].blockOwnerDeletion == true) and
	([.status.containerStatuses[]? | select(.name == "benchmark")] | length == 1) and
	([.status.containerStatuses[] | select(.name == "benchmark") | .imageID | sub("^(docker-pullable|containerd)://"; "")] | .[0]) as $image_id |
	($image_id == $image or $image_id == ($image | split("@") | .[1]))
' <<<"$pod" >/dev/null || { echo 'diagnostic evidence result provenance rejected: Pod ownership or image identity is invalid' >&2; exit 1; }

payload="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" logs "job/$name" --container benchmark)"
[[ "$(wc -l <<<"$payload" | tr -d '[:space:]')" == '1' ]] || { echo 'diagnostic evidence result is ambiguous' >&2; exit 65; }
payload_bytes="$(printf '%s' "$payload" | LC_ALL=C wc -c | tr -d '[:space:]')"
[[ "$payload_bytes" =~ ^[0-9]+$ && "$payload_bytes" -le "$MAX_BYTES" ]] || { echo 'diagnostic evidence result exceeds its bounded size' >&2; exit 65; }
[[ "$(jq -S -c . <<<"$payload")" == "$payload" ]] || { echo 'diagnostic evidence result is not canonical' >&2; exit 65; }
jq -e -c --arg run "$RUN_ID" '
	def exact($expected): type == "object" and (keys | sort) == ($expected | sort);
	def status: . == "complete" or . == "failed" or . == "harness-blocked";
	def gcd($a; $b): if $b == 0 then $a else gcd($b; ($a % $b)) end;
	def rational: exact(["denominator","numerator"]) and (.numerator | type == "number" and floor == . and . >= 0) and (.denominator | type == "number" and floor == . and . > 0) and (gcd(.numerator; .denominator) == 1);
	def chromaticity: exact(["x","y"]) and (.x | rational) and (.y | rational);
	def metadata: exact(["masteringDisplay","maxCLL","maxFALL"]) and (.masteringDisplay | exact(["displayPrimaries","luminance","whitePoint"]) and (.displayPrimaries | exact(["blue","green","red"]) and (.red | chromaticity) and (.green | chromaticity) and (.blue | chromaticity)) and (.whitePoint | chromaticity) and (.luminance | exact(["max","min"]) and (.min | rational) and (.max | rational))) and (.maxCLL | rational) and (.maxFALL | rational);
	def oracle: (exact(["status"]) and (.status == "null" or .status == "absent" or .status == "malformed")) or (exact(["metadata","status"]) and .status == "ok" and (.metadata | metadata));
	def authoritative: (exact(["metadata","status"]) and .status == "ok" and (.metadata | metadata)) or (exact(["reasons","status"]) and .status == "unresolved" and (.reasons | type == "array" and all(.[]; type == "string")));
	def normalized_oracle: exact(["clip","encoded","schemaVersion","source"]) and .schemaVersion == 1 and (.source | exact(["authoritative","streamProbe","windows"]) and (.streamProbe | oracle) and (.authoritative | authoritative) and (.windows | type == "object" and ([keys[]] | all(. == "beginning" or . == "detail" or . == "end")) and all(.[]; exact(["authoritative","decoded","trace"]) and (.decoded | oracle) and (.trace | oracle) and (.authoritative | authoritative)))) and ((.clip | exact([])) or (.clip | exact(["authoritative","decoded","trace"]) and (.decoded | oracle) and (.trace | oracle) and (.authoritative | authoritative))) and ((.encoded | exact([])) or (.encoded | exact(["authoritative","decoded","trace"]) and (.decoded | oracle) and (.trace | oracle) and (.authoritative | authoritative)));
	def class: exact(["classification","reasons","schemaVersion"]) and .schemaVersion == 1 and (.classification | type == "string") and (.reasons | type == "array" and all(.[]; type == "string"));
	def psnr: . == null or type == "number" or (exact(["kind"]) and .kind == "positive-infinity") or (exact(["kind","value"]) and .kind == "finite" and (.value | type == "number"));
	def vmaf_frame: exact(["frameIndex","vmaf"]) and (.frameIndex | type == "number" and floor == .) and (.vmaf | type == "number");
	def setting: exact(["globalQuality","offsets","reason","status","timeline","vmaf"]) and (.globalQuality == 16 or .globalQuality == 30) and (.status | status) and (.reason == null or type == "string") and (.vmaf | exact(["current","reset"]) and (.current | type == "array" and length <= 5 and all(.[]; vmaf_frame)) and (.reset | type == "array" and length <= 5 and all(.[]; vmaf_frame))) and (.offsets | type == "array" and length <= 5 and all(.[]; exact(["offset","psnr","ssim"]) and (.offset | type == "number" and floor == . and . >= -2 and . <= 2) and (.ssim == null or type == "number") and (.psnr | psnr))) and (.timeline | exact(["discontinuity","zeroOffsetAligned"]) and (.zeroOffsetAligned | type == "boolean") and (.discontinuity == null or (exact(["kind","offset"]) and (.kind | type == "string") and (.offset | type == "number" and floor == .))));
	def source: exact(["decodedFrameCount","frames","stream"]) and (.decodedFrameCount | type == "number" and . >= 0) and (.stream | exact(["averageFrameRate","duration","startTime","timeBase"]) and all(.[]; type == "string")) and (.frames | type == "array" and length <= 5 and all(.[]; exact(["bestEffortTimestamp","frameIndex","keyFrame","packetDuration","pictureType"]) and (.frameIndex | type == "number" and floor == .) and (.bestEffortTimestamp | type == "string") and (.packetDuration | type == "string") and (.keyFrame | type == "boolean") and (.pictureType | type == "string")));
	def vmaf_row: exact(["classification","clipId","observedFrameIndex","sampleId","settings","sourceContinuity","status"]) and (.sampleId | type == "string") and (.clipId | type == "string") and (.observedFrameIndex | type == "number" and floor == .) and (.status | status) and (.sourceContinuity | source) and (.settings | type == "array" and length == 2 and all(.[]; setting) and ([.[].globalQuality] | sort) == [16,30]) and (.classification | class);
	def hdr_row: exact(["classification","clipId","globalQuality","normalizedOracle","reason","sampleId","status"]) and (.sampleId | type == "string") and .clipId == "detail" and .globalQuality == 16 and (.status | status) and (.reason == null or type == "string") and (.normalizedOracle | normalized_oracle) and (.classification | class);
	type == "object" and keys == ["hdr","mode","runId","schemaVersion","strategyId","vmaf"] and
	.schemaVersion == 1 and .strategyId == "qsv-hevc-icq-v1" and .mode == "diagnostic-evidence-reader" and .runId == $run and
	(.vmaf | type == "array" and length == 5 and all(.[]; vmaf_row) and ([.[] | [.sampleId,.clipId] | join("/")] | sort) == ["avc-clean-coco/motion","avc-grain-memento/dark","avc-grain-memento/detail","vc1-fugitive/detail","vc1-fugitive/motion"]) and
	(.hdr | type == "array" and length == 3 and all(.[]; hdr_row) and ([.[] | .sampleId] | sort) == ["hdr10-clean-ministry","hdr10-grain-goodfellas","hdr10-motion-john-wick-2"]) and
	(tostring | test("/media|/out|command|identity|nodeName"; "i") | not)
' <<<"$payload" >/dev/null || { echo 'diagnostic evidence result schema rejected' >&2; exit 65; }
printf '%s\n' "$payload"
