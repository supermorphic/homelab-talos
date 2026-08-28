#!/usr/bin/env bats

setup() {
	SCRIPTS="$BATS_TEST_DIRNAME/../app/scripts"
	COLLECTOR_SCRIPT="$SCRIPTS/diagnostic-evidence.sh"
	COLLECTOR=run_collector
	RUN_ID='20260820T223425Z-082b3d38'
	EVIDENCE_ROOT="$BATS_TEST_TMPDIR/evidence"
	# Derive the retained producer identity from the same committed contract and
	# samples document that create the diagnostic manifest.
	# shellcheck disable=SC1091
	source "$SCRIPTS/contract.sh"
	yq -e -r '.data."samples.json"' "$BATS_TEST_DIRNAME/../app/samples.yaml" >"$BATS_TEST_TMPDIR/samples.json"
	CONFIGURED_IMAGE="$(jq -e -r '.runtime.image' "$BATS_TEST_TMPDIR/samples.json")"
	PANEL_SHA256="$(contract_diagnostics_panel_sha256 "$BATS_TEST_TMPDIR/samples.json")"
	EVIDENCE_PANEL="$(contract_diagnostics_evidence_panel_json "$BATS_TEST_TMPDIR/samples.json")"
	mkdir -p "$EVIDENCE_ROOT"
}

run_collector() {
	"$COLLECTOR_SCRIPT" "$@" "$EVIDENCE_PANEL" "$CONFIGURED_IMAGE"
}

create_projected_scripts() {
	local payload="$BATS_TEST_TMPDIR/projected-scripts/..2026_08_28_17_56_18.0000000000"
	local source name
	mkdir -p "$payload"
	cp "$SCRIPTS"/* "$payload/"
	ln -s "${payload##*/}" "$BATS_TEST_TMPDIR/projected-scripts/..data"
	for source in "$payload"/*; do
		name="${source##*/}"
		ln -s "..data/$name" "$BATS_TEST_TMPDIR/projected-scripts/$name"
	done
}

# The expected document is hand-written from the approved 5+3 panel.  It is
# deliberately not assembled from the collector so a broadened panel, raw path,
# or command leak changes the observable result.
@test "collector emits one canonical redacted diagnostic evidence document" {
	create_valid_evidence_tree

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 0 ] || {
		echo "collector status=$status output=$output" >&3
		return 1
	}
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
		(.vmaf | all(.[]; .sourceContinuity == null or
			.sourceContinuity.sourceWindow == {status:"clean",issue:null})) and
		(tostring | test("/media|/out|raw-command-secret|command|identity|nodeName"; "i") | not)
	' <<<"$output"
	[ "$status" -eq 0 ]
}

# Kubernetes ConfigMap volumes expose each key through ..data/<key>. The
# collector must authenticate that real projection instead of requiring the
# regular-file layout used by the offline source tree.
@test "collector authenticates scripts from a Kubernetes projected ConfigMap" {
	create_valid_evidence_tree
	create_projected_scripts
	COLLECTOR_SCRIPT="$BATS_TEST_TMPDIR/projected-scripts/diagnostic-evidence.sh"

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 0 ] || {
		echo "collector status=$status output=$output" >&3
		return 1
	}
	run jq -e --arg run "$RUN_ID" '
		.mode == "diagnostic-evidence-reader" and .runId == $run and
		(.vmaf | length) == 5 and (.hdr | length) == 3
	' <<<"$output"
	[ "$status" -eq 0 ]
}

@test "collector rejects a projected script target outside the scripts mount" {
	create_valid_evidence_tree
	create_projected_scripts
	cp "$SCRIPTS/contract.sh" "$BATS_TEST_TMPDIR/outside-contract.sh"
	rm "$BATS_TEST_TMPDIR/projected-scripts/contract.sh"
	ln -s ../outside-contract.sh "$BATS_TEST_TMPDIR/projected-scripts/contract.sh"
	COLLECTOR_SCRIPT="$BATS_TEST_TMPDIR/projected-scripts/diagnostic-evidence.sh"

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 65 ]
	[ "$output" = 'diagnostic evidence reader script identity is unavailable' ]
}

@test "collector authenticates the exact completed retained producer through projected current scripts" {
	local retained_scripts='{"benchmark.sh":"sha256:749746d12b6c8c9398061314e3a8918707ed620830165c6ffaf71e22ebfe7b37","census.sh":"sha256:505c58d595fad640cec7fbac2eefcb02b4e1c96b3c64094afd785f2b72d39f07","contract.sh":"sha256:b6a2b679556932773f7804843822e750640453a9700dc41f0351a43a0c83675b","diagnostic-evidence.sh":"sha256:f13bf66d0f3af7675f2121c4529e0679a594e03ef08e2165ba1f0b6e15389c25","probe.sh":"sha256:ccf31501570406304ad6292ba77901610b2d3dffe59d53d19128e9d1facff82d","runmeta.sh":"sha256:df5891bea05ee4ebb9c920c62fd363bc5c8a54744ac60ff558a265c4646128a3","stills.sh":"sha256:5887426ee150673a91604916a8a860a7e3395a8172557ff2e3e3456358eb510e"}'
	RUN_ID='20260827T233832Z-2a79502c'
	create_valid_evidence_tree
	jq --argjson scripts "$retained_scripts" '.scriptDigests = $scripts' \
		"$EVIDENCE_ROOT/manifest.json" >"$BATS_TEST_TMPDIR/manifest.json"
	mv "$BATS_TEST_TMPDIR/manifest.json" "$EVIDENCE_ROOT/manifest.json"
	create_projected_scripts
	COLLECTOR_SCRIPT="$BATS_TEST_TMPDIR/projected-scripts/diagnostic-evidence.sh"

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 0 ] || {
		echo "collector status=$status output=$output" >&3
		return 1
	}
	run jq -e --arg run "$RUN_ID" '.runId == $run' <<<"$output"
	[ "$status" -eq 0 ]
}

@test "collector rejects completed retained producer script identity drift and cross-run reuse" {
	local retained_scripts='{"benchmark.sh":"sha256:749746d12b6c8c9398061314e3a8918707ed620830165c6ffaf71e22ebfe7b37","census.sh":"sha256:505c58d595fad640cec7fbac2eefcb02b4e1c96b3c64094afd785f2b72d39f07","contract.sh":"sha256:b6a2b679556932773f7804843822e750640453a9700dc41f0351a43a0c83675b","diagnostic-evidence.sh":"sha256:f13bf66d0f3af7675f2121c4529e0679a594e03ef08e2165ba1f0b6e15389c25","probe.sh":"sha256:ccf31501570406304ad6292ba77901610b2d3dffe59d53d19128e9d1facff82d","runmeta.sh":"sha256:df5891bea05ee4ebb9c920c62fd363bc5c8a54744ac60ff558a265c4646128a3","stills.sh":"sha256:5887426ee150673a91604916a8a860a7e3395a8172557ff2e3e3456358eb510e"}'
	local case_name run_id scripts
	while IFS='|' read -r case_name run_id scripts; do
		RUN_ID="$run_id"
		create_valid_evidence_tree
		jq --argjson scripts "$scripts" '.scriptDigests = $scripts' \
			"$EVIDENCE_ROOT/manifest.json" >"$BATS_TEST_TMPDIR/manifest.json"
		mv "$BATS_TEST_TMPDIR/manifest.json" "$EVIDENCE_ROOT/manifest.json"
		create_projected_scripts
		COLLECTOR_SCRIPT="$BATS_TEST_TMPDIR/projected-scripts/diagnostic-evidence.sh"

		run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		[ "$status" -eq 65 ] || {
			echo "collector accepted invalid completed producer identity: $case_name" >&3
			return 1
		}
		jq -e '.manifestIssues == [{field:"scriptDigests",kind:"mismatch"}]' <<<"$output" >/dev/null
		rm -rf "$BATS_TEST_TMPDIR/projected-scripts"
	done <<EOF
digest-drift|20260827T233832Z-2a79502c|$(jq -c '."benchmark.sh" = ("sha256:" + ("a" * 64))' <<<"$retained_scripts")
cross-run|20260827T233832Z-deadbeef|$retained_scripts
EOF
}

# Catches an infrastructure-specific run allowlist or an incomplete binding of
# the retained summary and producer timestamp to the caller-supplied run ID.
@test "collector accepts a syntactically valid fresh immutable run and rejects cross-run retained bindings" {
	local fresh_run='20260823T141907Z-9d6f6b71'
	RUN_ID="$fresh_run"
	create_valid_evidence_tree

	run "$COLLECTOR_SCRIPT" collect "$fresh_run" "$EVIDENCE_ROOT" "$PANEL_SHA256" "$EVIDENCE_PANEL" "$CONFIGURED_IMAGE"
	[ "$status" -eq 0 ]
	run jq -e --arg run "$fresh_run" '.runId == $run' <<<"$output"
	[ "$status" -eq 0 ]

	jq '.runId = "20260823T141907Z-deadbeef"' "$EVIDENCE_ROOT/diagnostic-summary.json" >"$BATS_TEST_TMPDIR/summary.json"
	mv "$BATS_TEST_TMPDIR/summary.json" "$EVIDENCE_ROOT/diagnostic-summary.json"
	run "$COLLECTOR_SCRIPT" collect "$fresh_run" "$EVIDENCE_ROOT" "$PANEL_SHA256" "$EVIDENCE_PANEL" "$CONFIGURED_IMAGE"
	[ "$status" -eq 65 ]
}

@test "collector rejects retained VMAF continuity labels that contradict raw timestamps" {
	local path mutation
	for mutation in \
		'.sourceClip.frameWindow.sourceWindow = {status:"discontinuity",issue:{kind:"gap",afterFrameIndex:(.observedFrameIndex - 2)}} | .settings |= map(.sourceFrameWindow.sourceWindow = {status:"discontinuity",issue:{kind:"gap",afterFrameIndex:(.sourceFrameWindow.frames[0].frameIndex)}})' \
		'.settings[0].outputFrameWindow.sourceWindow = {status:"discontinuity",issue:{kind:"repeat",afterFrameIndex:(.observedFrameIndex - 2)}}'; do
		create_valid_evidence_tree
		path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
		jq "$mutation" "$path" >"$BATS_TEST_TMPDIR/evidence.json"
		mv "$BATS_TEST_TMPDIR/evidence.json" "$path"

		run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		[ "$status" -eq 65 ] || {
			echo "collector accepted a false retained continuity label: $mutation" >&3
			return 1
		}
	done
}

