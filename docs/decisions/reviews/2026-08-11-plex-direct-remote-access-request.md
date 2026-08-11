# Spec Review Request

You are a second opinion on a written specification. It was written by claude-code; you are running in a different client, so you do not share its context. That difference is the whole reason you were asked.

Two people have already read this spec: the model that wrote it, which shares
every blind spot that produced it, and the human who commissioned it, who knows
what they meant and so skims for "does this match what I said." Both reliably
miss the same four things. Those four things are your entire job.

**Spec under review:** /Users/ksiggins/Development/homelab-talos.investigate-plex-remote-access/docs/decisions/2026-08-11-plex-direct-remote-access.md
**Written by:** claude-code
**Spec SHA-256 (first 16):** 3809e775bd89777f
**Deliver your review as:** your entire final message (it is captured automatically — you cannot write files)

Read the spec in full before writing anything.

---

## Intent

This is ground truth. The spec is an attempt to express what follows. Where the
two disagree, this section is right and the spec is wrong.

### The original ask

The operator wants their Sonos speakers to appear in Plexamp and actually play music,
without AirPlay. That is the whole objective. Every gateway, DNAT, DNS record, and
exporter in this investigation exists only in service of it.

Their framing across the session, roughly in order: "relay failed... it's time for the
next rank item"; "evaluate design spec and plans on this subject to understand what is
next step and weigh the risk"; and, when I concluded the experiment had failed,
"instead of giving up, what are next steps to troubleshoot speaker connection?".

The second, equally load-bearing part of the ask is that **nothing local may break**.
They repeatedly verified Apple TV, native Sonos, Plexamp local, Tautulli, Homepage, and
Gatus after every change, and treated a local regression as disqualifying regardless of
whether the Sonos objective was met.

Background the spec assumes: a previous decision built a dedicated public Envoy Gateway
for this, it was fully implemented and measured, and it failed its acceptance gate —
Plexamp could switch to a Sonos player but audio never started. This spec is the
replacement.

### Stated constraints

**Local playback must not regress.** Inherited unchanged from the superseded amendment's
§2 and enforced by the operator in practice. Apple TV, native Sonos, Plexamp "This
device", Plex iOS, Tautulli, Homepage, and Gatus must keep working. The objective
succeeding while a hard row regresses is a failed experiment.

**Teardown of the existing public machinery is deferred until the replacement is
proven.** Asked for explicitly: "let's do 1 [revert everything] but save it after we
proved port forward 32400 actually works and we truly don't need the machinery currently
implemented." The superseded public Envoy Gateway, DDNS drift exporter, Cloudflare A
record, UniFi DDNS entry, and scoped token all stay live until stage 3 passes. This is
why the spec's stage 4 exists rather than the teardown being part of stage 1.

**Repository policy, non-negotiable and not the spec's to change:** accepted decision
records are superseded, never revised. No live public IPv4/IPv6 address, credential, or
other unique infrastructure identifier may appear in any committed artifact. Cluster
rollouts, UniFi actions, and guarded recipes are operator-run; the agent stages and
validates source only.

**Ruled out earlier and still out:** Cloudflare Tunnel and Tailscale Funnel for media
delivery, a VPS relay, cluster-wide transparent encryption (WireGuard), and public IPv6
or any AAAA record.

**Ruled out during this session:** the zero-Internet-exposure branch. The operator
initially chose it, then reversed after being shown that its only viable mechanism
(`hostNetwork` on Plex) removes Cilium policy enforcement entirely — verified against
Cilium's documentation and the cluster's `enable-host-firewall = false` — and would
require a cluster-wide CNI change plus host policies covering kube-apiserver and etcd.
Their instruction after seeing that: "go with port forward option."

### Decisions already approved

**Direct WAN `32400` is the selected path, over the zero-exposure alternative.** This was
argued at length and reversed once, so it is genuinely closed. The operator was shown
both branches with their costs — the zero-exposure branch requiring `hostNetwork` (which
verifiably removes all Cilium policy enforcement) plus enabling the host firewall
cluster-wide, versus §8.3's one Service, one policy edit, one DNAT for a single risk row
moving from Low–medium to Medium — and chose the port forward. A finding that
re-argues "you should not expose Plex directly" is relitigation.

**Accepting `Medium · High` for Plex process compromise.** The direct consequence of the
above, taken knowingly from the operator's own risk register.

**Superseding rather than amending the 2026-08-03 decision.** Required by repository
policy; the record's status-line transition is machine-validated.

