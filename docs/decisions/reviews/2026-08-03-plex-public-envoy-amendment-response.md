# Spec Review Response

**Spec:** docs/decisions/2026-08-03-plex-public-envoy-amendment.md
**Review:** docs/decisions/reviews/2026-08-03-plex-public-envoy-amendment-review.md
**Reviewer verdict:** Not ready — route admission and Cilium containment do not enforce
their stated boundaries, and one hard gate cannot be completed deterministically.
**Independence:** different-client (GPT-5.6-sol / Codex, grounding on)

Preflight passed: the reviewed spec digest `7b5a94e06d83039b` matched the file as it
stood, so every citation landed on current text.

Six findings held and were fixed. One was rejected on its evidence. Four need your
decision. Two fixes were partial — the false claim was corrected, but choosing the
remedy is yours.

## For you to decide

### 1. Route admission has a latent hole (from F1 — the remedy, not the claim)

**What the spec now says.** §6.2 controls 2 and 3 have been corrected to state what they
actually enforce: the exact-hostname listener stops a route naming a *different*
hostname, but a route that omits `hostnames` inherits the listener's, and namespace
selection cannot separate Plex from the seven other apps sharing `media`.

**What this means.** A future HTTPRoute in `media` that targets the public Gateway and
omits `hostnames` would attach and serve `plex.lab.supermorphic.com` from a non-Plex
backend. I verified all eight current media routes pin their own hostname, so nothing
attaches today. This is latent, not present.

**Why I did not fix it.** Three remedies exist and nothing settles the choice:

- Move the public HTTPRoute to `networking-public` with `from: Same` plus a
  ReferenceGrant from `media`. Structurally airtight — and you explicitly declined this
  when it was offered during design.
- Add a CI assertion that exactly one HTTPRoute references the public Gateway, and that
  it is Plex's. Cheap, consistent with the securityContext assertion you already
  approved, but a convention check rather than an API refusal.
- Accept it, on the grounds that a new public route in `media` is a reviewable change.

### 2. Plex egress on 443 is not confined to the Plex cloud (from F2 — the remedy)

**What the spec now says.** §7.2 has been corrected: Cilium's `world` entity is every
endpoint outside the cluster, so `world:443` permits TCP 443 to the NAS, the UniFi
gateway, and any VLAN device on HTTPS. It bounds protocol and port, not destination.
Negative test 8 in §13 has been narrowed accordingly.

**What this means.** The containment claim in the risk register is weaker than it read.
Note this is the cluster's existing pattern — the ntfy policy uses the same broad rule,
because there is no FQDN-egress baseline.

**Why I did not fix it.** The remedies are live choices: a `toCIDRSet` with RFC1918
exclusions, a Cilium DNS-proxy FQDN policy for `plex.tv` and `plex.direct`, or accepting
it as consistent with existing cluster practice. Introducing an FQDN-egress baseline is
a cluster-wide change this experiment never scoped.

### 3. The phase-4 DDNS gate cannot be satisfied on a stable lease (F3)

The gate requires proving "an address change propagates," but nothing specifies how to
cause one. A residential lease can hold for weeks, so a correctly-working DDNS setup can
fail to clear the gate. Candidates: force a change (modem reboot or WAN MAC change),
edit the record to a wrong value and confirm UniFi corrects it, or weaken the gate to
"record matches current address and the DDNS client reports success." Each has different
disruption and different proof strength.

### 4. The DDNS drift check is underspecified (F8)

§9 describes behaviour but not workload kind, schedule, or endpoints. CronJob plus
Alertmanager, or a long-running exporter with a gauge and PrometheusRule, are different
implementations. **Both send a query to a third-party IP-echo service, which is a
disclosure decision** — that endpoint and the public resolver are unnamed, and given the
care you have taken over what this repo reveals, naming them is your call.

### 5. New-risk rows do not show three-way deltas (F9 — scope, unactioned)

Your brief required deltas across Relay, direct Plex, and dedicated Envoy. §15.2 does
this; §15.3's 16 new-risk rows carry a single rating. Most describe risks that do not
exist under Relay, so the delta would often read "N/A." Adding the columns is a
completeness call I will not make for you.

### 6. Auth-token disclosure through access logs is unassessed (F10 — scope, unactioned)

Plex documents `X-Plex-Token` as a permissible **URL query parameter**, and Envoy's
default access-log format records the full path including query string. §9 now requires
access logging. So a request using that auth form writes a live Plex token into the log.
The risk register does not assess this. I have not added it — adding a risk row is
scope, and scope is yours — but on the evidence this is the sharpest finding in the
review and I would not proceed to a plan without ruling on it.

### 7. Grounding items the reviewer could not verify

Treat these as open questions, not facts:

- **UniFi DNAT removal and established sessions.** The spec says removing the rule ends
  exposure "in seconds." UniFi is stateful and its documentation does not establish that
  deleting a port-forward flushes existing connection state. An in-flight session may
  survive rollback.
