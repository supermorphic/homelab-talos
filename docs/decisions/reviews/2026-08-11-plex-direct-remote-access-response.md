# Spec Review Response

**Spec:** docs/decisions/2026-08-11-plex-direct-remote-access.md
**Review:** docs/decisions/reviews/2026-08-11-plex-direct-remote-access-review.md
**Reviewer verdict:** Not ready — the specified Plex settings can regress local discovery, the stage-2 gate contradicts measured evidence, and rollback does not terminate established exposure
**Independence:** different-client (GPT-5.6-sol / Codex; spec written by claude-code)

All four findings were verified against their own cited evidence. All four held. Three
were fixed; one was fixed in part, with its remaining design choice surfaced below.

## For you to decide

**All four items below were resolved by the operator on 2026-08-11. Their dispositions
are recorded inline; nothing here is outstanding.**

### 1. How an established session is terminated after the DNAT is removed

**From F3.** The spec now says plainly that removing the DNAT blocks new connections but
does not necessarily drop sessions UniFi already holds in conntrack. What it does *not*
do is choose the mechanism that ends them, because that is a live design trade rather
than a determinate correction.

The superseded design could flush by restarting the public Envoy, which never touched
local playback because local clients used a different data plane. Under direct exposure
Plex is itself the listener, so the equivalent action interrupts every client at once.

Candidate mechanisms, none selected:

- **Restart the Plex Deployment.** Certain to drop everything, and drops local playback
  with it. The config PVC is `ReadWriteOncePod` with a `Recreate` strategy, so this is a
  brief full outage rather than a rolling one.
- **Clear the conntrack entry on UniFi.** Targets only the forwarded flow and leaves
  local playback alone, but it is a gateway-side operation with no repository recipe and
  no guarded workflow behind it.
- **Accept the gap.** Treat rollback as blocking new exposure, and rely on the session
  ending on its own. Weakest, and it means "rollback" no longer means what it meant in
  the superseded design.

**RESOLVED — restart the Plex Deployment.** Chosen by the operator for the case that
matters: evicting an intruder. §8 now names it as step 2, states plainly that it
interrupts local playback and is a short full outage rather than a rolling restart, and
scopes it to eviction rather than ordinary teardown. The router-side conntrack flush is
recorded as a possible later improvement, explicitly rejected for now because inventing
an unrehearsed gateway operation during an incident is a bad plan.

### 2. The central hypothesis is still unverified

**Reviewer grounding, marked UNVERIFIED.** The reviewer checked whether Plex documents
that a retained custom connection plus a direct `32400` publication causes Sonos to
select the native `plex.direct` connection. It found that Plex documents custom URLs
being published to plex.tv, but **does not document client-specific connection
precedence**. The measured states do not include that combination.

This is the same gap flagged in the request, now independently confirmed rather than
merely self-reported: the exact configuration this design depends on has never been
observed, and no vendor documentation establishes it. The exposure stage's gate exists to
catch it, but the design could still fail for this reason.

**RESOLVED — accepted, with the wording kept and the test run early.** The operator
accepts that the record's central claim is an inference and wants it falsified quickly
rather than hedged in prose. The Plex log lines that diagnosed the original failure will
answer it within minutes of the DNAT existing.

### 3. Whether `192.168.90.31` is genuinely free outside the cluster

**Reviewer grounding, marked UNVERIFIED.** `.31` sits inside the `.30–.38`
`autoAssign: false` pool and no repository manifest requests it — that much is grounded.
Whether UniFi currently assigns it to a host, DHCP reservation, or other object was not
checkable from the repository. The README records `.30–.39` as excluded from DHCP, which
makes a collision unlikely but not proven. Worth a UniFi check before stage 1.

**RESOLVED — `.31` is free.** The operator confirmed the DHCP range begins at
`192.168.90.100`, and the only fixed assignments on that network are Pi-hole at `.2` and
the three nodes at `.10`–`.12`. Nothing outside the cluster claims `.31`.

### 4. The §4 correction rests on recorded evidence, not a live trace

**Reviewer grounding, marked UNVERIFIED.** The claim that the containment capture's
zero-ingress finding is explained by Relay terminating on pod loopback `127.0.0.1:32401`
was checked against the accepted 2026-08-02 design and the repository's Relay diagnostic,
and both support it. No fresh live Relay trace was collected during the review. The
correction stands on recorded evidence; if you want it stronger before it becomes the
durable account, a live trace would settle it.

**RESOLVED — noted, no trace required.** The operator accepted the correction on its
recorded evidence. The claim remains supported by the accepted 2026-08-02 design's own
description of Relay's loopback termination, the repository's Relay diagnostic, and the
observed `127.0.0.1` media fetches, rather than by a single combined live observation.
Recorded here so a future reader knows which it is.

### 5. Scope added after the review: detection before exposure

