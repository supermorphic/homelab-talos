# Spec Review Request

You are a second opinion on a written specification — a different model from the
one that wrote it. That difference is the whole reason you were asked.

Two people have already read this spec: the model that wrote it, which shares
every blind spot that produced it, and the human who commissioned it, who knows
what they meant and so skims for "does this match what I said." Both reliably
miss the same four things. Those four things are your entire job.

**Spec under review:** /Users/ksiggins/Development/homelab-talos.challenge-agent-rules/docs/decisions/2026-08-02-agent-rules-audit.md
**Written by:** claude-code
**Write your review to:** /Users/ksiggins/Development/homelab-talos.challenge-agent-rules/docs/decisions/reviews/2026-08-02-agent-rules-audit-review.md

Read the spec in full before writing anything.

---

## Intent

This is ground truth. The spec is an attempt to express what follows. Where the
two disagree, this section is right and the spec is wrong.

### The original ask

Verbatim: *"I want you to challenge the governing rules of the repo as outlined in
AGENTS.md but also elsewhere, it is a good time for an audit to check in to see what is
working and what is not, a retrospective."*

Later, after the first findings landed: *"this is exactly why we are doing the audit, I
need honest feedback as a second-set of eyes without intimate knowledge of the repo
mechanics over time, that you are performing as 'an outsider' continue this analysis and
we have the potential to strip away all crud."*

The operator runs a three-node Talos + Flux homelab, single-handed, with AI agents doing
most of the authoring. The felt problems they named, unprompted, were: rules that churn
without settling, a per-app cost that keeps growing, and every rollout landing on them
personally. Notably they did **not** report agents violating the rules — that answer
reframed the whole audit, because it means advisory rules are being followed and the
heavy guard apparatus is insuring against a failure mode that is not occurring.

They also framed the output: *"after this audit and wayfinding task, we will have a
number of parallel brainstorming sessions to do."* So this document is a retrospective
plus direction that seeds later sessions — not a complete design for everything it
touches.

### Stated constraints

**Ruled out — do not propose these:**

- **Test reporting is out of scope and is being EXPANDED, not reduced.** ~9,587 lines of
  Allure/JUnit/campaign/catalog machinery plus a deployed `test-reports` service stay
  untouched. The operator went through a full planning cycle to build it and wants more
  resilience/E2E/smoke coverage reported through it. A finding that it is oversized is
  explicitly unwanted.
- **Do not split this into per-subsystem records.** Proposed in an earlier review and
  declined; the rationale is recorded in the spec's Review disposition section.
- **Do not defer the documentation/prose work.** Also proposed and declined.
- **`bypassPermissions` is not being changed.** Recorded as a known condition only.
- **No agent-managed worktrees.** Agents neither create nor remove them, and no skill is
  added for it.
- **No shared or symlinked credentials.** On-demand minting was chosen specifically
  because the operator wants to be *told* when cluster access becomes necessary.

**Ruled in:**

- The audit may delete, change, and add rules — full authority over the rule set.
- The prior 2026-07-31 nested-`AGENTS.md` design and its PR #171 were deleted outright
  and closed unmerged, at the operator's instruction, *"like it never existed."* Do not
  suggest resurrecting nested `AGENTS.md`; do not treat its absence as an oversight.
- The operator prefers warnings over guards: *"I don't like added restrictions, but
  warning should be presented if accidentally working on main."*
- Division of labour today: operator runs `mise exec -- just …`, agent does git through
  PR creation, agent never merges.

### Decisions already approved

Listed roughly in order of how hard they were argued before settling — the top ones are
the most likely to be reopened by a cold reader and the least useful to reopen.

1. **One root `AGENTS.md`. No nested layer.** Settled after researching Anthropic's
   context-engineering guidance and the AGENTS.md specification. The operator's words:
   *"I don't want to keep churning on this topic of agents.md, ruleset, and hierarchy"*
   and then *"Settle it."* Root is 67 lines, under every published split threshold.
