# Spec Review Response

**Spec:** docs/decisions/2026-08-13-alerting-architecture.md
**Review:** docs/decisions/reviews/2026-08-13-alerting-architecture-review.md
**Reviewer verdict:** Not ready — stage 3 has a false scope bound and leaves matcher, threshold, and time semantics unresolved.
**Independence:** different-client (codex, GPT-5.6-sol; spec written by claude-code)

Preflight passed: the spec still matched the reviewed digest `76258823f3fc1e7f`, so every
citation was checked against the text the reviewer actually read.

I agree with the verdict. Six findings held and were fixed; one held and was surfaced as a
scope question; none were rejected. The review also produced two verified factual
corrections and two `UNVERIFIED` grounding results.

## For you to decide

### 1. Stage 3 needs a second exclusion mechanism, and this record does not choose one

**Recorded as §11 item 4. This blocks stage 3 alongside the lidarr question.**

The reviewer found that my five-destination bound in §6.1 was false, and it is. I checked:
**all five** remaining CiliumNetworkPolicies enforce egress, not only ingress — plex,
alertmanager-ntfy, ntfy, portainer, and test-reports. So a denial happens in two
directions, and the bound is that one *endpoint* is a policy-owning workload, not that the
*destination* is.

The consequence matters more than the miscount. Stage 3's whole exclusion rests on
deliberate denials carrying an empty `destination`. An egress denial from a policy-owning
workload to an in-cluster workload carries a **non-empty** destination — so it is
deliberate containment that the filter does not remove, and `PolicyDeniedTotalBlock` would
treat it as a broken integration.

The evidence for this was sitting in my own document: the SSDP multicast block I cited as
the canonical deliberate denial *is itself an egress denial from Plex*. I reasoned about
ingress only and did not follow it through.

I corrected the false claim, because that part is factual. I did not invent a replacement
exclusion, because choosing one is a design decision.

### 2. Which `source` matcher form

**Recorded as §11 item 5.**

The originating handoff specified `source=~"k8s:.*"` and marked it settled. I reopened it
during our conversation as a correctness question and you have not ruled. The spec required
`=~` but never wrote the expression. Anchored versus namespace-label-substring are
different selectors that match different compound identities.

### 3. No threshold for `PolicyDeniedSustained`

**Recorded as §11 item 6.**

"A workload source has sustained denials" gives neither a rate nor a count. Any positive
rate held for the `for:` duration, and a numeric floor, are different rules.

### 4. `PolicyDeniedTotalBlock` cannot see a previously-working integration go dark

**Recorded as §11 item 7.**

This one I resolved on the spec's terms and then surfaced the cost, because I think you
should see it rather than inherit it.

Approved decision 6 selected the "never worked, not degraded" signature, so `unless` tests
series *presence* over retained history. But `hubble_flows_processed_total` is cumulative:
once a pair carries a single forwarded flow, that series persists. An integration that
worked and is later blocked completely therefore never triggers this rule.

That is arguably the more common real-world breakage, and stage 3 does not cover it. The
approved decision is what it is — accept the limitation, or commission a second rule.

### 5. Stage 4 implements rather than only audits — a scope question

**F8. Not actioned; scope is never mine to change.**

You asked to "audit if we are missing other alerts entirely." Stage 4 goes further and
commits to *building* the Gatus and certificate-expiry alerts while deferring Longhorn and
trivy. The reviewer is right that this exceeds the brief. It may be exactly what you want —
but it is an addition you did not ask for, so it is yours to confirm or cut back to an
audit that only records findings.

### 6. The load-bearing PromQL premise is still unverified

**G7, `UNVERIFIED`. Recorded as §11 item 8.**

My claim that a never-successful pair has no `FORWARDED` series — the reason the rule needs
`unless` rather than `== 0` — could not be confirmed by the reviewer either. It verified the
metric labels, the configured contexts, and PromQL's missing-series behaviour against
Cilium 1.19.6 docs, but committed configuration cannot prove whether the live exporter
creates, retains, or drops a zero-valued series for a given pair.

