# QSV HEVC ICQ movie-encoding evaluation — design

- **Status: Accepted.** Approved by the operator on 2026-08-15.
Date: 2026-08-15.
Branch: `fileflows-icq-evaluation`.

Builds on these accepted records without revising them:

- [Movie encoding benchmark — design](2026-08-01-fileflows-movie-encoding.md)
- [Movie encoding benchmark storage contract — amendment](2026-08-06-encode-benchmark-storage-contract-amendment.md)
- [Encode benchmark quality-run correction — amendment](2026-08-14-encode-benchmark-quality-run-correction.md)
- [Encode benchmark findings — no-go](2026-08-14-encode-benchmark-findings.md)

## 1. Decision

Evaluate Intel Quick Sync Video (QSV) HEVC Intelligent Constant Quality (ICQ)
without look-ahead as a distinct movie-encoding strategy.

Adapt the existing inert benchmark harness in place. Preserve its accepted storage,
safety, validation, run-identity, and operator-authority boundaries. Replace its
LA-ICQ-specific command, predicates, setting guards, schemas, stage flow, and tests
with an ICQ-only contract.

The evaluation determines whether ICQ preserves acceptable quality, produces useful
savings, compares acceptably with software x265 at matched quality, and can coexist
with Plex. It does not authorize FileFlows deployment or media replacement. A later
accepted findings decision is required for either outcome.

## 2. Evidence boundary

The accepted 2026-08-14 findings remain a no-go for the LA-ICQ strategy. ICQ does not
retroactively satisfy that strategy.

Both eligible NUCs previously selected ICQ, showed positive i915 video-engine activity
and positive encode progress, produced decodable video, and passed the VMAF availability
check. Those observations prove ICQ execution compatibility only. They establish no
quality, savings, matched-quality, visual, or Plex contention result.

Both schema-v2 records also classified initialization as failed because the old oracle
required a specific verbose success phrase. That classification is not an ICQ platform
verdict: the same executions opened the QSV path, selected ICQ, performed positive
hardware work, progressed, decoded, and ran VMAF. It proves that the old initialization
oracle cannot be reused.

Run `20260813T221312Z-5a22cde6` remains inadmissible and deleted. None of its rows may
become fixtures, measurements, candidates, or findings. The deleted run directories
must not be reconstructed.

## 3. Scope and authority

This decision authorizes source changes and operator-run evaluation stages for only:

- QSV HEVC ICQ without look-ahead;
- fresh ICQ capability proof;
- a bounded quality sweep on the committed quality panel;
- independent VMAF and SSIM measurement;
- full output validation;
- operator crop and Plex finalist review;
- x265 comparison at matched VMAF;
- full-title savings measurement; and
- applicable Plex contention measurement.

This decision does not authorize:

- revision of an accepted decision;
- FileFlows deployment or movie replacement;
- LA-ICQ, AV1, software x265 as a production engine, another driver/runtime, or new
  hardware;
- changes to Talos, Kubernetes, Cilium, the Intel GPU plugin, Flux architecture, or
  Plex deployment manifests;
- cleanup of any benchmark run;
- access to TV or downloads; or
- agent-run Job creation, cleanup, rollout, Plex UI mutation, or credential handling.

The temporary Plex library and playback actions needed for finalist and contention
review are part of this evaluation, but remain operator-run. They do not authorize a
Plex GitOps or deployment change.

## 4. Harness architecture

### 4.1 In-place ICQ adaptation

Keep the existing package, Job-template pattern, guarded dispatch, run scoping, sample
panels, measurement functions, and independent validation oracles. Do not create a
parallel harness. Do not generalize it into a multi-strategy framework.

Keeping the harness applies to its safety and lifecycle behavior, not its LA-ICQ
literals. Every setting producer, allowlist, committed-setting reader, dispatch guard,
runtime mode, contention fragment validator, result reader, resume path, findings path,
and test fixture uses one shared ICQ setting source.

### 4.2 Strategy and schemas

Every ICQ artifact carries this exact identity:

```text
qsv-hevc-icq-v1
```

