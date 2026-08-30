# FileFlows QSV HEVC ICQ Evaluation

## Purpose and status

Evaluate Intel Quick Sync Video (QSV) HEVC Intelligent Constant Quality (ICQ) without
look-ahead as a movie-compression strategy. Use the existing inert encode-benchmark
harness to select settings before building FileFlows automation or changing production
media.

The first quality sweep completed, but VMAF and HDR source-probe defects prevented a
valid setting selection. Bounded diagnostics are now complete. Their accepted result
supports one fresh quality sweep under the corrected evidence contract in this
specification. No further anomaly diagnostic is required.

This evaluation can select an ICQ setting per supported source cohort and then measure
visual quality, x265 efficiency, storage savings, and Plex contention. It does not by
itself authorize FileFlows deployment or media replacement.

## Historical boundary

The LA-ICQ no-go in specification 002 remains valid. Its runs, settings, and evidence
cannot be relabeled as ICQ evidence. This evaluation retains the separate strategy
identity:

```text
qsv-hevc-icq-v1
```

The original ICQ quality run remains immutable. It contains 144 required row identities,
but it cannot supply corrected candidates:

| Cohort | Retained outcome |
| --- | --- |
| AVC | VMAF exact-zero anomalies prevented every setting from passing the objective gate. |
| VC-1 | VMAF exact-zero anomalies prevented every setting from passing the objective gate. |
| HDR10 | A null source stream probe invalidated otherwise populated HDR output evidence. |

The corrected evaluation uses a fresh run identity and does not edit, resume, or combine
historical rows.

## Strategy and candidate set

Every ordinary evaluation artifact uses `qsv-hevc-icq-v1`. The candidate set remains
exactly:

```text
16, 18, 20, 22, 24, 26, 28, 30
```

The encoder command remains:

```text
-c:v hevc_qsv
-global_quality <setting>
-look_ahead 0
-extbrc 0
```

The runtime must select exactly `ICQ`. LA-ICQ, CQP, another known mode, or unknown mode
evidence fails the row. The same committed setting list controls command construction,
validation, candidate ranking, selected-setting state, x265 comparison, savings,
contention, resume, and findings.

The corrected contract uses samples schema version 3, capability proof schema version 3,
run-manifest schema version 2, results schema version 3, quality-evidence schema version
1, and quality-candidates schema version 2. A quality result row adds
`quality_evidence_path` and `quality_evidence_sha256`; those fields are empty for modes
that do not produce quality evidence. Existing schema-version-2 results remain readable
as historical evidence but cannot satisfy the corrected quality gate.

## Harness and safety boundary

Flux manages only inert inputs: the scripts ConfigMap, samples ConfigMap, and a
negative-priority class. A guarded dispatcher creates finite run-owned Jobs from a
non-rendered template. The source contract pins the runtime image by digest and each
immutable manifest binds scripts, samples, commands, model, runtime, source, and upstream
identities.

The workload boundary is unchanged:

- `/media` exposes only `media/movies` and is read-only;
- `/out` exposes only the benchmark subtree and stores run-scoped evidence;
- `/scratch` is a 105 GiB node-local `emptyDir`, with 105 GiB requested and 110 GiB
  limited ephemeral storage;
- full-title work requires the 115 GiB free-space preflight floor;
- media and downloads outside the movie subtree are not mounted;
- containers run as UID/GID `568`, non-root, without privilege escalation or a service
  account token, and with all capabilities dropped;
- GPU Jobs request one i915 resource, require Plex anti-affinity, and use negative
  priority; and
- Jobs use finite deadlines, `restartPolicy: Never`, and `backoffLimit: 0`.

The source library is never writable. Clip sweeps and savings outputs remain temporary.
Only an operator-confirmed finalist can enter a durable benchmark `encodes/` directory.
Resume requires an explicit run ID and exact manifest identity. A completed row skips
only when its full schema and referenced evidence remain valid. Every FFmpeg command uses
`-nostdin`, and decode validation maps only the primary video before independent stream
and metadata checks.

## Capability and dispatch gate

A node has passing ICQ capability only when all of these are true:

1. Configured, dispatched, and running image digests agree.
2. QSV initialization succeeds without a known device or session failure.
3. The FFmpeg process binds the configured render node and i915 driver.
4. The production command selects ICQ.
5. DRM fdinfo reports positive video-engine work.
6. Encode progress is finite and positive.
7. The primary output video decodes.
8. The configured metric command executes successfully.

Missing identity, telemetry, or oracle evidence is `harness-blocked`, not an encoder
failure. Expensive GPU stages repeat the short proof on their assigned node before source
hashing or run-directory creation. Two-worker contention additionally requires two
distinct eligible nodes.

Dispatch revalidates deployed source, contract, image, node capability, run identity,
and upstream selected-setting state. It authenticates the kubelet's immutable `imageID`;
the runtime display-only `status.image` value is not a registry-identity oracle.
Kubernetes-projected scripts may use only the canonical `..data/<same-name>` link shape,
must resolve inside the scripts mount, and must match the manifest digest.