This needs a live Prometheus query before stage 3 is implemented. If the premise is false,
the rule is wrong in the silent direction.

### 7. Stage 5 sizing is an estimate, not a finding

**G9, `UNVERIFIED`.** The exportarr shape, five scrape targets, API-key requirements, and
"larger than stages 1–4 combined" are my estimates. The reviewer confirmed the underlying
gap — no exporter or ServiceMonitor on any of the five apps — but not the sizing. Stage 5
gets its own decision record, so this resolves there.

## Ledger

### F1 — Defect — evidence holds — FIXED (partially surfaced)
**Changed:** §6.1 no longer claims only five destinations can produce a denial. It now
states that all five policies enforce egress, that the bound is one endpoint of the pair
rather than the destination, and that the empty-destination exclusion does not cover egress
denials to a workload. Verified independently: all five policy files contain an `egress:`
section. The replacement exclusion is surfaced, not invented — see *For you to decide* 1.

### F2 — Ambiguity — evidence holds — FIXED
**Changed:** §5 now states the lint tracks the **individual alert name**, extracting every
`.spec.groups[].rules[].alert` value, not the rule file. Determinate: §5 states its purpose
is preventing untested alerts recurring, and file-level association cannot achieve it —
`media/alerts` already has a test file, so a new untested alert added to it would pass.

### F3 — Contradiction — evidence holds — FIXED
**Changed:** §4 now reads "proposed for deletion rather than moved, pending the §11
decision", and adds that stage 1 moves the alert unchanged if the operator declines.
Determinate: the request marks this as unsettled, so §11 was correct and §4 overstated.

### F4 — Ambiguity — evidence holds — SURFACED
**Question:** anchored `source=~"k8s:.*"` or a namespace-label substring match. Not
determinate — the handoff declared it settled, I reopened it, and you have not ruled.
Recorded as §11 item 5.

### F5 — Ambiguity — evidence holds — SURFACED
**Question:** what threshold `PolicyDeniedSustained` uses. Nothing in the spec or Intent
chooses. Recorded as §11 item 6.

### F6 — Ambiguity — evidence holds — FIXED (limitation surfaced)
**Changed:** §6 now states explicitly that `unless` tests series presence over retained
history rather than a rate over a lookback, per approved decision 6, and names the
consequence. Determinate on Intent; the cost is surfaced as §11 item 7.

### F7 — Ambiguity — evidence holds — FIXED
**Changed:** §7 now states that placement follows the §4 rule — an alerts application sits
in the domain of what it monitors — so certificate-expiry rules create
`kubernetes/apps/security/alerts/` while Gatus-derived rules stay in `monitoring/alerts`.
Determinate: every application §4 enumerates already follows that pattern.

### F8 — Scope — evidence holds — SURFACED
**Question:** the brief said "audit if we are missing other alerts entirely"; stage 4
commits to implementing Gatus and certificate-expiry alerts. Never fixed by me.

### G2 — Grounding — verified against the repo — FIXED
**Changed:** §2 said "four domains" and "Fifteen of roughly thirty alerts". Both wrong. I
recounted independently: nine rule files across **three** domains (media, monitoring,
networking); **37** alerts defined; **20** names asserted in promtool tests; **17** with no
assertion. §2 now carries those figures and notes that five of the seventeen disappear in
stage 1, so stage 2's real workload is twelve alerts.

### G7, G9 — Grounding — `UNVERIFIED` — SURFACED
See *For you to decide* 6 and 7. G7 is recorded as §11 item 8.

## Note on edit scope

Fixes were confined to the cited locations, with one deliberate exception: F1 and F6
established new open decisions, so I added items 4–8 to §11, the section the document uses
to record exactly that. Without it the new §6 and §6.1 text would carry dangling
cross-references. No other section was touched.

Both repository validators pass after the revisions: `just repo decisions-validate` and
`just repo links-validate`.
