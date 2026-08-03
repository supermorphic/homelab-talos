# Spec Review Request

You are a second opinion on a written specification. It was written by claude-code; you are running in a different client, so you do not share its context. That difference is the whole reason you were asked.

Two people have already read this spec: the model that wrote it, which shares
every blind spot that produced it, and the human who commissioned it, who knows
what they meant and so skims for "does this match what I said." Both reliably
miss the same four things. Those four things are your entire job.

**Spec under review:** /Users/ksiggins/Development/homelab-talos.investigate-plex-remote-access/docs/decisions/2026-08-03-plex-public-envoy-amendment.md
**Written by:** claude-code
**Spec SHA-256 (first 16):** 7b5a94e06d83039b
**Deliver your review as:** your entire final message (it is captured automatically — you cannot write files)

Read the spec in full before writing anything.

---

## Intent

This is ground truth. The spec is an attempt to express what follows. Where the
two disagree, this section is right and the spec is wrong.

### The original ask

"Make Sonos players appear in Plexamp and accept playback without AirPlay, while
preserving reliable local Plex / Plexamp / Apple TV playback."

The user also required, in their own words, that "security containment and a complete
ranked failure/risk assessment are mandatory" and that "all credible failure points are
exposed and addressed."

Background the user supplied: an earlier design (2026-08-02) selected Plex Relay and
claimed the Plex custom server access URL did not block the experiment. Later hands-on
testing disproved that. With the custom URL set, Sonos switching fails ("could not
switch to player"); with it cleared, Sonos works but Apple TV cannot connect at all and
Plexamp falls back to Relay. The user concluded the custom hostname must stay advertised
*and* become reachable from the Plex/Sonos cloud, and asked for an additive amendment
that supersedes only the Relay-first remote-path choice.

This is an experiment authorisation, not a permanent-configuration proposal. The user
was explicit that permanence is a later, separate decision.

### Stated constraints

**Ruled out, explicitly and non-negotiably:**

- Forwarding any WAN traffic to the existing shared internal Envoy Gateway.
- Any wildcard public route.
- Exposing any Envoy admin or control endpoint.
- Cloudflare Tunnel, and Cloudflare proxy (`proxied=true`).
- Tailscale Tunnel or Funnel.
- Public IPv6 / any AAAA record, until IPv6 receives its own separate firewall design.
- Accepting a Cloudflare **Global API Key**. If UniFi will not work with a
  least-privilege scoped token, the user directed that the DDNS mechanism be rejected
  outright and the design returned to brainstorming — never a global key "to make it
  work."
- Clearing the Plex custom server access URL (tested and rejected: it breaks Apple TV).
- Modifying internal DNS, the internal Envoy route, the internal certificate, or the
  custom URL as part of the public experiment.

**Ruled in / required:**

- Relay stays enabled as a best-effort fallback.
- **Failure-domain invariant**, stated by the user: failure of public DNS, UniFi DDNS,
  the WAN DNAT, or the external Envoy must not cross into the internal Plex path. Apple
  TV, Plex iOS, Plexamp local, internal browser access, and in-cluster integrations must
  keep working. Plexamp-to-Sonos failing is the acceptable consequence.
- The Cilium policy must be deployed and proven *before* opening WAN ingress, and every
  current internal consumer tested before public activation.
- The risk assessment must reuse the **same qualitative likelihood/impact scale** as the
  2026-08-02 register and show explicit deltas across three columns (Relay baseline,
  direct Plex exposure, dedicated external Envoy). The user specifically said: do not
  create an unrelated replacement risk table.
- Exposure likelihood must be rated **separately** from successful-exploitation
  likelihood, not combined.
- Diagrams must follow the existing pattern: editable SVG source kept, PNG generated,
  PNG embedded in the Markdown, SVG source linked. Reuse the existing deterministic
  generation process rather than introducing a brittle new generator.
- Supersede **only** the Relay-first remote-path selection and the acceptance claims
  resting on it. Preserve the Relay identity fix, pod hardening, read-only media, and
  the containment analysis. Do not rewrite completed implementation history.

**Repository/process constraints (from AGENTS.md, binding on the resulting plan):**

- All cluster mutations and health checks go through guarded `just` recipes, run by the
  operator. Never raw `kubectl`/`talosctl`/`helm`/`flux` against the live cluster.
- Cluster-dependent `*-verify` / `*-preflight` recipes stay out of `just ci`.
- The repository is **public**. No live public IP addresses, hardware serials, or MAC
  addresses may be committed, and residual risk must not be published as a dated
  schedule of undefended items.
- The operator creates and holds all Cloudflare/UniFi credentials; the agent never
  handles plaintext secrets.

### Decisions already approved

Each of these was presented as an option set and explicitly chosen by the user. Several
were argued before settling — they are closed.

1. **Option ranking:** (1) dedicated public Envoy on one WAN TCP 443 DNAT — the selected
   experiment; (2) direct public Plex VIP/port — fallback, not enabled here; (3) Relay —
   fallback only.
2. **Split horizon on the existing hostname.** Same FQDN `plex.lab.supermorphic.com` on
   both sides. The user was offered a separate, non-obvious public hostname (which would
   avoid Certificate-Transparency disclosure of the `plex` name) and declined, keeping
   the single FQDN.
3. **DDNS:** UniFi-managed, Cloudflare authoritative, `proxied=false`, A record only,
   short TTL, internal Pi-hole record untouched. Rationale accepted: UniFi observes the
   WAN lease directly; a Kubernetes ExternalDNS controller would publish the private
   MetalLB VIP.
4. **TLS — option "A2":** a dedicated certificate for `plex.lab.supermorphic.com` only.
   The alternatives (reuse the existing wildcard secret; issue a second separately-keyed
   wildcard) were both presented with their trade-offs and rejected. The CT disclosure
   cost was stated plainly and accepted.
5. **Public Gateway in its own namespace**, so referencing the wildcard secret would
   require a ReferenceGrant that will not exist. The alternative (`from: Same` with a
   ReferenceGrant from `media`) was offered and declined.
6. **Backend hop stays plaintext.** BackendTLSPolicy rejected; Cilium WireGuard named as
   the correct fix and placed out of scope.
7. **Monitoring — option "A":** no scheduled externally-hosted probe. Operator-run
   external checks at the gates, plus an internal credential-free DDNS drift check. The
   GitHub-Actions-hosted probe and a third-party uptime monitor were both offered and
   declined.
8. **Isolation model:** seven controls with the exact-hostname listener as the primary,
   specification-guaranteed control.
9. **Two new gated steps**, added after repo inspection: a Hubble flow capture before the
   Cilium policy is written, and widening the Envoy Gateway controller watch selector as
   an independent, regression-gated step.
10. **A CI assertion pinning Plex's securityContext.** The user was offered the option to
    drop this and the option to relocate Plex out of the PSA-`privileged` `media`
    namespace; they chose to keep the CI assertion and leave the namespace move out.
11. **Six-phase staged sequence with seven hard gates**, exposure confined to a single
    reversible UniFi rule in phase 5. Offered variants (splitting 2a earlier, time-boxing
    phase 5) were declined.
12. **Client acceptance matrix:** 11 rows, run twice (phase 0 baseline, phase 5 live),
    Sonos switching as the sole primary objective, path determined by Envoy pod address +
    public access log + bitrate rather than Plex's route label, with forced client
    re-discovery before each row. Offered additions (a second Sonos zone; promoting
    off-site to a hard gate) were declined.
13. **Rollback:** five steps where step 1 alone ends exposure; containment (2a/2b/2c)
    **retained** on failure; rollback rehearsed live during phase 5. The alternative of
    fully reverting everything on failure was offered and declined.
14. **Risk register:** exposure/exploitation split, deltas across the three options,
    16 new risks. Offered variants (raising configuration regression to Medium·High; a
    separate signed-off accepted-risk section) were declined.
15. **UPnP/NAT-PMP confirmed disabled** as a required negative control, and Plex Remote
    Access left **enabled** with no manual public port (because Relay depends on it).

Findings that reopen an approved decision are the most common way a spec review
wastes everyone's time, so treat that list as closed unless the spec contradicts
itself about one of them.

### Not settled — the author's own choices

Everything below is the author's own choice, supplied because the document needed
something there. The user approved the *shape* of several of these by approving the
section they sit in, but never evaluated the specific value or mechanism. Findings here
are the most useful thing this review can return.

**Names and identifiers — invented wholesale:**

- Namespace `networking-public`; GatewayClass `public`; MetalLB pool `public`.
- The route-admission label `gateway.supermorphic.com/public-plex: "true"`.
- The `matchExpressions … operator: In, values: [internal, public]` form chosen to widen
  the controller watch selector.

**Values the user did not pick:**

- **TTL 300.** The user approved a range of "120–300 seconds"; the author picked the top
  of it with no stated reason.
- The individual likelihood·impact cells throughout §15.2 and §15.3. The user approved
  the framework and the table as a whole; no cell was argued individually.
- "Token expiry" is named as the principal compensating control for a zone-scoped
  Cloudflare token, but **no duration is specified**.
- Which matrix rows are Hard versus Soft, and the acceptance rule "row 1 plus rows 2–5
  and 9–11 match baseline."

**Mechanisms the author supplied:**

- The **DDNS drift check** (§9): fetch the WAN address from an IP-echo endpoint, resolve
  the public A record from a public resolver, compare, alert via ntfy. The user approved
  "an internal drift check" as a concept; this mechanism, its schedule, where it runs,
  what workload kind it is, and which IP-echo endpoint it trusts are all unspecified or
  author-chosen.
- The **13 negative tests** in §13 — their content, grouping, and numbering.
- The specific consumer list the Hubble capture window must contain (§7.1).
- Using the **Gateway-owner pod label** to distinguish the two Envoy data planes, and the
  accompanying claim about Envoy Gateway's default deployment mode.
- Rollback **steps 2–5** and their ordering. Only "remove the DNAT first" came from the
  user.
- Recording rather than changing Plex's "Secure connections" value.

**Assertions the author made that nobody has checked:**

- That no SMB egress rule is needed because the media share is mounted by the CSI driver
  on the node rather than by the pod.
- That `external-dns` "cannot and will not touch Cloudflare or the public record."
- That phases 0–4 are all reversible and none of them makes Plex reachable.
- That removing the DNAT (step 1) is *sufficient on its own* as a rollback.
- That Envoy Gateway provisions infrastructure per Gateway.
- The characterisation of Plex's `plex.direct` certificate — that the hash derives from
  the server address and that the chain rotates on Plex's schedule — used to reject
  BackendTLSPolicy.
- That a sustained bitrate above 2 Mbps is definitive proof a session is not on Relay.

**Known gaps the author left, deliberately or otherwise:**

- The public Envoy's replica count, resource requests, and PodDisruptionBudget are never
  specified — the spec only says to mirror the internal EnvoyProxy config.
- Access logging on the public data plane is *required* for attribution, but its format,
  destination, and retention are unspecified.
- The dedicated certificate's key algorithm and size are unspecified (the existing
  wildcard is ECDSA P-256).