Use these new schema identities:

- samples/config schema version 2;
- capability proof schema version 3;
- run-manifest schema version 2; and
- results schema version 2, declared in the manifest and represented by a
  `strategy_id` field in every result row.

Dispatch, resume, selection, result collection, and findings re-evaluate the strategy
and schema. LA-ICQ evidence, an older schema, or a row without the exact strategy cannot
satisfy an ICQ gate.

## 5. Encoder and capability contract

### 5.1 ICQ command

Retain the current preset, stream-copy, metadata, chapter, and hardware-device behavior.
Use these exact rate-control controls:

```text
-c:v hevc_qsv
-global_quality <setting>
-look_ahead 0
-extbrc 0
```

The runtime must report that it selected exactly `ICQ`. `LA-ICQ`, `CQP`, another known
mode, or an unknown mode fails the ICQ mode predicate.

### 5.2 Per-node capability proof

Capability dispatch creates one short Job targeted to each eligible non-Plex node with
an available i915 resource. Prior schema-v2 evidence cannot pass.

A node passes only when all conditions hold:

1. Configured, dispatched, and running images have the same immutable digest.
2. A dedicated initialization-only FFmpeg command uses
   `-init_hw_device qsv=hw:/dev/dri/renderD128` and `-filter_hw_device hw`, exits zero,
   and emits no known device-creation or initialization failure.
3. Initialization does not depend on a particular verbose success sentence.
4. A five-second synthetic encode uses the exact production ICQ path.
5. The encoder has a file descriptor that resolves to the configured render node, and
   DRM fdinfo reports `drm-driver: i915`.
6. Verbose runtime evidence selects exactly `ICQ`.
7. DRM fdinfo records a positive i915 video-engine busy-time delta.
8. Encode progress is finite and positive.
9. The primary output video decodes.
10. The configured VMAF filter compares output with the source successfully.

A nonzero dedicated initialization command under a validated image and command
contract, or a known mode-selection, encode, telemetry-activity, progress, decode, or
VMAF failure, produces `failed`. A zero-exit initialization whose render-node or driver
binding is missing, malformed, or unparseable is `harness-blocked`, as is another
unavailable oracle. `harness-blocked` is not a platform verdict.

Quality, savings, finalist, and contention dispatch require at least one committed
passing node. Each expensive GPU Job repeats the short proof on its assigned node before
source hashing or run-directory creation. Two-worker contention requires two committed
passing nodes and assigned-node proof on both.

The x265 stage is CPU-only. It requires trusted selected-ICQ inputs but requests no i915
resource and does not repeat an irrelevant QSV proof.

## 6. Evaluation stages

### 6.1 Source panels and preflight

The committed quality and savings panels remain authoritative repository inputs. A new
census is not required. Preflight rechecks every selected source path, size, and SHA-256
identity. A missing or changed source stops the applicable stage until reviewed source
changes replace it. The harness never selects a substitute at runtime.

The Dolby Vision sample remains detection-only and is never encoded.

### 6.2 Fixed ICQ quality sweep

The candidate set is exactly:

```text
16, 18, 20, 22, 24, 26, 28, 30
```

Do not extend outside it. Run all eight settings across six encodable quality titles and
all three pinned clips: 144 QSV clip encodes.

The same set applies to every downstream provisional or final setting consumer. An
in-range value remains valid through finalist, x265-input selection, savings,
contention dispatch and execution, result collection, resume, and findings. An
out-of-range value fails before mutation. No consumer silently skips an in-range value.

Each row independently records:

- strategy, requested setting, and selected rate control;
- QSV initialization, hardware activity, and progress proof;
- encode status, time, speed, input/output size, and reduction;
- primary-video decode;
- codec, duration, resolution, frame rate, bit depth, and HDR validation;
- audio-track, subtitle-track, and chapter-count validation;
- VMAF harmonic mean and one-percent low; and
- SSIM.

VMAF and SSIM are independent comparisons against the copied source clip. HDR static
metadata expectations continue to come from the original title. SSIM remains a
report-only diagnostic without a pass threshold.

