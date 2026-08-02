# Movie encoding benchmark — design

Status: approved design, pending implementation plan.
Date: 2026-08-01.
Branch: `fileflows-movie-encoding-strategy`.

## 1. Purpose

Determine, cheaply and reversibly, whether Intel Quick Sync HEVC encoding on the
NUC cluster can normalize and meaningfully shrink the movie catalog — **before**
committing to build the FileFlows platform described in
`plans/fileflows-movie-evaluation-implementation-plan.md`.

That plan is deploy-first: steps 1–11 build a three-node FileFlows application,
storage, probes, and classification flows before a single frame is encoded. The
risk it leaves unaddressed is the one most likely to sink the project — whether
QSV HEVC preserves acceptable quality, particularly on grain-heavy 4K HDR10
material, at a worthwhile size reduction.

This design inverts that order. A throwaway benchmark harness answers the
quality-and-savings question first. FileFlows gets built only if the answer
justifies it, and gets scoped by what the measurements show.

The benchmark's deliverable is a **decision**, not a dataset.

## 2. Scope

In scope:

- A read-only library census Job (`ffprobe` inventory of `/data/media/movies`).
- A GPU-backed encode benchmark Job running a QSV settings sweep on clips.
- Full-file confirmation encodes for the finalist settings.
- Guarded `just` recipes: preflight, run, results, clean.
- A `findings.md` deliverable carrying an explicit go/no-go with per-cohort scope.
- Measurement of encoding's effect on concurrent Plex playback.

Out of scope (deliberately deferred):

- Deploying FileFlows itself. That is gated on this benchmark's outcome.
- TV. Per plan §17, `/data/media/tv` is untouched and unmounted.
- Dolby Vision encoding. DV appears only as a detection-only sample.
- Audio track pruning, subtitle cleanup, and metadata hygiene. The census
  gathers audio inventory as reconnaissance; no audio is modified.
- Any change to `intel-gpu-plugin`. See §5 — the two-runner topology removes the
  need for one.

## 3. Context and findings

### 3.1 The library is largely self-ripped

`kubernetes/apps/media/storage/app/persistentvolume.yaml` mounts one SMB share
from the UNAS Pro with server inodes preserved. `radarr/app/values.yaml` confirms
imports **hardlink** `/data/downloads` into `/data/media/movies` rather than
copying, and `qbit-manage/app/config.yml` documents the proof (inodes 934/952,
links=2).

For a torrent-sourced file this matters: re-encoding breaks the hardlink, leaving
the full-size download inode *plus* a new encode. Since
`qbit-manage/app/config.yml` sets `share_limit_action: Stop` with
`cleanup: false`, torrents are paused but never deleted — so net storage on those
titles goes **up**, not down.

Operator-supplied counts settle the concern: 345 of 388 MKV files (88.9%) are
MakeMKV rips. The addressable pool is nearly the whole catalog, and the plan §21
seeding gate is a cheap safety check rather than a project-killer.

Caveat: the MakeMKV tag comes from muxing-app metadata and identifies who *ripped*
a file, not whether this copy is a torrent payload — a scene release of someone
else's MakeMKV rip carries the same tag. Link count (`st_nlink > 1`) is the
authoritative test. The census performs it.

### 3.2 Sizing the prize

From the plan's cohort table, Dolby Vision removes 137 titles / 7.7 TiB from
scope, leaving roughly 9 TiB addressable (6.04 TiB HDR10 + 2.91 TiB AVC). At a
plausible 35–45% reduction that is **~3–4 TiB recovered**.

This is an estimate built on the plan's prose table, which is not itself in the
repository. The census reconciles it against reality, and `findings.md` replaces
it with a measured figure.

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
a Flux-managed ConfigMap** holding the scripts. `jellyfin/ffmpeg` ships QSV/VAAPI
and `libvmaf` prebuilt, so no build step is needed. A custom in-repo image was
rejected: a container publish workflow, registry auth, and a tag-bump loop per
script edit is disproportionate infrastructure for tooling intended to be deleted
in weeks.