@test "collector rejects permuted and misaligned output windows whose retained timeline and classification still agree" {
	local case_name path mutation
	for case_name in permuted misaligned; do
		create_valid_evidence_tree
		path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
		case "$case_name" in
		permuted) mutation='.settings[0].outputFrameWindow.frames |= [.[1],.[0],.[2],.[3],.[4]]' ;;
		misaligned) mutation='.settings[0].outputFrameWindow.frames[2].bestEffortTimestamp = "0.100000000"' ;;
		esac
		jq -L "$SCRIPTS" "include \"diagnostic-contract\";
			$mutation |
			.settings[0].outputFrameWindow as \$window |
			.settings[0].outputFrameWindow.sourceWindow = (\$window.frames | diagnostic_continuity(\$window.stream.timeBase))" \
			"$path" >"$BATS_TEST_TMPDIR/evidence.json"
		mv "$BATS_TEST_TMPDIR/evidence.json" "$path"

		run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		[ "$status" -eq 65 ] || {
			echo "collector accepted unauthenticated retained timeline: $case_name" >&3
			return 1
		}
	done
}

@test "collector accepts genuinely clean gap repeat nonmonotonic and inconsistent VMAF windows" {
	local case_name path mutation
	for case_name in clean gap repeat nonmonotonic inconsistent; do
		create_valid_evidence_tree
		path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
		case "$case_name" in
		clean)
			mutation='.'
			;;
		gap)
			mutation='.sourceClip.frameWindow.frames[1].bestEffortTimestamp = "0.050000000" | .sourceClip.frameWindow.sourceWindow = {status:"discontinuity",issue:{kind:"gap",afterFrameIndex:(.observedFrameIndex - 2)}}'
			;;
		repeat)
			mutation='.sourceClip.frameWindow.frames[1].bestEffortTimestamp = "0.000000000" | .sourceClip.frameWindow.sourceWindow = {status:"discontinuity",issue:{kind:"repeat",afterFrameIndex:(.observedFrameIndex - 2)}}'
			;;
		nonmonotonic)
			mutation='.sourceClip.frameWindow.frames[1].bestEffortTimestamp = "-0.001000000" | .sourceClip.frameWindow.sourceWindow = {status:"discontinuity",issue:{kind:"non-monotonic-timestamp",afterFrameIndex:(.observedFrameIndex - 2)}}'
			;;
		inconsistent)
			mutation='.sourceClip.frameWindow.frames[0].packetDuration = "0.050000000" | .sourceClip.frameWindow.sourceWindow = {status:"discontinuity",issue:{kind:"inconsistent-duration",afterFrameIndex:(.observedFrameIndex - 2)}}'
			;;
		esac
		jq --arg case_name "$case_name" "$mutation | . as \$root |
			.settings |= map(.sourceFrameWindow = \$root.sourceClip.frameWindow) |
			if \$case_name == \"clean\" then . else .settings |= map(.timeline.zeroOffsetAligned = false) end" \
			"$path" >"$BATS_TEST_TMPDIR/evidence.json"
		mv "$BATS_TEST_TMPDIR/evidence.json" "$path"

		run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		[ "$status" -eq 0 ] || {
			echo "collector rejected a genuine continuity outcome: $case_name" >&3
			return 1
		}
	done
}

@test "collector rejects evidence whose retained manifest timestamp names another run" {
	create_valid_evidence_tree
	jq '.createdAt = "20260820T223426Z"' "$EVIDENCE_ROOT/manifest.json" >"$BATS_TEST_TMPDIR/manifest.json"
	mv "$BATS_TEST_TMPDIR/manifest.json" "$EVIDENCE_ROOT/manifest.json"

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -ne 0 ]
	[[ "$output" == *'manifest'* ]]
}

@test "collector accepts the producer manifest timestamp for the exact immutable run" {
	create_valid_evidence_tree
	jq 'del(.runId) | .createdAt = "20260820T223425Z"' \
		"$EVIDENCE_ROOT/manifest.json" >"$BATS_TEST_TMPDIR/manifest.json"
	mv "$BATS_TEST_TMPDIR/manifest.json" "$EVIDENCE_ROOT/manifest.json"

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 0 ]
}

@test "collector rejects missing and wrong corrected script and producer image identities" {
	local case_name mutation expected_field expected_kind
	for case_name in missing-scripts wrong-scripts missing-images wrong-image; do
		create_valid_evidence_tree
		case "$case_name" in
		missing-scripts) mutation='del(.scriptDigests)'; expected_field='scriptDigests'; expected_kind='missing' ;;
		wrong-scripts) mutation='.scriptDigests."benchmark.sh" = ("sha256:" + ("a" * 64))'; expected_field='scriptDigests'; expected_kind='mismatch' ;;
		missing-images) mutation='del(.images)'; expected_field='images'; expected_kind='missing' ;;
		wrong-image) mutation='.images.configured = "example.invalid/ffmpeg@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'; expected_field='images'; expected_kind='mismatch' ;;
		esac
		jq "$mutation" "$EVIDENCE_ROOT/manifest.json" >"$BATS_TEST_TMPDIR/manifest.json"
		mv "$BATS_TEST_TMPDIR/manifest.json" "$EVIDENCE_ROOT/manifest.json"

		run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		[ "$status" -eq 65 ] || {
			echo "collector accepted unauthenticated producer manifest identity: $case_name" >&3
			return 1
		}
		jq -e --arg field "$expected_field" --arg kind "$expected_kind" '
			.manifestIssues == [{field:$field,kind:$kind}]
		' <<<"$output" >/dev/null
	done
}

@test "collector binds the retained diagnostic summary to the full immutable run id" {
	create_valid_evidence_tree
	jq '.runId = "20260820T223425Z-deadbeef"' \
		"$EVIDENCE_ROOT/diagnostic-summary.json" >"$BATS_TEST_TMPDIR/summary.json"
	mv "$BATS_TEST_TMPDIR/summary.json" "$EVIDENCE_ROOT/diagnostic-summary.json"

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 65 ]
	[ "$output" = 'diagnostic summary does not bind the approved panel' ]
}

@test "collector rejects a well-formed manifest digest for a different diagnostic panel" {
	create_valid_evidence_tree
	jq '.upstream.diagnostics.panelSha256 = ("sha256:" + ("f" * 64))' \
		"$EVIDENCE_ROOT/manifest.json" >"$BATS_TEST_TMPDIR/manifest.json"
	mv "$BATS_TEST_TMPDIR/manifest.json" "$EVIDENCE_ROOT/manifest.json"

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 65 ]
	[[ "$output" == *'manifest'* ]]
}

@test "collector reports every manifest binding issue without retained values" {
	local case_name mutation expected_field expected_kind
	while IFS=$'\t' read -r case_name mutation expected_field expected_kind; do
		create_valid_evidence_tree
		jq "$mutation" "$EVIDENCE_ROOT/manifest.json" >"$BATS_TEST_TMPDIR/manifest.json"
		mv "$BATS_TEST_TMPDIR/manifest.json" "$EVIDENCE_ROOT/manifest.json"

		run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		[ "$status" -eq 65 ] || {
			echo "collector accepted invalid manifest binding: $case_name" >&3
			return 1
		}
		run jq -e -S -c --arg field "$expected_field" --arg kind "$expected_kind" '
			keys == ["manifestIssues","reason","schemaVersion","status"] and
			.schemaVersion == 1 and .status == "failed" and
			.reason == "diagnostic-manifest-binding-invalid" and
			.manifestIssues == [{field:$field,kind:$kind}]
		' <<<"$output"
		[ "$status" -eq 0 ] || {
			echo "collector returned the wrong bounded issue for: $case_name" >&3
			return 1
		}
		[[ "$output" != *'deadbeef'* && "$output" != *'ffff'* ]]
	done <<'EOF'
wrong-manifest-type	[]	manifest	wrong-type
missing-schema-version	del(.schemaVersion)	schemaVersion	missing
wrong-schema-version-type	.schemaVersion = "2"	schemaVersion	wrong-type
wrong-mode	.mode = "quality"	mode	mismatch
missing-created-at	del(.createdAt)	createdAt	missing
wrong-created-at-type	.createdAt = 7	createdAt	wrong-type
wrong-created-at	.createdAt = "20260820T223426Z"	createdAt	mismatch
missing-upstream	del(.upstream)	upstream.diagnostics	missing
wrong-upstream-type	.upstream = []	upstream.diagnostics	missing
wrong-diagnostics-type	.upstream.diagnostics = []	upstream.diagnostics	wrong-type
missing-manifest-schema	del(.upstream.diagnostics.manifestSchemaVersion)	upstream.diagnostics.manifestSchemaVersion	missing
wrong-result-schema	.upstream.diagnostics.resultSchemaVersion = 2	upstream.diagnostics.resultSchemaVersion	mismatch
wrong-findings-type	.upstream.diagnostics.acceptedFindingsSha256 = 7	upstream.diagnostics.acceptedFindingsSha256	wrong-type
wrong-decision	.upstream.diagnostics.decisionSha256 = ("sha256:" + ("f" * 64))	upstream.diagnostics.decisionSha256	mismatch
missing-quality-run	del(.upstream.diagnostics.historicalQualityRunId)	upstream.diagnostics.historicalQualityRunId	missing
wrong-findings-run	.upstream.diagnostics.historicalFindingsRunId = "20260820T223425Z-deadbeef"	upstream.diagnostics.historicalFindingsRunId	mismatch
wrong-panel	.upstream.diagnostics.panelSha256 = ("sha256:" + ("f" * 64))	upstream.diagnostics.panelSha256	mismatch
EOF
}

@test "collector reports multiple manifest issues once in fixed order" {
	create_valid_evidence_tree
	jq '.mode = "quality" | del(.upstream.diagnostics.resultSchemaVersion) | .upstream.diagnostics.panelSha256 = ("sha256:" + ("f" * 64))' \
		"$EVIDENCE_ROOT/manifest.json" >"$BATS_TEST_TMPDIR/manifest.json"
	mv "$BATS_TEST_TMPDIR/manifest.json" "$EVIDENCE_ROOT/manifest.json"

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 65 ]
	run jq -e -S -c '.manifestIssues == [
		{field:"mode",kind:"mismatch"},
		{field:"upstream.diagnostics.resultSchemaVersion",kind:"missing"},
		{field:"upstream.diagnostics.panelSha256",kind:"mismatch"}
	]' <<<"$output"
	[ "$status" -eq 0 ]
}

@test "rendered scripts ConfigMap includes the collector executable" {
	run kustomize build "$BATS_TEST_DIRNAME/../app"
	[ "$status" -eq 0 ]
	run yq -N -e 'select(.kind == "ConfigMap" and (.metadata.name | test("^encode-benchmark-scripts-"))) | .data."diagnostic-contract.jq" | contains("def diagnostic_continuity")' <<<"$(kustomize build "$BATS_TEST_DIRNAME/../app")"
	[ "$status" -eq 0 ]
}

@test "collector rejects an unexpected source path from retained frame metadata" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
	jq '.sourceClip.frameWindow.stream.path = "/media/private/title.mkv"' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -ne 0 ]
}

