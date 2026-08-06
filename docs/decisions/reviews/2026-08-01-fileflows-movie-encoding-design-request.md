# Spec Review Request

You are a second opinion on a written specification. It was written by claude-code; you are running in a different client, so you do not share its context. That difference is the whole reason you were asked.

Two people have already read this spec: the model that wrote it, which shares
every blind spot that produced it, and the human who commissioned it, who knows
what they meant and so skims for "does this match what I said." Both reliably
miss the same four things. Those four things are your entire job.

**Spec under review:** /Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy/docs/superpowers/specs/2026-08-01-fileflows-movie-encoding-design.md
**Written by:** claude-code
**Spec SHA-256 (first 16):** b73417461223ea14
**Deliver your review as:** your entire final message (it is captured automatically — you cannot write files)

Read the spec in full before writing anything.

---

## Intent

This is ground truth. The spec is an attempt to express what follows. Where the
two disagree, this section is right and the spec is wrong.

### The original ask

The user's opening framing, verbatim:

> "use plans/fileflows-movie-evaluation-implementation-plan.md as a starting
> point, not as verbatim scripture, to brainstorm with me on how we can test out
> the fileflows workflow to normalize and ultimately reduce size of my movie
> catalog."

Two things in that phrasing shaped everything after it. **"Test out"** — the ask
was for a way to *evaluate* the approach, not a deployment plan. **"Not as
verbatim scripture"** — the source plan was explicitly demoted to input, so
departing from it is licensed rather than a deviation to justify.

The user is the operator of a three-node Talos/Flux homelab cluster and runs the
media stack on it personally. The catalog is ~388 MKV files, 345 of them their
own MakeMKV disc rips. The motivating problem is NAS space.

Mid-conversation the user twice made an unprompted constraint explicit, in their
own words:

> "I don't want plex ever to compete with a 'background job' of fileflows, when
> I'm streaming media from plex, so confirm we are on same page"

> "ensure plex always takes precedence on gpu allocation, even after a node
> drain or helmrelease upgrade"

and separately:

> "will the experiment be reversable back to pre-install state to retain health
> in production?"

Those three questions are the user's real acceptance criteria and matter more
than the encoding details. The user is protecting a working production system
they use daily.

### Stated constraints

**Ruled in (user-stated, hard):**

- Plex must **never** compete with FileFlows for a GPU while the user is
  streaming. Stated twice, unprompted.
- Plex takes precedence on GPU allocation **even after a node drain or
  HelmRelease upgrade**.
- The experiment must be **reversible to pre-install state** without damaging
  production health.
- A processing window (encoding pauses during viewing hours) is to be built in.
  The user said "agreed, build the window in" after being told it was probably
  unnecessary — so it is a requirement, not a default the reviewer should
  question as over-engineering.
- The source evaluation plan is a starting point, not scripture.

**Ruled out:**

- The source evaluation plan must **not be tracked in this repository**. The
  user directed its removal after it was initially committed. It is working
  input; the spec must stand alone without it.
- No change to Plex or to `intel-gpu-plugin` as part of this work.

**Repository constraints (from AGENTS.md, binding and non-negotiable):**

- `main` is the Flux production boundary; never commit or push to it directly.
- All cluster mutations and health checks go through guarded `just` recipes.
  Never raw `kubectl`, `talosctl`, `helm`, or `flux` against the live cluster.
- Cluster-mutating recipes require an explicit `*_CONFIRM` value and are
  operator-run; agents stage and validate source, then hand off.
- Guarded rollouts must verify their sources match the current remote
  `origin/main` commit.
- Run repository workflows through the pinned toolchain (`mise exec -- just …`);
  never unpinned or system tools.
- `just ci` is the canonical cluster-independent, secret-free validation used by
  the required PR check. Cluster-dependent `*-verify` / `*-status` /
  `*-preflight` recipes stay out of it.
- New apps begin suspended, roll out through guarded `just bootstrap <app>`, then
  persist the unsuspended state.