## Fixed evaluation population

The quality panel remains a fixed stress panel covering VC-1, clean and grain-heavy AVC,
and clean, grain-heavy, dark, and high-motion HDR10 material. Dolby Vision Profile 7 is
a detection-only exclusion and is never encoded.

The quality sweep covers six titles, three 90-second stream-copy clips per title, and all
eight ICQ settings. A complete run therefore contains 144 unique QSV rows. Before work,
the harness rechecks each committed source path, size, and hash. Source drift requires a
new source identity; it cannot silently substitute a title or clip.

Each row records:

- ICQ selection, QSV initialization, GPU work, progress, and output decode;
- input and output bytes, bit rates, reduction, wall time, and throughput;
- codec, duration, resolution, frame rate, bit depth, audio, subtitle, and chapter
  validation;
- raw and evaluated VMAF evidence, including any permitted frame exclusion;
- whole-clip SSIM and PSNR evidence; and
- authoritative HDR preservation evidence when the source cohort is HDR10.

## Accepted diagnostic decision

Final diagnostic run `20260829T020752Z-43984d8d` completed the bounded evidence protocol.
The authenticated collector returned five VMAF and three HDR entries.

Four VMAF entries are `vmaf-measurement-defect`:

| Sample | Clip | Frame |
| --- | --- | ---: |
| `avc-clean-coco` | `motion` | 1641 |
| `avc-grain-memento` | `dark` | 523 |
| `avc-grain-memento` | `detail` | 370 |
| `vc1-fugitive` | `motion` | 798 |

At ICQ 16 and 30, each entry had clean source and output windows, zero-offset timeline
agreement, high finite zero-offset PSNR and SSIM, and the same isolated exact-zero VMAF
value before and after timeline reset. Adjacent VMAF frames were nonzero. Together with
the repeated frame identities in the original eight-setting sweep, this establishes a
source-frame-specific VMAF measurement defect rather than an encoder-output defect.

`vc1-fugitive/detail` frame 781 remains unresolved because its source frame window was
unavailable. It receives no correction permission.

All three HDR entries are `source-probe-defect`. The stream-level source probe returned
null, while decoded-frame and `trace_headers` source evidence agreed and the stream-copy
clip and encoded output preserved the same normalized static metadata. The null stream
probe is not an encoder verdict.

These classifications close the diagnostic stage. The diagnostic artifacts do not
become quality rows and no diagnostic run is repeated.

## Corrected VMAF contract

The four accepted sample, clip, and frame identities form a closed correction list. The
list is bound to the diagnostic decision, the committed sample identity, and the quality
run manifest. No wildcard, score-based search, neighboring frame, additional sample, or
additional clip is permitted.

For a listed identity, the quality metric reducer:

1. validates the complete raw libvmaf frame array;
2. locates exactly one matching frame index;
3. excludes that frame only when its VMAF value is exactly zero;
4. retains the raw frame and value in the row's bounded quality-evidence document; and
5. computes harmonic mean and one-percent low from the remaining frames.

If the listed frame is absent, duplicated, nonnumeric, or not exactly zero, no exclusion
is applied. Malformed evidence fails the metric. An exact-zero frame outside the closed
list is never automatically excluded. The unresolved `vc1-fugitive/detail` identity
uses unmodified VMAF and cannot qualify through an exclusion.

The correction does not lower the VMAF thresholds. It removes only values independently
classified as measurement defects. The raw libvmaf output remains retained beneath the
immutable run. Each row references a bounded evidence document by relative path and
SHA-256 digest. That document records raw and evaluated frame counts, the excluded frame
identity or `none`, evaluated VMAF statistics, whole-clip SSIM, whole-clip PSNR, and the
row identity. Resume and candidate ranking independently validate the document and its
digest.

SSIM and PSNR are independent report-only quality metrics. Their commands must succeed
and return finite values for an admissible row, but this design does not add post-outcome
thresholds for them. Input/output byte counts and reduction remain mandatory and drive
candidate ranking only after all objective gates pass.

## Corrected HDR preservation contract

HDR10 validation no longer treats the known-null stream-level source side data as the
authoritative static-metadata oracle. It retains stream-level format, color primaries,
transfer, color space, bit depth, duration, and stream-layout checks.

For static metadata, the harness reuses the validated diagnostic oracle:

- decoded-frame side data and `trace_headers` must both parse;
- they must agree exactly after rational normalization;
- the full-title source at the clip region, stream-copy clip, and encoded output must
  agree; and
- mastering-display primaries, white point, luminance, MaxCLL, and MaxFALL are all
  required.

Source decoded/trace disagreement is `harness-blocked`. Source and stream-copy clip
disagreement is a clip-boundary defect and is `harness-blocked`. Clip and encoded-output
disagreement fails HDR preservation as an encoder-output defect. A null auxiliary stream
probe is recorded but does not override an otherwise complete authoritative oracle.

The normalized oracle and classification are stored in the row's bounded
quality-evidence document. Candidate ranking requires `validation_hdr=passed` and a
validated `preserved` classification for every HDR10 row.