## 5. GPU allocation and Plex precedence

**Requirement:** Plex must never compete with FileFlows for a GPU while streaming.

**Resolution: two Flow Runners, not three.** With two runners the arithmetic fits
`shared-dev-num=1` exactly — 3 slots, Plex takes 1, runners take 2 — and hard
anti-affinity against Plex keeps Plex's node encode-free. No change to
`intel-gpu-plugin` is required. GPU contention becomes structurally impossible
rather than merely discouraged: the kubelet refuses to admit a second
GPU-requesting pod on Plex's node. That is admission control, not a scheduling
preference, so there is no race condition.

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

**PriorityClass as backstop.** `plex-critical` (high) and `fileflows-runner`
(low). At full allocation there is no spare slot, so if Plex must relocate the
scheduler preempts a runner to seat Plex, and the runner waits for capacity. This
is safe *because* the encode design fails safe — a preempted encode is a failed
job with the original untouched behind a read-only mount. Preemption would not be
an acceptable tool otherwise.

The benchmark Job itself carries a **low** priority — it is always the first
casualty of contention, never the cause.

## 6. Storage and network contention

GPU contention is eliminated; NAS I/O contention is not, and is the likelier way
a stream degrades. Estimated sustained draw:

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

Worst realistic case is two runners on 1080p (~90 MB/s) plus a Plex stream
(~8 MB/s) ≈ **100 MB/s aggregate**. The NUCs' `enp88s0` interfaces are 2.5 GbE
(~300 MB/s), so the network has ample headroom. Two open variables:

- **NAS uplink speed** — unknown. At 2.5 GbE this is a third of capacity; at
  1 GbE it is ~80% and Plex would likely stutter on seeks. Worth confirming from
  the Unifi UI.
- **Concurrent sequential streams on the array** — three sequential readers is a
  case HDD arrays handle well with readahead; this only bites if the array is
  degraded or rebuilding.

One genuine spike regardless: a finished encode copying back from node-local
scratch writes ~25 GB at line speed for several minutes. A steady stream rides
through it on Plex's buffer; a seek during that window may re-buffer briefly.

**Decisions:** the benchmark measures this directly via an interleaved test
(encode while streaming a UHD remux, record whether playback buffers), and a
processing window is built into the FileFlows design regardless. The window costs
nothing on a job with days of slack. If the interleaved test shows no impact it
can be widened later, on evidence.

## 7. Architecture

```text
kubernetes/apps/media/encode-benchmark/
├── ks.yaml                    # Flux Kustomization (media namespace)
├── app/
│   ├── kustomization.yaml     # configMapGenerator → benchmark-scripts
│   └── scripts/
│       ├── census.sh          # read-only library inventory
│       ├── benchmark.sh       # orchestrate: clip → sweep → measure → CSV
│       ├── probe.sh           # ffprobe inventory incl. per-track audio bytes
│       └── stills.sh          # matched-timestamp 1:1 PNG crops
└── templates/
    └── job.yaml               # NOT in kustomization.yaml — rendered by the recipe
```

Flux manages only inert objects: a ConfigMap of scripts. No Deployment, no PVC,
nothing that runs on its own. Jobs are created on demand by the recipe, keeping
Flux out of the business of managing immutable Job specs. The template lives in
`templates/`, a sibling directory Kustomize never reads, so Flux cannot apply it.

### Job pod shape