- Secrets are SOPS-encrypted; the age key is operator-only. Never decrypt,
  rewrite, or expose secret values.
- Do not edit generated files under `clusterconfig/`.

**Operator-workflow note:** the operator runs `mise`/`just` recipes; the agent
handles git. So the spec deliberately specifies recipes it does not itself
execute.

### Decisions already approved

Each of these was put to the user as an explicit multiple-choice question and
answered. They are closed.

1. **Benchmark first, standalone; do not deploy FileFlows yet.** The user chose
   this over (b) deploy-first per the source plan and (c) a hybrid deploying the
   FileFlows server plus one runner. The whole "don't build the platform yet"
   posture is the user's decision, not the author's.

2. **Quality gate is VMAF-screens / eyes-approve.** Chosen over metric-only and
   eyes-only. A finding that the spec should automate the visual sign-off, or
   drop VMAF, reopens this.

3. **Normalization is video-codec-only.** Chosen over (b) also pruning audio
   tracks and (c) also subtitle/metadata hygiene. The census reports audio
   inventory as reconnaissance for a possible later project, but **no audio is
   modified**. A finding that the spec should prune audio reopens this.

4. **Harness = pinned public ffmpeg image + scripts in a Flux-managed
   ConfigMap.** Chosen over (b) a custom image built and published from this
   repo and (c) scripts living on the SMB share. The user also approved three
   sub-decisions: include a CPU x265 reference encode as a yardstick; read
   sources from SMB and write to node-local scratch; and record which node ran
   each encode. (A fourth — pinning the Job to one named node — was proposed,
   approved, then withdrawn by the author when it was found to deadlock against
   Plex's GPU slot. The withdrawal is the author's call, listed as open below.)

5. **Two Flow Runners, not three; `shared-dev-num` stays at 1; no change to
   `intel-gpu-plugin`.** The user accepted this after the author first proposed
   three runners plus a plugin change, then retracted it. This is how the "Plex
   never competes" constraint is satisfied, and the ~1 extra day of wall-clock
   cost was accepted explicitly.

6. **A processing window is built in.** See Stated constraints.

7. **The 15% minimum savings gate** is inherited unchanged from the source plan,
   which the user supplied. Its *value* is open (see below); its *existence* is
   not.

8. The five design sections (architecture, census/sampling/sweep, safety,
   decision gate, and the GPU/Plex analysis) were each presented and approved in
   sequence before the spec was written.

**Also closed:** the spec has already been through one code review by another
agent, and eight blocking items were resolved — image name, storage contract,
rollout lifecycle, a stale qbit_manage premise, sampling design, resume safety,
priority/eviction claims, and QSV rate-control naming. Re-finding those exact
eight is not useful. Finding that a *fix* to one of them is itself wrong is very
useful.

Findings that reopen an approved decision are the most common way a spec review
wastes everyone's time, so treat that list as closed unless the spec contradicts
itself about one of them.

### Not settled — the author's own choices

The user approved the *shape* of this design but has not checked a single number
in it. Everything below was supplied by the author because the spec needed a
value there. Most of it was written in one pass while resolving code-review
findings and has had less scrutiny than anything above.

**Every quantitative threshold in §11 is invented.** None is derived, cited, or
validated:

- VMAF harmonic mean ≥ 95 and 1% low ≥ 90 as the screening bar.
- Per-cohort savings verdicts: ≥25% GO, 15–25% MARGINAL, <15% NO-GO. Note these
  sit alongside the inherited 15% savings gate and the relationship between the
  two was not worked through.
- x265 comparison bands: ≤15% bitrate premium at matched VMAF is fine, 15–30%
  acceptable, >30% escalate.

**Sampling design is invented, including the sizes.** Quality panel of 7 titles
(one detection-only); savings panel of ~24, "~8 per major cohort," described as
stratified and seeded. No power analysis or precision target justifies 24, and
the spec promises a median with interquartile range from it. Three ~90-second
clips per title at hand-chosen "hard" scenes is also the author's construction.

