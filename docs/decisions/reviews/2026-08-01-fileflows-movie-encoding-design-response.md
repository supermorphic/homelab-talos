# Spec Review Response

**Spec:** `docs/superpowers/specs/2026-08-01-fileflows-movie-encoding-design.md`
**Review:** `docs/superpowers/specs/reviews/2026-08-01-fileflows-movie-encoding-design-review.md`
**Reviewer verdict:** Not ready — storage placement and two decision gates are not executable as specified.
**Independence:** different-client (codex / GPT-5.6-sol; spec written by claude-code)
**Preflight:** spec digest `b73417461223ea14` matched the reviewed version — no drift.

All eight findings' evidence held. Six were determinate and are fixed. Two need
you.

---

## For you to decide

### 1. Scratch placement has a real hole, and closing it reopens a decision you already made

**What the reviewer found (F1, verified).** The spec claimed an
`ephemeral-storage` request makes the scheduler "place the Job only where
capacity exists." That is false. Kubernetes schedules against node *allocatable*
storage minus other pods' *requests* — it never looks at currently free bytes.
Meanwhile preflight measures free NVMe on "the candidate node," but nothing binds
the Job to that node. So preflight can pass on nuc2 and the Job can land on nuc3,
which has plenty of unrequested allocatable storage and very little actual free
disk.

**What I changed:** corrected the false claim in §7.3 and §9 — that part was
determinately wrong. I did **not** pick a fix, because all three candidates are
live design choices and one of them reverses something you approved:

| Option | Cost |
|---|---|
| Preflight requires *every* eligible node to pass | Simplest. Refuses to run when any node is low, even though the Job would have been fine on a good one. |
| Recipe selects a verified node at dispatch and pins to it | Most capable, and avoids the Plex GPU deadlock that killed the original `nodeSelector` pin, because it picks a node with a free GPU *at that moment*. More machinery in the recipe. |
| Accept the gap | A scratch-exhaustion eviction becomes an ordinary failed run. Given `backoffLimit: 0` and read-only sources, the blast radius is one wasted encode. |

Note this is the same ground as the withdrawn node-pin. You approved pinning
early on; I withdrew it when it turned out to deadlock against Plex's GPU slot.
Option 2 is that decision coming back in a form that doesn't deadlock.

My read: option 3 is defensible and cheapest, because the consequence is a wasted
run rather than damage — but it is your call, not mine.

### 2. The temp Plex library contradicts a constraint I wrote (F8, Scope)

The reviewer flagged that §8.7 stages finalist encodes into a temporary Plex
library, while the brief's Stated Constraints say "No change to Plex … as part of
this work." Adding a library through the UI mutates Plex's persisted config on
its PVC, and §9.1 already admits it leaves thumbnail/metadata residue.

The evidence holds — but you should know **the conflict is my fault, not the
spec's.** You approved the temp Plex library during the design conversation as
part of the review stage. The "no change to Plex" constraint is wording *I* wrote
into the review brief, and I meant it narrowly: no `priorityClassName`, no
manifest edits to the Plex Deployment. A reviewer reading it cold reasonably took
it to cover any Plex mutation at all.

So this is a scope finding against a constraint the reviewer was given, not
against anything you said. Per the disposition rules I have not touched it.
Options: confirm the temp library is fine (my expectation, since you approved it
and it is UI-level and reversible), or drop it and review finalists from stills
plus a direct player instead.

### 3. Grounding items the reviewer could not verify

Flagged as questions rather than facts:

- **Benchmark completion notifications.** The spec routes them through the
  existing Alertmanager → `alertmanager-ntfy` path. The reviewer confirmed that
  receiver exists but noted **no alert source for the benchmark exists yet** — a
  Job finishing does not generate a Prometheus alert on its own. So as written,
  notification is not actually wired. The spec does say results always land on
  disk and notification never blocks a run, so this degrades rather than breaks.
  Worth deciding whether it needs a real source or whether the recipe simply
  prints on completion.
- **Runtime image.** `linuxserver/ffmpeg` documentation lists QSV/oneVPL,
  libvmaf, and x265, but digest, behavior under UID 568, the 4K VMAF model, and a
  real cluster QSV encode remain unverified — as §7.1 already records.
