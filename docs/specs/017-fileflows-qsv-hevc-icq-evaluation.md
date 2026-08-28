# FileFlows QSV HEVC ICQ Evaluation

## Purpose

Evaluate Intel Quick Sync Video (QSV) HEVC Intelligent Constant Quality (ICQ) without
look-ahead as a strategy distinct from the earlier LA-ICQ evaluation. Adapt the existing
inert encode-benchmark harness rather than build FileFlows or create a second benchmark
framework.

The evaluation asked whether ICQ could pass objective and visual quality gates, preserve
the output contract, recover useful storage, compare acceptably with x265 at matched
quality, and coexist with Plex. It produced evaluation and diagnostic evidence only. It
did not authorize FileFlows deployment, media replacement, or another encoder strategy.

ICQ justified a second-generation evaluation because both eligible nodes had already
performed hardware-backed ICQ work while failing the earlier experiment's exact LA-ICQ
predicate. That observation gave ICQ a concrete capability basis, but no quality or
operational evidence. A separate strategy identity and fresh evidence were therefore
required instead of weakening or correcting the LA-ICQ result.

## Historical boundary

The LA-ICQ no-go in specification 002 remains valid. Earlier capability evidence showed
that the nodes could perform hardware-backed ICQ work, but that evidence did not provide
an ICQ quality, savings, matched-quality, visual, or contention result. The old LA-ICQ
quality run remained inadmissible and could not become a fixture or input for this
strategy.

The ICQ adaptation preserved the harness's storage, mount, run-scoping, validation, and
failure-safety boundaries while replacing every LA-ICQ command, setting guard, schema,
resume rule, result reader, and test fixture with an ICQ-only contract.

The earlier initialization schema had required one verbose success phrase. It reported
initialization failure even when the same executions bound the render device, selected
ICQ, showed hardware activity and progress, decoded output, and ran VMAF. Those
observations justified a phrase-independent ICQ capability proof. They did not become
schema-version-3 capability records or quality rows.

## Alternatives considered

| Approach | Decision and rationale |
| --- | --- |
| Deploy FileFlows and evaluate through it | Rejected. It again placed platform work before the evidence that could invalidate the platform. |
| Build a second ICQ benchmark | Rejected. It would duplicate reviewed mount, scheduling, identity, resume, evidence, and failure controls. |
| Generalize the harness into a multi-strategy framework | Rejected. The evaluation needed one bounded ICQ contract, not a larger reusable platform. |
| Reuse or relabel the stopped LA-ICQ run | Rejected. Its strategy, schemas, scripts, telemetry, iteration, decode, and HDR evidence were inadmissible under the corrected contract. |
| Adapt the inert harness in place with an ICQ-only identity | Chosen. It reused established safety boundaries while keeping the two strategy lineages and their evidence disjoint. |

The candidate range was fixed before the quality outcome. The evaluation did not widen
it, pool clip scores, lower thresholds, promote visual review ahead of the objective
gate, extrapolate an x265 curve, or treat later diagnostics as corrected quality data.

## Strategy identity

Every ordinary evaluation artifact uses strategy identity:

```text
qsv-hevc-icq-v1
```

The implemented contract uses:

- samples schema version 2;
- capability proof schema version 3;
- run-manifest schema version 2; and
- results schema version 2, including `strategy_id` in every result row.

The candidate set is exactly `16, 18, 20, 22, 24, 26, 28, 30`. The same committed list
controls command construction, result validation, candidate selection, finalist state,
x265 input selection, savings, contention, resume, and findings. An older schema,
LA-ICQ identity, missing strategy field, or out-of-set value cannot satisfy an ICQ gate.

The encoder command uses:

```text
-c:v hevc_qsv
-global_quality <setting>
-look_ahead 0
-extbrc 0
```

The runtime must select exactly `ICQ`. LA-ICQ, CQP, another known mode, or unknown mode
evidence fails the rate-control predicate.

## Harness and safety architecture

