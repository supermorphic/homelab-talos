# Movie encoding benchmark — design

Status: Draft
Date: 2026-08-01.
Branch: `fileflows-movie-encoding-strategy`.

Revised after a code review and an independent spec review (codex). Two open
decisions remain — scratch placement and the temporary Plex library — recorded in
`reviews/2026-08-01-fileflows-movie-encoding-design-response.md`. Draft rather
than Accepted precisely because those are open: an accepted record is superseded,
never revised.

## 1. Purpose

Determine, cheaply and reversibly, whether Intel Quick Sync HEVC encoding on the
NUC cluster can normalize and meaningfully shrink the movie catalog — **before**
committing to build a FileFlows platform.

**Source document.** This design responds to an operator-supplied "FileFlows Movie
Evaluation and Implementation Plan," which is deliberately **not tracked in this
repository** — it is working input, not a deliverable. Citations below of the form
"plan §N" refer to that document's numbered sections and are recorded for
provenance; the material this design actually depends on is restated here, so this
spec stands alone. The sections cited are: §4 safety principles, §6 QSV
requirement, §11 encoding strategy, §13 output validation, §14 the 15% savings
gate, §16 phased rollout, §17 the TV boundary, and §21 the seeding boundary.

That plan is deploy-first: its steps 1–11 build a three-node FileFlows
application, storage, probes, and classification flows before a single frame is
encoded. The risk it leaves unaddressed is the one most likely to sink the
project — whether QSV HEVC preserves acceptable quality, particularly on
grain-heavy 4K HDR10 material, at a worthwhile size reduction.

This design inverts that order. A throwaway benchmark harness answers the
quality-and-savings question first. FileFlows gets built only if the answer
justifies it, and gets scoped by what the measurements show.

The benchmark's deliverable is a **decision**, not a dataset.

## 2. Scope

In scope:

- A read-only library census Job (metadata-only `ffprobe` inventory of the movie
  directory).
- A GPU-backed encode benchmark Job running two distinct sampling panels: a
  quality panel on stress clips, and a savings panel on stratified full titles.
- Guarded `just` recipes across `.just/bootstrap.just` and `kubernetes/mod.just`,
  following existing repository conventions.
- Harness tests wired into `just ci`.
- A `findings.md` deliverable carrying an explicit go/no-go with per-cohort scope
  against quantitative thresholds.
- A defined protocol for measuring encoding's effect on concurrent Plex playback.

Out of scope (deliberately deferred):

- Deploying FileFlows itself. That is gated on this benchmark's outcome.
- TV. Per plan §17, `media/tv` is neither mounted nor traversed (§7.2).
- Dolby Vision encoding. DV appears only as a detection-only sample.
- Audio track pruning, subtitle cleanup, and metadata hygiene. The census
  gathers audio inventory as reconnaissance; no audio is modified.
- Any change to `intel-gpu-plugin`. See §5.
- Any change to Plex, including assigning it a PriorityClass. See §5.3.

## 3. Context and findings

### 3.1 Torrent hardlink economics

`kubernetes/apps/media/storage/app/persistentvolume.yaml` mounts one SMB share
from the UNAS Pro with server inodes preserved. `radarr/app/values.yaml` confirms
imports **hardlink** `/data/downloads` into `/data/media/movies` rather than
copying, and `qbit-manage/app/config.yml` documents the proof (inodes 934/952,
links=2).

Re-encoding breaks the hardlink. Whether that costs or saves space depends on the
torrent's lifecycle state, and `qbit-manage/app/config.yml` defines four distinct
states that must be modeled separately:

| State | Config basis | Effect of re-encoding |
|---|---|---|
| **Active / seeding** | Any torrent still within its share limits | Must SKIP — changing a byte breaks the torrent's hashes |
| **Private (CZTeam)** | `czteam` group, `cleanup: false`, `max_seeding_time: -1` | Download copy is **never** deleted. Re-encoding permanently adds the encode's size on top of the original. Net loss. |
| **Public, awaiting cleanup** | `public` group, `cleanup: true`, stops at ratio 1.5 / 7 d | Download copy is removed to a 7-day recycle bin once eligible. Re-encoding before cleanup temporarily doubles; savings realize after cleanup plus the recycle window. |
| **Already cleaned / never torrented** | `st_nlink == 1` | Full savings realize immediately. |

An earlier draft of this spec claimed torrents are "paused but never deleted."
That is true only of the `czteam` group. The `public` group — which carries the
`movies` category — has `cleanup: true`. The census must therefore classify by
link count *and* by tag, not by a single global assumption.

Operator-supplied counts bound the problem: 345 of 388 MKV files (88.9%) are
MakeMKV rips. Caveat: the MakeMKV tag comes from muxing-app metadata and
identifies who *ripped* a file, not whether this copy is a torrent payload — a
scene release of someone else's MakeMKV rip carries the same tag. Link count
(`st_nlink > 1`) is the authoritative test, and the census performs it.

### 3.2 Sizing the prize

From the plan's cohort table, Dolby Vision removes 137 titles / 7.7 TiB from
scope, leaving roughly 9 TiB addressable (6.04 TiB HDR10 + 2.91 TiB AVC). At a
plausible 35–45% reduction that is **~3–4 TiB recovered**.

