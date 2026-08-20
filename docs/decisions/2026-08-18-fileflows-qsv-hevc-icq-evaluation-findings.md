# FileFlows QSV HEVC ICQ evaluation — findings

- **Status: Accepted.** Approved by the operator on 2026-08-18.
Date: 2026-08-18.
Branch: `codex/fileflows-icq-evaluation-findings`.

Builds on these accepted records without revising them:

- [QSV HEVC ICQ movie-encoding evaluation — design](2026-08-15-fileflows-qsv-hevc-icq-evaluation.md)
- [Encode benchmark quality-run correction — amendment](2026-08-14-encode-benchmark-quality-run-correction.md)
- [Movie encoding benchmark storage contract — amendment](2026-08-06-encode-benchmark-storage-contract-amendment.md)
- [Movie encoding benchmark — design](2026-08-01-fileflows-movie-encoding.md)

## 1. Decision

The QSV HEVC ICQ strategy is an objective **NO-GO** for AVC and VC-1 under
the accepted quality contract. HDR10 is **harness-blocked / unresolved** and
has no encoder verdict.

No cohort has an admissible objective candidate under the completed quality
evidence. There is therefore no setting to submit for crop review, no
provisional or final `chosenSettings` record, and no admissible input for
finalist, x265, savings, or Plex-contention evaluation.

The AVC and VC-1 conclusions apply only to the accepted `qsv-hevc-icq-v1`
strategy, fixed source panel, candidate settings, and objective thresholds.
Their failure pattern is anomalous and its cause is unresolved, but the
completed rows do not satisfy the accepted gate. The HDR10 rows cannot produce
an encoder conclusion because their source static-metadata oracle was
unavailable. Encoder corruption is not established.

The strategy remains unauthorized for FileFlows deployment or media
replacement.

## 2. Admissible quality evidence

Quality run `20260817T233546Z-debc0498` used results schema 2 and strategy
`qsv-hevc-icq-v1`. Its 144 unique rows cover the accepted six titles, three
clips per title, and eight ICQ settings. The run produced 71 passed rows and 73
invalid rows. A passed row satisfies the row-level execution and output
contract; it does not by itself satisfy both objective VMAF thresholds.

The results digest agrees with the run-scoped candidate artifact. Independent
recalculation applied the accepted per-clip gate without pooling scores and
agreed with that artifact:

| Cohort | Row evidence | Objective candidate result |
| --- | --- | --- |
| AVC | 47 passed; 1 invalid because QSV proof failed; 39 passed rows missed at least one VMAF threshold | No setting passed every required clip |
| VC-1 | 24 passed; every row missed at least one VMAF threshold | No setting passed every required clip |
| HDR10 | 72 invalid because the source static-metadata oracle reported null `masteringDisplay` and `maxCLL` while every output reported populated values | Harness-blocked; no encoder verdict |

The run-scoped candidate artifact records `no-objective-candidate` for all
three cohorts. Invalid rows did not participate in selection. That artifact is
preserved as generated. Its HDR10 status does not override the accepted rule
that an unavailable or malformed oracle is `harness-blocked` and is not a
platform verdict.

Findings run `20260818T214739Z-8bc2de3e` completed against the exact quality
input above. Its manifest binds the findings input and upstream result and
candidate digests. Its sanitized output separately records objective
`no-go`, no selected setting, and a final **NO-GO** conclusion for all three
cohorts under the evidence supplied to it. This record preserves that output
without adopting its HDR10 conclusion. Retained probe evidence establishes
that the HDR failure was an oracle mismatch, so HDR10 remains unresolved. The
findings output correctly records x265, savings, and contention as not
applicable.

## 3. Cohort conclusions

| Cohort | Objective quality | Selected setting | Downstream evaluation | Conclusion |
| --- | --- | --- | --- | --- |
| AVC | No objective candidate under the accepted 95/90 gate | None | Not applicable | Objective NO-GO; anomaly cause unresolved |
| VC-1 | No objective candidate under the accepted 95/90 gate | None | Not applicable | Objective NO-GO; anomaly cause unresolved |
| HDR10 | Static-metadata oracle unavailable | None | Not applicable | Harness-blocked / unresolved |

