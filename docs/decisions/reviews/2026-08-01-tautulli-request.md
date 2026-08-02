# Spec Review Request

You are a second opinion on a written specification. It was written by claude-code; you are running in a different client, so you do not share its context. That difference is the whole reason you were asked.

Two people have already read this spec: the model that wrote it, which shares
every blind spot that produced it, and the human who commissioned it, who knows
what they meant and so skims for "does this match what I said." Both reliably
miss the same four things. Those four things are your entire job.

**Spec under review:** /Users/ksiggins/Development/homelab-talos.tautulli-monitoring-addition/docs/decisions/2026-08-01-tautulli.md
**Written by:** claude-code
**Spec SHA-256 (first 16):** 104234d67e1022ac
**Deliver your review as:** your entire final message (it is captured automatically — you cannot write files)

Read the spec in full before writing anything.

---

## Intent

This is ground truth. The spec is an attempt to express what follows. Where the
two disagree, this section is right and the spec is wrong.

### The original ask

"I'd like to add Tautulli to my media stack." A three-node Talos + Flux homelab
already running Plex plus the full `*arr` chain; the operator wanted Plex viewing
analytics — who watched what, when, on what device.

Two things reframed the work mid-conversation, both operator-initiated:

1. They challenged whether Tautulli notifications were worth anything: *"for the
   plex server down, wouldn't I get that from gatus? what unique alerts would I
   get that I don't already from my stack?"* Investigating that turned up a real
   gap — Gatus probes Plex every minute but **no PrometheusRule reads the Plex
   probe**, so a Plex outage turned a dashboard tile red and paged nobody. Closing
   that gap became part of the work.

2. They then said plainly: *"I want a notification if a service is down, since
   obviously it's not functioning and requires attention, no it's not critical if
   it's media, so homelab warning is good."* And separately: *"down being over
   some period of time, as updates do occur, right?"* — which is what drove the
   `for: 15m` window.

They also asked the author to interrogate the repo's own two-PR staging ritual
(*"does the 2 PR staging make sense or is this just busy work?"*) and explicitly
asked for out-of-the-box thinking there rather than deference to existing
convention.

### Stated constraints

**Repository invariants** (from `AGENTS.md`, not negotiable in this spec):

- Never commit or push to `main`; work on the feature branch.
- All workflows run through the pinned toolchain as `mise exec -- just …`. Never
  raw `kubectl`/`talosctl`/`helm`/`flux` against the live cluster.
- `mise exec -- just ci` is the canonical cluster-independent validation; the
  cluster-dependent `*-verify` / `*-preflight` recipes stay out of it.
- All secrets SOPS-encrypted; the age key never leaves the operator.
- New apps begin suspended, roll out through a guarded recipe, then persist the
  unsuspended state.
- Flux app layout is `kubernetes/apps/<domain>/<app>/{ks.yaml, app/, config/}`.
- A Deployment mounting an RWO PVC uses `Recreate`, never `RollingUpdate`.

**Ruled out during the conversation:**

- **ntfy notifications from Tautulli** — the operator accepted the author's
  recommendation to defer. `docs/ntfy-startup-guide.md` §G already forbids direct
  Plex/`*arr` ntfy producers. Reasoning is in §10.1; the operator explicitly asked
  for that reasoning to be recorded in the spec.
- **Hand-configuring an ntfy agent in Tautulli's web UI** — rejected outright as
  it would create an ntfy producer token absent from `identities.yaml`, breaking
  the declarative credential model.
- **Prometheus stream/transcode metrics via a sidecar exporter** — out of scope.
- **Newsletters** and **any watch-history import** — out of scope; greenfield.
- **Migrating the existing `seerr`/`flaresolverr` bootstrap recipes** into the new
  parameterized one — deliberately not done (D10).

**Relevant environment facts:** the operator keeps their phone outside the
bedroom, so ntfy `urgent` priority buys nothing and severity is a filing/routing
decision, not a wake-me one. Plex was migrated into the cluster from a Mac mini,
so its config PVC holds an irreplaceable library database.

### Decisions already approved

Each of these was put to the operator explicitly and chosen by them.

1. **Greenfield history.** No Tautulli database import; history starts at rollout.
2. **Stats-only scope** (approach A of three offered). Tautulli provides the
   dashboard and history; no notification path from it. See §10.1.
3. **Fold the Plex alerting gap into this work** rather than shipping it
   separately or skipping it.
4. **Generic `MediaEndpointDown` over `group="Media"`** instead of per-app down
   rules — chosen after being shown both. This knowingly widens alerting to
   Sonarr, Radarr, Lidarr, Prowlarr, Seerr, and FlareSolverr; the operator wanted
   that.
5. **`severity: warning` → `homelab` topic for media availability**, reserving
   `critical` for data/privacy events. Their words: "no it's not critical if it's
   media, so homelab warning is good."
6. **Keep the two-PR staging, kill the copy-paste** — after the author argued the
   staging is load-bearing only because of a data dependency (the Homepage widget
   needs an API key that cannot exist before first run), and that the real waste
   was 62 lines of near-identical bash. The operator chose staging plus a
   parameterized recipe over both a third copy and dropping staging entirely.
7. **No Chainsaw smoke, resilience, or automated E2E** (D8), after the operator
   asked directly whether they were warranted.