@test "collector rejects malformed missing extra escaped symlinked oversized and wrong-panel evidence" {
	for case_name in malformed missing extra escaped symlink wrong-panel; do
		create_valid_evidence_tree
		case "$case_name" in
		malformed) printf '{' >"$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json" ;;
		missing) mv "$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json" "$BATS_TEST_TMPDIR/missing.json" ;;
		extra) printf '{}\n' >"$EVIDENCE_ROOT/unexpected.json" ;;
		escaped) jq '.vmaf.entries[0].evidence = "../../outside.json"' "$EVIDENCE_ROOT/diagnostic-summary.json" >"$BATS_TEST_TMPDIR/summary.json" && mv "$BATS_TEST_TMPDIR/summary.json" "$EVIDENCE_ROOT/diagnostic-summary.json" ;;
		symlink) mv "$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json" "$BATS_TEST_TMPDIR/target.json" && ln -s "$BATS_TEST_TMPDIR/target.json" "$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json" ;;
		wrong-panel) jq '.sampleId = "avc-clean-coco"' "$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json" >"$BATS_TEST_TMPDIR/wrong.json" && mv "$BATS_TEST_TMPDIR/wrong.json" "$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json" ;;
		esac
	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		[ "$status" -ne 0 ]
	done
}

@test "collector rejects valid oversized JSON at the input size boundary" {
	create_valid_evidence_tree
	jq -n --argjson length 65537 '{padding:("a" * $length)}' >"$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"
	jq -e . "$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json" >/dev/null

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 65 ]
	[ "$output" = 'diagnostic evidence input exceeds its bounded size' ]
}

@test "collector rejects injected nested raw evidence fields" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
	jq '.settings[0].vmaf.injected = {artifactPath:"unexpected"}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -ne 0 ]
}

@test "collector rejects injected nested classification fields" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
	jq '.classification.injected = {artifactPath:"unexpected"}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -ne 0 ]
}

@test "collector rejects non-string classification reasons" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
	jq '.classification.reasons = [{artifactPath:"unexpected"}]' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -ne 0 ]
}

@test "collector rejects producer-invalid strings at every projected diagnostic boundary" {
	local case_name path mutation
	for case_name in \
		vmaf-setting-reason vmaf-classification vmaf-classification-reason timeline-kind \
		frame-timestamp frame-duration frame-picture-type stream-start stream-duration stream-time-base stream-frame-rate \
		hdr-reason hdr-classification hdr-classification-reason source-authoritative-reason \
		source-window-authoritative-reason clip-authoritative-reason encoded-authoritative-reason; do
		create_valid_evidence_tree
		case "$case_name" in
		vmaf-setting-reason) path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"; mutation='.settings[0].reason = "/media/private"' ;;
		vmaf-classification) path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"; mutation='.classification.classification = "credential-fragment"' ;;
		vmaf-classification-reason) path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"; mutation='.classification.reasons = ["credential-fragment"]' ;;
		timeline-kind) path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"; mutation='.settings[0].timeline.discontinuity = {kind:"credential-fragment",offset:1}' ;;
		frame-timestamp) path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"; mutation='.sourceClip.frameWindow.frames[0].bestEffortTimestamp = "/media/private"' ;;
		frame-duration) path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"; mutation='.sourceClip.frameWindow.frames[0].packetDuration = "credential=fragment"' ;;
		frame-picture-type) path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"; mutation='.sourceClip.frameWindow.frames[0].pictureType = "private-path"' ;;
		stream-start) path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"; mutation='.sourceClip.frameWindow.stream.startTime = "/media/private"' ;;
		stream-duration) path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"; mutation='.sourceClip.frameWindow.stream.duration = "credential=fragment"' ;;
		stream-time-base) path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"; mutation='.sourceClip.frameWindow.stream.timeBase = "/out/private"' ;;
		stream-frame-rate) path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"; mutation='.sourceClip.frameWindow.stream.averageFrameRate = "private-log"' ;;
		hdr-reason) path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"; mutation='.reason = "/media/private"' ;;
		hdr-classification) path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"; mutation='.classification.classification = "credential-fragment"' ;;
		hdr-classification-reason) path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"; mutation='.classification.reasons = ["credential-fragment"]' ;;
		source-authoritative-reason) path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"; mutation='.normalizedOracle.source.authoritative.reasons = ["credential-fragment"]' ;;
		source-window-authoritative-reason) path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"; mutation='.normalizedOracle.source.windows.beginning.authoritative.reasons = ["credential-fragment"]' ;;
		clip-authoritative-reason) path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"; mutation='.normalizedOracle.clip.authoritative.reasons = ["credential-fragment"]' ;;
		encoded-authoritative-reason) path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"; mutation='.normalizedOracle.encoded.authoritative.reasons = ["credential-fragment"]' ;;
		esac
		jq "$mutation" "$path" >"$BATS_TEST_TMPDIR/mutated.json"
		mv "$BATS_TEST_TMPDIR/mutated.json" "$path"
	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		[ "$status" -ne 0 ] || {
			echo "collector accepted producer-invalid projected string: $case_name" >&3
			return 1
		}
	done
}

@test "collector requires retained classifications and reasons to match the summary" {
	local case_name summary
	for case_name in vmaf-classification vmaf-reasons hdr-classification hdr-reasons; do
		create_valid_evidence_tree
		case "$case_name" in
		vmaf-classification) summary='.vmaf.entries[0].classification = "vmaf-measurement-defect" | .vmaf.entries[0].reasons = ["vmaf-only-exact-zero"]' ;;
		vmaf-reasons) summary='.vmaf.entries[0].reasons = ["classification-predicate-not-met"]' ;;
		hdr-classification) summary='.hdr.entries[0].classification = "preserved" | .hdr.entries[0].reasons = ["source-clip-encoded-metadata-agree"]' ;;
		hdr-reasons) summary='.hdr.entries[0].reasons = ["source-window-null"]' ;;
		esac
		jq "$summary" "$EVIDENCE_ROOT/diagnostic-summary.json" >"$BATS_TEST_TMPDIR/summary.json"
		mv "$BATS_TEST_TMPDIR/summary.json" "$EVIDENCE_ROOT/diagnostic-summary.json"
	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		[ "$status" -ne 0 ] || {
			echo "collector accepted summary mismatch: $case_name" >&3
			return 1
		}
	done
}

@test "collector rejects exact-path cross-wiring in the retained summary" {
	create_valid_evidence_tree
	jq '
		.vmaf.entries[0].evidence = "vmaf/avc-grain-memento/dark/evidence.json" |
		.vmaf.entries[1].evidence = "vmaf/avc-clean-coco/motion/evidence.json" |
		.hdr.entries[0].evidence = "hdr/hdr10-grain-goodfellas/evidence.json" |
		.hdr.entries[1].evidence = "hdr/hdr10-clean-ministry/evidence.json"
	' "$EVIDENCE_ROOT/diagnostic-summary.json" >"$BATS_TEST_TMPDIR/summary.json"
	mv "$BATS_TEST_TMPDIR/summary.json" "$EVIDENCE_ROOT/diagnostic-summary.json"

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 65 ]
	[ "$output" = 'diagnostic summary does not bind the approved panel' ]
}

@test "collector recomputes the exact complete VMAF classification" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
	jq '.classification = {schemaVersion:1,classification:"encoder-output-defect",reasons:["zero-offset-timeline-agreement","target-frame-local-metric-minimum","source-window-clean"]}' \
		"$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	jq '.vmaf.entries[0].classification = "encoder-output-defect" | .vmaf.entries[0].reasons = ["zero-offset-timeline-agreement","target-frame-local-metric-minimum","source-window-clean"]' \
		"$EVIDENCE_ROOT/diagnostic-summary.json" >"$BATS_TEST_TMPDIR/summary.json"
	mv "$BATS_TEST_TMPDIR/summary.json" "$EVIDENCE_ROOT/diagnostic-summary.json"

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 65 ]
	[ "$output" = 'VMAF diagnostic evidence violates its approved schema' ]
}

@test "collector recomputes the exact complete HDR classification" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"
	jq '.classification = {schemaVersion:1,classification:"source-probe-defect",reasons:["authoritative-source-metadata","stream-probe-null"]}' \
		"$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	jq '.hdr.entries[0].classification = "source-probe-defect" | .hdr.entries[0].reasons = ["authoritative-source-metadata","stream-probe-null"]' \
		"$EVIDENCE_ROOT/diagnostic-summary.json" >"$BATS_TEST_TMPDIR/summary.json"
	mv "$BATS_TEST_TMPDIR/summary.json" "$EVIDENCE_ROOT/diagnostic-summary.json"

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 65 ]
	[ "$output" = 'HDR diagnostic evidence violates its approved schema' ]
}

@test "collector binds every HDR probe window to its committed title bounds" {
	local case_name path
	for case_name in wrong-detail wrong-end wrong-clip wrong-encoded cross-title; do
		create_valid_evidence_tree
		path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"
		case "$case_name" in
		wrong-detail) jq '.source.windows.detail.start = "01:04:14.000"' "$path" >"$BATS_TEST_TMPDIR/evidence.json" ;;
		wrong-end) jq '.source.windows.end.start = "0"' "$path" >"$BATS_TEST_TMPDIR/evidence.json" ;;
		wrong-clip) jq '.clip.start = "0"' "$path" >"$BATS_TEST_TMPDIR/evidence.json" ;;
		wrong-encoded) jq '.encoded.start = "0"' "$path" >"$BATS_TEST_TMPDIR/evidence.json" ;;
		cross-title) jq '.source.windows.detail.start = "01:06:25.000" | .clip.start = "01:06:25.000" | .encoded.start = "01:06:25.000"' "$path" >"$BATS_TEST_TMPDIR/evidence.json" ;;
		esac
		mv "$BATS_TEST_TMPDIR/evidence.json" "$path"

		run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		[ "$status" -eq 65 ] || {
			echo "collector accepted wrong HDR bounds: $case_name" >&3
			return 1
		}
	done
}

@test "collector requires exact complete VMAF frame and offset coverage" {
	local path mutation
	for mutation in \
		'.sourceClip.frameWindow.frames |= .[0:4]' \
		'.sourceClip.frameWindow.frames[4].frameIndex = (.observedFrameIndex - 2)' \
		'.sourceClip.frameWindow.frames[4].frameIndex = (.observedFrameIndex + 3)' \
		'.settings[0].sourceFrameWindow.frames |= .[0:4]' \
		'.settings[0].outputFrameWindow.frames[4].frameIndex = (.observedFrameIndex - 2)' \
		'.settings[0].vmaf.current |= .[0:4]' \
		'.settings[0].vmaf.reset[4].frameIndex = (.observedFrameIndex - 2)' \
		'.settings[0].vmaf.current[4].frameIndex = (.observedFrameIndex + 3)' \
		'.settings[0].offsets |= .[0:4]' \
		'.settings[0].offsets[4] = (.settings[0].offsets[3])' \
		'.settings[0] |= (.status = "failed" | .reason = "decode-failed" | .sourceFrameWindow.frames = [] | .outputFrameWindow.frames = [] | .vmaf.current = [] | .vmaf.reset = [] | .offsets = [])' \
		'.settings[0].offsets[4] = {offset:3,sourceFrameIndex:.observedFrameIndex,encodedFrameIndex:(.observedFrameIndex + 3),ssim:{command:[],value:0.9},psnr:{command:[],value:{kind:"finite",value:40}}}'; do
		create_valid_evidence_tree
		path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
		jq "$mutation" "$path" >"$BATS_TEST_TMPDIR/evidence.json"
		mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		[ "$status" -ne 0 ] || {
			echo "collector accepted incomplete complete-evidence coverage: $mutation" >&3
			return 1
		}
	done
}