**Relay remains the fallback and is not being removed.** It demonstrably works and is
currently serving native Sonos.

**Deferring the public-plane teardown to stage 4.** Explicitly requested; see constraints.

Findings that reopen an approved decision are the most common way a spec review
wastes everyone's time, so treat that list as closed unless the spec contradicts
itself about one of them.

### Not settled — the author's own choices

**The central hypothesis is unproven, and everything rests on it.** §2.2 claims the Sonos
speaker failed because the published connection was not a `*.plex.direct` name it could
validate, and that direct `32400` fixes this by making Plex publish one. This is
consistent with all observed evidence but has never been demonstrated. If it is wrong,
the design does not meet the objective. Attack this first.

**The specific configuration the design depends on has never been measured.** Only two
states were tested:

| `customConnections` | Public path | Local clients | Sonos cast |
|---|---|---|---|
| set | Envoy on 443 via DNAT | full bitrate | fails |
| cleared | none | all fall to Relay | plays |

The design requires a third, unobserved combination: **`customConnections` set *and*
direct `32400` exposed**. The reasoning is that the two serve different clients — local
clients follow the custom URL, the speaker follows the new `plex.direct` connection — but
nothing rules out the custom URL still taking precedence for the speaker and reproducing
the original failure. §7 stage 2's gate exists to catch this, but the spec presents the
outcome more confidently than the evidence supports.

**`externalTrafficPolicy: Local`, and the `world:32400` policy rule it forces.** I chose
this over `Cluster`, which would need no policy change at all. The trade is client-IP
attribution versus leaving the containment policy untouched. The operator was shown both
and did not discuss either; treat it as unexamined.

**`192.168.90.31` from the existing `internal` pool, with no dedicated pool.** The
superseded design mandated a dedicated pool; I dropped that, arguing `autoAssign: false`
plus an explicit address gives the same stability without repeating a MetalLB admission
deadlock that froze this cluster earlier in the week. Nobody checked that reasoning.

**Default port `32400` rather than a non-standard external port.** Chosen to keep the
proving run to one variable. It maximises drive-by scanning against the best-known Plex
port.

**The entire staging structure and every gate criterion in §7**, including which
observable proves stage 2 — Plex's mapping state leaving `Not Published (Not
Reachable)`. That state has never been seen to change in this environment, so the gate
may not be observable in the way §7 assumes.

**Every risk rating delta in §9** — which rows move, which improve, and by how much. In
particular the claims that configuration regression *improves* to `Low · Medium` and that
TLS key compromise improves to `Low · Low`.

**The three corrections in §4 to earlier accepted records.** These are my readings of
other decisions, asserted as fact in a durable record. The Relay-loopback explanation for
the containment capture's false inference is the one most worth checking against the
repository.

**Whether superseding the amendment in full is correct**, given it also carried
containment work that §1.2 says is retained. There is no partial-supersession mechanism
in the validated format, so full supersession plus a retention list was my construction.

**The validation list in §10**, the rollback ordering in §8, and the assertion that
removing the DNAT alone constitutes complete rollback.

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

<!-- built-for: client=codex delivery=capture independence=different-client spec-sha256=3809e775bd89777f -->

<!-- dispatched: client=codex model=gpt-5.6-sol effort=medium resolved-from=/Users/ksiggins/.codex/config.toml at=2026-08-11T11:58:03 -->
<!-- invocation: codex exec -C /Users/ksiggins/Development/homelab-talos.investigate-plex-remote-access -s read-only -o /Users/ksiggins/Development/homelab-talos.investigate-plex-remote-access/docs/decisions/reviews/2026-08-11-plex-direct-remote-access-review.md - < /Users/ksiggins/Development/homelab-talos.investigate-plex-remote-access/docs/decisions/reviews/2026-08-11-plex-direct-remote-access-request.md -->

<!-- dispatched: client=codex model=gpt-5.6-sol effort=medium resolved-from=/Users/ksiggins/.codex/config.toml at=2026-08-11T11:58:18 -->
<!-- invocation: codex exec -C /Users/ksiggins/Development/homelab-talos.investigate-plex-remote-access -s read-only -o /Users/ksiggins/Development/homelab-talos.investigate-plex-remote-access/docs/decisions/reviews/2026-08-11-plex-direct-remote-access-review.md - < /Users/ksiggins/Development/homelab-talos.investigate-plex-remote-access/docs/decisions/reviews/2026-08-11-plex-direct-remote-access-request.md -->