This is an unvalidated estimate built on the plan's prose table, which is not
itself in the repository, and it ignores the lifecycle states in §3.1. It exists
only to size the work. The census reconciles cohort counts; the savings panel
(§8.4) produces the measured figure that supersedes it.

### 3.3 GPU allocation constrains topology

`kubernetes/apps/kube-system/intel-gpu-plugin/app/daemonset.yaml` passes no
`-shared-dev-num`, so it defaults to **1**. Each NUC advertises exactly one
`gpu.intel.com/i915`; three exist cluster-wide, and Plex holds one permanently.

`-shared-dev-num=N` advertises N slots per physical render device. Both settings
inject the *same* `/dev/dri/renderD128` into every container that receives a
slot — there is no partitioning, no memory split, no time-slice quota. It is
purely a scheduling counter. The kernel i915 driver multiplexes concurrent
clients regardless; `N=1` simply forbids Kubernetes from admitting more than one
pod requesting the resource per node.

Consequence for the plan: §6's topology of one Flow Runner per NUC wants all
three slots, leaving none for Plex. Either a runner hangs `Pending` forever, or
Plex cannot reschedule after a node drain or HelmRelease upgrade. **The plan's
core topology cannot schedule on this cluster as configured.**

§5 resolves this without touching the plugin.

## 4. Approach

Four alternatives were considered.

| Approach | Verdict |
|---|---|
| Deploy FileFlows first, benchmark with it (plan as written) | Rejected. Builds the whole app before the kill-shot question is answered. |
| Deploy Server + one runner, benchmark through FileFlows | Rejected. Still ~60% of the deploy work before any answer. |
| **Standalone benchmark Job, FileFlows deferred** | **Chosen.** Answers the decisive question in days, discards cleanly. |
| Benchmark script on the SMB share, generic image runs it | Rejected. Fastest iteration, but the script escapes git entirely — no review, no history, breaks "git is the source of truth." |

Within the chosen approach, the harness uses a **pinned public ffmpeg image plus
a Flux-managed ConfigMap** holding the scripts. A custom in-repo image was
rejected: a container publish workflow, registry auth, and a tag-bump loop per
script edit is disproportionate infrastructure for tooling intended to be deleted
in weeks. Image selection is an implementation task with explicit acceptance
criteria (§7.1), not a decision this design makes.

## 5. GPU allocation, Plex precedence, and priority

### 5.1 Two Flow Runners, not three

**Requirement:** Plex must never compete with FileFlows for a GPU while streaming.

With two runners the arithmetic fits `shared-dev-num=1` exactly — 3 slots, Plex
takes 1, runners take 2 — and hard anti-affinity against Plex keeps Plex's node
encode-free. No change to `intel-gpu-plugin` is required. GPU contention becomes
structurally impossible rather than merely discouraged: the kubelet refuses to
admit a second GPU-requesting pod on Plex's node. That is admission control, not
a scheduling preference, so there is no race condition.

Three runners were rejected. With only three nodes, one runner per node means
every node has a runner and Plex must share with one permanently.

The throughput cost is negligible. The candidate pool is ~247 titles (113 HDR10 +
123 AVC + 11 VC-1). At roughly 1–1.5 h per 4K title and ~20 min per 1080p title,
that is ~176 runner-hours:

| Runners | Full-catalog wall clock | Plex GPU contention |
|---|---|---|
| 3 | ~2.5 days | Permanent — Plex always co-resident |
| 2 | ~3.7 days | None — Plex's node is encode-free |

One extra day, once, on a job run once. After the initial pass this handles only
new acquisitions, a trickle a single runner absorbs.

### 5.2 Benchmark priority (this design)

The benchmark Job is assigned a dedicated PriorityClass with a **negative value**,
placing it below every workload at the default priority of 0. This requires no
change to any existing application.

Precise claim: negative priority guarantees the benchmark is preempted *by the
scheduler* whenever a higher-priority pod needs its resources. It does **not**
guarantee the benchmark is the first pod evicted under node resource pressure —
for ephemeral storage the kubelet ranks candidates by usage above request first,
and only then by priority
(https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/).
§9 states the mitigations and the narrowed guarantee.

### 5.3 Plex priority (deferred to FileFlows work)

A `plex-critical` PriorityClass, letting Plex preempt a Flow Runner when it must
relocate, is genuinely needed once FileFlows runs at full GPU allocation. It is
**not** needed for the benchmark, and adding a `priorityClassName` to a working
Plex Deployment is a production change that belongs in its own reviewed PR
alongside the FileFlows deployment. Plex currently has no `priorityClassName`,
and this design does not add one.

Preemption is safe in that future design because the encode design fails safe — a
preempted encode is a failed job with the original untouched behind a read-only
mount.

## 6. Storage and network contention

GPU contention is eliminated; NAS I/O contention is not, and is the likelier way
a stream degrades. Modeled sustained draw:

| Workload | NAS read draw |
|---|---|
| Plex direct play, UHD remux | ~8 MB/s |
| Plex transcode | ~10 MB/s sustained; brief 40–80 MB/s buffer-ahead burst |
| FileFlows **4K** encode | ~8–10 MB/s |
| FileFlows **1080p** encode | ~45 MB/s |

Counterintuitively the large 4K files are the gentle workload — QSV runs near 1×
realtime on 4K, so the encoder is GPU-bound and sips input. The small 1080p files
are demanding precisely because they encode at 8–15× realtime and become
I/O-bound.