Flux manages only the scripts ConfigMap, the samples ConfigMap, and a negative-priority
class. Run-owned Jobs are created from the non-rendered template. The source contract
pins the runtime image by digest and records script, samples, source, command, model, and
runtime identities in each immutable manifest.

The storage and process boundaries remain:

- `/media` exposes only `media/movies` and is read-only;
- `/out` exposes only the benchmark subtree and holds run-scoped evidence;
- `/scratch` is a 105 GiB node-local `emptyDir`, with 105 GiB requested and 110 GiB
  limited ephemeral storage;
- full-title GPU work requires the 115 GiB free-space preflight floor;
- media and downloads outside the movie subtree are not mounted;
- containers run as UID/GID `568`, non-root, without privilege escalation or a
  service-account token, and with all capabilities dropped;
- GPU Jobs request and limit one i915 resource, use required Plex anti-affinity, and run
  at negative priority; and
- Jobs have finite deadlines, `restartPolicy: Never`, and `backoffLimit: 0`.

Clip sweeps and savings outputs remain temporary. Only a confirmed finalist can enter a
durable `encodes/` directory. Resume requires an explicit run ID and exact manifest
identity. Completed work skips only an exact valid row; failed attempts remain evidence.

The benchmark's safety claim is structural but local to its mounts: its source movie
subpath is read-only and its output subpath is outside the library paths managed or
indexed by media applications. Other media containers mount the shared claim at their
own roots, so the design does not claim that benchmark bytes are invisible to every
container.

## Inherited corrected evidence model

This evaluation inherited methodological corrections from specification 002 without
inheriting its LA-ICQ command, settings, or outcome:

- every FFmpeg path uses `-nostdin`, including quality, savings, finalist, contention,
  and still generation, so a child cannot consume later panel records;
- decode validation maps only the primary video, while independent probes validate
  audio, subtitle, chapter, and other stream properties;
- the full title is the HDR static-metadata oracle and the copied clip is the duration
  and stream-layout reference;
- x265 is restricted to the two grain-heavy reference titles and is only a comparator;
- QSV telemetry follows the encoder's i915 descriptor and missing or malformed telemetry
  is `harness-blocked`, not a platform failure;
- capability evidence is evaluated per node, and dispatch re-evaluates its fields rather
  than trusting a status string; and
- a synthetic capability encode proves positive progress only. It does not establish a
  production throughput band.

A missing or malformed independent oracle cannot become an encoder verdict. Correcting
commands, source identity, evidence semantics, or schemas requires a fresh run identity;
historical rows remain immutable.

## Capability proof and dispatch boundary

Capability proof is per node. A passing schema-version-3 record requires all of these:

1. Configured, dispatched, and running image digests agree.
2. A dedicated QSV initialization command exits successfully without a known device or
   initialization failure.
3. The FFmpeg process binds the configured render node and reports the i915 driver.
4. The production command selects exactly ICQ.
5. DRM fdinfo reports a positive video-engine busy-time delta.
6. Encode progress is finite and positive.
7. The primary output video decodes.
8. The configured VMAF comparison succeeds.

Initialization does not depend on one verbose success phrase. A missing binding,
malformed telemetry interface, or unavailable oracle is `harness-blocked`; a complete
semantic failure is `failed`. Ordinary expensive GPU stages require at least one
committed passing node and repeat the short proof on their assigned node before source
hashing or creation of a run directory. Two-worker contention requires two distinct
passing and still-eligible nodes. CPU-only x265 work instead binds its node, CPU, kernel,
FFmpeg, and libx265 identity.

The current capability record also carries image-bound diagnostic capability evidence
for `trace_headers`, `libvmaf`, `ssim`, `psnr`, and the required bounded ffprobe frame
fields. Diagnostics dispatch accepts only a node whose ordinary ICQ proof and every
diagnostic capability predicate pass.

The cataloged recipe and dispatcher together revalidate deployed source, source
contract, chosen-setting state, upstream run identity, and committed capability evidence
before creating a Job. The dispatcher also establishes a run-owned image-evidence
handoff: it observes the controlled Pod's actual `imageID`, requires digest equality,
creates an owner-bound ConfigMap, and waits for the runtime to accept that evidence. A
failed handoff removes only the exact objects owned by that dispatch.