@test "collector projects a producer-shaped VMAF decode failure with null output evidence" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
	jq '
		.status = "failed" |
		.classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]} |
		.settings |= map(
			.status = "failed" | .reason = "decode-failed" |
			.outputIdentity = null | .outputFrameWindow = null |
			.vmaf.current = [] | .vmaf.reset = [] |
			.offsets |= map(.ssim.value = null | .psnr.value = null) |
			.timeline = {zeroOffsetAligned:false,discontinuity:null})
	' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	jq '
		.vmaf.entries[0].status = "failed" |
		.vmaf.entries[0].classification = "unresolved" |
		.vmaf.entries[0].reasons = ["incomplete-setting-evidence"]
	' "$EVIDENCE_ROOT/diagnostic-summary.json" >"$BATS_TEST_TMPDIR/summary.json"
	mv "$BATS_TEST_TMPDIR/summary.json" "$EVIDENCE_ROOT/diagnostic-summary.json"

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 0 ]
	run jq -e '
		.vmaf[0].status == "failed" and
		.vmaf[0].sourceContinuity != null and
		all(.vmaf[0].settings[];
			.status == "failed" and .reason == "decode-failed" and
			(.vmaf.current | length) == 0 and (.vmaf.reset | length) == 0 and
			(.offsets | length) == 5 and all(.offsets[]; .ssim == null and .psnr == null))
	' <<<"$output"
	[ "$status" -eq 0 ]
}

@test "collector projects a producer-shaped VMAF encode failure with null output evidence" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
	jq '
		.status = "failed" |
		.classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]} |
		.settings |= map(
			.status = "failed" | .reason = "encode-failed" |
			.outputIdentity = null | .outputFrameWindow = null |
			.vmaf.current = [] | .vmaf.reset = [] |
			.offsets |= map(.ssim.value = null | .psnr.value = null) |
			.timeline = {zeroOffsetAligned:false,discontinuity:null})
	' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	set_vmaf_summary_partial failed

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 0 ]
	run jq -e '.vmaf[0].settings | all(.[]; .status == "failed" and .reason == "encode-failed" and (.offsets | length) == 5)' <<<"$output"
	[ "$status" -eq 0 ]
}

@test "collector accepts reachable corrected VMAF preparation reasons with exact classifications" {
	for reason in source-clip-create-failed source-clip-identity-unavailable source-frame-window-unavailable; do
		create_valid_evidence_tree
		path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
		jq --arg reason "$reason" --arg retain_identity "$(if [[ "$reason" == 'source-frame-window-unavailable' ]]; then printf true; else printf false; fi)" '
			.status = "harness-blocked" |
			.classification = {schemaVersion:1,classification:"unresolved",reasons:[$reason]} |
			(if $retain_identity == "true" then .sourceClip.frameWindow = null
			 else .sourceClip.identity = null | .sourceClip.frameWindow = null end) |
			.settings |= map(
				.status = "harness-blocked" | .reason = $reason |
				(if $retain_identity == "true" then .sourceFrameWindow = null
				 else .sourceIdentity = null | .sourceFrameWindow = null end) |
				.outputIdentity = null | .outputFrameWindow = null |
				.vmaf.current = [] | .vmaf.reset = [] |
				.offsets |= map(.ssim.value = null | .psnr.value = null) |
				.timeline = {zeroOffsetAligned:false,discontinuity:null})
		' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
		mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
		set_vmaf_summary_partial harness-blocked "$reason"

		run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		[ "$status" -eq 0 ]
		run jq -e --arg reason "$reason" '.vmaf[0].status == "harness-blocked" and .vmaf[0].sourceContinuity == null and all(.vmaf[0].settings[]; .reason == $reason)' <<<"$output"
		[ "$status" -eq 0 ]
	done
}

@test "collector rejects unreachable corrected VMAF preparation prefixes" {
	local case_name reason prefix path
	while IFS='|' read -r case_name reason prefix; do
		create_valid_evidence_tree
		path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
		jq --arg reason "$reason" --arg prefix "$prefix" '
			.status = "harness-blocked" |
			.classification = {schemaVersion:1,classification:"unresolved",reasons:[$reason]} |
			(if $prefix == "identity-only" then .sourceClip.frameWindow = null
			 elif $prefix == "window-only" then .sourceClip.identity = null
			 else .sourceClip.identity = null | .sourceClip.frameWindow = null end) |
			.settings |= map(
				.status = "harness-blocked" | .reason = $reason |
				(if $prefix == "identity-only" then .sourceFrameWindow = null
				 elif $prefix == "window-only" then .sourceIdentity = null
				 else .sourceIdentity = null | .sourceFrameWindow = null end) |
				.outputIdentity = null | .outputFrameWindow = null |
				.vmaf.current = [] | .vmaf.reset = [] |
				.offsets |= map(.ssim.value = null | .psnr.value = null) |
				.timeline = {zeroOffsetAligned:false,discontinuity:null})
		' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
		mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
		set_vmaf_summary_partial harness-blocked "$reason"

		run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		[ "$status" -eq 65 ] || {
			echo "collector accepted unreachable VMAF preparation prefix: $case_name" >&3
			return 1
		}
	done <<'EOF'
create-retained-identity|source-clip-create-failed|identity-only
identity-retained-window|source-clip-identity-unavailable|window-only
window-missing-identity|source-frame-window-unavailable|none
abort-missing-source|source-panel-preparation-aborted|none
EOF
}

@test "collector admits legacy source-clip-unavailable only for its immutable producer identity" {
	local historical_run='20260826T014246Z-373a665e'
	local historical_scripts='{"benchmark.sh":"sha256:8bc91c7ca04168c648509eb778dcd384e9af50d05ee6e2a6dd3c2553be6022b4","census.sh":"sha256:505c58d595fad640cec7fbac2eefcb02b4e1c96b3c64094afd785f2b72d39f07","contract.sh":"sha256:e62192d0e6f03a1f44ee96760da32c4efe0f52436305f0d83a5e89c0759632c8","diagnostic-evidence.sh":"sha256:da81c1a8725d95ccd1a0e992c789c09387750d9df2efaa73877ded6e0c1bfc70","probe.sh":"sha256:537724eac650d8bdf8a38412b5b2125ca26d4925d88caa8ef5958b9053ae20fb","runmeta.sh":"sha256:df5891bea05ee4ebb9c920c62fd363bc5c8a54744ac60ff558a265c4646128a3","stills.sh":"sha256:5887426ee150673a91604916a8a860a7e3395a8172557ff2e3e3456358eb510e"}'
	local case_name expected run_id path
	while IFS='|' read -r case_name expected run_id; do
		RUN_ID="$run_id"
		create_valid_evidence_tree
		path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
		jq '
			.status = "harness-blocked" |
			.classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]} |
			.sourceClip.identity = null | .sourceClip.frameWindow = null |
			.settings |= map(
				.status = "harness-blocked" | .reason = "source-clip-unavailable" |
				.sourceIdentity = null | .sourceFrameWindow = null |
				.outputIdentity = null | .outputFrameWindow = null |
				.vmaf.current = [] | .vmaf.reset = [] |
				.offsets |= map(.ssim.value = null | .psnr.value = null) |
				.timeline = {zeroOffsetAligned:false,discontinuity:null})
		' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
		mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
		case "$case_name" in
		historical | wrong-run)
			jq --argjson scripts "$historical_scripts" '.scriptDigests = $scripts' "$EVIDENCE_ROOT/manifest.json" >"$BATS_TEST_TMPDIR/manifest.json"
			;;
		wrong-digest)
			jq --argjson scripts "$historical_scripts" '.scriptDigests = $scripts | .scriptDigests."benchmark.sh" = ("sha256:" + ("f" * 64))' "$EVIDENCE_ROOT/manifest.json" >"$BATS_TEST_TMPDIR/manifest.json"
			;;
		corrected-producer)
			cp "$EVIDENCE_ROOT/manifest.json" "$BATS_TEST_TMPDIR/manifest.json"
			;;
		esac
		mv "$BATS_TEST_TMPDIR/manifest.json" "$EVIDENCE_ROOT/manifest.json"
		set_vmaf_summary_partial harness-blocked

		run "$COLLECTOR_SCRIPT" collect "$run_id" "$EVIDENCE_ROOT" "$PANEL_SHA256" "$EVIDENCE_PANEL" "$CONFIGURED_IMAGE"
		if [[ "$expected" == 'accept' ]]; then
			[ "$status" -eq 0 ]
		else
			[ "$status" -eq 65 ]
		fi
		done <<EOF
historical|accept|$historical_run
wrong-run|reject|20260820T223425Z-082b3d38
wrong-digest|reject|$historical_run
corrected-producer|reject|$historical_run
EOF
}

@test "collector projects prepared VMAF sources aborted by another preparation failure" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
	jq '
		.status = "harness-blocked" |
		.classification = {schemaVersion:1,classification:"unresolved",reasons:["source-panel-preparation-aborted"]} |
		.settings |= map(
			.status = "harness-blocked" | .reason = "source-panel-preparation-aborted" |
			.outputIdentity = null | .outputFrameWindow = null |
			.vmaf.current = [] | .vmaf.reset = [] |
			.offsets |= map(.ssim.value = null | .psnr.value = null) |
			.timeline = {zeroOffsetAligned:false,discontinuity:null})
	' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	set_vmaf_summary_partial harness-blocked source-panel-preparation-aborted

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 0 ]
	run jq -e '.vmaf[0].sourceContinuity != null and all(.vmaf[0].settings[]; .reason == "source-panel-preparation-aborted")' <<<"$output"
	[ "$status" -eq 0 ]
}