Worst modeled case is two runners on 1080p (~90 MB/s) plus a Plex stream
(~8 MB/s) ≈ **100 MB/s aggregate**. The NUCs' `enp88s0` interfaces are 2.5 GbE
(~300 MB/s), so the network has ample headroom. Two open variables:

- **NAS uplink speed** — unknown. At 2.5 GbE this is a third of capacity; at
  1 GbE it is ~80% and Plex would likely stutter on seeks. Operator to confirm
  from the Unifi UI; recorded in `findings.md`.
- **Concurrent sequential streams on the array** — three sequential readers is a
  case HDD arrays handle well with readahead; this only bites if the array is
  degraded or rebuilding.

One genuine spike regardless: a finished encode copying back from node-local
scratch writes ~25 GB at line speed for several minutes.

**Every figure above is a model, not a measurement.** §8.6 defines the protocol
that replaces them. A processing window is built into the FileFlows design
regardless (§14) — it costs nothing on a job with days of slack, and can be
widened later on evidence.

## 7. Architecture

```text
kubernetes/apps/media/encode-benchmark/
├── ks.yaml                    # Flux Kustomization, suspend: true initially
├── app/
│   ├── kustomization.yaml     # configMapGenerator → benchmark-scripts (hashed)
│   ├── priorityclass.yaml     # negative-value class for benchmark Jobs
│   ├── samples.yaml           # pinned sample manifest (both panels)
│   └── scripts/
│       ├── census.sh          # metadata-only library inventory
│       ├── benchmark.sh       # orchestrate: clip → sweep → measure → CSV
│       ├── probe.sh           # ffprobe inventory incl. audio estimation
│       ├── runmeta.sh         # emit immutable run manifest
│       └── stills.sh          # matched-timestamp 1:1 PNG crops
├── templates/
│   └── job.yaml               # NOT in kustomization.yaml — rendered by the recipe
└── tests/
    ├── fixtures/              # synthetic tiny media + golden CSVs
    └── *.bats                 # harness unit tests (§12)
```

Flux manages only inert objects: a ConfigMap of scripts, a PriorityClass, and the
sample manifest. No Deployment, no PVC, nothing that runs on its own. Jobs are
created on demand by recipes, keeping Flux out of the business of managing
immutable Job specs. The template lives in `templates/`, a sibling directory
Kustomize never reads, so Flux cannot apply it.

### 7.1 Runtime image — selection is an implementation task

**This design does not name an image.** An earlier draft asserted
`jellyfin/ffmpeg`, which does not exist —
`hub.docker.com/v2/repositories/jellyfin/ffmpeg/` returns 404. Jellyfin ships
`jellyfin-ffmpeg` as a Debian package bundled inside `jellyfin/jellyfin`, not as a
standalone ffmpeg image.

Implementation must select an image against these acceptance criteria, verify each
empirically inside a Job on a cluster node, and record the result:

| Requirement | Verification |
|---|---|
| Exists and is pinnable by digest | Registry manifest fetch |
| Intel QSV encode via VPL/oneVPL runtime | `ffmpeg -hide_banner -encoders \| grep hevc_qsv`, plus a real 5-second encode |
| `libvmaf` with the 4K model available | `ffmpeg -filters \| grep libvmaf` + a scored run |
| `libx265` | `ffmpeg -encoders \| grep libx265` |
| POSIX shell + `coreutils`, `awk`, `jq` | Direct invocation |
| `ffprobe` | Direct invocation |
| Runs as UID 568 non-root | Job admission |

`linuxserver/ffmpeg` is the leading candidate — it exists (5.4M pulls) and
documents Intel VAAPI/QSV support — but its `libvmaf`, `libx265`, and shell/utility
contents are **unverified** and must be checked before the digest is pinned. If no
single image satisfies all criteria, the fallback is a two-image split (encode
image + analysis image) rather than building a custom image.

The selected digest is recorded in `samples.yaml` and in every run manifest (§8.5).

### 7.2 Storage contract

The `media-data` PV is the **share root**, containing `downloads/`,
`media/movies/`, and `media/tv/`. Mounting it unqualified would expose all three
and contradict the TV exclusion in §2. Every mount is therefore `subPath`-scoped:

| Mount path | Source | Mode | Contents |
|---|---|---|---|
| `/media` | `media-data`, `subPath: media/movies` | **read-only** | The only media visible to any Job |
| `/out` | `media-data`, `subPath: benchmark` | read-write | Run-scoped results (§8.5) |
| `/scratch` | `emptyDir` with `sizeLimit` | read-write | Encode workspace (benchmark Job only) |

Consequences, which all scripts must honor:

- `media/tv` and `downloads/` are **not mounted** and cannot be traversed. TV
  exclusion is enforced by the mount, not by script logic.
- The census walks `/media`, not `/data/media/movies`. No script references a
  `/data/...` path; that prefix belongs to other applications' mount conventions
  and does not exist in these pods.
- **The census Job mounts both `/media` (ro) and `/out` (rw)** — it must persist
  `census.csv`. It does not mount `/scratch` and requests no GPU.

Hardlink detection needs only `st_nlink` from `stat`, which is available without
mounting `downloads/`.

### 7.3 Job pod shape