## Evaluation stages

The committed quality and savings populations had different purposes. The quality panel
was a stress panel: VC-1, clean and grain-heavy AVC, and clean, grain-heavy, and
dark-or-high-motion HDR10 material. Grain was a decisive stressor because HEVC provides
no film-grain synthesis, and VMAF could reject HDR but could not approve it without
visual review. A Dolby Vision Profile 7 title was a detection-only exclusion control and
was never encoded. The seeded, stratified savings panel represented applicable catalog
cohorts and bitrate bands so difficult quality samples did not bias the storage estimate.
A new census was not required.

Before a stage, preflight rechecked each committed source path, byte size, and hash. It
could not substitute a different title or timestamp. Source drift stopped the applicable
stage until source changes established a new identity.

The fixed quality sweep covers six encoded titles, three clips per title, and all eight
settings, for 144 unique QSV rows. Each row records ICQ selection and QSV proof, encode
progress and reduction, primary-video decode, codec and stream properties, HDR
validation, audio/subtitle/chapter preservation, VMAF harmonic mean and one-percent
low, and report-only SSIM.

A setting qualifies for a cohort only when every applicable clip independently has
VMAF harmonic mean at least 95, VMAF one-percent low at least 90, no output-validation
failure, exact ICQ selection, and passing QSV proof. Qualifying settings are ranked by
median clip-size reduction, with the lower `global_quality` value winning a tie.

Visual selection uses one bounded state record per cohort. Objective candidates enter
1:1 source/output crop review in rank order. A crop pass makes the setting provisional;
a full-title Plex review then checks Direct Play, HDR behavior, motion, grain retention,
banding, and blocking. A Plex pass makes the setting final. A failure appends the setting
and its evidence identity to the rejected prefix before the next candidate is considered.
The bounded list is exhausted rather than extended after observed failures. Only a
provisional record can authorize its finalist, and only a final record can authorize
x265, savings, or contention evidence.

The x265 comparator uses all three clips from the grain-heavy AVC and HDR10 references.
It starts at CRF `18, 20, 22, 24`, extends in steps of two only as needed, remains within
CRF 10 through 34, and never extrapolates. Each reference uses all three clips and binds
its CPU, node, runtime, FFmpeg, and libx265 identity. Interpolation is permitted only
inside a measured bracket; otherwise the result is `no verdict`. An ICQ bitrate premium
of at most 15 percent over matched-quality x265 favors QSV, more than 15 through 30
percent is acceptable with a recorded cost, and more than 30 percent is materially worse.

Savings uses one validated full-title ICQ encode per applicable representative title and
reports cohort median, quartiles, and interquartile range. Applicability is cohort-scoped:
a cohort without a final setting contributes no rows. Median reduction of at least 25
percent is GO, 15 to less than 25 percent is MARGINAL and requires an operator decision,
and less than 15 percent is NO-GO. This full-title stage was necessary because media
hardlink and torrent lifecycle determine realized savings; clip reduction alone cannot
establish catalog economics.

Contention fixes one physical playback device and one UHD HDR source in run identity.
Three 15-minute no-encode baselines use the same one-seek-every-two-minutes sequence as
the seek case. The cases are direct play with one 4K encode; direct play with two 1080p
encodes; forced transcode with two 1080p encodes; and the two-worker direct-play case
with the matching seek sequence. Every run records playback-start latency, buffering
count and duration, every seek-to-resume latency, NAS throughput at five-second
intervals, and encode wall time. Comparison uses the worst baseline values, not averages.
Non-seek cases require zero buffering; every contended start may be no more than two
seconds worse than baseline; and every seek may be no more than three seconds worse.

## Quality outcome

The completed ICQ quality run contained all 144 required row identities: 71 rows passed
the row-level execution and output contract and 73 were invalid. No cohort produced an
admissible objective candidate:

