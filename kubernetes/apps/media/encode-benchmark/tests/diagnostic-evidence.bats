#!/usr/bin/env bats

setup() {
	SCRIPTS="$BATS_TEST_DIRNAME/../app/scripts"
	COLLECTOR="$SCRIPTS/diagnostic-evidence.sh"
	RUN_ID='20260820T223425Z-082b3d38'
	EVIDENCE_ROOT="$BATS_TEST_TMPDIR/evidence"
	mkdir -p "$EVIDENCE_ROOT"
}

# The expected document is hand-written from the approved 5+3 panel.  It is
# deliberately not assembled from the collector so a broadened panel, raw path,
# or command leak changes the observable result.
@test "collector emits one canonical redacted diagnostic evidence document" {
	create_valid_evidence_tree

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT"
	[ "$status" -eq 0 ]
	[ "$(wc -l <<<"$output" | tr -d ' ')" -eq 1 ]
	run jq -e --arg run "$RUN_ID" '
		keys == ["hdr","mode","runId","schemaVersion","strategyId","vmaf"] and
		.schemaVersion == 1 and .mode == "diagnostic-evidence-reader" and .runId == $run and
		.strategyId == "qsv-hevc-icq-v1" and
		(.vmaf | type == "array" and length == 5 and
		 (map(.sampleId + "/" + .clipId) | sort) == [
			"avc-clean-coco/motion", "avc-grain-memento/dark", "avc-grain-memento/detail",
			"vc1-fugitive/detail", "vc1-fugitive/motion"
		 ]) and
		(.hdr | type == "array" and length == 3 and (map(.sampleId) | sort) == [
			"hdr10-clean-ministry", "hdr10-grain-goodfellas", "hdr10-motion-john-wick-2"
		 ]) and
		(tostring | test("/media|/out|command|identity|nodeName"; "i") | not)
	' <<<"$output"
	[ "$status" -eq 0 ]
}

@test "collector rejects evidence whose retained manifest names another run" {
	create_valid_evidence_tree
	jq '.runId = "20260820T223425Z-deadbeef"' "$EVIDENCE_ROOT/manifest.json" >"$BATS_TEST_TMPDIR/manifest.json"
	mv "$BATS_TEST_TMPDIR/manifest.json" "$EVIDENCE_ROOT/manifest.json"

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT"
	[ "$status" -ne 0 ]
	[[ "$output" == *'manifest'* ]]
}

@test "rendered scripts ConfigMap includes the collector executable" {
	run kustomize build "$BATS_TEST_DIRNAME/../app"
	[ "$status" -eq 0 ]
	run yq -N -e 'select(.kind == "ConfigMap" and (.metadata.name | test("^encode-benchmark-scripts-"))) | .data."diagnostic-evidence.sh" | contains("EVIDENCE_RUN_ID")' <<<"$output"
	[ "$status" -eq 0 ]
}

@test "collector redacts an unexpected source path from retained frame metadata" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
	jq '.sourceClip.frameWindow.stream.path = "/media/private/title.mkv"' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT"
	[ "$status" -eq 0 ]
	[[ "$output" != *'/media/private/title.mkv'* ]]
}

@test "collector rejects malformed missing extra escaped symlinked oversized and wrong-panel evidence" {
	for case_name in malformed missing extra escaped symlink oversized wrong-panel; do
		create_valid_evidence_tree
		case "$case_name" in
		malformed) printf '{' >"$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json" ;;
		missing) mv "$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json" "$BATS_TEST_TMPDIR/missing.json" ;;
		extra) printf '{}\n' >"$EVIDENCE_ROOT/unexpected.json" ;;
		escaped) jq '.vmaf.entries[0].evidence = "../../outside.json"' "$EVIDENCE_ROOT/diagnostic-summary.json" >"$BATS_TEST_TMPDIR/summary.json" && mv "$BATS_TEST_TMPDIR/summary.json" "$EVIDENCE_ROOT/diagnostic-summary.json" ;;
		symlink) mv "$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json" "$BATS_TEST_TMPDIR/target.json" && ln -s "$BATS_TEST_TMPDIR/target.json" "$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json" ;;
		oversized) head -c 65537 /dev/zero >"$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json" ;;
		wrong-panel) jq '.sampleId = "avc-clean-coco"' "$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json" >"$BATS_TEST_TMPDIR/wrong.json" && mv "$BATS_TEST_TMPDIR/wrong.json" "$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json" ;;
		esac
		run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT"
		[ "$status" -ne 0 ]
	done
}

