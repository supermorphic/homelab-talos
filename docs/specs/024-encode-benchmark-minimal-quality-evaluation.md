# Encode Benchmark Minimal Quality Evaluation

## Purpose and status

Reduce the encode benchmark to one disposable, pre-FileFlows experiment. The retained
system can launch one guarded QSV HEVC ICQ quality run, collect valid evidence, and rank
each source cohort or return a defensible `no-go` or `no-verdict`. It is not a durable
encoding platform and does not authorize media replacement.

This specification preserves the corrected quality contract from specification 017.
It retires the completed diagnostic protocol and speculative downstream modes. A later
FileFlows implementation requires a separate design and operator decision.

The offline encode validator must retain 35-50 high-value Bats identities and have a
controlled complete-run median of 60-120 seconds. No test simulates 144 encodes; one
independent planner assertion proves the exact work set, and small integrations exercise
representative rows.

## Fixed strategy and work plan

Every artifact uses strategy `qsv-hevc-icq-v1`. The settings remain exactly:

```text
16, 18, 20, 22, 24, 26, 28, 30
```

The QSV encoder command remains:

```text
-c:v hevc_qsv
-global_quality <setting>
-look_ahead 0
-extbrc 0
```

Runtime evidence must identify the selected rate control as exactly `ICQ`. LA-ICQ,
CQP, another known mode, or an unknown mode fails the row.

The quality population remains six titles. Each title supplies the three named
90-second stream-copy clips, and every clip uses all eight settings:

| Source identity | Cohort | `detail` | `dark` | `motion` |
| --- | --- | --- | --- | --- |
| `vc1-fugitive` | `vc1` | `01:15:00.000` | `00:35:00.000` | `01:20:00.000` |
| `avc-clean-coco` | `avc` | `00:10:00.000` | `00:45:00.000` | `00:05:00.000` |
| `avc-grain-memento` | `avc` | `00:23:00.000` | `00:38:00.000` | `01:15:30.000` |
| `hdr10-clean-ministry` | `hdr10` | `01:04:15.000` | `01:19:15.000` | `00:29:15.000` |
| `hdr10-grain-goodfellas` | `hdr10` | `01:06:25.000` | `00:36:55.000` | `00:40:45.000` |
| `hdr10-motion-john-wick-2` | `hdr10` | `01:04:50.000` | `00:06:30.000` | `01:38:00.000` |

The complete plan is exactly `6 x 3 x 8 = 144` unique QSV rows. Dolby Vision Profile 7
remains detection-only and is never encoded. Before measured work, the harness rechecks
each committed source path, byte size, and SHA-256 digest. Drift requires a new source
identity and cannot silently substitute a title or clip.

## Scientific evidence contract

### VMAF, SSIM, and PSNR

The correction list is closed and bound to accepted diagnostic run
`20260829T020752Z-43984d8d`:

| Sample | Clip | Frame |
| --- | --- | ---: |
| `avc-clean-coco` | `motion` | 1641 |
| `avc-grain-memento` | `dark` | 523 |
| `avc-grain-memento` | `detail` | 370 |
| `vc1-fugitive` | `motion` | 798 |

For a listed identity, the reducer validates the complete raw libvmaf frame array,
finds exactly one matching frame, and excludes it only when its VMAF value is exactly
zero. The raw frame remains in bounded evidence. The harmonic mean and one-percent low
use only the evaluated population. An absent, duplicate, nonnumeric, or nonzero listed
frame is not excluded; malformed evidence fails. No wildcard, score search, neighboring
frame, sample, or clip can extend the list.

The unresolved `vc1-fugitive/detail` frame 781 has no correction permission. All
unlisted exact-zero frames remain in the evaluated population.

Whole-clip SSIM and PSNR commands must succeed and return finite values. They are
report-only metrics and have no threshold. Input/output byte counts and numeric reduction
remain mandatory.

### HDR10

Stream-level format, color primaries, transfer, color space, bit depth, duration, and
stream-layout checks remain required. Static HDR metadata uses decoded-frame evidence and
`trace_headers` evidence as equal authoritative oracles. Both must parse and agree after
exact rational normalization across the full-title source at the clip region, the
stream-copy clip, and the encoded output. Mastering-display primaries, white point,
luminance, MaxCLL, and MaxFALL are all required.