| Cohort | Evidence | Conclusion |
| --- | --- | --- |
| AVC | 47 passed rows, one QSV-proof failure, and no setting that passed every clip's 95/90 VMAF gate | Objective no-go under the fixed contract; anomaly cause unresolved |
| VC-1 | 24 passed rows, but every row missed at least one VMAF threshold | Objective no-go under the fixed contract; anomaly cause unresolved |
| HDR10 | 72 invalid rows because source static-metadata values were unavailable while output values were populated | Harness-blocked; no encoder verdict |

Five AVC or VC-1 clips contained a repeatable exact-zero VMAF frame at the same frame
position across widely separated settings. Those frames collapsed harmonic VMAF but did
not establish whether the cause was temporal alignment, encoder output, or the VMAF
measurement boundary. The HDR10 outputs retained format, color, transfer, color-space,
and bit-depth properties, but the existing source oracle could not independently prove
the populated static-metadata values.

The objective gate precedes visual review. Therefore `chosenSettings` remains empty and
finalist, x265, savings, and contention results are not applicable. The evidence does
not define an ICQ production setting, storage-savings distribution, x265 premium, or
Plex processing window. FileFlows and media replacement remain unauthorized.

The generated findings artifact emitted an HDR10 no-go because it consumed the invalid
HDR rows. The accepted findings decision did not adopt that conclusion: independent
probe evidence showed that the source static-metadata oracle was unavailable, so the
stronger `harness-blocked / unresolved` rule governed. Populated output metadata proved
neither preservation nor corruption. The generated artifact remains immutable evidence,
but it does not override the accepted evidence classification.

## Bounded anomaly diagnostics

The implemented `diagnostics` mode investigates only the two unresolved anomaly classes.
It has separate manifest and result schema version 1 values that cannot resume or feed
quality, candidates, selected settings, or findings.

The VMAF panel is fixed to the five affected sample/clip/frame identities. It encodes
each clip only at ICQ 16 and ICQ 30, for exactly ten encodes. For the target frame and
two frames on either side, it records decoded continuity fields, the existing VMAF
result, VMAF after independently resetting both timelines, and local SSIM and PSNR for
offsets -2 through +2.

The classifier requires independent evidence:

- `temporal-alignment-defect` requires the same nonzero best SSIM and PSNR offset at
  both settings plus a matching timeline discontinuity;
- `encoder-output-defect` requires aligned zero-offset timelines, clean source
  continuity, repeatable zero VMAF, and a unique local SSIM and PSNR minimum at the
  target;
- `vmaf-measurement-defect` requires aligned timelines, independent metrics that do not
  make the target a unique local minimum, and exact zero only in VMAF; and
- all incomplete, tied, conflicting, or unsupported evidence is `unresolved`.

The HDR panel is fixed to the `detail` clip from each of the three HDR10 quality titles
at ICQ 16, for three more encodes. It compares bounded decoded-frame side data with HEVC
`trace_headers` evidence at the source beginning, the clip region, and the final source
window, then checks the stream-copy clip and encoded output. Exact rational metadata is
retained until normalization. Classification is limited to `source-probe-defect`,
`clip-boundary-defect`, `encoder-output-defect`, `preserved`, or `unresolved-oracle`.

Diagnostics dispatch is deliberately narrow. Before mutation it requires the dedicated
confirmation, a complete committed diagnostics object, digest agreement for the
historical findings and diagnostic design, exact historical run references, matching
committed and deployed panel hashes, and a passing diagnostic-capable ICQ node. A new or
explicit run ID cannot reuse either historical input run ID. The one diagnostic Job is
node-bound, has an eight-hour deadline, and keeps media outputs in scratch.

The initial four-hour bound proved insufficient. Diagnostic run
`20260825T134041Z-00bdae00` reached the exact 14,400-second Kubernetes deadline before
controlled finalization and terminated with `DeadlineExceeded`. The ordinary sanitized
results interface had no termination summary, and the bounded evidence reader rejected
the incomplete retained file census as `diagnostic-evidence-files-unexpected`. This is a
harness timeout, not an encoder, VMAF, timeline, or HDR metadata verdict. The immutable
run cannot be resumed, repaired, or interpreted as partial diagnostic evidence.