**Encoder parameters are invented.** `global_quality` swept at 20/22/24/26/28;
"slow preset" unnamed; `extbrc` and lookahead on; x265 at CRF 18/20/22/24 preset
slow. The claim that interpolating across those four CRF points supports a
matched-VMAF comparison is the author's assertion.

**The entire Plex contention protocol (§8.6) is invented** — 15-minute runs,
three baseline runs, four named cases, a seek every 2 minutes, and the pass
thresholds (zero buffering events; start latency within 2 s of baseline; no seek
exceeding baseline by more than 3 s). The user asked whether encoding would
disturb streaming; the author designed the entire measurement.

**Mechanism choices the author made alone:**

- Negative-value PriorityClass for the benchmark, and the decision to defer
  `plex-critical` to later work rather than add it now.
- `ephemeral-storage` request sized to the full scratch budget as the placement
  mechanism, replacing the withdrawn `nodeSelector` pin.
- Census is metadata-only (no `-count_packets`), which makes per-track audio
  byte counts *estimates* with a method flag rather than measurements. The I/O
  argument for this (~9 TiB vs ~1–2 GB) is the author's arithmetic.
- The five-state torrent lifecycle taxonomy (`never-torrented`, `active`,
  `private-permanent`, `public-awaiting-cleanup`, `already-cleaned`) is the
  author's construction from reading `qbit-manage/app/config.yml`.
- Run-id scheme (UTC timestamp + manifest identity hash) and the rule that any
  manifest divergence starts a new run rather than resuming.
- All recipe names and `*_CONFIRM` token formats, patterned on repo convention
  but not matched against it line by line.
- The §12 test list, and the claim that the mount-contract and confirmation-guard
  tests are the load-bearing ones.
- Following the suspended-first bootstrap convention for an app containing only
  inert objects. The spec itself notes this is near-vacuous and does it anyway.

**Unvalidated models presented as estimates.** §3.2's ~3–4 TiB recovery, §5.1's
throughput arithmetic (~176 runner-hours, "one extra day"), and §6's per-workload
NAS draw figures (8 / 10 / 45 MB/s) are all author models. The spec labels them
as models, but nothing checks them, and §5.1's is load-bearing for a decision the
user already approved.

**Two open unknowns the spec records rather than resolves:** NUC NVMe free
capacity, and the NAS uplink speed. Both are deferred to preflight/operator.

**Runtime image is unresolved by design.** §7.1 names acceptance criteria instead
of an image, because an earlier draft asserted `jellyfin/ffmpeg`, which does not
exist. `linuxserver/ffmpeg` is flagged as the leading candidate with its
`libvmaf`/`libx265` contents explicitly unverified. Whether "pick an image later
against criteria" is adequate for a spec meant to precede an implementation plan
is itself open.

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

<!-- built-for: client=codex delivery=capture independence=different-client spec-sha256=b73417461223ea14 -->

<!-- dispatched: client=codex model=gpt-5.6-sol effort=high resolved-from=/Users/ksiggins/.codex/config.toml at=2026-08-02T10:02:28 -->
<!-- invocation: codex exec -C /Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy -s read-only -o /Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy/docs/superpowers/specs/reviews/2026-08-01-fileflows-movie-encoding-design-review.md - < /Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy/docs/superpowers/specs/reviews/2026-08-01-fileflows-movie-encoding-design-request.md -->

<!-- dispatched: client=codex model=gpt-5.6-sol effort=high resolved-from=/Users/ksiggins/.codex/config.toml at=2026-08-02T10:02:36 -->
<!-- invocation: codex exec -C /Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy -s read-only -o /Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy/docs/superpowers/specs/reviews/2026-08-01-fileflows-movie-encoding-design-review.md - < /Users/ksiggins/Development/homelab-talos.fileflows-movie-encoding-strategy/docs/superpowers/specs/reviews/2026-08-01-fileflows-movie-encoding-design-request.md -->
