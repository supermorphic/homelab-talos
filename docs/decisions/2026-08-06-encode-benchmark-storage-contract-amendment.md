# Movie encoding benchmark storage contract — amendment

- **Status: Accepted.** Approved by the operator on 2026-08-06.
Amends [Movie encoding benchmark — design](2026-08-01-fileflows-movie-encoding.md).
Date: 2026-08-06.
Branch: `fileflows-movie-encoding-strategy`.

This document is **additive**. It supersedes exactly three numbers in the 2026-08-01
design — the scratch budget, the `ephemeral-storage` request/limit pair, and the
preflight free-space floor — together with the acceptance claim that those figures were
satisfiable. Everything else in that document, including the safety guarantees of §9 and
the read-only mount contract of §7.2, remains in force unchanged.

## 1. Why the original figures cannot hold

§9 recorded an explicit open unknown:

> The NVMe check resolves an open unknown — `docs/nuc-cluster.md` records the install
> device but not its capacity.

It has now been measured, and it resolved against the design. Each NUC carries a 1.0 TB
NVMe partitioned into two independent filesystems:

| Partition | Size | Contents |
| --- | --- | --- |
| `EPHEMERAL` (`nvme0n1p4` → `/var`) | **149 GiB** | container images, logs, etcd, **emptyDir scratch** |
| `u-longhorn` (`nvme0n1p5` → `/var/mnt/longhorn`) | 537 GB | Longhorn replicas only |

Kubernetes reports `ephemeral-storage` capacity of 149 GiB and **allocatable of
134.66 GiB** (`144600839543` bytes) on all three nodes.

Two consequences follow, and both were live defects rather than theoretical ones:

- The preflight floor of **200 GiB free** exceeds the partition's *total* size. It could
  never pass, on any node, at any time.
- The Job's `ephemeral-storage` **request of 150 GiB** exceeds node allocatable, so the
  pod was unschedulable even with preflight bypassed. This also affected the capability
  probe, which inherited the request while needing no scratch at all.

Longhorn is not implicated. It occupies a separate partition and never competes with
benchmark scratch. Measured non-Longhorn usage on the ephemeral partition is 5.7–10.1 GB
of container images plus under 0.5 GB of etcd and logs per node; the nodes sit at roughly
91% free. **There was no capacity problem to reclaim — only an unsatisfiable contract.**

## 2. What the census measured

The corrected figures are derived from a completed census of the live library
(`census.csv`, run `20260806T175355Z-57647486`, 397 titles, 17.26 TiB), not from an
assumed number:

| Statistic | Value |
| --- | --- |
| Median title | 47.28 GiB |
| p90 | 72.13 GiB |
| p95 | 78.43 GiB |
| p99 | 83.55 GiB |
| **Maximum title** | **88.18 GiB** |

## 3. Scratch holds one encode, not a source copy

The budget depends on what actually occupies `/scratch`, which the implementation
settles: `benchmark.sh` reads each source directly from the read-only `/media` mount and
writes only the encode to scratch. No source is ever copied there. Quality-panel clips
are `-c copy` extracts of roughly 90 seconds and are negligible beside a full title;
contention mode's concurrent workers operate on 1080p sources, whose cohort averages
about 24 GiB.

The binding case is therefore savings mode: **one full-title encode output resident at a
time**, bounded by the largest source at 88.18 GiB.

An earlier reading of this amendment's own evidence assumed scratch had to hold source
plus encode, which would have required about 176 GiB and made the benchmark infeasible on
these nodes. That reading was wrong, and the distinction is the difference between a
project that fits and one that does not.

## 4. Decision

| Setting | 2026-08-01 | This amendment |
| --- | --- | --- |
| `emptyDir.sizeLimit` | 150Gi | **105Gi** |
| `ephemeral-storage` request | 150Gi | **105Gi** |
| `ephemeral-storage` limit | 160Gi | **110Gi** |
| Preflight free-NVMe floor | 200Gi | **115Gi** |

Each figure is chosen against a measurement:

- **105 GiB scratch** covers the 88.18 GiB maximum title with about 19% headroom, which
  absorbs an encode that fails to shrink. It sits 29.66 GiB below node allocatable, so the
  Job schedules with margin rather than at the edge.
- **110 GiB limit** stays marginally above the request, preserving §9's stated shape.
- **115 GiB preflight floor** clears the measured free space on both eligible non-Plex
  nodes — nuc1 at 136.05 GiB and nuc3 at 138.54 GiB — with roughly 21 GiB to spare, while
  remaining well inside the 149 GiB partition so it stays satisfiable in principle.

## 5. Stated assumption and its failure mode

105 GiB assumes a quality-targeted HEVC encode never exceeds about 1.19× its source. That
is near-certain for a remux input and is not a guarantee. The consequence of being wrong
is bounded and unchanged from §9: `emptyDir.sizeLimit` deterministically evicts the
offending pod when it exceeds its own limit, `backoffLimit: 0` prevents a silent retry,
and the source is behind a read-only mount. A violation costs one wasted encode. Nothing
is corrupted and no original is touched.

§9's **accepted gap remains accepted**: preflight measures nodes but does not bind
placement, so the Job may still land on a node other than the one measured. The narrowed
guarantee and its rationale are unchanged; only the threshold moves.

## 6. What this does not change

- The read-only `/media` mount, the `subPath` scoping, and the TV exclusion (§7.2).
- Every structural guarantee in §9 other than the three numbers above.
- The negative-value PriorityClass, `restartPolicy: Never`, `backoffLimit: 0`, and
  `activeDeadlineSeconds` (§7.3).
- The decision gates and thresholds in §11.

## 7. Consequential findings from the same census

Recorded here because they bear on the project's scope, though they change no decision in
this amendment:

- **The hardlink risk is largely absent.** 393 of 397 titles are `unlinked`
  (`st_nlink == 1`) and realize full savings immediately. Four are `active` and must be
  skipped. There are **no** `private-permanent` and **no** `public-awaiting-cleanup`
  titles, so §3.1's central concern — that re-encoding a permanently-seeded private
  torrent is a net loss — does not arise for this library.
- **§3.2's sizing survives.** Addressable non-Dolby-Vision content totals 9.59 TiB against
  the design's "roughly 9 TiB", and per-cohort TiB tracks the plan closely (Dolby Vision
  7.63 vs 7.7, HDR10 6.28 vs 6.04, AVC 2.92 vs 2.91). Cohort *counts* differ more (Dolby
  Vision 126 vs 137, HDR10 128 vs 113), so the plan's counts should not be quoted as fact.
- **One title cannot be probed.** A 19.42 GiB source returns `EINVAL` from `ffprobe`
  inside the pod while reading normally from the operator workstation. It is
  `active`/`unmatched-hardlink`, so it is skipped regardless. At 1 of 397 it is treated as
  a single bad title rather than evidence of a mount fault; a qBittorrent force-recheck
  will settle whether the payload is corrupt.