| Aspect | Choice | Rationale |
|---|---|---|
| Image | `jellyfin/ffmpeg`, pinned by digest | QSV/VAAPI + `libvmaf` prebuilt |
| GPU | `gpu.intel.com/i915: 1`, request == limit | Extended resources require equality |
| Node | Anti-affinity against the Plex pod; node name recorded per run | A `nodeSelector` pin would hang `Pending` if Plex held that node |
| Sources | `media-data` PVC at `/media`, `readOnly: true` | Structurally incapable of damaging the library |
| Outputs | `media-data` PVC at `/out`, `subPath: benchmark` | RW blast radius confined outside `media/` |
| Scratch | `emptyDir` at `/scratch` with `sizeLimit` | Encode locally; copy only kept artifacts to SMB |
| Security | `runAsUser: 568`, non-root, `drop: ["ALL"]` | Matches the SMB mount's uid/gid |
| Priority | Low PriorityClass | Yields to production, never preempts it |
| Retries | `restartPolicy: Never`, `backoffLimit: 0` | A failed benchmark must not silently re-run |
| Bound | `activeDeadlineSeconds` | Caps a runaway encode |

The census Job uses the same shape minus the GPU, scratch, and RW mount.

### Recipes

Added to `kubernetes/mod.just`, following the existing `<app>-validate` /
`<app>-verify` naming pattern:

- `encode-benchmark-preflight` — read-only. Gates the run (§9).
- `encode-benchmark-census` — cluster-mutating; requires `*_CONFIRM`.
- `encode-benchmark` — cluster-mutating; requires `*_CONFIRM`, and verifies the
  ConfigMap source matches `origin/main` per the AGENTS.md guarded-rollout rule.
- `encode-benchmark-results` — read-only. Prints the CSV.
- `encode-benchmark-clean` — removes `/data/benchmark`.

## 8. Data flow

### Stage 0 — Census (read-only, zero risk)

A probe-only Job walks `/data/media/movies` and `ffprobe`s every file. No GPU, no
scratch, no write access beyond the results CSV. Safe to run while streaming.

One pass answers four questions:

- **Cohort counts** — reconciles the plan's 137/113/123/11 against reality. This
  *is* plan §16 Phase 1 dry-run classification, for the cost of a read pass
  instead of a full FileFlows deployment.
- **Sample selection** — picks benchmark titles by measured properties.
- **Audio inventory** — per-track codec, channels, language, bytes. Recon for the
  deferred audio project.
- **Link-count census** — `st_nlink > 1` identifies torrent-hardlinked files, the
  authoritative form of the MakeMKV heuristic.

Output: `census.csv`, one row per file. Everything downstream keys off it.

### Stage 1 — Sample selection

Six encode samples plus one detection-only, chosen from the census. Paths and
sizes are pinned in git so re-runs use identical inputs.

| # | Cohort | Role |
|---|---|---|
| 1 | 1080p VC-1 | Smallest cohort, oldest codec — the easy win |
| 2 | 1080p AVC ≥30 Mb/s, clean | Best-case AVC |
| 3 | 1080p AVC ≥30 Mb/s, grain-heavy | Worst-case AVC |
| 4 | 4K HDR10, clean modern digital | Best-case UHD |
| 5 | 4K HDR10, grain-heavy film | **Decisive sample** — where QSV grain smoothing and VMAF's blind spot are most likely to coincide |
| 6 | 4K HDR10, dark / high-motion | Banding and blocking stress |
| 7 | Dolby Vision Profile 7 | **Detection only, never encoded** — proves the skip gate fires |

### Stage 2 — Clip extraction

Three ~90-second clips per title: a detail/grain scene, a dark gradient scene, a
high-motion scene. Two rules:

- **Extract with `-c copy`, never re-encoding.** Otherwise the benchmark measures
  an encode of an encode and every number is contaminated. Cost: cuts snap to
  keyframes, so timestamps drift a second or two. Acceptable.
- **Choose hard scenes deliberately.** An average scene flatters any encoder. If
  quality holds on the worst 90 seconds of a grainy film, it holds everywhere.

### Stage 3 — Settings sweep

`hevc_qsv` in ICQ mode — quality-targeted rather than fixed-bitrate, per plan
§11 — swept across `-global_quality` 20/22/24/26/28 at a slow preset, with
`-extbrc` and lookahead enabled. Being GPU-bound with days of slack, quality
beats speed everywhere.

