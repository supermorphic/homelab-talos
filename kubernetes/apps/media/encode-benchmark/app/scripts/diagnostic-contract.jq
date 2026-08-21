# Pure diagnostic predicates shared by the evidence producer and both readers.
# This module must not read files, environment variables, or external state.

def diagnostic_decimal_units:
	capture("^(?<sign>-?)(?<whole>[0-9]+)([.](?<fraction>[0-9]{1,9}))?$") |
	((.fraction // "") + "000000000" | .[0:9] | tonumber) as $fraction |
	((.whole | tonumber) * 1000000000 + $fraction) as $units |
	if .sign == "-" then -$units else $units end;

def diagnostic_continuity:
	. as $window |
	reduce range(1; ($window | length)) as $index
		({status:"clean",issue:null};
		 if .status != "clean" then .
		 else
			$window[$index - 1] as $previous |
			$window[$index] as $current |
			($previous.bestEffortTimestamp | diagnostic_decimal_units) as $previous_timestamp |
			($current.bestEffortTimestamp | diagnostic_decimal_units) as $current_timestamp |
			($previous.packetDuration | diagnostic_decimal_units) as $previous_duration |
			if $previous_duration <= 0 then
				{status:"discontinuity",issue:{kind:"inconsistent-duration",afterFrameIndex:$previous.frameIndex}}
			elif $current_timestamp == $previous_timestamp then
				{status:"discontinuity",issue:{kind:"repeat",afterFrameIndex:$previous.frameIndex}}
			elif $current_timestamp < $previous_timestamp then
				{status:"discontinuity",issue:{kind:"non-monotonic-timestamp",afterFrameIndex:$previous.frameIndex}}
			elif $current_timestamp > ($previous_timestamp + $previous_duration) then
				{status:"discontinuity",issue:{kind:"gap",afterFrameIndex:$previous.frameIndex}}
			elif $current_timestamp < ($previous_timestamp + $previous_duration) then
				{status:"discontinuity",issue:{kind:"inconsistent-duration",afterFrameIndex:$previous.frameIndex}}
			else . end
		 end);

def diagnostic_exact_keys($keys):
	type == "object" and ((keys | sort) == ($keys | sort));

def diagnostic_metric_rank($metric):
	if $metric == "psnr" then
		if .psnr | type == "number" then {infinity:0,value:.psnr}
		elif .psnr.kind == "finite" then {infinity:0,value:.psnr.value}
		else {infinity:1,value:0} end
	else {infinity:0,value:.ssim} end;

def diagnostic_metric_nonzero($metric):
	if $metric == "psnr" and (.psnr | type) == "object" and .psnr.kind == "positive-infinity" then true
	elif $metric == "psnr" and (.psnr | type) == "object" then .psnr.value != 0
	else .[$metric] != 0 end;

def diagnostic_offset_entry:
	diagnostic_exact_keys(["offset", "psnr", "ssim"]) and
	(.offset | type == "number" and floor == . and . >= -2 and . <= 2) and
	((.ssim == null) or (.ssim | type == "number")) and
	((.psnr == null) or (.psnr | type == "number") or
		(.psnr | diagnostic_exact_keys(["kind"]) and .kind == "positive-infinity") or
		(.psnr | diagnostic_exact_keys(["kind","value"]) and .kind == "finite" and (.value | type == "number")));

def diagnostic_timeline:
	diagnostic_exact_keys(["discontinuity", "zeroOffsetAligned"]) and
	(.zeroOffsetAligned | type == "boolean") and
	(
		.discontinuity == null or
		(
			.discontinuity |
			diagnostic_exact_keys(["kind", "offset"]) and
			(.kind == "duplicate" or .kind == "drop" or .kind == "timestamp-discontinuity") and
			(.offset | type == "number" and floor == . and . >= -2 and . <= 2 and . != 0)
		)
	);

def diagnostic_source_window:
	diagnostic_exact_keys(["status"]) and
	(.status == "clean" or .status == "decode-error" or .status == "discontinuity");

def diagnostic_classifier_setting:
	diagnostic_exact_keys([
		"completeEvidence", "currentTargetVmaf", "globalQuality", "offsets",
		"resetTargetVmaf", "sourceWindow", "timeline"
	]) and
	(.globalQuality == 16 or .globalQuality == 30) and
	(.completeEvidence | type == "boolean") and
	(.currentTargetVmaf | type == "number" and . >= 0) and
	(.resetTargetVmaf | type == "number" and . >= 0) and
	(.sourceWindow | diagnostic_source_window) and
	(.timeline | diagnostic_timeline) and
	(.offsets | type == "array" and length == 5 and all(.[]; diagnostic_offset_entry) and
		([.[].offset] | sort == [-2, -1, 0, 1, 2]));

def diagnostic_unique_metric_offset($metric):
	([.offsets[] | select(.[$metric] != null)] | length) as $present_count |
	if $present_count != 5 then
		{state: "missing"}
	else
		([.offsets[] | {offset, rank:(diagnostic_metric_rank($metric))}] |
			max_by([.rank.infinity,.rank.value]).rank) as $best_rank |
		([.offsets[] | select(diagnostic_metric_rank($metric) == $best_rank) | .offset]) as $best_offsets |
		if ($best_offsets | length) == 1 then {state: "unique", offset: $best_offsets[0]}
		else {state: "tie"} end
	end;

def diagnostic_unique_target_minimum($metric):
	([.offsets[] | select(.[$metric] != null) | .[$metric]] | length) == 5 and
	(
		([.offsets[] | {offset,rank:(diagnostic_metric_rank($metric))}] |
			min_by([.rank.infinity,.rank.value]).rank) as $minimum |
		([.offsets[] | select(diagnostic_metric_rank($metric) == $minimum) | .offset]) as $minimum_offsets |
		($minimum_offsets | length) == 1 and $minimum_offsets[0] == 0
	);

def diagnostic_summarize_setting:
	. as $setting |
	($setting | diagnostic_unique_metric_offset("ssim")) as $ssim_best |
	($setting | diagnostic_unique_metric_offset("psnr")) as $psnr_best |
	{
		globalQuality: .globalQuality,
		completeEvidence,
		currentZero: (.currentTargetVmaf == 0),
		resetZero: (.resetTargetVmaf == 0),
		zeroAligned: .timeline.zeroOffsetAligned,
		discontinuity: .timeline.discontinuity,
		sourceStatus: .sourceWindow.status,
		targetUniqueMinimum: (diagnostic_unique_target_minimum("ssim") and diagnostic_unique_target_minimum("psnr")),
		independentTargetNonzero: (
			([.offsets[] | select(.offset == 0)][0]) as $target |
			($target | diagnostic_metric_nonzero("ssim")) and
			($target | diagnostic_metric_nonzero("psnr"))
		),
		pair: (
			if $ssim_best.state == "missing" or $psnr_best.state == "missing" then {state: "missing"}
			elif $ssim_best.state == "tie" or $psnr_best.state == "tie" then {state: "tie"}
			elif $ssim_best.offset != $psnr_best.offset then {state: "disagreement"}
			else {state: "unique", offset: $ssim_best.offset} end
		),
		validNonzeroPairing: (
			$ssim_best.state == "unique" and $psnr_best.state == "unique" and
			$ssim_best.offset == $psnr_best.offset and $ssim_best.offset != 0
		),
		timelineCorroboratesPairing: (
			$ssim_best.state == "unique" and $psnr_best.state == "unique" and
			$ssim_best.offset == $psnr_best.offset and $ssim_best.offset != 0 and
			.timeline.discontinuity != null and .timeline.discontinuity.offset == $ssim_best.offset
		)
	};

def diagnostic_classification($name; $reasons):
	{schemaVersion: 1, classification: $name, reasons: $reasons};

def diagnostic_vmaf_classify:
	if
		diagnostic_exact_keys(["clipId", "observedFrameIndex", "sampleId", "schemaVersion", "settings"]) and
		.schemaVersion == 1 and
		(.sampleId | type == "string" and length > 0) and
		(.clipId | type == "string" and length > 0) and
		(.observedFrameIndex | type == "number" and floor == . and . >= 0) and
		(.settings | type == "array" and length >= 1 and all(.[]; diagnostic_classifier_setting))
	then
		.settings as $settings |
		if ($settings | length) == 1 then
			diagnostic_classification("unresolved"; ["one-setting-evidence"])
		elif ([ $settings[].globalQuality ] | sort) != [16, 30] then
			diagnostic_classification("unresolved"; ["incomplete-setting-evidence"])
		elif any($settings[]; .completeEvidence | not) then
			diagnostic_classification("unresolved"; ["incomplete-setting-evidence"])
		elif any($settings[]; ([.offsets[] | .ssim == null or .psnr == null] | any)) then
			diagnostic_classification("unresolved"; ["missing-offset-window"])
		else
			($settings | map(diagnostic_summarize_setting) | sort_by(.globalQuality)) as $summaries |
			if
				all($summaries[]; .validNonzeroPairing and .timelineCorroboratesPairing and .currentZero) and
				([ $summaries[].pair.offset ] | unique | length) == 1
			then diagnostic_classification("temporal-alignment-defect"; [
				"nonzero-ssim-psnr-offset-agreement", "timeline-discontinuity-at-offset"
			])
			elif
				all($summaries[];
					.zeroAligned and .currentZero and .resetZero and .targetUniqueMinimum and
					.sourceStatus == "clean" and (.discontinuity == null) and
					(.timelineCorroboratesPairing | not))
			then diagnostic_classification("encoder-output-defect"; [
				"zero-offset-timeline-agreement", "target-frame-local-metric-minimum", "source-window-clean"
			])
			elif
				all($summaries[];
					.zeroAligned and .currentZero and .resetZero and (.pair.offset == 0) and
					(.targetUniqueMinimum | not) and .independentTargetNonzero)
			then diagnostic_classification("vmaf-measurement-defect"; [
				"zero-offset-timeline-agreement", "independent-metrics-not-target-minimum", "vmaf-only-exact-zero"
			])
			elif any($summaries[]; .pair.state == "tie") then
				diagnostic_classification("unresolved"; ["offset-best-tie"])
			elif any($summaries[]; .pair.state == "disagreement") then
				diagnostic_classification("unresolved"; ["ssim-psnr-offset-disagreement"])
			elif any($summaries[]; .pair.state == "missing") then
				diagnostic_classification("unresolved"; ["missing-offset-window"])
			else diagnostic_classification("unresolved"; ["classification-predicate-not-met"])
			end
		end
	else error("invalid diagnostic vmaf evidence") end;

def diagnostic_hdr_classify_normalized:
	if .source.authoritative.status != "ok" then
		diagnostic_classification("unresolved-oracle"; .source.authoritative.reasons)
	elif .source.streamProbe.status == "null" then
		diagnostic_classification("source-probe-defect"; ["authoritative-source-metadata", "stream-probe-null"])
	elif .source.streamProbe.status == "absent" then
		diagnostic_classification("unresolved-oracle"; ["source-stream-probe-absent"])
	elif .source.streamProbe.status == "malformed" then
		diagnostic_classification("unresolved-oracle"; ["source-stream-probe-malformed"])
	elif .source.streamProbe.metadata != .source.authoritative.metadata then
		diagnostic_classification("unresolved-oracle"; ["source-stream-probe-conflict"])
	elif .clip.authoritative.status != "ok" then
		diagnostic_classification("unresolved-oracle"; .clip.authoritative.reasons)
	elif .clip.authoritative.metadata != .source.authoritative.metadata then
		diagnostic_classification("clip-boundary-defect"; ["authoritative-source-metadata", "clip-metadata-changed"])
	elif .encoded.authoritative.status != "ok" then
		diagnostic_classification("unresolved-oracle"; .encoded.authoritative.reasons)
	elif .encoded.authoritative.metadata != .source.authoritative.metadata then
		diagnostic_classification("encoder-output-defect"; ["source-and-clip-metadata-agree", "encoded-metadata-changed"])
	else diagnostic_classification("preserved"; ["source-clip-encoded-metadata-agree"])
	end;