### 6.3 Objective candidate gate

A setting qualifies for a cohort only if every applicable clip from every quality-panel
title in that cohort independently meets:

| Criterion | Requirement |
| --- | --- |
| VMAF harmonic mean | at least 95 |
| VMAF one-percent low | at least 90 |
| Output validation | zero failures |
| Selected rate control | exactly `ICQ` |
| QSV proof | passed |

Scores are never pooled to hide a weak clip. Invalid rows do not become candidates or
contribute to later calculations.

Rank qualifying settings by measured median clip-size reduction within the cohort. A
tie prefers the lower `global_quality` value.

### 6.4 Crop selection and finalist state

The operator reviews 1:1 source/output crops in ranked order. The first setting that
passes every reviewed clip becomes provisional. Crop failure moves to the next ranked
candidate. Exhaustion is a cohort quality no-go.

Each cohort has one `chosenSettings.<cohort>` record, updated in place. It contains:

- strategy and quality run ID;
- current setting;
- state: `provisional`, `final`, or `rejected`;
- crop review;
- optional finalist review; and
- an append-only `rejectedSettings` list.

Each rejected entry records its setting, failed stage (`crop` or `plex`), relevant run
ID, and review result. There is no separate persistent provisional and final record.

The provisional record enters reviewed Git source before finalist dispatch. Only
finalist dispatch accepts `state: provisional`; x265, savings, and contention reject
it. An interrupted finalist can resume while the record remains provisional. Finalist
dispatch refuses after finalization.

Create one full-title finalist per qualifying cohort using the existing sole or
worst-case quality title: VC-1, grain-heavy AVC, and grain-heavy HDR10 respectively.
The operator reviews it in the temporary Plex library for Direct Play, HDR handling,
motion artifacts, grain retention, banding, and blocking.

A pass changes the same record to final through reviewed Git source. The record retains
the quality/crop identity and adds the finalist run, full-title sample, and explicit
Plex pass. Only final records authorize later stages.

A Plex failure appends the setting to `rejectedSettings`. The next ranked unrejected
candidate becomes provisional through reviewed source. This loop is bounded by the
eight settings. Exhaustion changes the record to rejected and produces a cohort visual
no-go.

### 6.5 x265 matched-quality stage

Run x265 only after the AVC and HDR10 settings receive final visual approval. Use all
three clips of the two existing grain-heavy `x265Reference` titles.

Start each curve at CRF `18, 20, 22, 24`. Extend by two only in the direction required
to bracket the selected ICQ clip's VMAF, and never outside CRF 10 through 34. Compare by
interpolation only. Never extrapolate. If valid points do not bracket the selected ICQ
point, record `no verdict`.

Keep the accepted matched-quality premium bands:

| ICQ bitrate premium over x265 | Verdict |
| --- | --- |
| at most 15% | QSV preferred |
| more than 15% and at most 30% | QSV acceptable; record cost |
| more than 30% | QSV materially worse; escalate or abandon |
| unbracketed | no verdict |

Run the two reference titles as separate CPU-only Jobs with 60-hour hard deadlines.

### 6.6 Savings

Run one full-file ICQ encode per savings-panel title whose cohort has a final setting.
Preserve the complete output-validation chain, retain results and logs, and discard the
measured encode from scratch.

Savings is cohort-scoped. Dispatch requires at least one final cohort setting and
includes only titles from final cohorts. Record excluded cohorts as `not applicable`
with their upstream quality or visual no-go. One cohort no-go does not block another
cohort's savings evidence. Missing, stale, or contradictory evidence claimed as final
remains a pre-dispatch failure.

Report median, Q1, Q3, and IQR per cohort. Keep the accepted thresholds:

| Median reduction | Verdict |
| --- | --- |
| at least 25% | GO |
| at least 15% and less than 25% | MARGINAL; operator decision |
| less than 15% | NO-GO |

### 6.7 Plex contention

Use one designated physical playback device and one fixed UHD HDR10 remux from the
quality panel. Record both in the run identity.