Not a reviewer finding. Raised by the operator after the review returned, and recorded
here so the boundary of what was reviewed stays clear.

The reviewed record acknowledged that Plex has no rate limiting and treated a denial of
service as answered by removing the DNAT. It contained no detection, no alerting, and no
log path. The cluster has none either: Hubble is enabled but `hubble-metrics` is not
configured, nothing scrapes Cilium or Hubble into Prometheus, and there is no log
collector, so Plex's per-request source addresses stay in its config PVC until they
rotate away.

The operator's instruction was "no exposure at all before detection." §7.1 now states
that as a hard gate and the staging table carries a new stage 2 for it, ahead of the
DNAT. Being attended is explicitly not accepted as a substitute.

**This section of the record was added after the review and is therefore not covered by
it.** The defence design itself is deferred to a companion decision rather than appended
here, which is why the reviewed content is otherwise intact.

## Ledger

### F1 — Defect — evidence holds — FIXED

**Verified:** the spec did specify manual public port `32400` alongside a portless custom
URL; the internal Gateway has exactly one listener (`HTTPS/443`, `*.lab.supermorphic.com`)
and the Plex route attaches to it via `sectionName: https`. Plex's documentation confirms
the mechanism: a custom URL without a port inherits the Remote Access port. The failure
trace follows exactly as described — Plex would publish
`plex.lab.supermorphic.com:32400`, Pi-hole resolves that to the internal VIP, nothing
serves `32400` there, and a rediscovering local client regresses.

**Determinate because** only one resolution preserves both a stated requirement (§5.1's
local path "not modified"; Intent's non-regression constraint) and an approved decision
(§8.3's manual public port matching the UniFi rule).

**Changed:** §6 now specifies `https://plex.lab.supermorphic.com:443/` with an explicit
port, and states why the port is not optional (was: `https://plex.lab.supermorphic.com/`).

### F2 — Contradiction — evidence holds — FIXED

**Verified:** both quotes are accurate. §3 states the mapping state remained
`Mapped - Not Published (Not Reachable)` in both measured states "including while Sonos
played… reachability state is therefore not the discriminator". §7 made leaving that
state the exposure-stage gate and called it "the precondition for Plex constructing the media
URL". A state observed during successful playback cannot be a precondition for it.

**Determinate because** §3 is grounded in direct measurement while §7's claim was
asserted without evidence, and §2.2 independently identifies the connection's *name* as
the mechanism. The reasoned side wins and the unreasoned side adapts.

**Changed:** §7's exposure-stage gate is now "Plex publishes a `*.plex.direct` remote
connection" (was: "Plex mapping state leaves `Not Published (Not Reachable)`"), and the
surrounding prose demotes the mapping state to an indicator, citing §3's measurement.
That stage was subsequently renumbered from 2 to 3 by the post-review scope addition.

### F3 — Defect — evidence holds — FIXED IN PART, MECHANISM SURFACED

**Verified:** the spec declared step 1 "Sufficient on its own" and "complete rollback",
and §11 repeated it. The repository's accepted runbook states directly that "DNAT
deletion blocks new exposure but might not terminate an established conntrack session"
and follows it with a guarded connection flush. The claim was false against the repo's
own accepted evidence.

**Determinate part:** correcting a false claim to an accurate one.
**Not determinate:** which mechanism replaces the Envoy flush, since the candidates have
materially different consequences and nothing in the spec or Intent chooses between them.
Surfaced above.

**Changed:** §8's table now reads "Blocks new connections in seconds. Established sessions
may survive", adds an explicit step 2 for termination, and states that step 1 is not
complete rollback and why the superseded flush does not carry over. §11's exposure-control
row corrected to match.

### F4 — Defect — evidence holds — FIXED

**Verified:** §7 stage 4 did say the Gateway, exporter, Cloudflare A record, UniFi DDNS
entry, and token are removed "each through a reviewed Git revert rather than a live
edit". The latter three are external state the operator created directly in Cloudflare
and UniFi; no Git change can delete, disable, or revoke them. The required teardown would
have been silently incomplete.

**Determinate because** only one correction is defensible: Flux-managed resources revert
through Git, external state requires operator action.

**Changed:** §7 stage 4 now separates the two mechanisms explicitly and names the token
revocation as the last operator action (was: a single "each through a reviewed Git
revert" clause).

## Notes

The reviewer confirmed the spec digest matched before reviewing, and its grounding
section shows it checked the actual manifests — `httproute.yaml`, `gateway.yaml`,
`ciliumnetworkpolicy.yaml`, `address-pool.yaml`, `kubernetes/mod.just`, and the runbook —
rather than reasoning from the spec alone. It also correctly marked three claims
UNVERIFIED rather than asserting them, including the one the request identified as
load-bearing.

No finding was rejected. No finding reopened an approved decision.