6 titles × 3 clips × 5 quality values ≈ 90 clip encodes ≈ **2–3 hours**. Cheap
enough to rerun whenever a parameter changes.

**x265 reference:** one setting (`crf 20`, `preset slow`) on the grain-heavy 4K
clips only. Not a production candidate — the yardstick measuring what QSV costs.
If QSV lands within a couple of percent at 20× the speed, that settles it. If
x265 is dramatically better on grain, that fact is needed before building
anything.

### Stage 4 — Finalist confirmation

The 2–3 winning settings run as **full-file** encodes on 3–4 titles. Clips
establish quality; only full encodes give trustworthy size-reduction figures.
This stage also runs the interleaved Plex-contention test from §6.

### Stage 5 — Review

Two paths, both built into the harness:

- **1:1 PNG crops** at matched timestamps, source versus each variant. Grain
  smoothing is instantly visible on a still and this triages the sweep fast.
- **Temp Plex library** for the finalists, catching motion artifacts and
  confirming Direct Play and HDR handling on the real client.

## 9. Safety and failure handling

The benchmark should be **incapable** of harming production, not merely careful.

Structural guarantees, holding even if every script has bugs:

| Guarantee | Mechanism |
|---|---|
| Originals cannot be modified | `readOnly: true` on `/media`, enforced by the kubelet |
| Writes confined to `/data/benchmark` | Separate RW mount with `subPath: benchmark` |
| Plex/Radarr never see outputs | Benchmark dir lives outside `media/` |
| Node cannot be destabilized | `emptyDir.sizeLimit` + `ephemeral-storage` limits — the benchmark pod is evicted first, never Plex |
| Benchmark never preempts production | Low PriorityClass |
| No silent retry | `restartPolicy: Never`, `backoffLimit: 0` |
| No runaway | `activeDeadlineSeconds` |

**Fail-closed preflight.** `encode-benchmark-preflight` aborts before any frame is
encoded unless all hold: i915 advertised on a non-Plex node; free NVMe above
threshold; `/media` readable; `/data/benchmark` writable; every pinned sample
present at its recorded size; ffmpeg reports both QSV and `libvmaf` support.

The NVMe check resolves an open unknown — `docs/nuc-cluster.md` records the
install device but not its capacity, and a 4K benchmark needs ~40–100 GB of
scratch.

**QSV must be proven, never assumed.** Per plan §6, silent CPU fallback is the
dangerous failure: it produces plausible output at 20× the time and quietly
invalidates every speed measurement. `-init_hw_device qsv` failure aborts the run,
and each output is probed to confirm which encoder actually ran. A benchmark that
lies about its hardware is worse than no benchmark.

**Partial-run resilience.** `results.csv` is appended per encode, so a killed Job
retains completed work and re-runs skip finished rows. A multi-hour sweep
interrupted by a node reboot resumes rather than restarting.

**Output validation.** Every output runs the plan §13 chain — decode, duration
tolerance, resolution, frame rate, codec, bit depth, HDR metadata, audio /
subtitle / chapter counts. Failures are recorded as rows, not fatal errors: a
variant that drops HDR metadata is a *result*, and precisely what the benchmark
hunts for.

**Notification and cleanup.** Completion and failure route through the existing
ntfy stack. `encode-benchmark-clean` removes `/data/benchmark`.

### Reversibility

| Artifact | Reversal | Residue |
|---|---|---|
| Flux Kustomization + ConfigMap | `git revert`; Flux prunes | None |
| Benchmark Job | `ttlSecondsAfterFinished` auto-deletes | None |
| `/scratch` emptyDir | Dies with the pod | None |
| Image layers on the node | kubelet GC | ~400 MB, self-clearing |
| `/data/benchmark/` on the NAS | `encode-benchmark-clean` | Tens of GB until cleaned |
| Temp Plex library | Remove library in Plex UI | Bounded thumbnail/metadata bloat in the Plex config PVC |
| **Movie originals** | **Never modified** | None — read-only mount |