@test "collector rejects VMAF status reason and evidence shapes the producer cannot emit" {
	local path mutation summary_status
	for mutation in failed-null-source failed-retained-output harness-failed-setting missing-current-with-metrics; do
		create_valid_evidence_tree
		path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
		case "$mutation" in
		failed-null-source)
			summary_status='failed'
			jq '
				.status = "failed" |
				.sourceClip.identity = null | .sourceClip.frameWindow = null |
				.settings |= map(
					.status = "failed" | .reason = "decode-failed" |
					.sourceIdentity = null | .sourceFrameWindow = null |
					.outputIdentity = null | .outputFrameWindow = null |
					.vmaf = {current:[],reset:[]} |
					.offsets |= map(.ssim.value = null | .psnr.value = null) |
					.timeline = {zeroOffsetAligned:false,discontinuity:null}) |
				.classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-or-failed-evidence"]}
			' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		failed-retained-output)
			summary_status='failed'
			jq '
				.status = "failed" |
				.settings |= map(.status = "failed" | .reason = "encode-failed") |
				.classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-or-failed-evidence"]}
			' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		harness-failed-setting)
			summary_status='harness-blocked'
			jq '
				.status = "harness-blocked" |
				.settings[0] |= (
					.status = "failed" | .reason = "decode-failed" |
					.outputIdentity = null | .outputFrameWindow = null |
					.vmaf = {current:[],reset:[]} |
					.offsets |= map(.ssim.value = null | .psnr.value = null) |
					.timeline = {zeroOffsetAligned:false,discontinuity:null}) |
				.classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-or-failed-evidence"]}
			' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		missing-current-with-metrics)
			summary_status='harness-blocked'
			jq '
				.status = "harness-blocked" |
				.settings |= map(.status = "harness-blocked" | .reason = "missing-current-vmaf") |
				.classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-or-failed-evidence"]}
			' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		esac
		mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
		set_vmaf_summary_partial "$summary_status"

		run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		[ "$status" -ne 0 ] || {
			echo "collector accepted impossible VMAF producer state: $mutation" >&3
			return 1
		}
	done
}

@test "collector accepts producer invalidation of a completed VMAF row" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
	jq '
		.status = "harness-blocked" | .reason = "post-run-identity-drift" |
		.settings |= map(.status = "harness-blocked" | .reason = "post-run-identity-drift") |
		.classification = {schemaVersion:1,classification:"unresolved",reasons:["post-run-identity-drift"]}
	' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	jq '
		.vmaf.entries[0].status = "harness-blocked" |
		.vmaf.entries[0].classification = "unresolved" |
		.vmaf.entries[0].reasons = ["post-run-identity-drift"]
	' "$EVIDENCE_ROOT/diagnostic-summary.json" >"$BATS_TEST_TMPDIR/summary.json"
	mv "$BATS_TEST_TMPDIR/summary.json" "$EVIDENCE_ROOT/diagnostic-summary.json"

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 0 ]
}

@test "collector rejects a post-run VMAF override with an unreachable acquisition shape" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
	jq '
		.status = "harness-blocked" | .reason = "post-run-identity-drift" |
		.settings |= map(.status = "harness-blocked" | .reason = "post-run-identity-drift") |
		.settings[0].vmaf.current = [] |
		.classification = {schemaVersion:1,classification:"unresolved",reasons:["post-run-identity-drift"]}
	' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	set_vmaf_summary_post_run

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 65 ]
	[ "$output" = 'VMAF diagnostic evidence violates its approved schema' ]
}

@test "collector rejects a retained VMAF window after clip identity failure" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
	jq '
		.status = "harness-blocked" |
		.sourceClip.identity = null |
		.settings |= map(
			.status = "harness-blocked" | .reason = "source-clip-identity-unavailable" |
			.sourceIdentity = null |
			.outputIdentity = null | .outputFrameWindow = null |
			.vmaf = {current:[],reset:[]} |
			.offsets |= map(.ssim.value = null | .psnr.value = null) |
			.timeline = {zeroOffsetAligned:false,discontinuity:null}) |
		.classification = {schemaVersion:1,classification:"unresolved",reasons:["source-clip-identity-unavailable"]}
	' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	set_vmaf_summary_partial harness-blocked source-clip-identity-unavailable

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 65 ]
	[ "$output" = 'VMAF diagnostic evidence violates its approved schema' ]
}

# Each row is a hand-built producer state. The expected result does not call or
# reproduce the collector predicate.
@test "collector accepts the reachable VMAF acquisition prefix matrix" {
	local case_name path
	for case_name in \
		output-identity output-window current reset first-ssim middle-psnr final-psnr timeline \
		failed-dominates post-reset post-final-psnr; do
		create_valid_evidence_tree
		path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
		case "$case_name" in
		output-identity)
			jq '.status = "harness-blocked" | .settings |= map(.status = "harness-blocked" | .reason = "output-identity-unavailable" | .outputIdentity = null | .outputFrameWindow = null | .vmaf = {current:[],reset:[]} | .offsets |= map(.ssim.value = null | .psnr.value = null) | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		output-window)
			jq '.status = "harness-blocked" | .settings |= map(.status = "harness-blocked" | .reason = "incomplete-output-frame-window" | .outputFrameWindow = null | .vmaf = {current:[],reset:[]} | .offsets |= map(.ssim.value = null | .psnr.value = null) | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		current)
			jq '.status = "harness-blocked" | .settings |= map(.status = "harness-blocked" | .reason = "missing-current-vmaf" | .vmaf = {current:[],reset:[]} | .offsets |= map(.ssim.value = null | .psnr.value = null) | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		reset)
			jq '.status = "harness-blocked" | .settings |= map(.status = "harness-blocked" | .reason = "missing-reset-vmaf" | .vmaf.reset = [] | .offsets |= map(.ssim.value = null | .psnr.value = null) | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		first-ssim)
			jq '.status = "harness-blocked" | .settings |= map(.status = "harness-blocked" | .reason = "missing-ssim-metric" | .offsets |= map(.ssim.value = null | .psnr.value = null) | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		middle-psnr)
			jq '.status = "harness-blocked" | .settings |= map(.status = "harness-blocked" | .reason = "missing-psnr-metric" | .offsets[2].psnr.value = null | .offsets[3:] |= map(.ssim.value = null | .psnr.value = null) | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		final-psnr)
			jq '.status = "harness-blocked" | .settings |= map(.status = "harness-blocked" | .reason = "missing-psnr-metric" | .offsets[4].psnr.value = null | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		timeline)
			jq '.status = "harness-blocked" | .settings |= map(.status = "harness-blocked" | .reason = "timeline-evidence-invalid" | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		failed-dominates)
			jq '.status = "failed" | .settings[0] |= (.status = "failed" | .reason = "encode-failed" | .outputIdentity = null | .outputFrameWindow = null | .vmaf = {current:[],reset:[]} | .offsets |= map(.ssim.value = null | .psnr.value = null) | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .settings[1] |= (.status = "harness-blocked" | .reason = "missing-reset-vmaf" | .vmaf.reset = [] | .offsets |= map(.ssim.value = null | .psnr.value = null) | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		post-reset)
			jq '.status = "harness-blocked" | .reason = "post-run-identity-drift" | .settings |= map(.status = "harness-blocked" | .reason = "post-run-identity-drift" | .vmaf.reset = [] | .offsets |= map(.ssim.value = null | .psnr.value = null) | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["post-run-identity-drift"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		post-final-psnr)
			jq '.status = "harness-blocked" | .reason = "post-run-identity-drift" | .settings |= map(.status = "harness-blocked" | .reason = "post-run-identity-drift" | .offsets[4].psnr.value = null | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["post-run-identity-drift"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		esac
		mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
		case "$case_name" in
		failed-dominates) set_vmaf_summary_partial failed incomplete-setting-evidence ;;
		post-*) set_vmaf_summary_post_run ;;
		*) set_vmaf_summary_partial harness-blocked incomplete-setting-evidence ;;
		esac

		run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		[ "$status" -eq 0 ] || {
			echo "collector rejected reachable VMAF acquisition prefix: $case_name" >&3
			return 1
		}
	done
}

@test "collector rejects the impossible VMAF cross-prefix matrix" {
	local case_name path
	for case_name in post-reset-with-offsets post-offset-hole post-source-null-with-metrics normal-reset-with-offsets wrong-top-merge; do
		create_valid_evidence_tree
		path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
		case "$case_name" in
		post-reset-with-offsets)
			jq '.status = "harness-blocked" | .reason = "post-run-identity-drift" | .settings |= map(.status = "harness-blocked" | .reason = "post-run-identity-drift" | .vmaf.reset = []) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["post-run-identity-drift"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		post-offset-hole)
			jq '.status = "harness-blocked" | .reason = "post-run-identity-drift" | .settings |= map(.status = "harness-blocked" | .reason = "post-run-identity-drift" | .offsets[1] |= (.ssim.value = null | .psnr.value = null)) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["post-run-identity-drift"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		post-source-null-with-metrics)
			jq '.status = "harness-blocked" | .reason = "post-run-identity-drift" | .sourceClip |= (.identity = null | .frameWindow = null) | .settings |= map(.status = "harness-blocked" | .reason = "post-run-identity-drift" | .sourceIdentity = null | .sourceFrameWindow = null) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["post-run-identity-drift"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		normal-reset-with-offsets)
			jq '.status = "harness-blocked" | .settings |= map(.status = "harness-blocked" | .reason = "missing-reset-vmaf" | .vmaf.reset = [] | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		wrong-top-merge)
			jq '.status = "harness-blocked" | .settings[0] |= (.status = "failed" | .reason = "decode-failed" | .outputIdentity = null | .outputFrameWindow = null | .vmaf = {current:[],reset:[]} | .offsets |= map(.ssim.value = null | .psnr.value = null) | .timeline = {zeroOffsetAligned:false,discontinuity:null}) | .classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		esac
		mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
		case "$case_name" in
		post-*) set_vmaf_summary_post_run ;;
		*) set_vmaf_summary_partial harness-blocked incomplete-setting-evidence ;;
		esac

		run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		[ "$status" -eq 65 ] || {
			echo "collector accepted impossible VMAF cross-prefix state: $case_name" >&3
			return 1
		}
	done
}

@test "collector rejects causal VMAF classification for non-complete evidence" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
	jq '
		.status = "failed" |
		.settings |= map(
			.status = "failed" | .reason = "decode-failed" |
			.outputIdentity = null | .outputFrameWindow = null |
			.vmaf = {current:[],reset:[]} |
			.offsets |= map(.ssim.value = null | .psnr.value = null) |
			.timeline = {zeroOffsetAligned:false,discontinuity:null}) |
		.classification = {schemaVersion:1,classification:"unresolved",reasons:["incomplete-setting-evidence"]}
	' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	set_vmaf_summary_partial failed

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 0 ]

	jq '.classification = {schemaVersion:1,classification:"vmaf-measurement-defect",reasons:["vmaf-only-exact-zero"]}' \
		"$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 65 ]
	[ "$output" = 'VMAF diagnostic evidence violates its approved schema' ]
}