8. **Tautulli web authentication as a blocking pre-activation gate** (D13),
   accepted from a prior review round.
9. **Media alert rules isolated in a dedicated `media-alerts` Kustomization**
   (D12) rather than adding `kube-prometheus-stack` to the media app
   Kustomizations — accepted from a prior review round.
10. **Keep the bootstrap recipe despite the accepted agent rules audit**
    superseding it (D15/§6.4), because that audit is unimplemented, unpushed, and
    on another branch.

Items 8, 9 and the per-endpoint `absent()` rules (D14) came from an earlier code
review of this same spec and are already applied — do not re-report them as new.

Findings that reopen an approved decision are the most common way a spec review
wastes everyone's time, so treat that list as closed unless the spec contradicts
itself about one of them.

### Not settled — the author's own choices

Everything below was supplied by the author because the spec needed a value, not
because anyone chose it. Findings here are wanted.

**Health endpoint — the largest unknown.** `/status` is asserted as Tautulli's
web health path, gating three kubelet probes *and* the Gatus endpoint (§4.1). The
author could not verify its behaviour on
`ghcr.io/home-operations/tautulli:2.17.2`, and deliberately dropped an earlier
claim that it returns JSON. The auth interaction (§8.3 gate 2) is reasoned, not
tested — if enabling authentication turns `/status` into a login redirect, four
things break at once. The `tcpSocket` fallback is asserted to work but unverified.

**Probe thresholds** (§4.1): readiness 10s/3, liveness 30s/5, startup 5s/30.
Copied from the Seerr shape, not measured against Tautulli's actual startup time
on a cold SQLite database.

**Alert timings and severities** (§5.2). `for: 15m` on `MediaEndpointDown` is
derived in §7.1 from Plex's `terminationGracePeriodSeconds: 120` plus a 300s
startup budget — arithmetic, not observation, and it is applied uniformly to every
media endpoint including ones that restart in seconds. `for: 5m` on the PVC rules
and `15m` on the probe-missing rules are unjustified beyond symmetry. The
`plex` = critical / `tautulli` = warning PVC split is the author's judgement.

**Scope of `absent()` coverage** (D14, §5.3). Only `plex` and `tautulli` get
per-endpoint absence rules; six other endpoints are covered for *down* but not for
*silently removed*. The author calls this a deliberate bounded gap — it may be the
wrong boundary.

**`qbittorrent-vpn` exclusion** from `MediaEndpointDown`, on the grounds that it
has its own critical rule. Not verified against how Alertmanager would actually
group or inhibit the two.

**Sizing and placement.** 5Gi config PVC, `kubernetes/apps/media/alerts/` as the
Kustomization path, `dependsOn: [internal-gateway, media]`, image pin `2.17.2`,
port `8181`. **The spec never specifies CPU/memory requests or limits at all** —
every sibling app sets them, so this is an omission rather than a decision.

**Bootstrap safety contract** (§6.2). The 13-path `require_deployed_source`
closure was assembled by the author by inspecting the `arr` recipe; whether it is
complete for Tautulli is unchecked. The `tautulli`-only allowlist is a choice.

**PR boundary reasoning** (§8.1). The author moved the two `tautulli` `absent()`
rules to PR 2 on the reasoning that they would otherwise fire against a
deliberately-suspended app. The rest of the PR-1/PR-2 split follows from that
logic and has not been independently checked.

**Post-activation gates** (§8.5) describe *what* to verify but not *how* — "every
rule appears in Prometheus's active rule set with no evaluation errors" has no
named command or recipe behind it.

**Deliberately not fixed:** `qbittorrent` owns a PrometheusRule without a
`kube-prometheus-stack` dependency — the same deadlock D12 exists to prevent. The
author flagged it (§10) rather than fixing it, to avoid changing a live app's
dependency graph inside this work. That call is open to challenge.

**Repo-mechanical:** §6.3 requires bumping the hardcoded `-eq 24` rollout-guard
count at `.just/repository.just:1206` to 25. This was found late; verify the count
is actually 24 today and that 25 is right.

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

<!-- built-for: client=codex delivery=capture independence=different-client spec-sha256=104234d67e1022ac -->

<!-- dispatched: client=codex model=gpt-5.6-sol effort=high resolved-from=/Users/ksiggins/.codex/config.toml at=2026-08-02T10:06:15 -->
<!-- invocation: codex exec -C /Users/ksiggins/Development/homelab-talos.tautulli-monitoring-addition -s read-only -o /Users/ksiggins/Development/homelab-talos.tautulli-monitoring-addition/docs/decisions/reviews/2026-08-01-tautulli-review.md - < /Users/ksiggins/Development/homelab-talos.tautulli-monitoring-addition/docs/decisions/reviews/2026-08-01-tautulli-request.md -->

<!-- dispatched: client=codex model=gpt-5.6-sol effort=high resolved-from=/Users/ksiggins/.codex/config.toml at=2026-08-02T10:06:25 -->
<!-- invocation: codex exec -C /Users/ksiggins/Development/homelab-talos.tautulli-monitoring-addition -s read-only -o /Users/ksiggins/Development/homelab-talos.tautulli-monitoring-addition/docs/decisions/reviews/2026-08-01-tautulli-review.md - < /Users/ksiggins/Development/homelab-talos.tautulli-monitoring-addition/docs/decisions/reviews/2026-08-01-tautulli-request.md -->