- **Live cluster state.** Catalog link counts, allocatable GPU counts, and Plex's
  current node placement are all unverified from a read-only checkout. Expected;
  preflight covers them.

---

## Ledger

### F1 — Defect — evidence holds — PARTIALLY FIXED, SURFACED
**Changed:** §7.3 and §9 no longer claim the `ephemeral-storage` request
guarantees placement on a node with free space; both now state what the request
actually bounds. §9 carries the open item with all three candidate mechanisms
named.
**Surfaced because:** the three resolutions are live design choices with
different downstream consequences, and one reverses a decision previously
approved then withdrawn. Not determinate. See *For you to decide* §1.

### F2 — Defect — evidence holds — FIXED
**Changed:** §8.4 now states the x265 CRF points are a *starting* set and the
sweep extends — lower or higher CRF as needed — until the QSV operating point is
bracketed; comparison is by interpolation only, never extrapolation. §11.3 gains
an explicit "not bracketed → **no verdict**" row.
**Determinate because:** the sweep exists solely to enable the matched-VMAF
comparison. Only "extend until bracketed" serves that stated purpose; the fixed
four-point list gave no rationale. Reasoned side wins.

### F3 — Defect — evidence holds — FIXED
**Changed:** §8.6's baseline runs now execute the same one-seek-per-2-minutes
sequence as case (d), and explicitly record seek-to-resume latency.
**Determinate because:** case (d)'s threshold is defined relative to baseline. A
baseline that produces no seek samples makes the threshold unevaluable — there is
only one defensible repair.

### F4 — Contradiction — evidence holds — FIXED
**Changed:** §8.1 now emits the **four** states of §3.1's table, with
`never-torrented` and `already-cleaned` merged as `unlinked`, and states why they
cannot be separated.
**Determinate because:** §3.1 gives its rationale (link-count observation, storage
economics) and §8.1 merely listed outputs. The reviewer independently confirmed
no durable history exists to split them, and no decision in the spec depends on
the distinction — both realize full savings immediately.

### F5 — Ambiguity — evidence holds — FIXED
**Changed:** §8.5 now specifies resume as **operator-directed**:
`encode-benchmark-run` takes an optional run-id; omitting it always starts a new
run; given one, it resumes only on exact manifest-identity match and otherwise
aborts with a diff.
**Determinate because:** the spec already establishes run-id as an operator-held
handle — `encode-benchmark-clean` takes one in §7.4. Reading 2 (hash-suffix
directory discovery) would have introduced a second, inconsistent mechanism. Also
worth noting the reviewer's underlying catch: because run-id embeds a fresh UTC
timestamp, the resume path as written was unreachable in *both* readings.

### F6 — Ambiguity — evidence holds — FIXED
**Changed:** §11.1 now requires **every individual clip** to meet every threshold
independently, and states that scores are not pooled.
**Determinate because:** §8.3 gives an explicit rationale for choosing hard scenes
— "if quality holds on the worst 90 seconds, it holds everywhere." Pooling lets a
strong clip mask a weak one, defeating that stated purpose. Reasoned side wins.

### F7 — Ambiguity — evidence holds — FIXED
**Changed:** §8.5 adds an `encodes/` directory holding **finalist full-title
outputs only**, and states that clip-sweep and savings-panel outputs are measured
in `/scratch` and discarded. §13 updated to match.
**Determinate because:** §9.1 states the run tree occupies "tens of GB."
Persisting all savings-panel encodes would be roughly 600 GB. Only selective
persistence preserves an already-stated figure.

### F8 — Scope — evidence holds — SURFACED
**Question:** §8.7's temp Plex library mutates Plex's persisted config, against
the brief's "no change to Plex." Never fixed per the disposition rules — adding
or removing scope is yours. See *For you to decide* §2, including the note that
the constraint wording was mine and narrower in intent than the reviewer read it.

---

## Notes on the review itself

Contract-compliant on the first pass: eight findings, all with the required
evidence fields, no Strengths section, no recommendations, no solutions proposed.
The grounding section labeled unverifiable claims as `UNVERIFIED` rather than
guessing, which is what made the notification gap in §3 above visible.

Nothing was rejected. That is unusual and worth flagging rather than treating as
a good sign — it more likely reflects that the "Not settled" section of the brief
pointed the reviewer at genuinely unexamined material than that the spec was
sound in the places nobody looked.