@test "collector rejects causal HDR classification for non-complete evidence" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"
	jq '
		.status = "failed" | .reason = "decode-failed" |
		.encoded = {start:.encoded.start,durationSeconds:10,status:"failed",reason:"encoded-output-unavailable",identity:null,decoded:{command:[],oracle:{status:"malformed"}},trace:{command:[],oracle:{status:"malformed"}}} |
		.normalizedOracle = null |
		.classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]}
	' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	set_hdr_summary_partial failed

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 0 ]

	jq '.classification = {schemaVersion:1,classification:"preserved",reasons:["source-clip-encoded-metadata-agree"]}' \
		"$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 65 ]
	[ "$output" = 'HDR diagnostic evidence violates its approved schema' ]
}

@test "collector admits only the producer VMAF classifier-failure override" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
	jq '.status = "harness-blocked" | .classification = {schemaVersion:1,classification:"unresolved",reasons:["classification-failed"]}' \
		"$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	set_vmaf_summary_partial harness-blocked classification-failed

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 0 ]

	jq '
		.settings[0] |= (
			.status = "harness-blocked" | .reason = "missing-current-vmaf" |
			.vmaf = {current:[],reset:[]} |
			.offsets |= map(.ssim.value = null | .psnr.value = null) |
			.timeline = {zeroOffsetAligned:false,discontinuity:null})
	' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 65 ]
}

@test "collector admits only the producer HDR classifier-failure override" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"
	jq '.status = "harness-blocked" | .reason = "HDR-classification-failed" | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["classification-failed"]}' \
		"$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	set_hdr_summary_partial harness-blocked classification-failed

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 0 ]

	jq '.normalizedOracle = null' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 65 ]
}

@test "collector rejects injected VMAF frame fields" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
	jq '.settings[0].vmaf.current = [{frameIndex:1641,vmaf:95.0,injected:"artifact"}]' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -ne 0 ]
}

@test "collector rejects injected VMAF setting fields" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
	jq '.settings[0].injected = {artifactPath:"unexpected"}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -ne 0 ]
}

@test "collector emits explicit positive-infinity evidence without commands" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
	jq '
		.settings[].offsets |= map(if .offset == 0 then .ssim = {command:["secret"],value:0.99} | .psnr = {command:["secret"],value:{kind:"positive-infinity"}} else . end) |
		.classification = {schemaVersion:1,classification:"unresolved",reasons:["classification-predicate-not-met"]}
	' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	jq '.vmaf.entries[0].reasons = ["classification-predicate-not-met"]' "$EVIDENCE_ROOT/diagnostic-summary.json" >"$BATS_TEST_TMPDIR/summary.json"
	mv "$BATS_TEST_TMPDIR/summary.json" "$EVIDENCE_ROOT/diagnostic-summary.json"
	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 0 ]
	run jq -e '
		.vmaf[0].settings[0].offsets | map(.offset) == [-2,-1,0,1,2] and
		([.[] | select(.offset == 0 and .ssim == 0.99 and .psnr == {kind:"positive-infinity"})] | length) == 1 and
		(tostring | contains("secret") | not)
	' <<<"$output"
	[ "$status" -eq 0 ]
}

@test "collector rejects tagged positive infinity for SSIM" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/vmaf/avc-clean-coco/motion/evidence.json"
	jq '.settings[0].offsets = [{offset:0,sourceFrameIndex:1641,encodedFrameIndex:1641,ssim:{command:[],value:{kind:"positive-infinity"}},psnr:{command:[],value:42.0}}]' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -ne 0 ]
}

@test "collector projects a producer-shaped HDR encode failure with null encoded identity and oracle" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"
	jq '
		.status = "failed" | .reason = "encode-failed" |
		.encoded = {start:"01:04:15.000",durationSeconds:10,status:"failed",reason:"encoded-output-unavailable",identity:null,decoded:{command:[],oracle:{status:"malformed"}},trace:{command:[],oracle:{status:"malformed"}}} |
		.normalizedOracle = null |
		.classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]}
	' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	set_hdr_summary_partial failed

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 0 ]
	run jq -e '.hdr[0].status == "failed" and .hdr[0].reason == "encode-failed" and .hdr[0].normalizedOracle == null' <<<"$output"
	[ "$status" -eq 0 ]
}

@test "collector accepts reachable corrected HDR preparation prefixes" {
	local case_name reason prefix path
	while IFS='|' read -r case_name reason prefix; do
		create_valid_evidence_tree
		path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"
		jq --arg reason "$reason" --arg prefix "$prefix" '
			def unavailable($start):
				{start:$start,durationSeconds:10,status:"harness-blocked",reason:$reason,decoded:{command:[],oracle:{status:"malformed"}},trace:{command:[],oracle:{status:"malformed"}}};
			.status = "harness-blocked" | .reason = $reason |
			.source.streamProbe = {command:[],oracle:{status:"malformed"}} |
			.source.windows = {beginning:unavailable("0"),detail:unavailable("01:04:15.000"),end:unavailable("<end-start>")} |
			.clip = (unavailable("01:04:15.000") + {identity:(if $prefix == "both" then .clip.identity else null end)}) |
			.encoded = (unavailable("01:04:15.000") + {identity:null}) |
			(if $prefix == "none" then .source.identity = null else . end) |
			.normalizedOracle = null |
			.classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:[$reason]}
		' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
		mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
		set_hdr_summary_partial harness-blocked "$reason"

		run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		[ "$status" -eq 0 ] || {
			echo "collector rejected reachable HDR preparation prefix: $case_name" >&3
			return 1
		}
	done <<'EOF'
create-failed|source-clip-create-failed|none
source-identity-failed|source-clip-identity-unavailable|none
clip-identity-failed|source-clip-identity-unavailable|source
peer-aborted|source-panel-preparation-aborted|both
EOF
}

@test "collector rejects unreachable corrected HDR preparation prefixes and reasons" {
	local case_name reason prefix path
	while IFS='|' read -r case_name reason prefix; do
		create_valid_evidence_tree
		path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"
		jq --arg reason "$reason" --arg prefix "$prefix" '
			def unavailable($start):
				{start:$start,durationSeconds:10,status:"harness-blocked",reason:$reason,decoded:{command:[],oracle:{status:"malformed"}},trace:{command:[],oracle:{status:"malformed"}}};
			.status = "harness-blocked" | .reason = $reason |
			.source.streamProbe = {command:[],oracle:{status:"malformed"}} |
			.source.windows = {beginning:unavailable("0"),detail:unavailable("01:04:15.000"),end:unavailable("<end-start>")} |
			.clip = (unavailable("01:04:15.000") + {identity:(if $prefix == "both" then .clip.identity else null end)}) |
			.encoded = (unavailable("01:04:15.000") + {identity:null}) |
			(if $prefix == "none" then .source.identity = null else . end) |
			.normalizedOracle = null |
			.classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:[$reason]}
		' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
		mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
		set_hdr_summary_partial harness-blocked "$reason"

		run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		[ "$status" -eq 65 ] || {
			echo "collector accepted unreachable HDR preparation state: $case_name" >&3
			return 1
		}
	done <<'EOF'
create-retained-identities|source-clip-create-failed|both
identity-retained-clip|source-clip-identity-unavailable|both
vmaf-window-reason|source-frame-window-unavailable|none
abort-missing-identities|source-panel-preparation-aborted|none
EOF
}

@test "collector projects a producer-shaped HDR oracle failure as null" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"
	jq '
		.status = "harness-blocked" | .reason = "HDR-oracle-normalization-failed" |
		.normalizedOracle = null |
		.classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]}
	' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	set_hdr_summary_partial harness-blocked

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 0 ]
	run jq -e '.hdr[0].status == "harness-blocked" and .hdr[0].reason == "HDR-oracle-normalization-failed" and .hdr[0].normalizedOracle == null' <<<"$output"
	[ "$status" -eq 0 ]
}

@test "collector rejects HDR status reason and evidence shapes the producer cannot emit" {
	local path mutation summary_status
	for mutation in failed-retained-output harness-normalize-with-null-source harness-source-with-clip harness-with-failed-reason conflict-without-conflict; do
		create_valid_evidence_tree
		path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"
		case "$mutation" in
		failed-retained-output)
			summary_status='failed'
			jq '
				.status = "failed" | .reason = "encode-failed" |
				.classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]}
			' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		harness-normalize-with-null-source)
			summary_status='harness-blocked'
			jq '
				.status = "harness-blocked" | .reason = "HDR-oracle-normalization-failed" |
				.source.identity = null | .normalizedOracle = null |
				.classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]}
			' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		harness-source-with-clip)
			summary_status='harness-blocked'
			jq '
				.status = "harness-blocked" | .reason = "source-clip-unavailable" |
				.normalizedOracle = null |
				.classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]}
			' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		harness-with-failed-reason)
			summary_status='harness-blocked'
			jq '
				.status = "harness-blocked" | .reason = "decode-failed" |
				.normalizedOracle = null |
				.classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]}
			' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		conflict-without-conflict)
			summary_status='harness-blocked'
			jq '
				.status = "harness-blocked" | .reason = "conflicting-HDR-oracle" |
				.classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]}
			' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		esac
		mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
		set_hdr_summary_partial "$summary_status"

		run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		[ "$status" -ne 0 ] || {
			echo "collector accepted impossible HDR producer state: $mutation" >&3
			return 1
		}
	done
}

@test "collector rejects a post-run HDR override with an unreachable normalized oracle" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"
	jq '
		.status = "harness-blocked" | .reason = "post-run-identity-drift" |
		.source.identity = null |
		.classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["post-run-identity-drift"]}
	' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	set_hdr_summary_post_run

	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 65 ]
	[ "$output" = 'HDR diagnostic evidence violates its approved schema' ]
}

@test "collector accepts the reachable HDR acquisition matrix" {
	local case_name path
	for case_name in source-identity clip-identity output-identity source-pair pair-both-fail encoded-pair normalization post-source-identity post-complete; do
		create_valid_evidence_tree
		path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"
		case "$case_name" in
		source-identity)
			jq '.status = "harness-blocked" | .reason = "source-identity-unavailable" | .source.identity = null | .normalizedOracle = null | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		clip-identity)
			jq '.status = "harness-blocked" | .reason = "clip-identity-unavailable" | .clip.identity = null | .normalizedOracle = null | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		output-identity)
			jq '.status = "harness-blocked" | .reason = "output-identity-unavailable" | .encoded.identity = null | .normalizedOracle = null | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		source-pair)
			jq '.status = "harness-blocked" | .reason = null | .source.windows.beginning |= (.status = "harness-blocked" | .reason = "decoded-frame-oracle-failed" | .decoded.oracle = {status:"malformed"}) | .normalizedOracle = null | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		pair-both-fail)
			jq '.status = "harness-blocked" | .reason = null | .source.windows.beginning |= (.status = "harness-blocked" | .reason = "trace-headers-oracle-failed" | .decoded.oracle = {status:"malformed"} | .trace.oracle = {status:"malformed"}) | .normalizedOracle = null | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		encoded-pair)
			jq '.status = "harness-blocked" | .reason = null | .encoded |= (.status = "harness-blocked" | .reason = "trace-headers-oracle-failed" | .trace.oracle = {status:"malformed"}) | .normalizedOracle = null | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		normalization)
			jq '.status = "harness-blocked" | .reason = "HDR-oracle-normalization-failed" | .normalizedOracle = null | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		post-source-identity)
			jq '.status = "harness-blocked" | .reason = "post-run-identity-drift" | .source.identity = null | .normalizedOracle = null | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["post-run-identity-drift"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		post-complete)
			jq '.status = "harness-blocked" | .reason = "post-run-identity-drift" | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["post-run-identity-drift"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		esac
		mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
		case "$case_name" in
		post-*) set_hdr_summary_post_run ;;
		*) set_hdr_summary_partial harness-blocked ;;
		esac

		run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		[ "$status" -eq 0 ] || {
			echo "collector rejected reachable HDR acquisition state: $case_name" >&3
			return 1
		}
	done
}