| Aspect | Choice | Rationale |
|---|---|---|
| Image | Selected per §7.1, pinned by digest | Capability-verified, immutable |
| GPU | `gpu.intel.com/i915: 1`, request == limit (benchmark only) | Extended resources require equality |
| Node | Anti-affinity against the Plex pod; node name recorded per run | A `nodeSelector` pin would hang `Pending` if Plex held that node |
| Scratch placement | `ephemeral-storage` **request** sized to the full scratch budget | Bounds the Job against node *allocatable* ephemeral storage minus other pods' requests. It does **not** attest current free bytes, so it is not by itself a placement guarantee — see the open item below |
| Sources | `/media`, `subPath: media/movies`, `readOnly: true` | Structurally incapable of damaging the library; TV invisible |
| Outputs | `/out`, `subPath: benchmark` | RW blast radius confined outside `media/` |
| Security | `runAsUser: 568`, non-root, `drop: ["ALL"]` | Matches the SMB mount's uid/gid |
| Priority | Negative-value PriorityClass (§5.2) | Yields to production; adds nothing to Plex |
| Retries | `restartPolicy: Never`, `backoffLimit: 0` | A failed benchmark must not silently re-run |
| Bound | `activeDeadlineSeconds` | Caps a runaway encode |

### 7.4 Rollout lifecycle and recipes

Per AGENTS.md, the app begins suspended and is rolled out through a guarded
bootstrap recipe, after which the unsuspended state is persisted in git — matching
`lidarr/ks.yaml:20`.

`ks.yaml` ships with `suspend: true`. Note this app contains only inert objects, so
suspension guards review discipline rather than preventing a workload from
starting; the meaningful safety gates are the per-Job confirmations below. The
convention is followed regardless — it is unambiguous and costs one field.

**`.just/bootstrap.just`:**

| Recipe | Guard |
|---|---|
| `bootstrap encode-benchmark` | `ENCODE_BENCHMARK_BOOTSTRAP_CONFIRM`, plus `require_deployed_source` against `origin/main` |

**`kubernetes/mod.just`:**

| Recipe | Kind | Guard |
|---|---|---|
| `encode-benchmark-validate` | Cluster-independent, runs in `just ci` | None — read-only source validation |
| `encode-benchmark-preflight` | Read-only cluster check | None |
| `encode-benchmark-census` | Mutating (creates a Job) | `ENCODE_BENCHMARK_CENSUS_CONFIRM` + `require_deployed_source` |
| `encode-benchmark-run` | Mutating (creates a Job) | `ENCODE_BENCHMARK_RUN_CONFIRM` + `require_deployed_source` |
| `encode-benchmark-verify` | Read-only, operator-only | None |
| `encode-benchmark-results` | Read-only | None |
| `encode-benchmark-clean` | **Destructive** — deletes run outputs | `ENCODE_BENCHMARK_CLEAN_CONFIRM='delete:encode-benchmark:<run-id>'`, run-id scoped so it cannot wipe all runs by accident |

`encode-benchmark-validate` is the only one added to `just ci`; per AGENTS.md all
`*-verify`, `*-status`, and `*-preflight` recipes stay operator-only.

## 8. Data flow

### 8.1 Stage 0 — Census (read-only, zero risk)

A Job walks `/media` and `ffprobe`s every file. No GPU, no scratch. Safe to run
while streaming.

**Metadata-only, by design.** `ffprobe` runs with `-show_streams -show_format` and
**without** `-count_packets` or `-show_packets`. Packet-level counting requires
reading every byte — roughly 9 TiB of SMB traffic and many hours. Header-and-index
reads cost a few MB per file, so the full census is on the order of **1–2 GB and
minutes**, not hours.

Consequence for audio inventory: per-track *exact* byte counts are unavailable at
this tier. The census records `bit_rate × duration` as an **estimate**, flagged as
such in a `audio_bytes_method` column (`reported` | `estimated` | `unknown`).
Variable-bitrate lossless formats — TrueHD in particular — frequently report no
`bit_rate` and land in `unknown`. Exact measurement runs only on the stratified
savings panel (§8.4), where the files are being fully read anyway.

One pass answers four questions:

- **Cohort counts** — reconciles the plan's 137/113/123/11 against reality. This
  *is* plan §16 Phase 1 dry-run classification, for the cost of a metadata pass
  instead of a full FileFlows deployment.
- **Sample frame** — the population both panels sample from.
- **Audio inventory** — per-track codec, channels, language, and estimated bytes.
  Recon for the deferred audio project.
- **Lifecycle classification** — `st_nlink` plus the qbit_manage state model from
  §3.1, yielding one of the **four** states in that table: `active`,
  `private-permanent`, `public-awaiting-cleanup`, or `unlinked`. The last covers
  both never-torrented and already-cleaned files, which are indistinguishable:
  once cleanup removes the download-side name the torrent is gone from
  qBittorrent, and no durable history remains to separate them. They are merged
  deliberately — both realize full savings immediately, so no decision in this
  design depends on telling them apart.

Output: `census.csv`, one row per file.

### 8.2 Stage 1 — Two sampling panels

An earlier draft used one 6-title sample for both quality and savings. Stress
clips are the right instrument for **rejecting** bad quality and the wrong one for
**estimating** catalog savings, because they are deliberately unrepresentative.
The panels are therefore separate, drawn from `census.csv`, and pinned in
`samples.yaml`.

**Quality panel — worst case, 7 titles.** Purpose: reject settings that fail on
the hardest material. Deliberately biased toward difficulty.