Establish three 15-minute baseline playback runs with no encoding active. Each baseline
uses the case (d) seek sequence: one seek every two minutes. Retain every baseline run
and every per-seek latency measurement.

Run these applicable cases:

- (a) direct play plus one 4K encode;
- (b) direct play plus two concurrent 1080p encodes;
- (c) forced transcode plus two concurrent 1080p encodes; and
- (d) case (b) with one seek every two minutes.

Record playback start latency, buffering count and duration, every seek-to-resume
latency, NAS throughput at five-second intervals, and encode wall time.

The baseline start comparator is the largest start latency across all three baseline
runs. The baseline seek comparator is the largest seek-to-resume latency across every
baseline seek. Averages do not replace or hide individual events.

Keep the accepted thresholds:

- zero buffering events in cases (a) through (c);
- every contended start no more than two seconds above the worst observed baseline
  start; and
- every case (d) seek no more than three seconds above the worst observed baseline
  seek.

Run only cases whose required final cohort settings exist. Two-worker cases also need
two passing ICQ nodes. A missing applicable setting is `not applicable`, not evidence.
A contention failure determines a later FileFlows processing window; it does not
redefine encoding quality or savings.

## 7. Run identity, resources, and safety

### 7.1 Immutable identity and resume

Write an immutable manifest after fast runtime gates pass and before measured work. It
records:

- schema and `qsv-hevc-icq-v1` identities;
- configured and running image digests;
- script and sample hashes;
- exact encoder commands and candidate bounds;
- source identities;
- selected-setting and upstream-result identities;
- node name and kernel for every measured run;
- i915 and VPL details for GPU work;
- CPU model plus FFmpeg and libx265 versions for CPU-only x265 work;
- VMAF model and version; and
- sampling seed and playback device where applicable.

Resume requires an explicit run ID and exact identity equality. A strategy, schema,
command, source, setting, upstream result, image, model, script, or relevant runtime
change refuses resume with a sanitized diff.

CPU-only x265 runs are node-bound. Resume requires the same node name, kernel, CPU
model, FFmpeg version, and libx265 version. A change requires a fresh x265 run; do not
combine measurements across nodes or runtime identities.

Completed row identities skip only exact valid work. Failed attempts remain visible and
do not become completed candidates.

### 7.2 Artifacts and cleanup

Retain the established run-scoped layout. Clip sweeps and savings outputs remain in
scratch and are discarded after measurement. Only explicitly confirmed full-title
finalists are copied to persistent `encodes/` storage.

Cleanup remains exact-run-ID scoped and requires the existing destructive confirmation.
This decision does not authorize cleanup.

### 7.3 Structural safety

Preserve:

- movie-only `/media`, read-only;
- benchmark-only `/out`, read-write;
- bounded node-local `/scratch`;
- no TV or downloads mount;
- UID/GID 568, non-root, dropped capabilities;
- no service-account token;
- required Plex anti-affinity;
- negative benchmark priority;
- `restartPolicy: Never` and `backoffLimit: 0`;
- equal i915 request and limit for GPU Jobs; and
- finite active deadlines.

Capability Jobs use a 15-minute deadline. ICQ quality, savings, finalist, and
contention Jobs keep the existing 36-hour deadline. Each CPU-only x265 reference Job
uses 60 hours.

The accepted 105 GiB scratch size, 105/110 GiB ephemeral request/limit, 115 GiB
preflight floor, and accepted placement gap remain unchanged for full-title GPU Jobs.
CPU-only x265 scratch can be reduced only if implementation encodes and tests an
independent upper bound. The full-title contract cannot be weakened.

### 7.4 Fail-closed behavior

- Capability, image, source, manifest, or upstream-evidence failure stops before
  expensive work.
- Absence of a final setting because of an admissible cohort no-go is an expected stage
  outcome, not failed evidence for another cohort.
- A malformed oracle is `harness-blocked`.
- An individual encode or output failure records an invalid row and continues the
  bounded sweep.
- Invalid rows never participate in selection, interpolation, savings, or findings.
- Interrupted work resumes only under exact identity.

## 8. Test and validation contract