Future diagnostic Jobs use `activeDeadlineSeconds: 28800`. The eight-hour bound keeps
execution finite without changing the panel, commands, settings, metrics, classifiers,
output schemas, or artifact paths. It does not authorize automatic retries or further
deadline increases. If a fresh run reaches this deadline, stop and first distinguish
cumulative execution time from a stuck operation before changing the bound again.

## Diagnostic artifacts and sanitized results

One immutable diagnostics directory contains `manifest.json`, five VMAF evidence
documents, three HDR evidence documents, and `diagnostic-summary.json`. The manifest
binds the fixed panel, observed frames, commands, image and runtime identity, source
identity, historical input runs, and the digests of the findings and diagnostic design.
After acquisition, the producer rechecks source, clip, and output identities. Drift
invalidates the affected evidence instead of leaving a stale causal classification.

The diagnostic Job's termination message is a separate, bounded monitoring interface.
It carries canonical protocol, run, artifact, status, category, and allowlisted-reason
metadata, but no raw diagnostic evidence. The ordinary results reader authenticates the
matching workload and reports terminal work only after validating that summary and its
provenance. Active work produces only a terse state line; raw diagnostic files and logs
never cross this interface.

## Read-only diagnostic evidence reader

The later evidence reader is isolated from diagnostic execution. It accepts one
explicitly supplied valid immutable run ID only after proving the exact terminal owned
diagnostics Job, then mounts only that run's `diagnostics` subtree from the media claim,
read-only. The reader Job has no media-source, general output, scratch, samples,
image-evidence, GPU, pod identity, or node identity input. It has no service-account
token, uses the same non-root security boundary, and has finite execution and retention
bounds.

The in-cluster collector rejects unexpected files, unsafe paths, malformed evidence,
panel or manifest mismatch, and inconsistent summaries. It independently validates
provenance, panel completeness, schemas, timestamp continuity, VMAF/HDR classifications,
reason compatibility, and reduced HDR rationals. Only a bounded canonical projection of
the validated metrics, oracles, classifications, and sanitized reasons can leave the
cluster; retained commands, source paths, file hashes, runtime details, and raw logs are
omitted.

Manifest-binding failure has a separate bounded, value-redacted contract. The collector
reports only an allowlisted field identity and failure kind, never retained or expected
values. Unknown fields, duplicate or inconsistent issues, ambiguous structure, and
noncanonical output fail closed rather than expanding the disclosure surface.

The workstation-side reader authenticates the collector before accepting its log. It
checks deterministic workload ownership, command and panel identity, pinned runtime,
read-only storage, resource bounds, and terminal state. It then revalidates the
collector's canonical projection with the same evidence schemas and classifiers. Only
closed, sanitized failure categories are transportable; unknown failures, ambiguous
output, invalid provenance, or invalid schemas fail closed.

This reader supplies evidence for a later decision. It does not alter retained files,
reinterpret the historical quality rows, create a new quality candidate, or authorize
another evaluation stage.

Current source binds one approved retained diagnostics run and provides guarded readers,
but it contains no committed terminal diagnostic conclusion. A run binding proves which
evidence a reader may access; a successful collector would prove only that its bounded
projection passed the reader contract. Neither fact establishes an actual causal
classification. Synthetic diagnostic fixtures also test classifiers rather than report
the retained run's result.

## Validation and consequences

Offline validation covers the shared ICQ contract, mode and schema isolation, panel
cardinality, classification predicates, identity drift, dispatch refusal boundaries,
terminal sanitization, collector bounds, provenance, and failed-result transport.
Diagnostic dispatch and read-only evidence transport remain separate authority
surfaces; no read interface can dispatch diagnostic work.

