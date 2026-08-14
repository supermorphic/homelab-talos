# Spec Review Request

You are a second opinion on a written specification. It was written by claude-code; you are running in a different client, so you do not share its context. That difference is the whole reason you were asked.

Two people have already read this spec: the model that wrote it, which shares
every blind spot that produced it, and the human who commissioned it, who knows
what they meant and so skims for "does this match what I said." Both reliably
miss the same four things. Those four things are your entire job.

**Spec under review:** /Users/ksiggins/Development/homelab-talos.dispatch-policy-denied-alert/docs/decisions/2026-08-13-alerting-architecture.md
**Written by:** claude-code
**Spec SHA-256 (first 16):** 76258823f3fc1e7f
**Deliver your review as:** your entire final message (it is captured automatically — you cannot write files)

Read the spec in full before writing anything.

---

## Intent

This is ground truth. The spec is an attempt to express what follows. Where the
two disagree, this section is right and the spec is wrong.

### The original ask

The author was present for the whole conversation; nothing below is reconstructed.

It started narrow and widened. The user handed over an agent handoff document
(`dispatch-policy-denied-alert.md`, untracked in the worktree root) about adding a
Prometheus alert for `POLICY_DENIED` network drops, and asked: evaluate the Seerr and
Lidarr alerting situation, and **determine whether we even need a spec**.

The background incident: a CiliumNetworkPolicy silently broke Seerr's Plex integration.
Seerr accumulated thousands of `POLICY_DENIED` drops with zero forwarded flows to Plex —
its Plex integration had been dead for weeks and was found by accident. A second instance
is live and unfixed: Lidarr has never once reached Plex.

From there the user asked, in order:

1. "Evaluate current landscape of monitoring and alerts ... across four domains, as this
   has evolved over time — which have fallen behind and what is most advanced, how would
   this architecture look ideally if we were to rework it now that we have enough
   examples in play currently? Is this an A. no refactor recommended, B. slight refactor,
   or C. major refactor to best software engineering practice of readability,
   maintainability, extensibility."
2. "Show me what ideal would look like from before and after folder structure and file
   changes, high-level not line-by-line. Which is the baseline that wouldn't change."
3. "The plex-ddns-drift is deprecated, we have moved on from relay to port forwarding for
   plex sonos solution. Confirm this is no longer required by looking at docs and code.
   Then create a decision record in stages: first refactor, fill gap in test coverage,
   then add in seerr — and audit if we are missing other alerts entirely. What is the
   state of lidarr, I'm still not clear on this as implemented or not for alerting."
4. "For stage 3, we discuss seerr and lidarr. What is prior precedence on the current arr
   stack, what is prowlarr and radarr doing for alerting/monitoring?"

So the user's framing is: *this grew organically, tell me honestly how bad it is, show me
the target, and write it up in stages.* The staging order in item 3 is theirs, not the
author's. The word "spec" in item 3 became a decision record under
`docs/decisions/`, because repository policy forbids committed spec artifacts (see
constraints).

The user has said explicitly they are "still in design mode." No implementation has been
requested and none has been done.

### Stated constraints

Most constraints here are standing repository policy in `AGENTS.md` at the repo root,
which the user treats as the sole repository-policy surface. Read it — it overrides
anything the spec assumes. The load-bearing ones for this review:

- **Durable architectural decisions belong in `docs/decisions/`.** Accepted decisions are
  **superseded, never revised.** This is why the spec is `Status: Draft` rather than
  Accepted — the tooling (`scripts/repository/decisions.py`) permits only `Draft` or
  `Accepted`, and Draft is the only revisable state.
- **Implementation plans must never be committed.** `docs/superpowers/plans/` and
  `docs/superpowers/specs/` are off-limits by policy. Design records go to
  `docs/decisions/YYYY-MM-DD-<topic>.md` only.
- **"A validation assertion must use an independent oracle or encode a genuine
  invariant."** Unconditional stubs and success-asserting mocks are explicitly not
  coverage. Stage 2 of the spec leans on this.