Implementation follows test-driven development. Each production change begins with a
focused failing regression. Tests assert observable commands, rows, artifacts, and
refusal boundaries rather than helper calls.

Required coverage includes:

1. ICQ commands contain `-look_ahead 0` and `-extbrc 0`, contain no LA-ICQ controls,
   and enumerate exactly `16,18,20,22,24,26,28,30`.
2. The same setting source controls finalist, x265-input selection, savings, contention
   dispatch/execution, contention fragments, results, resume, and findings. Tests carry
   `16`, `18`, and `30` through every applicable path and reject silent skips.
3. The mode parser accepts confirmed `ICQ` and rejects LA-ICQ, CQP, other known modes,
   and unknown evidence.
4. Initialization uses the dedicated command exit and independent render-node/i915
   binding, never a required success phrase.
5. Capability requires schema, strategy, digest, telemetry, progress, decode, and VMAF
   agreement.
6. Dispatch refuses older schemas, LA-ICQ evidence, incomplete node evidence, stale
   selections, and mismatched upstream runs before mutation.
7. The quality sweep executes six titles times three clips times eight settings exactly
   once and preserves `-nostdin` on every FFmpeg command.
8. Candidate selection requires every clip to pass both VMAF thresholds, output
   validation, exact ICQ selection, and QSV proof.
9. Ranking uses median clip reduction and the lower-setting tie break.
10. The one-record state machine verifies quality/finalist identities, preserves
    rejected settings, performs bounded crop/Plex fallback, permits interrupted
    finalist resume only while provisional, and refuses finalist after finalization.
11. x265 uses only the two reference titles and selected ICQ settings, stays within CRF
    10–34, interpolates without extrapolation, uses a CPU-only Job, and remains
    node-bound on resume.
12. Savings includes only final cohorts and records excluded cohorts as not applicable.
13. Contention retains per-run and per-seek evidence and uses worst-observed baseline
    comparators.
14. Independent VMAF, SSIM, HDR title-oracle, primary-video decode, stream inventory,
    resume, cleanup, mount, and Plex-separation tests remain active.
15. Cross-strategy and cross-schema inputs cannot resume or feed findings.
16. No fixture or assertion contains rows from `20260813T221312Z-5a22cde6`.

Scoped validation is the benchmark Bats suite followed by:

```text
mise exec -- just kube encode-benchmark-validate
```

Before every pull request, run:

```text
mise exec -- just ci
```

## 9. Rollout and findings flow

All live actions remain operator-run. The required flow after implementation is:

1. Merge the inert harness adaptation with ICQ capability pending.
2. Wait for Flux reconciliation.
3. Dispatch fresh per-node capability Jobs.
4. Commit sanitized passing evidence through a reviewed source change.
5. Dispatch a fresh quality run.
6. Complete crop review and commit provisional settings with quality-run identity.
7. Dispatch finalists and complete Plex review.
8. Commit final settings with finalist-run identity and explicit approval.
9. On visual failure, record the rejected setting and repeat the bounded candidate loop.
10. Dispatch x265, savings, and applicable contention stages.
11. Generate findings and create a separate findings decision.

Agents may prepare and validate source. Job creation, finalist copying, cleanup, Plex
UI actions, Flux reconciliation, and rollout remain operator-run. Live reads require
scoped credentials supplied to the assigned worktree.

## 10. Success criteria

The evaluation succeeds when admissible evidence answers:

1. Can eligible nodes initialize and execute exact no-look-ahead ICQ with positive
   hardware activity and progress?
2. Does a bounded setting pass objective and visual quality per cohort?
3. Does HDR metadata and the rest of the output contract survive?
4. What setting is selected per successful cohort?
5. How does selected ICQ compare with x265 at matched VMAF on the grain references?
6. What savings distribution does each successful cohort produce?
7. What processing window does Plex contention require?
8. Is later FileFlows implementation justified per cohort?

Success includes a no-go. Inadequate savings, exhaustion of all objective candidates in
crop or Plex review, excessive x265 premium, or no bounded eligible setting are valid
findings rather than harness failures.