| # | Cohort | Role |
|---|---|---|
| 1 | 1080p VC-1 | Smallest cohort, oldest codec |
| 2 | 1080p AVC ≥30 Mb/s, clean | Best-case AVC |
| 3 | 1080p AVC ≥30 Mb/s, grain-heavy | Worst-case AVC |
| 4 | 4K HDR10, clean modern digital | Best-case UHD |
| 5 | 4K HDR10, grain-heavy film | **Decisive sample** — where QSV grain smoothing and VMAF's blind spot coincide |
| 6 | 4K HDR10, dark / high-motion | Banding and blocking stress |
| 7 | Dolby Vision Profile 7 | **Detection only, never encoded** — proves the skip gate fires |

**Savings panel — representative, ~24 titles.** Purpose: estimate catalog-wide
reduction. Stratified random sample, ~8 per major cohort, drawn across bitrate
bands so each cohort's estimate spans its real distribution rather than its
extremes. Selection is seeded and the seed recorded, so the draw is reproducible.

At ~1.2 h per 4K title this is roughly **20–25 runner-hours** — two overnight runs.
Reported per-cohort savings carry a median and an interquartile range; a
single-point catalog estimate without a stated range is not an acceptable output.

### 8.3 Stage 2 — Clip extraction (quality panel only)

Three ~90-second clips per title: a detail/grain scene, a dark gradient scene, a
high-motion scene. Two rules:

- **Extract with `-c copy`, never re-encoding.** Otherwise the benchmark measures
  an encode of an encode and every number is contaminated. Cost: cuts snap to
  keyframes, so timestamps drift a second or two. Acceptable.
- **Choose hard scenes deliberately.** An average scene flatters any encoder.

Clip timestamps are pinned in `samples.yaml` so reruns are identical.

### 8.4 Stage 3 — Sweeps

**QSV sweep (quality panel).** `hevc_qsv` swept across `-global_quality`
20/22/24/26/28 at a slow preset with `-extbrc` and lookahead.