2. **App-tier bootstrap recipes are deleted; the platform tier keeps its `*_CONFIRM`
   gates.** Reached over several rounds after establishing that Flux already provides
   ordered, health-gated, time-bounded rollout on all 33 Kustomizations.
3. **Policy-as-code replaces per-app change-detector assertions.**
4. **Credential tiers `observer` / `diagnostic` / `admin`.** `diagnostic` grants
   `pods/exec` and `pods/portforward` and is explicitly *not* read-only.
5. **Credential scope follows directory** — main clone holds admin, worktrees hold
   observer — at unchanged repository-relative paths.
6. **Credentials are minted on demand, never at worktree creation.** The agent stops and
   asks; the ask is the point.
7. **30-day Kubernetes token, 90-day `os:reader` talosconfig.**
8. **A `PreToolUse` hook blocks four irreversible git patterns. A worktree-boundary hook
   was considered and rejected** because it would false-positive on legitimate
   out-of-tree reads and memory writes.
9. **A `SessionStart` hook warns — never blocks** — about tier, branch, and stray SOPS
   key material.
10. **`docs/decisions/` with date-based filenames** (not MADR's `NNNN-`, because parallel
    worktrees collide), a Status field, supersede-don't-revise, and CI enforcement.
11. **Implementation plans are written but never committed.**
12. **No fixed count of recipes to delete** — the eligibility criteria decide per recipe.

Findings that reopen an approved decision are the most common way a spec review
wastes everyone's time, so treat that list as closed unless the spec contradicts
itself about one of them.

### Not settled — the author's own choices

Everything here the author supplied because the spec needed *something*. None of it was
chosen by the operator, and none has been checked by anyone.

**The containment contract (decision 2)** — the entire mechanism is invented. Explicit
per-Kustomization `spec.retryInterval`; Helm `install.remediation` / `upgrade.remediation`
with a bounded retry count; a `NotReady`-duration alert whose threshold is
`spec.timeout + spec.retryInterval`. Whether that actually replaces what the deleted
cleanup trap did — *suspend* the Kustomization, halting reconciliation — is the load-
bearing question of the whole document, and the author has only argued it, not
demonstrated it.

**The three eligibility criteria** for the one-PR path, particularly criterion 2, that an
app must have a Gatus endpoint. That is an author-invented hard gate; ~10 of the affected
apps currently fail it.

**The four platform-tier criteria** and their wording.

**Post-merge acceptance mechanics** — actor, trigger, a timeout of
`spec.timeout + spec.retryInterval`, evidence under `.test-results/`, and a
revert-unless-explicitly-accepted failure response. All author-chosen. The spec also
flags an **unresolved conflict** here: on-demand credentials leave this automation with
nowhere to get them, and the candidate resolution (an in-cluster Job with its own
ServiceAccount) is recorded as needing operator approval, not decided.

**The four-layer policy architecture** — source / resource / rendered / domain, and the
declared input form per layer. Invented by the author in response to the finding that
`media.rego` is app-template-schema-coupled.

**Assertion rules** — the phrase "independent oracle or invariant"; the four retained
assertion categories; and per-assertion-**class** coverage-matrix granularity, which the
author argued down from per-assertion.

**The three-category admission test itself** — authoritative control / operator policy /
gotcha — and the enforcement-strength table, and every row's category assignment in the
final `AGENTS.md` rule table. The categories are the author's.

**`CLAUDE.md` as a "permitted vendor shim"** bounded to harness guidance.

**Record identity semantics** — filename as immutable identity, rename rejected,
merge-base as comparison base, the migration exception.

**Introduce-then-freeze link validation**, replacing the blanket exclusion that was
already committed as interim.

**Index contract** — generated and committed, sort by date descending then filename
ascending, CI compares rather than writes.

**The ~400-line distillation target** for the seven legacy plans, and the five-workstream
sequencing order.

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

Write exactly this shape to /Users/ksiggins/Development/homelab-talos.challenge-agent-rules/docs/decisions/reviews/2026-08-02-agent-rules-audit-review.md:

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
