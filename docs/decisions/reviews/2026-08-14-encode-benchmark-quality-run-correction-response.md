# Spec Review Response

**Spec:** `docs/decisions/2026-08-14-encode-benchmark-quality-run-correction.md`
**Review:** `docs/decisions/reviews/2026-08-14-encode-benchmark-quality-run-correction-review.md`
**Reviewer verdict:** Not ready — the capability gate can conflate a telemetry gap with platform ineligibility, and `-nostdin` scope is unclear.
**Independence:** unverified

## For you to decide

Nothing to decide.

## Ledger

### F1 — Defect — evidence holds — FIXED

**Changed:** §1 now makes independently validated telemetry a harness
precondition and classifies missing, unreadable, non-numeric, or unit-ambiguous
telemetry as `harness-blocked`. §4 no longer turns that condition into a QSV
eligibility verdict.

### F2 — Ambiguity — evidence holds — FIXED

**Changed:** §2.1 now states that `-nostdin` applies to every FFmpeg invocation
in both `benchmark.sh` and `stills.sh`, across quality, savings, finalist, and
contention modes. It also requires a multi-title savings regression in addition
to the three-clip quality regression.

### F3 — Defect — evidence fails — REJECTED

**Why:** §5 does not authorize dispatch from the four observed starting points.
It requires the implementation plan to calculate a new range and verify the
36-hour deadline before dispatch. The extension count has a known upper bound,
so that verification can multiply measured per-point times by the bounded
worst-case number of points. If the result exceeds 36 hours, the existing text
already prevents dispatch. The receiver independently verified the cited
Goodfellas per-variant times from the mounted failed-run `results.csv`.

### F4 — Contradiction — evidence holds — OPERATOR-RESOLVED

**Changed:** The operator chose one explicitly targeted short capability Job per
eligible node. The platform is ineligible only if every eligible node returns a
complete semantic failure. Passing evidence on any node preserves eligibility,
`harness-blocked` evidence prevents a cluster-wide verdict, and expensive Jobs
remain unpinned with a fast assigned-node proof before costly work.

### F5 — Defect — evidence fails — REJECTED

**Why:** §2.2 does not require the PGS regression to use the FFmpeg substitute
described for the distinct stdin-consumption test in §2.1. Section 3 already
requires an independent oracle. A stub that merely encodes the expected mapping
would violate that requirement; it is not an implementation permitted by the
draft.

### F6 — Ambiguity — evidence holds — OPERATOR-RESOLVED

**Changed:** The operator chose to separate capability progress from production
throughput. The five-second synthetic probe requires finite positive progress
and reports speed for diagnostics, but it does not apply a hard speed band.
Measured real-content variants retain the hard throughput gate because their
speed determines whether a setting is operationally useful.

### F7 — Ambiguity — evidence holds — FIXED

**Changed:** §1 now says a status string alone cannot pass dispatch. The
committed, versioned schema carries measured initialization, selected rate
control, telemetry, speed, decode, and VMAF fields; dispatch re-evaluates them
and refuses missing, stale, contradictory, or non-positive progress evidence.

### Grounding — run artifacts — verified by receiver

The reviewer could not access the mounted failed-run artifacts. The receiver
did: the run recorded 44 rows, 40 invalid, 25 QSV rows reporting ICQ/suspect,
and empty GPU busy evidence. The Goodfellas initial x265 points also support the
runtime figures quoted by the draft.

### Grounding — telemetry counter unit — RESOLVED

**Changed:** The replacement sampler uses FFmpeg's DRM render-node descriptor
under `/proc/<pid>/fdinfo`. The Linux DRM usage-statistics contract defines
`drm-engine-*` as per-client busy time in nanoseconds and defines absent engine
capacity as one. The sampler uses monotonic wall-clock nanoseconds, handles the
specified temporary counter regression behavior, and requires positive video
engine activity. Missing or malformed node support remains `harness-blocked`.