- **`mise exec -- just ci` is the canonical validation gate** and must run before opening
  a PR. It is cluster-independent and secret-free. Cluster-dependent verification lives
  outside it.
- **Never commit to `main`; never merge without explicit per-merge authorisation.** All
  work is on branch `dispatch-policy-denied-alert`.
- **Treat every committed file as public and permanently recoverable.** No live public
  IPs, no credentials, no unique infrastructure identifiers.
- **This worktree has no cluster credentials.** Any claim requiring a live Prometheus
  query could not be verified and had to be established from committed configuration
  instead.
- **A Deployment mounting a ReadWriteOnce PVC uses `Recreate`, never `RollingUpdate`.**
- The user has an established preference against "Phase N" notation in new work.

One constraint the user set in this conversation rather than in policy: when offered the
choice of folding `*arr` integration health into stage 4, expanding stage 4, or making it
a separate stage, they chose **a separate committed stage 5** — explicitly not an
open-ended deferral.

### Decisions already approved

**From this conversation, settled by the user:**

1. **The verdict is B — slight-to-moderate refactor.** Not A (no refactor) and not C
   (major). The user asked for the A/B/C call and accepted B.
2. **One alerts application per domain**, with `kubernetes/apps/media/alerts/` as the
   baseline pattern everything converges on. The user asked which structure was the
   baseline that would not change; this is the answer they accepted.
3. **`plex-ddns-drift` is deprecated and gets removed.** The user asserted this and asked
   for confirmation from docs and code. Confirmed: §1.1 of
   `docs/decisions/2026-08-11-plex-direct-remote-access.md` marks it superseded and
   schedules removal in its stage 5, which never executed.
4. **The stage ordering is the user's:** refactor → test coverage → policy-denied
   alerting → audit of missing alerts.
5. **`*arr` integration health is a separate committed stage 5**, chosen from three
   options offered.

**From the originating handoff document, declared settled before this conversation
began.** The handoff instructed the implementer to "implement these, do not re-litigate":

6. Two rules rather than one: `PolicyDeniedSustained` (warning) and
   `PolicyDeniedTotalBlock` (critical), the latter being the higher-value rule.
7. Severity routing is unchanged — the existing `severity` label already routes
   `critical` → ntfy `critical` topic and `warning` → `homelab` topic.
8. A long `for:` of 30m or more, because both real defects ran continuously for weeks.
9. Scope to in-cluster workload sources; the deliberate SSDP/UPnP multicast block
   recorded in `docs/decisions/2026-08-03-plex-containment-capture.md` must not trigger
   the alert.

Treat 6–9 as closed **except** for one point the author explicitly reopened during the
conversation and the user has not yet ruled on — see the "Not settled" section below
regarding the `source` matcher anchoring.

Findings that reopen an approved decision are the most common way a spec review
wastes everyone's time, so treat that list as closed unless the spec contradicts
itself about one of them.

### Not settled — the author's own choices

Everything below is the author's own choice, supplied because the document needed
something there. Nobody has checked any of it. Findings against these are the most useful
thing this review can return.

**Structural choices (§4):**

- Several small rule files inside one application directory, rather than one large
  `prometheusrule.yaml` per domain. Purely the author's taste.
- Which domains get an alerts application: media, monitoring, networking. No alerts
  application is proposed for `kube-system`, `storage`, or `security` — yet §7 identifies
  `security` and Longhorn as having zero rules and names them as gaps. Whether the scheme
  actually covers the gaps it identifies is unexamined.
- Consolidating every rule onto `namespace: monitoring`. The spec itself calls this
  cosmetic. Its only claimed payoff is deleting a repeated comment.
- Collapsing three validator scripts into one parameterised
  `scripts/validate/alerts.sh <domain>`. The parameterised shape is assumed, not designed.
