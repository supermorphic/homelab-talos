# Spec Review Request

You are a second opinion on a written specification. The client that wrote it was not recorded, so whether you share its blind spots is unknown. Do not assume you are independent of it.

Two people have already read this spec: the model that wrote it, which shares
every blind spot that produced it, and the human who commissioned it, who knows
what they meant and so skims for "does this match what I said." Both reliably
miss the same four things. Those four things are your entire job.

**Spec under review:** /Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy/docs/decisions/2026-08-14-encode-benchmark-quality-run-correction.md
**Written by:** unknown
**Spec SHA-256 (first 16):** 0105f024517701ee
**Deliver your review as:** your entire final message (it is captured automatically — you cannot write files)

Read the spec in full before writing anything.

---

## Intent

This is ground truth. The spec is an attempt to express what follows. Where the
two disagree, this section is right and the spec is wrong.

### The original ask

The operator was executing the accepted movie-encoding benchmark plan. After the
quality Job exceeded its 2–3 hour estimate and emitted repeated FFmpeg errors,
the operator asked to "audit what has run to see if we need a correction and a
restart." The audit showed that the run was not decision-usable. The operator
stopped it and asked the author to continue with a correction. The desired
outcome is a trustworthy, fail-closed quality benchmark, not merely a Job that
finishes.

### Stated constraints

- Preserve the accepted LA-ICQ eligibility gate. The operator explicitly agreed
  that verified inability to provide LA-ICQ makes QSV ineligible; ICQ must not be
  substituted or relabelled.
- The stopped run's artifacts remain available as evidence and must not be
  cleaned before regression coverage and a corrected run are accepted.
- Movie sources remain read-only. Agents do not run cluster mutations; the
  operator dispatches capability and benchmark Jobs and controls merges.
- Source changes go through the assigned feature branch and merge gates. Flux
  must reconcile merged source before dispatch.
- Accepted decision records are never revised. This new amendment remains
  **Draft** until the operator explicitly marks it accepted.
- Every corrected defect must have a regression test that demonstrably fails
  before the production fix and uses an independent oracle or genuine invariant.
- The Dolby Vision Profile 7 sample remains detection-only and is never encoded.
- The accepted three 90-second clip roles and operator-selected quality titles
  remain unchanged.

### Decisions already approved

- Use a capability-first correction rather than immediately rerunning the full
  quality panel.
- Strengthen capability proof to require exact LA-ICQ selection, successful QSV
  initialization, increasing GPU telemetry, plausible speed, decode, and VMAF.
- Treat the old weaker capability evidence as pending and refuse expensive modes
  until stronger evidence is committed.
- Repeat the short proof on the actual node assigned to an expensive Job before
  source hashing or run-directory creation.
- Prevent FFmpeg from consuming clip-loop input and prove that all `detail`,
  `dark`, and `motion` sweeps execute.
- Decode-check video only while retaining independent probe-based validation of
  audio, subtitle, and chapter counts.
- Use the original title as the HDR static-metadata oracle when the copied clip
  does not expose that metadata.
- Mark exactly the grain-heavy AVC and grain-heavy HDR10 samples as x265
  references; do not run x265 on every title.
- Preserve the accepted VMAF harmonic-mean calculation, including isolated zero
  scores.
- Use two merge gates: capability contract first, then harness corrections only
  after capability passes. A corrected quality sweep gets a fresh run ID.

Findings that reopen an approved decision are the most common way a spec review
wastes everyone's time, so treat that list as closed unless the spec contradicts
itself about one of them.

### Not settled — the author's own choices

- The exact JSON field names and schema used for stronger committed capability
  evidence.
- The exact point and mechanism for dispatch refusal versus the assigned-node
  runtime proof.
- Whether a failed capability probe emits structured JSON and then exits nonzero,
  and how the read-only results helper presents that failure.
- Which GPU telemetry interface replaces the current empty sysfs evidence if the
  expected engine `busy` files are unavailable.
- The exact implementation boundary between clip-structure validation and the
  original-title HDR oracle.
- Whether `x265Reference: true` is the final configuration shape or another
  explicit schema is clearer.
- The recalculated runtime range and whether the existing 36-hour Job deadline is
  still credible.
- The precise regression-fixture construction and how the work is divided across
  the two proposed PRs.

These are open. Nobody has checked them, and a finding against one of them is
not relitigation — it is the most useful thing you can return, because it is the
part of the spec that has had the least scrutiny.

The section above exists so you leave settled questions alone. This one exists
so that restraint does not spill over into the rest of the document. Where a
spec is silent about which of the two a detail belongs to, treat it as open.

---

## What to report

Four categories, and nothing else. Each one requires evidence, and the evidence
requirement is doing real work: it is easy to assert that something is ambiguous
and genuinely hard to produce two concrete divergent implementations. If you
cannot fill the fields, you do not have a finding — you have an impression, and
an impression reported as a finding gets acted on and makes the spec worse.

### Defect

The spec specifies a mechanism that will not do what the spec says it does.