Source decoded/trace disagreement is `source-oracle-defect` and harness-blocked. Source
to clip disagreement is `clip-boundary-defect` and harness-blocked. Clip to encoded-output
disagreement is `encoder-output-defect` and fails HDR preservation. Agreement is
`preserved`. A null auxiliary stream probe is recorded but cannot override a complete
authoritative oracle. Every HDR10 candidate row requires `validation_hdr=passed` and
`preserved`.

## Evidence, resume, and ranking

The retained versions are samples schema 3, capability-proof schema 3, run-manifest
schema 2, results schema 3, quality-evidence schema 1, and quality-candidates schema 2.
The immutable manifest binds scripts, samples, commands, model, runtime, source, and any
upstream identity. The candidate artifact binds the strategy, quality run, results schema
and digest, expected clip count, cohort status, and bounded candidate rows.
The 41-column result row includes `quality_evidence_path` and
`quality_evidence_sha256`. A quality-evidence document binds the exact strategy, run,
sample, cohort, source digest, clip, setting, raw and evaluated VMAF counts and statistics,
zero or one excluded raw frame, finite SSIM and PSNR, and the normalized HDR oracle or
`null` for non-HDR rows.

Evidence publication validates the complete schema before atomic no-clobber publication
inside the immutable run. The result stores a relative evidence path and SHA-256 digest.
Resume skips only an exact passed row whose full result schema, identity, evidence path,
digest, and evidence document still validate. Attempts increase monotonically. Schema-2
historical rows and diagnostic artifacts cannot satisfy the corrected gate.

A setting qualifies within one cohort only when every expected title/clip row exists
exactly once and passes strategy, QSV initialization, selected ICQ mode, positive GPU
work, progress, decode, stream and metadata validation, evidence authentication, and
these unchanged gates:

- VMAF harmonic mean is at least 95;
- VMAF one-percent low is at least 90;
- SSIM and PSNR are finite;
- HDR10 evidence is `preserved` when applicable; and
- reduction is numeric.

Qualifying settings are ordered by median clip-size reduction, highest first. Lower
`global_quality` wins an exact reduction tie. AVC, VC-1, and HDR10 rank independently.
A complete cohort with no qualifying setting is `no-go`; an incomplete or scientifically
unresolved cohort is `no-verdict`; a cohort with candidates is `eligible`. One cohort can
advance while another does not. Ranking produces evidence only; it does not select a
setting or authorize FileFlows.

## Dispatch and workload boundary

Flux manages inert inputs only: scripts, samples, the Job template, and negative priority.
An exact operator confirmation and a current schema-3 capability proof are required before
quality Job creation. Dispatch revalidates deployed source, contract, digest-pinned image,
eligible node, run identity, and Job rendering. Configured, dispatched, running handoff,
and kubelet `imageID` digests must agree. Rollback may delete only resources created by
the dispatch and uses captured ownership and UID preconditions. Result reading accepts
one terminal, owned Job and Pod and returns only the bounded quality completion record.

The workload boundary remains:

- `/media` exposes only `media/movies` and is read-only;
- `/out` exposes only the benchmark subtree and stores run-scoped evidence;
- `/scratch` is a node-local 105 GiB `emptyDir`, with 105 GiB requested and 110 GiB
  limited ephemeral storage;
- full-title work requires the 115 GiB free-space preflight floor;
- containers run as UID/GID `568`, non-root, without privilege escalation or a service
  account token, and with all capabilities dropped;
- GPU Jobs request one i915 resource, require Plex anti-affinity, and use negative
  priority; and
- Jobs have finite deadlines, `restartPolicy: Never`, and `backoffLimit: 0`.

FFmpeg uses `-nostdin`. Decode validation maps only primary video before independent
stream and metadata checks. Quality video and temporary clips stay in scratch and are
discarded; only bounded run evidence persists under `/out`.

## Retired surfaces and boundary

Remove the diagnostic producer, collector, reader, terminal transport, historical
protocols, and operator recipes. Also remove x265 comparison, finalist and durable
finalist publication, savings and audio inventory, contention and playback observation,
findings rendering, census and sample selection, and generalized cleanup or compatibility
surfaces that have no current quality-evaluation consumer.

Retirement must not change the encoder, settings, quality panel, source identities,
correction list, HDR oracle, schemas, objective thresholds, ranking, resume semantics,
dispatch guards, or workload safety boundary above. Internal helpers may be renamed or
narrowed when the corrected quality path still consumes them.

No cluster access, live benchmark, general CI change, FileFlows implementation, or media
mutation is part of this work. A real quality run and any FileFlows decision remain
operator-directed follow-up work.