## Objective candidate selection

A setting qualifies for a cohort only when every expected title/clip row exists exactly
once and independently satisfies all of these conditions:

- row status, ICQ selection, initialization, QSV proof, GPU work, and decode pass;
- codec, duration, resolution, frame rate, bit depth, audio, subtitle, and chapter
  validation pass;
- the bounded quality-evidence reference and digest validate;
- VMAF harmonic mean is at least 95;
- VMAF one-percent low is at least 90;
- SSIM and PSNR are finite;
- HDR10 static metadata is authoritatively preserved when applicable; and
- reduction is numeric and the strategy identity is exact.

Qualifying settings are ranked within each cohort by median clip-size reduction. Lower
`global_quality` wins an exact reduction tie. Cohorts are independent: AVC or HDR10 can
advance even if VC-1 has no admissible candidate. If the unresolved VC-1 frame continues
to prevent a complete passing setting, VC-1 remains `no verdict` and those titles remain
outside the selected strategy.

The fresh quality run and candidate artifact move the evaluation from diagnostics to
encoding selection. They do not automatically choose a setting.

## Visual and downstream selection

Objective candidates enter 1:1 source/output crop review in rank order. A crop pass makes
the setting provisional. A full-title Plex review then checks Direct Play, HDR behavior,
motion, grain retention, banding, and blocking. A Plex pass makes the setting final. A
failure records the rejected candidate and advances to the next ranked candidate. The
fixed list is exhausted rather than widened.

Only a provisional setting can authorize its finalist encode. Only a final setting can
authorize the later stages:

- x265 matched-quality comparison on the fixed grain-heavy AVC and HDR10 references;
- full-title savings measurement on the stratified cohort samples; and
- Plex contention measurement under the fixed playback cases.

The x265 curve remains measured, bounded to CRF 10 through 34, and never extrapolated.
The existing premium bands remain: at most 15 percent favors QSV, more than 15 through
30 percent is acceptable with a recorded cost, and more than 30 percent is materially
worse.

Savings remains cohort-scoped. Median reduction of at least 25 percent is GO, 15 to less
than 25 percent is MARGINAL and requires an operator decision, and less than 15 percent
is NO-GO. Contention continues to compare fixed playback and seek cases with the worst
matching baseline.

FileFlows implementation and media replacement require a later explicit operator
decision based on final quality, savings, comparison, and contention evidence.

## Evidence and failure handling

Every run is immutable and isolated by mode and run ID. Corrected quality evidence cannot
resume from schema-version-2 rows or consume diagnostic files at runtime. The committed
diagnostic decision supplies only the closed correction identities and oracle semantics.

The producer publishes canonical results and candidate artifacts only after validating
their complete schemas. A scientific no-go or harness-blocked outcome can still complete
the evidence protocol. Missing, malformed, ambiguous, foreign, or partially published
evidence fails closed. Kubernetes Job completion indicates protocol completion, not an
encoder verdict.

Readers authenticate Job, Pod, owner, imageID, script, command, volume, security, node,
run, artifact, and termination identities before returning bounded results. Raw logs,
source paths, runtime details, and unrestricted retained files do not cross the bounded
reader interface.

## Validation requirements

Executable tests must prove at least:

- only the four closed frame identities can be excluded;
- an allowed exact-zero frame is retained raw and excluded exactly once;
- absent, duplicate, nonnumeric, nonzero, and unlisted frames cannot be excluded;
- corrected harmonic mean and one-percent low use the evaluated frame population;
- raw/evaluated counts, evidence paths, and SHA-256 bindings fail closed on drift;
- whole-clip SSIM and PSNR are required and finite without becoming new thresholds;
- HDR decoded-frame and trace evidence normalize and agree across source, clip, and
  output;
- source-oracle, clip-boundary, and encoder-output HDR failures remain distinct;
- a null auxiliary source stream probe does not invalidate a complete authoritative HDR
  oracle;
- historical schema-version-2 rows cannot satisfy the corrected gate;
- a complete fresh panel has exactly 144 unique QSV rows;
- one cohort can advance while another remains without a candidate;
- candidate thresholds and ranking are unchanged; and
- diagnostic artifacts cannot enter quality, selected-setting, or findings inputs.

Run focused source-contract, runmeta, benchmark, dispatch, probe, and result-reader suites.
Then run `mise exec -- just kube encode-benchmark-validate` and
`mise exec -- just ci` before publication. After any required rebase, rerun affected
validation including `mise exec -- just ci`.

## Current next action and exclusions

The next implementation updates the quality evidence schema, VMAF reducer, HDR oracle,
resume validation, candidate ranker, bounded results, fixtures, and tests. After merge
and natural Flux reconciliation, one fresh preflight and one fresh quality run may
exercise the corrected contract. Do not run another anomaly diagnostic.

This design does not relabel LA-ICQ evidence, change the encoder, add AV1, deploy
FileFlows, replace media, alter Talos/Kubernetes/Cilium/GPU infrastructure, access TV or
downloads data, or authorize unbounded live operations.