Radarr and Plex are never notified of anything, and `/data/benchmark` sits
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
it on evidence.) That is a legitimate outcome,
not a failure — it would mean the grain-heavy cohort is out of scope and the
addressable pool is smaller than §3.2 estimates.

**VMAF is an SDR-trained metric.** Applying it to HDR10 is a known weak spot,
which is why the quality gate is metric-screens / eyes-approve rather than
metric-approves. On UHD samples VMAF ranks variants; it never sets an absolute
quality bar.

**Estimates in §3.2, §5, and §6 are models, not measurements.** They exist to size
the work and are explicitly superseded by `findings.md`.

## 11. Decision gate

Each cohort passes or fails independently, and each outcome maps to a concrete
scope change:

| Cohort result | Implication |
|---|---|
| 1080p VC-1 / AVC pass | Build FileFlows. ~2.9 TiB addressable, lowest risk, natural first phase. |
| 4K HDR10 clean passes, grain fails | Build it; grain cohort out of scope. Addressable pool shrinks by a known amount. |
| All 4K fails on HDR metadata | Solvable-looking, but blocks 6 TiB. Fix and re-run before committing. |
| All 4K fails on quality | UHD is out. A 1080p-only project worth ~1.2 TiB — possibly not worth the GitOps build. |
| QSV badly trails x265 everywhere | QSV is the wrong engine. Accept far slower CPU encoding, or abandon. |

That last row is what this design exists to find cheaply, rather than after
deploying a multi-node application.

### A simplification the benchmark enables

The plan sets bitrate thresholds — AVC ≥30 Mb/s, HDR10 ≥50 Mb/s — as policy. Those
are proxies for the real question, "will this file actually compress?" The 15%
savings gate answers that **directly**, per file, from measured output. A
quality-targeted encode plus a savings gate is self-selecting: files that will not
compress have their output discarded automatically, original untouched.

Bitrate thresholds are therefore not a safety mechanism and should not be policy.
They should survive only as a **scheduling** optimization — avoid burning GPU
hours on files the census predicts will fail the gate — with cutoffs derived from
census data rather than round numbers. This removes a class of threshold-tuning
from the FileFlows build.

## 12. Deliverables

1. `census.csv` — full library inventory, cohort counts reconciled against the plan.
2. `results.csv` — every encode, every metric: size and bitrate in/out, reduction
   %, wall time, encode fps, VMAF (harmonic mean + 1% low), SSIM, and validation
   of codec, resolution, frame rate, bit depth, HDR metadata, and audio /
   subtitle / chapter counts.
3. `stills/` — matched-frame crops for visual review.
4. `audio-inventory.csv` — recon for the deferred audio project.
5. **`findings.md`** — the actual deliverable: recommended QSV settings per
   cohort, measured savings by cohort, a revised TiB estimate replacing §3.2's
   guess, the NAS-contention measurement, and a go/no-go with scope.
6. GitOps sources under `kubernetes/apps/media/encode-benchmark/` and recipes in
   `kubernetes/mod.just`.

## 13. Success criteria

The benchmark succeeds when it answers:

1. Does QSV HEVC hold up visually on the worst available material?
2. Does HDR10 metadata survive intact?
3. What settings, per cohort?
4. How much space actually comes back?
5. Does encoding disturb a concurrent Plex stream?
6. Is Dolby Vision reliably detected and skipped?
7. Are the plan's cohort counts accurate?

Success explicitly **includes a no-go finding**. If the answer is "QSV smooths
grain unacceptably and saves only 12%," the benchmark succeeded — it prevented
building a multi-node encoding platform for a 12% return.

## 14. Follow-on work (not authorized by this design)

- FileFlows deployment, scoped by `findings.md`, with two Flow Runners, hard Plex
  anti-affinity, PriorityClasses, and a processing window.
- Audio track pruning, informed by `audio-inventory.csv`.
- Dolby Vision evaluation (plan §16 Phase 8).
- TV library audit (plan §17).