Naming precision: `-global_quality` combined with `-look_ahead 1` selects
**LA-ICQ**, not ICQ, and the runtime may silently fall back to a different rate
control mode depending on driver and platform support
(https://ffmpeg.org/ffmpeg-codecs.html#QSV-encoders). The harness therefore
**records the mode the runtime actually selected** from verbose encoder
initialization output (§8.5) rather than assuming the requested one. A run whose
selected mode differs from the requested mode is flagged in the CSV, not silently
averaged into results.

6 encoded titles (title 7 is detection-only) × 3 clips × 5 values = 90 clip
encodes ≈ **2–3 hours**.

**x265 reference sweep.** An earlier draft used a single CRF point, which cannot
support a quality-matched comparison — the two encoders sit at different points on
their rate-quality curves. Instead: x265 `preset slow` starting at **CRF
18/20/22/24** on the grain-heavy 4K and grain-heavy AVC clips only. This yields a
rate-quality curve for comparing QSV and x265 **at matched VMAF**, which is the
only comparison that means anything.

Comparison is by **interpolation only, never extrapolation**. The starting CRF
points are not guaranteed to bracket the QSV operating point's VMAF, so the sweep
**extends beyond them — lower or higher CRF as needed — until the QSV point lies
inside the x265 range.** If bracketing cannot be achieved, §11.3 returns **no
verdict** for that cohort and the unbracketed result is reported as such; a
verdict is never produced by extrapolating past the measured range.

x265 is a yardstick, not a production candidate.

**Savings panel encodes.** Full-file, at the single winning QSV setting per cohort
chosen from the quality panel. Only full encodes give trustworthy size figures.

### 8.5 Run scoping and the run manifest

Results are written to run-scoped directories, never a shared flat file:

```text
/out/runs/<run-id>/
├── manifest.json     # immutable; written first, never modified
├── results.csv
├── stills/
├── logs/
└── encodes/          # finalist full-title outputs ONLY
```

**What persists.** Clip-sweep outputs and savings-panel full encodes are measured
in `/scratch` and **discarded there**; only their measurements reach
`results.csv`. Just the finalist full encodes needed for §8.7's Plex review are
copied to `encodes/`. Persisting everything would put ~600 GB on the share for
the savings panel alone, contradicting §9.1's "tens of GB" — that figure is what
fixes this. `encode-benchmark-clean` therefore deletes a run tree whose bulk is
finalist encodes.

`<run-id>` is a UTC timestamp plus a short hash of the manifest's identity fields.

`manifest.json` is written **before** the first encode and captures everything that
could change a result:

- Image digest
- SHA-256 of every script and of `samples.yaml`
- Full encoder command line per variant
- Source file paths, sizes, and content hashes
- Node name, kernel version, i915/VPL driver and runtime versions
- VMAF model name and version
- Sampling seed for the savings panel

**Resume is scoped to a single run-id, supplied explicitly.** Because `<run-id>`
embeds a fresh UTC timestamp, a bare invocation can never match a prior run — so
resume is **operator-directed, not discovered**: `encode-benchmark-run` takes an
optional run-id, and omitting it always starts a new run. This matches
`encode-benchmark-clean`, which already takes a run-id (§7.4); the run-id is an
operator-held handle throughout.

Given a run-id, the run resumes **only** when the recomputed manifest identity
matches that run's stored one exactly; any divergence aborts with a diff rather
than resuming or silently starting elsewhere. This closes the failure mode where
a changed script, image, or VMAF model reuses stale CSV rows. Cross-run
comparison is an explicit analysis step over multiple manifests, never an
implicit merge.

### 8.6 Stage 4 — Plex contention protocol

The measurement needs to be reproducible, so it is fully specified rather than
described as "run an encode while streaming."

- **Client:** one designated physical playback device, recorded by name in the
  manifest. Not a browser, not a variable device.
- **Content:** a fixed UHD HDR10 remux from the quality panel, played from a fixed
  start timestamp.
- **Baseline:** three 15-minute playback runs with no encoding active, **each
  executing the same seek sequence as case (d) — one seek every 2 minutes.**
  Records every metric below, including seek-to-resume latency; a baseline that
  performs no seeks yields no comparator for case (d)'s threshold. Any test run
  is compared against this baseline, not against intuition.
- **Cases:** (a) direct play + 4K encode; (b) direct play + two concurrent 1080p
  encodes — the modeled worst case from §6; (c) forced transcode + two concurrent
  1080p encodes; (d) case (b) with a seek every 2 minutes.
- **Metrics per run:** playback start latency; count of buffering events from the
  Plex session API; total buffering duration; seek-to-resume latency; NAS
  throughput sampled at 5-second intervals; encode wall time (to detect the
  encoder being starved rather than Plex).
- **Pass threshold:** zero buffering events in cases (a)–(c); playback start
  latency within 2 s of baseline; no seek-to-resume exceeding baseline by more
  than 3 s in case (d).

A failure here does not block the project — it sets the width of the FileFlows
processing window, and that is the number recorded in `findings.md`.

### 8.7 Stage 5 — Review

Two paths, both built into the harness:

- **1:1 PNG crops** at matched timestamps, source versus each variant. Grain
  smoothing is instantly visible on a still and this triages the sweep fast.
- **Temp Plex library** for the finalists, catching motion artifacts and
  confirming Direct Play and HDR handling on the real client.

Operator visual sign-off is recorded as an explicit pass/fail per variant in
`findings.md`, alongside the VMAF score, so agreement and disagreement between the
two are both visible.

## 9. Safety and failure handling

The benchmark should be **incapable** of harming the library, and should minimize
— not eliminate — its ability to disturb a node.

Structural guarantees, holding even if every script has bugs:

| Guarantee | Mechanism | Strength |
|---|---|---|
| Originals cannot be modified | `readOnly: true` on `/media`, enforced by the kubelet | Absolute |
| TV is invisible | `subPath: media/movies` — TV is not in the mount | Absolute |
| Writes confined to the `benchmark/` share subtree | Separate RW mount, `subPath: benchmark` | Absolute |
| Plex/Radarr never see outputs | Benchmark dir lives outside `media/` | Absolute |
| Never preempts production | Negative-value PriorityClass | Absolute (scheduler) |
| No silent retry | `restartPolicy: Never`, `backoffLimit: 0` | Absolute |
| No runaway | `activeDeadlineSeconds` | Absolute |
| Bounded node disk impact | See below | **Best-effort, not absolute** |

**The node-pressure guarantee is narrowed.** An earlier draft claimed the node "cannot
be destabilized" and that the benchmark is "evicted first, never Plex." That
overstates it. The kubelet ranks ephemeral-storage eviction candidates by usage
above request *before* priority, so a pod within its request is not automatically
safe from eviction, and priority is only one input. Mitigations, stated as
mitigations:

- `emptyDir.sizeLimit` set to the scratch budget — this *does* deterministically
  evict the offending pod when it exceeds its own limit.
- `ephemeral-storage` **request** equal to the full scratch budget, keeping the
  pod within its request during normal operation. Note this bounds the Job
  against node *allocatable* storage minus other pods' requests; it does not
  attest currently free bytes, so it does not by itself guarantee the Job lands
  on a node with real headroom.
- `ephemeral-storage` limit set marginally above the request.
- Preflight refuses to launch unless free NVMe exceeds the budget by a stated
  margin. **Open:** the Job has no binding to the node preflight measured, so a
  preflight pass on one node does not constrain placement. Resolving this needs
  one of: preflight requiring *every* eligible node to pass; the recipe selecting
  a verified node at dispatch and pinning to it; or accepting the gap and
  treating a scratch-exhaustion eviction as an ordinary failed run. Not chosen
  here — see the response file.

Together these make node-pressure eviction unlikely and make the benchmark the
most likely victim if it occurs. They do not make it impossible.

**Fail-closed preflight.** `encode-benchmark-preflight` aborts before any frame is
encoded unless all hold: i915 advertised on a non-Plex node; free NVMe above
budget-plus-margin on the node or nodes the open item above resolves to;
`/media` readable; `/out` writable; every pinned
sample present at its recorded size and hash; the image digest resolvable; ffmpeg
reporting QSV, `libvmaf`, and `libx265`.

The NVMe check resolves an open unknown — `docs/nuc-cluster.md` records the
install device but not its capacity.

**QSV must be proven, not inferred from output.** Per plan §6, silent CPU fallback
is the dangerous failure: it produces plausible output at 20× the time and quietly
invalidates every speed measurement. An earlier draft proposed probing the finished
file to confirm the encoder — that does not work, since container encoder tags
reflect the requested codec name and cannot distinguish a hardware path from a
software fallback inside the QSV runtime. Instead:

- `-init_hw_device qsv` failure aborts the run.
- ffmpeg runs at `-v verbose` and the encoder initialization block — selected rate
  control mode, driver version, adapter — is captured to `logs/` and parsed into
  the CSV.
- GPU telemetry is sampled during each encode; a QSV encode showing no engine
  utilization is flagged as suspect.
- Encode wall time is compared against the cohort's expected range; an outlier is
  flagged rather than recorded as a valid result.

**Output validation.** Every output runs the plan §13 chain — decode, duration
tolerance, resolution, frame rate, codec, bit depth, HDR metadata, audio /
subtitle / chapter counts. Failures are recorded as rows, not fatal errors: a
variant that drops HDR metadata is a *result*, and precisely what the benchmark
hunts for.

**Notification.** `ntfy/app/server.yml:14` sets `auth-default-access: deny-all`
with `require-login: true`, so anonymous publishing is unavailable. This design
does **not** create a producer identity. Completion and failure notification uses
the existing Alertmanager → `alertmanager-ntfy` route; if a dedicated producer
identity is later preferred, it is an operator-run `*-secrets` task outside this
scope. Absence of notification never blocks a run — results are always on disk.

### 9.1 Reversibility

| Artifact | Reversal | Residue |
|---|---|---|
| Flux Kustomization, ConfigMap, PriorityClass | `git revert`; Flux prunes | None |
| Benchmark Job | `ttlSecondsAfterFinished` auto-deletes | None |
| `/scratch` emptyDir | Dies with the pod | None |
| Image layers on the node | kubelet GC | Self-clearing |
| `benchmark/runs/<run-id>/` on the share | `encode-benchmark-clean` (run-id scoped, confirmed) | Tens of GB until cleaned |
| Temp Plex library | Remove library in Plex UI | Bounded thumbnail/metadata bloat in the Plex config PVC |
| **Movie originals** | **Never modified** | None — read-only mount |
| **Plex configuration** | Never modified | None — no `priorityClassName` added |

Radarr and Plex are never notified of anything, and the `benchmark/` subtree sits
outside `media/`, so neither indexes it.

## 10. Known risks

**HDR10 metadata passthrough is the most likely thing to break.** ffmpeg does not
reliably carry `master-display` and `max-cll` static metadata through `hevc_qsv`;
it frequently must be extracted and re-injected explicitly, alongside setting
`bt2020` / `smpte2084` / `bt2020nc` by hand. Plan §4 makes HDR preservation a hard
blocker, so this is better discovered on a 90-second clip in week one than on
title 40.

**Grain may simply cost the savings.** HEVC has no film-grain synthesis (that is
AV1), so a grainy 4K source may need a `global_quality` low enough that output
lands above the savings gate and gets discarded. (The savings gate is plan §14's
requirement that output be no larger than 85% of source — a 15% minimum
reduction. This design adopts it unchanged; `findings.md` may recommend revising
it on evidence.) That is a legitimate outcome, not a failure.

**VMAF is an SDR-trained metric.** Applying it to HDR10 is a known weak spot,
which is why the quality gate is metric-screens / eyes-approve rather than
metric-approves. On UHD samples VMAF ranks variants; §11 states where an absolute
VMAF threshold is and is not load-bearing.

**Estimates in §3.2, §5.1, and §6 are models, not measurements.** They size the
work and are explicitly superseded by `findings.md`.

## 11. Decision gate

Thresholds are quantitative. Where operator judgment is required it is a recorded
binary, not an adjective.

### 11.1 Per-variant quality gate (quality panel)

A QSV setting is **eligible** for a cohort only if **every individual clip** of
that cohort's panel titles independently meets every threshold below. Scores are
**not** pooled across clips: pooling would let a strong clip offset a weak one,
which defeats §8.3's reason for choosing hard scenes deliberately — a setting
that fails the worst 90 seconds has not held.

| Criterion | Threshold |
|---|---|
| VMAF harmonic mean vs source | ≥ 95 |
| VMAF 1% low | ≥ 90 |
| Validation chain (§9) | Zero failures |
| Rate control mode | Matches requested LA-ICQ; no silent fallback |
| Operator visual sign-off | PASS, recorded per variant |

VMAF thresholds are **screening** criteria. A variant that fails them is rejected
outright; a variant that passes is a *candidate* only. Operator sign-off is
required for eligibility and cannot be substituted by score — this is the SDR-metric
caveat made operational.

The eligible setting with the highest size reduction becomes the cohort's chosen
setting.

### 11.2 Per-cohort savings gate (savings panel)

Evaluated at the chosen setting, on the stratified sample, reported as median with
interquartile range:

| Median reduction | Verdict |
|---|---|
| ≥ 25% | **GO** for that cohort |
| 15–25% | **MARGINAL** — operator decision, recorded with the encode-hours cost |
| < 15% | **NO-GO** for that cohort |

### 11.3 x265 comparison gate

Compared at **matched VMAF** by interpolation across the CRF sweep (§8.4):

| QSV bitrate premium at equal VMAF | Verdict |
|---|---|
| ≤ 15% | QSV is the right engine |
| 15–30% | QSV acceptable; note the cost in `findings.md` |
| > 30% | QSV is materially worse. Escalate: CPU x265 at ~20× the wall clock, or abandon. |
| QSV point not bracketed by the x265 sweep | **No verdict.** Reported as unbracketed; never resolved by extrapolation (§8.4). |

### 11.4 Cohort outcomes

| Result | Implication |
|---|---|
| 1080p VC-1 / AVC GO | Build FileFlows. ~2.9 TiB addressable, lowest risk, natural first phase. |
| 4K HDR10 clean GO, grain NO-GO | Build it; grain cohort out of scope. Addressable pool shrinks by a measured amount. |
| All 4K fails on HDR metadata | Solvable-looking, but blocks 6 TiB. Fix and re-run before committing. |
| All 4K NO-GO on quality or savings | UHD is out. A 1080p-only project worth ~1.2 TiB — possibly not worth the GitOps build. |
| §11.3 exceeds 30% everywhere | QSV is the wrong engine. |

### 11.5 A simplification the benchmark enables

The plan sets bitrate thresholds — AVC ≥30 Mb/s, HDR10 ≥50 Mb/s — as policy. Those
are proxies for the real question, "will this file actually compress?" The savings
gate answers that **directly**, per file, from measured output. A quality-targeted
encode plus a savings gate is self-selecting: files that will not compress have
their output discarded automatically, original untouched.

Bitrate thresholds are therefore not a safety mechanism and should not be policy.
They should survive only as a **scheduling** optimization — avoid burning GPU
hours on files the census predicts will fail the gate — with cutoffs derived from
the savings panel's measured relationship between source bitrate and achieved
reduction.

## 12. Harness testing

The harness is shell scripts making irreversible-looking decisions about a media
library, so it is tested like code. All of the following run in
`encode-benchmark-validate`, wired into `just ci` and therefore into the required
PR check. All are cluster-independent and secret-free.

| Test | Scope |
|---|---|
| `shellcheck` + `shfmt` | Every script under `app/scripts/` |
| Classification fixtures | Synthetic tiny media files with known codec, resolution, bit depth, HDR, DV, and link-count properties; asserts each lands in the expected cohort and lifecycle state |
| Resume fixtures | Asserts a manifest-identity change starts a new run-id rather than resuming; asserts an identical manifest resumes and skips completed rows |
| CSV schema | Column set, types, and required fields for `census.csv` and `results.csv`; golden-file comparison |
| Confirmation guards | Each mutating recipe refuses to proceed with absent, empty, or wrong `*_CONFIRM`; `clean` refuses a mismatched run-id |
| Kustomize render | `kustomize build` succeeds; `kubeconform` passes; asserts `templates/job.yaml` is **not** in the rendered output |
| Mount contract | Asserts the rendered Job template mounts `media/movies` read-only and never mounts the share root, `downloads/`, or `media/tv` |

The mount-contract and confirmation-guard tests are the load-bearing ones: they
encode the two safety properties this design relies on, so a future edit that
breaks either fails CI rather than a movie.

## 13. Deliverables

1. `census.csv` — full library inventory, cohort counts reconciled against the
   plan, lifecycle state per file, audio inventory with method flags.
2. `runs/<run-id>/manifest.json` — immutable run identity.
3. `runs/<run-id>/results.csv` — every encode: size and bitrate in/out, reduction
   %, wall time, encode fps, selected rate control mode, VMAF (harmonic mean +
   1% low), SSIM, GPU utilization, and validation of codec, resolution, frame
   rate, bit depth, HDR metadata, and audio / subtitle / chapter counts.
4. `runs/<run-id>/stills/` — matched-frame crops for visual review.
5. `runs/<run-id>/encodes/` — finalist full-title outputs only, for §8.7's Plex
   review. Clip-sweep and savings-panel outputs are measured in scratch and
   discarded (§8.5).
6. `audio-inventory.csv` — recon for the deferred audio project.
7. **`findings.md`** — recommended QSV settings per cohort, measured savings by
   cohort with median and IQR, the x265 matched-VMAF comparison, the Plex
   contention results against §8.6 thresholds, the NAS uplink figure, a revised
   TiB estimate superseding §3.2, and a go/no-go per §11.
8. GitOps sources under `kubernetes/apps/media/encode-benchmark/`, recipes in
   `.just/bootstrap.just` and `kubernetes/mod.just`, and tests in `just ci`.

## 14. Success criteria

The benchmark succeeds when it answers, against §11's thresholds:

1. Does QSV HEVC hold up on the worst available material?
2. Does HDR10 metadata survive intact?
3. What setting, per cohort?
4. How much space actually comes back, with a stated range?
5. How much does encoding disturb a concurrent Plex stream, per §8.6?
6. Is Dolby Vision reliably detected and skipped?
7. Are the plan's cohort counts accurate?
8. Is QSV the right engine, or does x265 justify its wall-clock cost?

Success explicitly **includes a no-go finding**. If the answer is "QSV smooths
grain unacceptably and saves only 12%," the benchmark succeeded — it prevented
building a multi-node encoding platform for a 12% return.

## 15. Follow-on work (not authorized by this design)

- FileFlows deployment, scoped by `findings.md`, with two Flow Runners, hard Plex
  anti-affinity, a processing window sized by §8.6, and the `plex-critical` /
  `fileflows-runner` PriorityClasses from §5.3.
- Audio track pruning, informed by `audio-inventory.csv`.
- Dolby Vision evaluation (plan §16 Phase 8).
- TV library audit (plan §17).
- An ntfy producer identity, if Alertmanager routing proves insufficient.