The live verifier establishes only that the inert application is Ready, its inputs and
alert rules exist, no persistent benchmark workload is reconciled, and active benchmark
Pods remain separated from Plex. Likewise, a completion alert means Kubernetes reported
Job success. Readiness, Job completion, reader success, and diagnostic transport do not
establish admissible rows, a quality verdict, a causal diagnosis, a selected setting, or
a FileFlows decision.

The ICQ design answered the objective quality gate without promoting anomalous or
harness-blocked rows. Bounded diagnostics can establish a cause without weakening that
gate, and the evidence reader can expose only validated, sanitized evidence from the
approved retained run.

One admissible terminal diagnostic decision must choose exactly one next direction:

1. recommend fresh `qsv-hevc-icq-v1` quality evidence under a corrected contract;
2. close `qsv-hevc-icq-v1` and recommend a separate strategy decision; or
3. record the exact unresolved evidence and required operator input.

No such terminal decision is committed in current source. Even when one exists, it does
not itself authorize a new quality run or replacement strategy. Reconsidering ICQ needs
separate authority, fresh run identity, corrected independent oracles, and all applicable
quality and downstream gates. A distinct strategy remains a new design lineage.

This design also left LA-ICQ relabeling, AV1, production x265, driver, runtime, or
hardware changes, Talos, Kubernetes, Cilium, or GPU-plugin changes, TV or downloads
access, FileFlows deployment, media replacement, and cleanup outside exact-run authority
out of scope.

## Corrective amendment — 2026-08-26 diagnostic preparation and completion

This amendment corrects the bounded `qsv-hevc-icq-v1` diagnostic harness after run
`20260826T014246Z-373a665e`. It preserves the original evaluation purpose, fixed panel,
authority boundaries, evidence lineage, and downstream consequences. It does not
reinterpret the retained run, weaken the quality gate, select an ICQ setting, authorize a
quality benchmark, or authorize FileFlows deployment or media replacement.

### Defects and evidence

The bounded reader validated the retained run's complete schema-version-1 evidence set.
Four VMAF cases completed both settings. For each case, SSIM and PSNR selected offset zero
uniquely, while the source window was marked discontinuous because a 42-millisecond
timestamp step followed a recorded 41-millisecond packet duration in a stream with a
`1/1000` time base. The exact continuity predicate treated the one-tick representation
difference as a gap. Exact comparison of whole-clip frame counts and absolute source and
output timelines also made `zeroOffsetAligned` false despite the bounded offset-zero
metric agreement.

The fifth VMAF case stopped before QSV encoding. Its retained reason,
`source-clip-unavailable`, cannot distinguish stream-copy creation failure, clip-identity
failure, and frame-window failure. The producer began other panel encodes before it had
validated every source input, so one preparation failure still consumed most of the GPU
panel.

The producer successfully published the complete diagnostic summary and termination
payload with scientific status `harness-blocked`, then deliberately returned process
status 2. Because the Job has `backoffLimit: 0` and `restartPolicy: Never`, Kubernetes
immediately reported the generic terminal reason `BackoffLimitExceeded`. No retry
occurred. That reason described the container exit policy, not missing evidence or an
encoder result.

All three HDR rows completed. Their authoritative bounded frame and trace evidence,
stream-copy clip evidence, and encoded-output evidence agreed. The separate stream-level
ffprobe oracle returned null, so the accepted classification remains
`source-probe-defect`. This amendment does not change the HDR classification predicate.

### Preserved diagnostic contract

The correction preserves:

- one immutable diagnostics run directory with no resume or replacement;
- the exact five VMAF cases at ICQ 16 and ICQ 30;
- the exact three HDR cases at ICQ 16;
- exactly ten VMAF plus three HDR QSV encodes when source preparation succeeds;
- no fourteenth QSV encode or exploratory encoder setting;
- the existing mounts, run-scoped output, scratch-only media, security context, GPU
  request, Plex anti-affinity, finite deadline, and redaction boundaries;
- producer and reader validation through the same pure diagnostic predicates; and
- isolation from quality, selected settings, savings, contention, findings, and
  production media.