The objective gate precedes visual selection. Crop or Plex review cannot
promote a setting that failed that gate, and a harness-blocked cohort cannot
supply a candidate. Without a visually final setting, the accepted x265,
full-title savings, and Plex-contention stages have no admissible input. The
x265 stage is only a matched-quality comparator for a successful ICQ finalist;
it does not authorize evaluating x265 as a production strategy.

## 4. Observation and inference

### 4.1 AVC and VC-1

Observed evidence establishes that the bounded quality run completed and
retained all expected row identities. Applying the accepted per-clip 95/90
VMAF gate without pooling produces no qualifying AVC or VC-1 setting. This
record does not reinterpret those rows, relax either threshold, or widen the
ICQ candidate range.

The failures are dominated by repeatable, setting-insensitive frame-level VMAF
anomalies. Five clips contain an exact-zero VMAF frame at the same frame
position at widely separated ICQ settings:

- `avc-clean-coco/motion`;
- `avc-grain-memento/dark`;
- `avc-grain-memento/detail`;
- `vc1-fugitive/detail`; and
- `vc1-fugitive/motion`.

Those zero frames collapse harmonic VMAF to approximately `0.002`. This does
not behave like a normal compression-quality curve. The retained evidence does
not establish whether the cause is a genuine encoder or output defect, a
temporal or frame-alignment problem, or a VMAF measurement-boundary problem.
The uncertainty qualifies the AVC and VC-1 findings but does not turn any
completed setting into an objective candidate.

### 4.2 HDR10

All 72 HDR10 outputs retained HDR10 format classification, BT.2020 primaries,
PQ transfer, BT.2020 non-constant color space, and 10-bit depth. QSV proof and
the other output-validation predicates passed. The exact HDR predicate failed
because the title-level source probes reported null `masteringDisplay` and
`maxCLL` values while every encoded output reported populated, title-specific
values.

The accepted exact-equality predicate therefore had no authoritative source
static-metadata value to compare with the outputs. The populated output values
are stable across each title's variants, but the existing evidence does not
independently prove that their numeric values are correct. The rows must not be
converted into passes. They are harness-blocked because the oracle is
unavailable, and they establish neither encoder success nor encoder
corruption.

### 4.3 Evidence boundary

The resulting inference is limited: the accepted ICQ candidate range does not
justify FileFlows deployment under the accepted panel and thresholds. The
evidence does not establish a matched-quality x265 premium, a full-title
savings distribution, a visual finalist verdict, or a Plex processing window.
Those questions are not applicable without an admissible objective candidate;
they are not silently treated as passing or failing measurements.

The completed quality run, candidate artifact, and findings output remain
immutable evidence. This record does not repair, mutate, or retrospectively
reinterpret them. Any corrected oracle requires fresh evidence under the
corrected contract.

## 5. Recommended next decision

Create a separate, narrowly scoped diagnostic and correction decision before
another full strategy evaluation. It should investigate only:

1. the repeatable zero-VMAF frame behavior on the five affected clips; and
2. an authoritative source static-metadata oracle for HDR10.

The investigation must determine whether each issue is an encoder or output
defect or a harness or oracle defect. It must not widen the ICQ candidate range,
change the accepted VMAF thresholds, reinterpret the completed rows, or treat
the existing x265 comparator as a production-strategy evaluation.

The result should determine whether `qsv-hevc-icq-v1` deserves fresh quality
evidence under a corrected contract or whether the ICQ evaluation should close
and a separate strategy should be considered. This findings record does not
create or authorize that diagnostic work.

## 6. Operator decision

The operator accepted this findings record on 2026-08-18. FileFlows movie
encoding and media replacement remain unauthorized for `qsv-hevc-icq-v1`.
AVC and VC-1 are objective no-go under the current contract. HDR10 is
harness-blocked / unresolved. Any diagnostic correction, fresh ICQ quality
run, or evaluation of another strategy requires a separate accepted decision
and fresh evidence.

This record does not authorize Flux or Plex changes, benchmark cleanup, media
replacement, or deployment of an alternative encoder strategy.