```
### F1 — Defect
**Where:** §3 Rotation
**Mechanism:** rotation renames the active log to <name>.1 and creates a fresh file
**Failure:** a writer holding the log open keeps writing to the renamed inode; the
new active log stays at zero bytes and the disk is never reclaimed
**When:** any writer that does not reopen its log on its own
```

This is the most valuable thing you can find and the easiest to miss, because it
requires tracing what the spec *does* rather than checking what it *says*. Walk
the mechanism through one concrete execution and see where it lands.

The bar is a concrete failure, not a risk. "This might not scale," "consider the
race here," and "this could be a problem under load" are not defects — they are
the speculation this contract exists to keep out. If you cannot describe the
failure as something that definitely happens under a stated condition, you do
not have one.

### Contradiction

Two parts of the spec cannot both be true.

```
### F2 — Contradiction
**Where:** §2 Storage and §7 Retention
**§2 says:** records are immutable once written
**§7 says:** expired records are rewritten with a tombstone marker
**Why both cannot hold:** a tombstone rewrite mutates a record §2 declares immutable
```

One location is not a contradiction. If you cannot cite a second place that
conflicts, you are looking at something you disagree with, which is not the same
thing and is not reportable.

Follow each statement one step out to what it implies for the other. Conflicts
frequently do not sit on the surface of two sentences — they appear when a
filename convention in one section meets a rename pattern in another, or a
schema claim meets an update rule. A pair that looks merely untidy is worth one
step of tracing before you drop it.

### Ambiguity

A requirement admits two readings that would produce *different
implementations*.

```
### F3 — Ambiguity
**Where:** §4 Retention
**Reading 1:** purge at 30 days from creation → implementation drops rows on a cron
**Reading 2:** purge at 30 days from last access → implementation needs an access timestamp
```

If you cannot write out both implementations concretely, the text was terse
rather than ambiguous. Terse is fine; a spec is not required to be long.

But readings that differ in what they put on disk or on the wire — filenames,
schemas, message shapes, API surfaces — are different implementations even when
the difference looks cosmetic. Someone has to pick one, and picking wrong is
found later by whatever depends on the artifact.

### Scope

The spec includes something the intent never asked for, or omits something the
intent requires.

```
### F4 — Scope
**Type:** Unrequested
**Where:** §5 Notifications
**Brief says:** "email only, no other channels" (Stated constraints)
**Mismatch:** the spec specifies an SMS delivery path
```

Quote the Intent section above. A scope finding grounded in your own sense of
what the project needs, rather than in what the brief says, is noise — you do
not know this project and the brief is all the standing you have.

### Grounding against the codebase

The spec makes assumptions about code that already exists. Check them.

For each assumption: state it, state what you checked, state what you found.
An assumption you did not verify must be labelled `UNVERIFIED` — a confident
guess here is worse than a gap, because it gets acted on.

---

## Rules

**Do not propose solutions.** Report the defect and stop. This is the sharpest
difference from a code review, where "how to fix" is welcome. A reviewer who
resolves the ambiguity it found has made a design decision nobody authorised,
and the person who *is* authorised will now have to reverse-engineer it out of
your prose.

**Do not edit the spec, or any file other than your review.** A reviewer that
helpfully fixes what it found destroys the artifact and the review at once.

**Nothing outside the four categories.** No Strengths section, no
Recommendations, no Minor or nitpick tier, no observations about style, wording,
structure, or "you might also consider." Review tooling usually asks for these
and their absence here is deliberate: a Minor tier is a box, a box invites
filling, and every item in it costs someone a decision. If an observation does
not fit one of the four categories, it does not get written down.

**An empty category is a good outcome.** Write "None." A review that finds
nothing on a sound spec is the review working correctly, not a review that
failed to try.

---

## Output format

Your **entire final message** must be the review and nothing else — no preamble, no summary, no closing remark about what you did. It is
captured verbatim into the review file by the harness.

Do not attempt to write the review to a path. You are sandboxed read-only; the write will fail, and a final message that reports writing a file
replaces the findings with a note about a file that does not exist.

Emit exactly this shape:

```
# Spec Review

**Spec:** <path>
**Reviewer:** <your model and client>
**Verdict:** Ready to plan | Not ready — <one line>

## Findings

<finding blocks in the formats above, numbered F1, F2, … — or "None.">

## Grounding

<per-assumption findings, or "Skipped.">
```

The verdict is the first thing a human reads. `Not ready` means at least one
defect, contradiction, or ambiguity would cause the wrong thing to be built.
Scope findings alone do not make a spec "Not ready" — they are questions for the
human rather than faults in the document.

<!-- built-for: client=claude delivery=capture independence=unverified spec-sha256=0105f024517701ee -->

<!-- dispatched: client=claude model=inherited (unresolved) effort=inherited (unresolved) resolved-from=inherited at=2026-08-14T09:20:09 -->
<!-- invocation: cd /Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy && claude -p --allowed-tools Read,Grep,Glob < /Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy/docs/decisions/reviews/2026-08-14-encode-benchmark-quality-run-correction-request.md > /Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy/docs/decisions/reviews/2026-08-14-encode-benchmark-quality-run-correction-review.md -->