@test "collector rejects producer-impossible HDR probe domains and normalized mismatches" {
	local accepted='' mutation path
	for mutation in decoded-null trace-null complete-malformed normalized-mismatch; do
		create_valid_evidence_tree
		path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"
		case "$mutation" in
		decoded-null)
			jq '.source.windows.beginning.decoded.oracle = {status:"null"}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		trace-null)
			jq '.clip.trace.oracle = {status:"null"}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		complete-malformed)
			jq '.encoded.decoded.oracle = {status:"malformed"}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		normalized-mismatch)
			jq '
				def metadata: {
					masteringDisplay:{
						displayPrimaries:{
							red:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}},
							green:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}},
							blue:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}}},
						whitePoint:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}},
						luminance:{min:{numerator:1,denominator:2},max:{numerator:1,denominator:2}}},
					maxCLL:{numerator:1,denominator:2},maxFALL:{numerator:1,denominator:2}};
				.source.windows.beginning.decoded.oracle = {status:"ok",metadata:metadata}
			' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		esac
		mv "$BATS_TEST_TMPDIR/evidence.json" "$path"

		run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		if [ "$status" -eq 0 ]; then
			accepted="${accepted}${accepted:+ }$mutation"
		else
			[ "$status" -eq 65 ]
			[ "$output" = 'HDR diagnostic evidence violates its approved schema' ]
		fi
	done
	[ -z "$accepted" ] || {
		echo "collector accepted producer-impossible HDR mutations: $accepted" >&3
		return 1
	}
}

@test "collector rejects the impossible HDR cross-acquisition matrix" {
	local case_name path
	for case_name in post-clip-null-normalized post-blocked-pair-normalized source-unavailable-dynamic-output source-unavailable-retained-clip decoded-failure-retained-oracle trace-failure-retained-oracle source-reason-after-clip-failure null-reason-with-null-identity; do
		create_valid_evidence_tree
		path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"
		case "$case_name" in
		post-clip-null-normalized)
			jq '.status = "harness-blocked" | .reason = "post-run-identity-drift" | .clip.identity = null | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["post-run-identity-drift"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		post-blocked-pair-normalized)
			jq '.status = "harness-blocked" | .reason = "post-run-identity-drift" | .source.windows.detail |= (.status = "harness-blocked" | .reason = "trace-headers-oracle-failed" | .trace.oracle = {status:"malformed"}) | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["post-run-identity-drift"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		source-unavailable-dynamic-output)
			jq '.status = "harness-blocked" | .reason = "source-clip-unavailable" | .clip.identity = null | .normalizedOracle = null | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		source-unavailable-retained-clip)
			jq '.status = "harness-blocked" | .reason = "source-clip-unavailable" | .encoded = {start:"0",durationSeconds:10,status:"harness-blocked",reason:"source-clip-unavailable",identity:null,decoded:{command:[],oracle:{status:"malformed"}},trace:{command:[],oracle:{status:"malformed"}}} | .normalizedOracle = null | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		decoded-failure-retained-oracle)
			jq '.status = "harness-blocked" | .reason = null | .source.windows.beginning |= (.status = "harness-blocked" | .reason = "decoded-frame-oracle-failed") | .normalizedOracle = null | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		trace-failure-retained-oracle)
			jq '.status = "harness-blocked" | .reason = null | .clip |= (.status = "harness-blocked" | .reason = "trace-headers-oracle-failed") | .normalizedOracle = null | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		source-reason-after-clip-failure)
			jq '.status = "harness-blocked" | .reason = "source-identity-unavailable" | .source.identity = null | .clip.identity = null | .normalizedOracle = null | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		null-reason-with-null-identity)
			jq '.status = "harness-blocked" | .reason = null | .source.identity = null | .normalizedOracle = null | .classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
			;;
		esac
		mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
		case "$case_name" in
		post-*) set_hdr_summary_post_run ;;
		*) set_hdr_summary_partial harness-blocked ;;
		esac

		run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		[ "$status" -eq 65 ] || {
			echo "collector accepted impossible HDR cross-acquisition state: $case_name" >&3
			return 1
		}
	done
}

@test "collector reduces exact HDR rationals without decimal rounding" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"
	jq '
		def raw_metadata: {
			masteringDisplay:{
				displayPrimaries:{
					red:{x:{numerator:2,denominator:4},y:{numerator:1,denominator:2}},
					green:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}},
					blue:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}}},
				whitePoint:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}},
				luminance:{min:{numerator:1,denominator:2},max:{numerator:1,denominator:2}}},
			maxCLL:{numerator:1,denominator:2},maxFALL:{numerator:1,denominator:2}};
		def normalized_metadata: raw_metadata | .masteringDisplay.displayPrimaries.red.x = {numerator:1,denominator:2};
		.source.windows.beginning.decoded.oracle = {status:"ok",metadata:raw_metadata} |
		.source.windows.beginning.trace.oracle = {status:"ok",metadata:raw_metadata} |
		.normalizedOracle.source.windows.beginning = {
			decoded:{status:"ok",metadata:normalized_metadata},
			trace:{status:"ok",metadata:normalized_metadata},
			authoritative:{status:"ok",metadata:normalized_metadata}}
	' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 0 ]
	run jq -e '.hdr[0].normalizedOracle.source.windows.beginning.decoded.metadata.masteringDisplay.displayPrimaries.red.x == {numerator:1,denominator:2}' <<<"$output"
	[ "$status" -eq 0 ]
}

@test "collector accepts deterministic HDR disagreement and source-window conflict normalization" {
	local case_name path
	for case_name in decoded-trace source-windows; do
		create_valid_evidence_tree
		path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"
		jq --arg case_name "$case_name" '
			def first: {
				masteringDisplay:{displayPrimaries:{red:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}},green:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}},blue:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}}},whitePoint:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}},luminance:{min:{numerator:1,denominator:2},max:{numerator:1,denominator:2}}},maxCLL:{numerator:1,denominator:2},maxFALL:{numerator:1,denominator:2}};
			def second: first | .masteringDisplay.displayPrimaries.red.x = {numerator:1,denominator:3};
			def raw_pair($metadata):
				.decoded.oracle = {status:"ok",metadata:$metadata} |
				.trace.oracle = {status:"ok",metadata:$metadata};
			def normalized_pair($metadata): {
				decoded:{status:"ok",metadata:$metadata},trace:{status:"ok",metadata:$metadata},
				authoritative:{status:"ok",metadata:$metadata}};
			(if $case_name == "decoded-trace" then
				.source.windows.beginning.decoded.oracle = {status:"ok",metadata:first} |
				.source.windows.beginning.trace.oracle = {status:"ok",metadata:second} |
				.normalizedOracle.source.windows.beginning = {
					decoded:{status:"ok",metadata:first},trace:{status:"ok",metadata:second},
					authoritative:{status:"unresolved",reasons:["decoded-trace-disagreement"]}} |
				.normalizedOracle.source.authoritative = {status:"unresolved",reasons:["decoded-trace-disagreement"]}
			else
				.source.windows.beginning |= raw_pair(first) |
				.source.windows.detail |= raw_pair(first) |
				.source.windows.end |= raw_pair(second) |
				.normalizedOracle.source.windows.beginning = normalized_pair(first) |
				.normalizedOracle.source.windows.detail = normalized_pair(first) |
				.normalizedOracle.source.windows.end = normalized_pair(second) |
				.normalizedOracle.source.authoritative = {status:"unresolved",reasons:["source-window-conflict"]}
			end) |
			.status = "harness-blocked" | .reason = "conflicting-HDR-oracle" |
			.classification = {schemaVersion:1,classification:"unresolved-oracle",reasons:["incomplete-or-failed-evidence"]}
		' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
		mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
		set_hdr_summary_partial harness-blocked

		run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
		[ "$status" -eq 0 ] || {
			echo "collector rejected deterministic HDR conflict normalization: $case_name" >&3
			return 1
		}
	done
}

@test "collector rejects injected nested HDR fields" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"
	jq '.normalizedOracle.source.streamProbe.injected = {artifactPath:"unexpected"}' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -ne 0 ]
}

@test "collector accepts and projects a different valid normalized HDR source authoritative result" {
	create_valid_evidence_tree
	path="$EVIDENCE_ROOT/hdr/hdr10-clean-ministry/evidence.json"
	jq '
		def metadata: {
			masteringDisplay:{displayPrimaries:{
				red:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}},
				green:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}},
				blue:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}}},
				whitePoint:{x:{numerator:1,denominator:2},y:{numerator:1,denominator:2}},
				luminance:{min:{numerator:1,denominator:2},max:{numerator:1,denominator:2}}},
			maxCLL:{numerator:1,denominator:2},maxFALL:{numerator:1,denominator:2}};
		def raw_ok: .decoded.oracle = {status:"ok",metadata:metadata} | .trace.oracle = {status:"ok",metadata:metadata};
		def normalized_ok: {decoded:{status:"ok",metadata:metadata},trace:{status:"ok",metadata:metadata},authoritative:{status:"ok",metadata:metadata}};
		.source.windows.beginning |= raw_ok |
		.source.windows.detail |= raw_ok |
		.source.windows.end |= raw_ok |
		.normalizedOracle.source.windows = {beginning:normalized_ok,detail:normalized_ok,end:normalized_ok} |
		.normalizedOracle.source.authoritative = {status:"ok",metadata:metadata} |
		.classification = {schemaVersion:1,classification:"source-probe-defect",reasons:["authoritative-source-metadata","stream-probe-null"]}
	' "$path" >"$BATS_TEST_TMPDIR/evidence.json"
	mv "$BATS_TEST_TMPDIR/evidence.json" "$path"
	jq '.hdr.entries[0].classification = "source-probe-defect" | .hdr.entries[0].reasons = ["authoritative-source-metadata","stream-probe-null"]' \
		"$EVIDENCE_ROOT/diagnostic-summary.json" >"$BATS_TEST_TMPDIR/summary.json"
	mv "$BATS_TEST_TMPDIR/summary.json" "$EVIDENCE_ROOT/diagnostic-summary.json"
	run "$COLLECTOR" collect "$RUN_ID" "$EVIDENCE_ROOT" "$PANEL_SHA256"
	[ "$status" -eq 0 ]
	run jq -e '.hdr[0].normalizedOracle.source.authoritative.status == "ok" and .hdr[0].classification.classification == "source-probe-defect"' <<<"$output"
	[ "$status" -eq 0 ]
}