- Deleting `EncodeBenchmarkJobCompleted` outright rather than moving it. Listed as an open
  question in §11, but §4 states the deletion as decided — the two may not agree.

**Stage 2 choices (§5):**

- The repository-lint invariant "every `PrometheusRule` in the tree appears in some
  promtool test file." Both the invariant and its enforcement point are invented here.
- Standardising test filenames on `tests/prometheus/<domain>-alerts_test.yaml`.

**Stage 3 mechanism (§6) — the highest-risk section:**

- The central technical claim is the author's, made from reading committed config rather
  than from querying a live Prometheus (this worktree has no cluster credentials): that
  "zero forwarded flows" **cannot** be expressed as `== 0`, because when a workload has
  never reached a destination no `hubble_flows_processed_total{verdict="FORWARDED"}`
  series exists for that pair, and a missing series is not a zero — so the rule requires
  `unless` with both sides aggregated to a common label set first, since the flow metric
  carries `protocol`/`subtype`/`type` labels the drop metric does not. **This is
  load-bearing and unverified against a running Prometheus.** If it is wrong the rule is
  wrong; if it is right and ignored, the rule never fires and does so silently.
- The claim that after stage 1 exactly **five** destinations can produce `POLICY_DENIED`
  from a workload source (plex, alertmanager-ntfy, ntfy, portainer, test-reports), on the
  grounds that there is no default-deny and no `CiliumClusterwideNetworkPolicy`.
- Placing the policy-denied rules in `networking/alerts/` rather than a cluster-level
  location. The handoff explicitly left placement open and told the implementer to ask.
- **Reopened by the author, not yet ruled on by the user:** the handoff specified matching
  in-cluster sources with `source=~"k8s:.*"`, which anchors at the start of the identity
  string. The author argued matching the namespace label as a substring is more robust and
  that this is a correctness question rather than a preference. The spec does not state
  which form it adopts.
- No concrete thresholds appear for `PolicyDeniedSustained` — "sustained denials" is not
  quantified anywhere in the document.

**Stage 4 and 5 choices (§7, §8):**

- Stage 4 covers the Gatus gap plus certificate expiry, while deferring Longhorn volume
  health and trivy findings. The split is the author's.
- The `runbook_url` annotation recommendation.
- The sizing claim that stage 5 is "larger than stages 1 through 4 combined," and that
  exportarr sidecars plus ServiceMonitors are the likely shape.

**Risk claims (§10):**

- That stages are ordered such that "no rule moves in the same pull request that changes
  its expression." Asserted; whether the stage definitions actually guarantee it is
  unchecked.

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

<!-- built-for: client=codex delivery=capture independence=different-client spec-sha256=76258823f3fc1e7f -->

<!-- dispatched: client=codex model=gpt-5.6-sol effort=medium resolved-from=/Users/ksiggins/.codex/config.toml at=2026-08-13T15:19:34 -->
<!-- invocation: codex exec -C /Users/ksiggins/Development/homelab-talos.dispatch-policy-denied-alert -s read-only -o /Users/ksiggins/Development/homelab-talos.dispatch-policy-denied-alert/docs/decisions/reviews/2026-08-13-alerting-architecture-review.md - < /Users/ksiggins/Development/homelab-talos.dispatch-policy-denied-alert/docs/decisions/reviews/2026-08-13-alerting-architecture-request.md -->

<!-- dispatched: client=codex model=gpt-5.6-sol effort=medium resolved-from=/Users/ksiggins/.codex/config.toml at=2026-08-13T15:19:46 -->
<!-- invocation: codex exec -C /Users/ksiggins/Development/homelab-talos.dispatch-policy-denied-alert -s read-only -o /Users/ksiggins/Development/homelab-talos.dispatch-policy-denied-alert/docs/decisions/reviews/2026-08-13-alerting-architecture-review.md - < /Users/ksiggins/Development/homelab-talos.dispatch-policy-denied-alert/docs/decisions/reviews/2026-08-13-alerting-architecture-request.md -->