- Envoy connection/rate limits are explicitly noted as not configured, with public
  denial of service accepted as a Medium·Medium risk.

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

<!-- built-for: client=codex delivery=capture independence=different-client spec-sha256=7b5a94e06d83039b -->

<!-- dispatched: client=codex model=gpt-5.6-sol effort=high resolved-from=/Users/ksiggins/.codex/config.toml at=2026-08-03T05:35:09 -->
<!-- invocation: codex exec -C /Users/ksiggins/Development/homelab-talos.investigate-plex-remote-access -s read-only -o /Users/ksiggins/Development/homelab-talos.investigate-plex-remote-access/docs/decisions/reviews/2026-08-03-plex-public-envoy-amendment-review.md - < /Users/ksiggins/Development/homelab-talos.investigate-plex-remote-access/docs/decisions/reviews/2026-08-03-plex-public-envoy-amendment-request.md -->

<!-- dispatched: client=codex model=gpt-5.6-sol effort=high resolved-from=/Users/ksiggins/.codex/config.toml at=2026-08-03T05:35:17 -->
<!-- invocation: codex exec -C /Users/ksiggins/Development/homelab-talos.investigate-plex-remote-access -s read-only -o /Users/ksiggins/Development/homelab-talos.investigate-plex-remote-access/docs/decisions/reviews/2026-08-03-plex-public-envoy-amendment-review.md - < /Users/ksiggins/Development/homelab-talos.investigate-plex-remote-access/docs/decisions/reviews/2026-08-03-plex-public-envoy-amendment-request.md -->