set_vmaf_summary_partial() {
	local status="$1" reason="${2:-incomplete-setting-evidence}"
	jq --arg status "$status" --arg reason "$reason" '
		.vmaf.entries[0].status = $status |
		.vmaf.entries[0].classification = "unresolved" |
		.vmaf.entries[0].reasons = [$reason]
	' "$EVIDENCE_ROOT/diagnostic-summary.json" >"$BATS_TEST_TMPDIR/summary.json"
	mv "$BATS_TEST_TMPDIR/summary.json" "$EVIDENCE_ROOT/diagnostic-summary.json"
}

set_vmaf_summary_post_run() {
	jq '
		.vmaf.entries[0].status = "harness-blocked" |
		.vmaf.entries[0].classification = "unresolved" |
		.vmaf.entries[0].reasons = ["post-run-identity-drift"]
	' "$EVIDENCE_ROOT/diagnostic-summary.json" >"$BATS_TEST_TMPDIR/summary.json"
	mv "$BATS_TEST_TMPDIR/summary.json" "$EVIDENCE_ROOT/diagnostic-summary.json"
}

set_hdr_summary_partial() {
	local status="$1" reason="${2:-incomplete-or-failed-evidence}"
	jq --arg status "$status" --arg reason "$reason" '
		.hdr.entries[0].status = $status |
		.hdr.entries[0].classification = "unresolved-oracle" |
		.hdr.entries[0].reasons = [$reason]
	' "$EVIDENCE_ROOT/diagnostic-summary.json" >"$BATS_TEST_TMPDIR/summary.json"
	mv "$BATS_TEST_TMPDIR/summary.json" "$EVIDENCE_ROOT/diagnostic-summary.json"
}

set_hdr_summary_post_run() {
	jq '
		.hdr.entries[0].status = "harness-blocked" |
		.hdr.entries[0].classification = "unresolved-oracle" |
		.hdr.entries[0].reasons = ["post-run-identity-drift"]
	' "$EVIDENCE_ROOT/diagnostic-summary.json" >"$BATS_TEST_TMPDIR/summary.json"
	mv "$BATS_TEST_TMPDIR/summary.json" "$EVIDENCE_ROOT/diagnostic-summary.json"
}

create_valid_evidence_tree() {
	local sample clip index path script_path script_name script_digest configured_digest
	local script_digests='{}'
	jq -n --arg run "$RUN_ID" '
		{schemaVersion:1,strategyId:"qsv-hevc-icq-v1",mode:"diagnostics",runId:$run,status:"complete",
		 vmaf:{total:5,entries:[]},hdr:{total:3,entries:[]}}' >"$EVIDENCE_ROOT/diagnostic-summary.json"
	for script_path in "$SCRIPTS"/*.sh; do
		script_name="${script_path##*/}"
		script_digest="sha256:$(sha256sum "$script_path" | awk '{print $1}')"
		script_digests="$(jq -c --arg name "$script_name" --arg digest "$script_digest" '. + {($name):$digest}' <<<"$script_digests")"
	done
	configured_digest="${CONFIGURED_IMAGE##*@}"
	jq -n --arg panel_sha "$PANEL_SHA256" --arg created_at "${RUN_ID%-*}" \
		--arg image "$configured_digest" --argjson scripts "$script_digests" '{
		schemaVersion:2,strategyId:"qsv-hevc-icq-v1",resultsSchemaVersion:1,mode:"diagnostics",createdAt:$created_at,
		images:{configured:$image,dispatched:$image,running:$image},scriptDigests:$scripts,
		samplesDigest:("sha256:" + ("c" * 64)),
		sources:[{path:"/media/fixture.mkv",sha256:("sha256:" + ("d" * 64)),size:4096}],
		encoderCommands:["ffmpeg -fixture"],selectedSettings:[],
		upstream:{diagnostics:{manifestSchemaVersion:1,resultSchemaVersion:1,acceptedFindingsSha256:"sha256:eb7ddcb42bffecb0ac0f8ab2df58be8317c586c56bb4485d48169568a6061294",decisionSha256:"sha256:17c476c4646e28bef71514bb48473771f449aa2c749b1d611f6c69ed518cc330",historicalQualityRunId:"20260817T233546Z-debc0498",historicalFindingsRunId:"20260818T214739Z-8bc2de3e",panelSha256:$panel_sha}},
		node:{name:"nuc1",kernel:"fixture-kernel"},gpu:{i915:"fixture-i915",vpl:"fixture-vpl"},cpu:null,
		vmaf:{model:"vmaf_4k_v0.6.1",version:"fixture-version"},savingsSeed:1,clientDevice:null
	}' >"$EVIDENCE_ROOT/manifest.json"
	while IFS=$'\t' read -r sample clip index; do
		path="$EVIDENCE_ROOT/vmaf/$sample/$clip"
		mkdir -p "$path"
		jq -n --arg sample "$sample" --arg clip "$clip" --argjson index "$index" '
			def identity: {sha256:("a" * 64),sizeBytes:4096};
			def frame_window:
				{decodedFrameCount:2160,
				 stream:{startTime:"0.000000",duration:"90.000000",timeBase:"1/90000",averageFrameRate:"24/1"},
				 frames:[range(0; 5) as $position | {
					frameIndex:($index - 2 + $position),
					bestEffortTimestamp:(["0.000000000","0.041667000","0.083334000","0.125001000","0.166668000"][$position]),
					packetDuration:"0.041667000",keyFrame:false,pictureType:"P"}],
				 sourceWindow:{status:"clean",issue:null}};
			def recorded_offset($offset):
				{offset:$offset,sourceFrameIndex:$index,encodedFrameIndex:($index + $offset),
				 ssim:{command:["raw-command-secret"],value:0.9},
				 psnr:{command:["raw-command-secret"],value:{kind:"finite",value:40}}};
			def setting($quality):
				{globalQuality:$quality,status:"complete",reason:null,
				 sourceIdentity:identity,outputIdentity:identity,
				 sourceFrameWindow:frame_window,outputFrameWindow:frame_window,
				 commands:{encode:["raw-command-secret"],decode:["raw-command-secret"],outputFrameProbe:["raw-command-secret"],vmafCurrent:["raw-command-secret"],vmafReset:["raw-command-secret"]},
				 vmaf:{current:[range($index - 2; $index + 3) | {frameIndex:.,vmaf:90}],reset:[range($index - 2; $index + 3) | {frameIndex:.,vmaf:90}]},
				 offsets:[range(-2; 3) | recorded_offset(.)],timeline:{zeroOffsetAligned:true,discontinuity:null}};
			{schemaVersion:1,strategyId:"qsv-hevc-icq-v1",sampleId:$sample,clipId:$clip,observedFrameIndex:$index,
			 status:"complete",sourceClip:{command:["raw-command-secret"],frameProbeCommand:["raw-command-secret"],identity:identity,frameWindow:frame_window},
			 settings:[setting(16),setting(30)],
			 classification:{schemaVersion:1,classification:"unresolved",reasons:["offset-best-tie"]}}' >"$path/evidence.json"
		summary="$(jq -c --arg sample "$sample" --arg clip "$clip" \
			'.vmaf.entries += [{sampleId:$sample,clipId:$clip,status:"complete",classification:"unresolved",reasons:["offset-best-tie"],evidence:("vmaf/" + $sample + "/" + $clip + "/evidence.json")}]' \
			"$EVIDENCE_ROOT/diagnostic-summary.json")"
		printf '%s\n' "$summary" >"$EVIDENCE_ROOT/diagnostic-summary.json"
	done <<'EOF'
avc-clean-coco	motion	1641
avc-grain-memento	dark	523
avc-grain-memento	detail	370
vc1-fugitive	detail	781
vc1-fugitive	motion	798
EOF
	while IFS=$'\t' read -r sample clip timestamp; do
		path="$EVIDENCE_ROOT/hdr/$sample"
		mkdir -p "$path"
		jq -n --arg sample "$sample" --arg clip "$clip" --arg timestamp "$timestamp" '
			def identity: {sha256:("b" * 64),sizeBytes:8192};
			def stream_oracle: {status:"null"};
			def pair_oracle: {status:"absent"};
			def raw_pair($start):
				{start:$start,durationSeconds:10,status:"complete",reason:null,
				 decoded:{command:["raw-command-secret"],oracle:pair_oracle},
				 trace:{command:["raw-command-secret"],oracle:pair_oracle}};
			def normalized_pair($reason):
				{decoded:pair_oracle,trace:pair_oracle,authoritative:{status:"unresolved",reasons:[$reason]}};
			{schemaVersion:1,strategyId:"qsv-hevc-icq-v1",sampleId:$sample,clipId:$clip,globalQuality:16,status:"complete",reason:null,
			 commands:{clip:["raw-command-secret"],encode:["raw-command-secret"],decode:["raw-command-secret"]},
			 source:{identity:identity,streamProbe:{command:["raw-command-secret"],oracle:stream_oracle},windows:{beginning:raw_pair("0"),detail:raw_pair($timestamp),end:raw_pair("<end-start>")}},
			 clip:(raw_pair($timestamp) + {identity:identity}),encoded:(raw_pair($timestamp) + {identity:identity}),
			 normalizedOracle:{schemaVersion:1,source:{streamProbe:stream_oracle,windows:{beginning:normalized_pair("source-window-absent"),detail:normalized_pair("source-window-absent"),end:normalized_pair("source-window-absent")},authoritative:{status:"unresolved",reasons:["source-window-absent"]}},clip:normalized_pair("clip-window-absent"),encoded:normalized_pair("encoded-window-absent")},
			 classification:{schemaVersion:1,classification:"unresolved-oracle",reasons:["source-window-absent"]}}' >"$path/evidence.json"
		summary="$(jq -c --arg sample "$sample" \
			'.hdr.entries += [{sampleId:$sample,status:"complete",classification:"unresolved-oracle",reasons:["source-window-absent"],evidence:("hdr/" + $sample + "/evidence.json")}]' \
			"$EVIDENCE_ROOT/diagnostic-summary.json")"
		printf '%s\n' "$summary" >"$EVIDENCE_ROOT/diagnostic-summary.json"
	done <<'EOF'
hdr10-clean-ministry	detail	01:04:15.000
hdr10-grain-goodfellas	detail	01:06:25.000
hdr10-motion-john-wick-2	detail	01:04:50.000
EOF
}