create_valid_evidence_tree() {
	local sample clip index path
	jq -n --arg run "$RUN_ID" '
		{schemaVersion:1,strategyId:"qsv-hevc-icq-v1",mode:"diagnostics",runId:$run,status:"complete",
		 vmaf:{total:5,entries:[]},hdr:{total:3,entries:[]}}' >"$EVIDENCE_ROOT/diagnostic-summary.json"
	jq -n --arg run "$RUN_ID" '{schemaVersion:2,mode:"diagnostics",runId:$run,upstream:{diagnostics:{manifestSchemaVersion:1,resultSchemaVersion:1,acceptedFindingsSha256:"sha256:eb7ddcb42bffecb0ac0f8ab2df58be8317c586c56bb4485d48169568a6061294",decisionSha256:"sha256:17c476c4646e28bef71514bb48473771f449aa2c749b1d611f6c69ed518cc330",historicalQualityRunId:"20260817T233546Z-debc0498",historicalFindingsRunId:"20260818T214739Z-8bc2de3e",panelSha256:("sha256:" + ("a" * 64))}}}' >"$EVIDENCE_ROOT/manifest.json"
	while IFS=$'\t' read -r sample clip index; do
		path="$EVIDENCE_ROOT/vmaf/$sample/$clip"
		mkdir -p "$path"
		jq -n --arg sample "$sample" --arg clip "$clip" --argjson index "$index" '
			{schemaVersion:1,strategyId:"qsv-hevc-icq-v1",sampleId:$sample,clipId:$clip,observedFrameIndex:$index,
			 status:"complete",sourceClip:{frameWindow:{decodedFrameCount:2160,stream:{startTime:"0",duration:"90",timeBase:"1/90000",averageFrameRate:"24/1"},frames:[]}},
			 settings:[{globalQuality:16,status:"complete",reason:null,vmaf:{current:[],reset:[]},offsets:[],timeline:{zeroOffsetAligned:true,discontinuity:null}},
			           {globalQuality:30,status:"complete",reason:null,vmaf:{current:[],reset:[]},offsets:[],timeline:{zeroOffsetAligned:true,discontinuity:null}}],
			 classification:{schemaVersion:1,classification:"unresolved",reasons:["classification-predicate-not-met"]}}' >"$path/evidence.json"
		summary="$(jq -c --arg sample "$sample" --arg clip "$clip" --argjson index "$index" \
			'.vmaf.entries += [{sampleId:$sample,clipId:$clip,observedFrameIndex:$index,status:"complete",classification:"unresolved",reasons:["classification-predicate-not-met"],evidence:("vmaf/" + $sample + "/" + $clip + "/evidence.json")}]' \
			"$EVIDENCE_ROOT/diagnostic-summary.json")"
		printf '%s\n' "$summary" >"$EVIDENCE_ROOT/diagnostic-summary.json"
	done <<'EOF'
avc-clean-coco	motion	1641
avc-grain-memento	dark	523
avc-grain-memento	detail	370
vc1-fugitive	detail	781
vc1-fugitive	motion	798
EOF
	while IFS=$'\t' read -r sample clip; do
		path="$EVIDENCE_ROOT/hdr/$sample"
		mkdir -p "$path"
		jq -n --arg sample "$sample" --arg clip "$clip" '
			{schemaVersion:1,strategyId:"qsv-hevc-icq-v1",sampleId:$sample,clipId:$clip,globalQuality:16,status:"complete",reason:null,
			 normalizedOracle:{schemaVersion:1,source:{streamProbe:{status:"null"},windows:{}},clip:{},encoded:{}},
			 classification:{schemaVersion:1,classification:"unresolved-oracle",reasons:["source-window-null"]}}' >"$path/evidence.json"
		summary="$(jq -c --arg sample "$sample" \
			'.hdr.entries += [{sampleId:$sample,status:"complete",classification:"unresolved-oracle",reasons:["source-window-null"],evidence:("hdr/" + $sample + "/evidence.json")}]' \
			"$EVIDENCE_ROOT/diagnostic-summary.json")"
		printf '%s\n' "$summary" >"$EVIDENCE_ROOT/diagnostic-summary.json"
	done <<'EOF'
hdr10-clean-ministry	detail
hdr10-grain-goodfellas	detail
hdr10-motion-john-wick-2	detail
EOF
}