- **The `plex.direct` characterisation** used to reject BackendTLSPolicy — hash derived
  from server address, chain rotating on Plex's schedule — is not confirmed by official
  Plex documentation. The rejection may rest on an inaccurate premise.
- **Bitrate above 2 Mbps proves non-Relay.** The ceiling is documented, but §12 never
  says where the bitrate is read or over what sampling window.
- **The dedicated certificate's key algorithm and size are unspecified.** The existing
  wildcard is ECDSA P-256.
- **Deterministic SVG-to-PNG generation is undocumented in-repo.** The PNGs were produced
  via the pinned `uv` toolchain with `vl-convert`; no recipe records this.
- **Live cluster state was not checked** — repository state only, per policy.

## Ledger

### F1 — Defect — evidence holds — FIXED (claim) / SURFACED (remedy)
**Changed:** §6.2 control 3 now states it narrows admission to `media` but does not
isolate Plex within it, and notes all eight media routes currently pin hostnames.
Control 2 now states its limit — a route omitting `hostnames` inherits the listener's —
instead of claiming an unqualified specification guarantee. Remedy is item 1 above.
**Note:** control 2 sits inside the cited §6.2 but was not itself cited; correcting it
was necessary because the finding's failure trace runs through it, and leaving it would
have left a false statement beside a corrected one.

### F2 — Defect — evidence holds — FIXED (claim) / SURFACED (remedy)
**Changed:** §7.2 no longer describes `world:443` as "the Plex cloud"; it now states that
`world` is every off-cluster endpoint and bounds protocol and port, not destination.
§13 negative test 8 is narrowed to ports other than 443 and states it cannot disprove
443 egress. Remedy is item 2 above.

### F3 — Defect — evidence holds — SURFACED
**Why not fixed:** three remedies with different disruption and proof strength; nothing
in the spec or Intent chooses. Item 3 above.

### F4 — Contradiction — evidence fails — REJECTED
**Why:** the `§10 says` quote is truncated. The actual sentence reads "Phases 0 through 4
are all reversible **without touching the internal path**, and none of them makes Plex
reachable from the Internet" — a claim about internal-path safety and reachability, not
about retracting information. CT permanence does not conflict with either. §5.2 already
calls the CT entry "a real new disclosure" and accepts it, so the spec nowhere claims it
is retractable.

### F5 — Contradiction — evidence holds — FIXED
**Changed:** §14.2 previously said phases 2a/2b/2c are kept, unconditionally, while
§10.1 gate 2 and §14.3 require reverting any change causing an internal regression. It
now reads "kept — provided each passed its own gate," and states that a phase-2 change
which itself caused a regression is reverted, because §2's non-regression constraint
outranks retention.
**Determinacy:** §2's constraint is a stated, non-negotiable requirement and §14.2's
rationale ("containment improvements worth having") does not survive a policy that
breaks local playback. Only one resolution preserves the settled requirement.

### F6 — Ambiguity — evidence holds — FIXED
**Changed:** §4.3 now states the public EnvoyProxy mirrors the internal one — replicas,
resource requests, PDB — differing only in address pool, listener hostname, certificate
reference, and `allowedRoutes`.
**Determinacy:** reading 1 carries a rationale (the internal data plane is proven to
carry Plex streaming); reading 2 carries none. The mirroring constraint was established
during design and was omitted from the written spec by mistake.

### F7 — Ambiguity — evidence holds — FIXED
**Changed:** §9 now specifies Envoy Gateway's default access log to container stdout,
read live during the experiment, with no aggregation, sink, or retention introduced, and
states plainly that attribution does not survive pod restart or log rotation.
**Determinacy:** the cluster has no collector, and adding one is unrequested scope; only
reading 1 is consistent with a time-boxed attended experiment.

### F8 — Ambiguity — evidence holds — SURFACED
**Why not fixed:** workload kind, schedule, and external endpoints are live choices, and
the endpoint choice is a disclosure decision. Item 4 above.

### F9 — Scope (Omitted) — evidence holds — SURFACED
**Question:** §15.3's new-risk rows carry one rating where the brief asked for
three-column deltas. Item 5 above.

### F10 — Scope (Omitted) — evidence holds — SURFACED
**Question:** token disclosure through access logs is unassessed. Item 6 above.

## Reviewer claims verified independently

- Gateway API: an HTTPRoute omitting `hostnames` inherits the listener's — confirms F1.
- All eight `media` HTTPRoutes specify hostnames — bounds F1 to a latent risk.
- Cilium `world` is every off-cluster endpoint — confirms F2.
- The §10 sentence carries a qualifier the F4 quote dropped — rejects F4.
- §14.2, §10.1 gate 2, and §14.3 conflict as described — confirms F5.
- The spec contains no mirroring instruction for the public EnvoyProxy — confirms F6.