The result document shape and diagnostic schema-version-1 identity remain unchanged. The
manifest's script digests distinguish the corrected producer and readers from earlier
runs. New reasons remain closed enumerations in the producer, in-cluster collector,
workstation reader, termination projection, and tests.

### Source-preparation gate

The producer creates and validates all fixed source inputs before the first QSV encode.
For each of the five VMAF cases it must:

1. create the 90-second stream-copy source clip;
2. record the clip identity; and
3. record the exact five-frame source window around the fixed observed frame.

For each of the three HDR cases it must create the 90-second stream-copy source clip and
record the identities needed by the existing HDR evidence path. HDR metadata oracle
outcomes remain scientific evidence and do not become preparation failures.

The gate records one specific reason at a failing boundary:

- `source-clip-create-failed`;
- `source-clip-identity-unavailable`; or
- `source-frame-window-unavailable`.

If any fixed input fails preparation, the producer performs zero QSV encodes and
publishes a complete canonical eight-entry summary. The failed input retains its specific
reason. Inputs whose own preparation succeeded use
`source-panel-preparation-aborted`. All affected evidence remains `harness-blocked` and
unresolved. This correction does not retry extraction, change seek placement, transcode
the source, or select a nearby window.

If all source inputs pass, the producer executes the unchanged census: ten VMAF encodes
and three HDR encodes. Later encoder, decoder, metric, oracle, or identity failures keep
their existing evidence behavior and do not trigger an automatic second run.

### Timestamp continuity correction

Continuity remains derived only from each consecutive pair in the five recorded frame
timestamps, the preceding packet duration, and the declared stream time base. The
producer and both readers convert the values exactly before comparison.

For each pair, `expected` is the previous timestamp plus the previous packet duration,
and `tick` is one positive unit of the stream time base. The predicate:

- reports `repeat` when the current timestamp equals the previous timestamp;
- reports `non-monotonic-timestamp` when the current timestamp is earlier;
- reports `inconsistent-duration` when the preceding duration is not positive;
- accepts the relationship when the absolute difference between `current` and
  `expected` is no greater than `tick`;
- otherwise reports `gap` when `current` is later than `expected`; and
- otherwise reports `inconsistent-duration` when `current` is earlier than `expected`.

The one-tick tolerance accounts only for timestamp representation quantization. It does
not hide repeated frames, non-monotonic timestamps, nonpositive durations, or a
difference larger than one tick. A real fixture must prove that a difference larger than
one tick remains discontinuous.

### Bounded zero-offset alignment correction

`zeroOffsetAligned` becomes a local five-frame predicate instead of an equality check on
whole-clip decoded-frame count and absolute timestamp values. It is true only when:

- source and output windows contain the same five consecutive frame indices;
- both windows have clean continuity under the one-tick rule;
- their average frame rates are equal;
- after subtracting the first timestamp in each window, each corresponding timestamp
  differs by no more than the larger of the two stream time-base ticks; and
- each corresponding packet duration differs by no more than that same bound.

Absolute start timestamps and whole-clip decoded-frame counts are not local alignment
oracles. SSIM and PSNR stay independent content oracles used by classification; they do
not make the timeline predicate true by themselves.

The accepted VMAF classifier rules remain in force. Temporal classification does not
require reset-PTS VMAF to clear zero. Encoder/output classification excludes a nonzero
SSIM/PSNR pairing only when bounded timeline evidence corroborates that pairing.
Reset-PTS VMAF remains supporting evidence. Positive-infinity PSNR remains explicit
`{"kind":"positive-infinity"}` evidence, ranks above every finite value, is unique-best
only when one offset is infinite, and is a tie when two or more offsets are infinite. No
finite surrogate is permitted.

### Job and evidence completion correction

The diagnostic summary's `status` remains the scientific and harness outcome:
`complete`, `failed`, or `harness-blocked`. The termination payload retains that status
and its allowlisted reasons.

The container returns success only after it publishes the complete canonical manifest,
five VMAF evidence documents, three HDR evidence documents, and diagnostic summary, then
emits a valid termination payload. This applies when the summary status is `failed` or
`harness-blocked`. Kubernetes Job `Complete` therefore means only that the bounded
evidence protocol completed.

