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

## Historical boundary

The LA-ICQ no-go in specification 002 remains valid. Earlier capability evidence showed
that the nodes could perform hardware-backed ICQ work, but that evidence did not provide
an ICQ quality, savings, matched-quality, visual, or contention result. The old LA-ICQ
quality run remained inadmissible and could not become a fixture or input for this
strategy.

The ICQ adaptation preserved the harness's storage, mount, run-scoping, validation, and
failure-safety boundaries while replacing every LA-ICQ command, setting guard, schema,
resume rule, result reader, and test fixture with an ICQ-only contract.

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
crop review in rank order. A crop pass makes the setting provisional; a full-title Plex
pass makes it final; a failure appends the setting and its evidence identity to the
rejected prefix before the next candidate is considered. Only a provisional record can
authorize its finalist, and only a final record can authorize x265, savings, or
contention evidence.

The x265 comparator uses all three clips from the grain-heavy AVC and HDR10 references.
It starts at CRF `18, 20, 22, 24`, extends in steps of two only as needed, remains within
CRF 10 through 34, and never extrapolates. Savings uses one validated full-title ICQ
encode per applicable representative title and reports cohort median, quartiles, and
interquartile range. Contention retains three seek-bearing baselines and compares every
applicable case against the worst observed baseline start and seek latencies.

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
node-bound, has a four-hour deadline, and keeps media outputs in scratch.

## Diagnostic artifacts and sanitized results

One immutable diagnostics directory contains `manifest.json`, five VMAF evidence
documents, three HDR evidence documents, and `diagnostic-summary.json`. The manifest
binds the fixed panel, observed frames, commands, image and runtime identity, source
identity, historical input runs, and the digests of the findings and diagnostic design.
After acquisition, the producer rechecks source, clip, and output identities. Drift
invalidates the affected evidence instead of leaving a stale causal classification.

The diagnostic Job's termination message is a separate, small monitoring interface. It
contains protocol identity (`schemaVersion`, `strategyId`, and `mode`), run identity,
artifact location, overall status, bounded category counts, and allowlisted reason
codes. It contains no raw diagnostic evidence. The message is canonical JSON, has a
3,072-byte maximum, and limits reason count and length. The ordinary results reader
queries the matching Pods once, requires exactly one canonical diagnostics Pod, and
allows beside it only the deterministic reader Pod with matching dispatch and Job
ownership. Active work produces a terse state line. Terminal work is reported only
after schema, count, reason, run, and artifact-location validation; raw diagnostic files
and logs are never printed through this interface.

## Read-only diagnostic evidence reader

The later evidence reader is isolated from diagnostic execution. It accepts only the
single explicitly approved retained diagnostics run and mounts only that run's
`diagnostics` subtree from the media claim, read-only. The Job has no media-source,
general output, scratch, samples, image-evidence, GPU, pod identity, or node identity
input. It has no service-account token, uses the same non-root security boundary, has a
five-minute deadline, and expires after one hour.

The in-cluster collector rejects symlinks, missing or extra files, unsafe paths,
malformed JSON, panel mismatch, manifest mismatch, summary mismatch, and any input file
larger than 65,536 bytes. It validates the exact ten-file allowlist and the producer's
reachable acquisition shapes. It independently recomputes timestamp continuity,
VMAF/HDR classifications, exact reason compatibility, summary coupling, and reduced HDR
rationals. Its one-line canonical JSON projection is also limited to 65,536 bytes and
contains only bounded continuity, metrics, normalized HDR oracles, classifications, and
reason codes. It omits retained commands, source paths, file hashes, runtime details,
and raw logs.

The workstation-side reader authenticates the collector before accepting its log. It
requires exactly one deterministic Job and one controlled Pod, exact labels and owner
UIDs, exact command and panel hash, the current scripts ConfigMap, pinned image identity,
read-only mount shape, resource limits, and an allowed terminal state. A successful
collector must emit one canonical JSON line that passes the same evidence schemas and
classifiers again. A collector that terminates with the defined contract exit is also a
valid result only when its one-line error belongs to the fixed allowlist; the reader
transports it as canonical structured `status: failed` evidence. Unknown failures,
ambiguous output, invalid provenance, or invalid schemas fail closed.

This reader supplies evidence for a later decision. It does not alter retained files,
reinterpret the historical quality rows, create a new quality candidate, or authorize
another evaluation stage.

## Validation and consequences

The source validator, rendered-manifest checks, and Bats suites cover the shared ICQ
contract, mode and schema isolation, exact panel cardinality, classification predicates,
identity drift, dispatch refusal boundaries, terminal sanitization, collector file and
size bounds, Job/Pod provenance, and failed-result transport. The cluster-independent
`encode-benchmark-validate` interface is part of the repository CI catalog. The
`encode-benchmark-diagnostics` interface owns only bounded diagnostic dispatch,
`encode-benchmark-results` exposes only the sanitized terminal summary, and the separate
`encode-benchmark-diagnostic-evidence-reader` and
`encode-benchmark-diagnostic-evidence-results` interfaces own creation and validation of
the read-only collector. None of these read interfaces can dispatch diagnostic work.

The ICQ design answered the objective quality gate without promoting anomalous or
harness-blocked rows. Bounded diagnostics can establish a cause without weakening that
gate, and the evidence reader can expose only validated, sanitized evidence from the
approved retained run. A fresh quality evaluation, a replacement encoder strategy,
FileFlows deployment, and media replacement all require separate authority.