The container returns nonzero when it cannot create, validate, finalize, or publish that
canonical evidence set, or cannot emit its valid termination payload. With
`backoffLimit: 0`, Kubernetes can report such a producer failure as
`BackoffLimitExceeded`. Readers determine scientific status from the authenticated
termination payload and summary, never from the Job condition alone.

The ordinary results reader and bounded evidence reader accept a terminal owned Job only
when Job state, termination payload, run identity, artifact identity, and summary
provenance agree. They continue to reject active, ambiguous, foreign, noncanonical, or
incomplete evidence.

### Validation and next pass

Independent fixtures and executable tests must prove:

- all source preparation occurs before the first QSV encode;
- one failed source preparation produces zero QSV encodes and a complete eight-entry
  summary with the specific failing reason;
- successful preparation performs exactly ten VMAF and three HDR encodes;
- 41/42-millisecond cadence in a `1/1000` time base is clean;
- repeat, non-monotonic, nonpositive-duration, and differences greater than one tick
  remain discontinuous;
- bounded relative source/output timelines align despite different absolute starts;
- a nonzero timeline-correlated metric pairing does not become encoder/output defect;
- one positive-infinity PSNR value is uniquely best while multiple infinities tie;
- a published `harness-blocked` or `failed` summary completes the Job protocol; and
- missing or invalid canonical publication still returns nonzero.

Focused source-contract, runmeta, benchmark, dispatch, diagnostic-evidence, and census
suites and the offline benchmark validator must pass. The
`mise exec -- just kube encode-benchmark-validate` and `mise exec -- just ci` gates must
also pass before publication.

After merge and natural Flux reconciliation, the next pass requires a fresh preflight and
new immutable run ID. If preparation succeeds, it performs the unchanged 13-encode panel.
If preparation fails, it stops before GPU work and the specific bounded reason determines
the next correction. No monitoring schedule is created before a live Job exists. A
diagnostic result still requires a separate accepted decision before any fresh quality
benchmark or encoding deployment.

## Corrective amendment — 2026-08-28 runtime image provenance

This amendment corrects terminal producer authentication after the completed diagnostic
run `20260827T233832Z-2a79502c`. It preserves the existing workload contract, immutable
evidence, reader authority, and downstream decision boundaries. It does not repeat the
diagnostic, change the runtime image, weaken registry identity checks, authorize a quality
benchmark, or authorize FileFlows deployment or media replacement.

The completed Job and Pod specs contained the exact configured registry digest. The
kubelet's immutable `status.containerStatuses[0].imageID` also contained that digest. The
runtime display field `status.containerStatuses[0].image` instead contained a local image
configuration digest. The shared terminal producer validator required the display field
to equal the configured registry reference, so both ordinary results and the bounded
evidence-reader dispatch rejected otherwise valid terminal provenance.

`status.containerStatuses[0].image` is not used as registry identity. Terminal producer
authentication continues to require:

- the exact configured registry digest in the Job template container spec;
- the exact configured registry digest in the controlled Pod container spec;
- the exact digest, with only the accepted runtime prefix normalization, in immutable
  `status.containerStatuses[0].imageID`; and
- all existing Job, Pod, owner, label, script, command, volume, security, node, terminal,
  run, artifact, and payload checks.

An executable fixture models the observed Kubernetes shape: the two specs and `imageID`
retain the configured registry digest while `status.image` contains a different local
configuration digest. Both terminal readers must accept that shape. Independent mutations
of either workload spec image or `imageID` must still fail closed. Focused dispatch and
results tests, the offline encode-benchmark validator, and canonical local CI must pass
before publication.

This source correction does not authorize merge, Flux reconciliation, evidence-reader
dispatch, or another live action. After an operator-authorized merge and natural Flux
reconciliation, the existing immutable run remains eligible for a separately authorized
bounded evidence-reader dispatch. The diagnostic must not be repeated. Any transported
result still requires a separate accepted decision before any quality benchmark or
encoding deployment.
