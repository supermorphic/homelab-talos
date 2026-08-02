# Spec Review Response

**Spec:** `docs/decisions/2026-08-02-agent-rules-audit.md`
**Review:** `docs/decisions/reviews/2026-08-02-2026-08-02-agent-rules-audit-review.md`
**Reviewer verdict:** Not ready — 12 evidence-backed findings

**Every finding's evidence held.** Nothing was rejected. That is unusual and worth
stating plainly rather than manufacturing a rejection for balance: codex grounded each
claim against the repository or vendor documentation, and each one reproduced when
checked independently. Nine were fixed; three are surfaced below, plus two open
questions that fixes exposed.

**Parse note:** the review file carries four trailing lines of `apply_patch` scaffolding
(`*** End Patch`, `"tool": "apply_patch"`, `>>> APPROVAL REQUEST END`). Transcript
artefact from the recovery, not content — no finding was lost to it.

---

## For you to decide

### 1. Which mechanism halts a failing reconciliation? (from F1 — blocking)

**What the spec said:** explicit `retryInterval` plus bounded Helm remediation plus a
`NotReady` alert would contain a thrashing app, replacing the deleted cleanup trap.

**What the reviewer established, against Flux's own documentation:** `retryInterval`
sets the *cadence* of another failed reconciliation and does not terminate one. Bounded
Helm remediation stops retrying a *Helm action* but leaves the parent Kustomization
reconciling, and a non-Helm failure has no remediation counter at all. An alert
notifies. **The deleted trap called `flux suspend`, which halts reconciliation — no
element of the replacement does that.**

**What I changed:** the containment table now states plainly that nothing in it halts
reconciliation, and the rollout workstream is marked blocked until a halting mechanism
exists. I did not invent one.

**Candidate mechanisms**, none chosen:

- an alert-driven automation that suspends a Kustomization after prolonged `NotReady`
  — closest to the deleted behaviour, but it is a cluster mutation performed by
  automation, which cuts against decision 1's tiering;
- accept a weaker control explicitly and amend the non-goal, which currently forbids
  replacing a control with a weaker one;
- keep the bootstrap recipes for any app whose failure mode needs halting, shrinking the
  rollout change to apps where alert-plus-revert genuinely suffices.

This is the load-bearing question for the entire rollout decision.

### 2. Post-merge acceptance: workstation runner or in-cluster Job? (from F6)

Already flagged unresolved in the spec; the reviewer confirmed it and **added a fact I
did not have**. Checking `tests/README.md`, `.github/workflows/ci.yml` and
`scripts/test/publish-report.sh`, it found canonical results are produced on a
workstation or CI filesystem and published *into* the cluster by a separate
operator-confirmed stream — **there is no reverse in-cluster ingestion path.**

So the in-cluster Job option, which I offered as the candidate resolution, needs an
evidence transport built before it can satisfy the "durable evidence" property. That
makes it materially more expensive than I implied when I proposed it.

Meanwhile sequencing still instructs workstream 3 to "build post-merge acceptance
automation" without saying which architecture.

### 3. Alert threshold architecture (from F8)

The spec said the alert fires when a Kustomization is `NotReady` beyond
`spec.timeout + spec.retryInterval`. The reviewer checked
`flux-kube-state-metrics/app/values.yaml` and the existing `flux-alerts.yaml`: the
`gotk_resource_info` series carries kind, namespace, name, readiness and suspension
labels **and no duration fields**, and the existing rule uses a single static `for: 15m`.

A per-Kustomization sum is therefore not expressible by extending the current rule. The
choice is between generating per-object alert rules from source — new machinery and
source-to-alert coupling — or picking one conservative static threshold and losing the
per-app fit. I changed the table to say the architecture is unresolved rather than pick.

### 4. Is admin isolation worth building? (exposed by F2's fix)

The fix states the true strength of the boundary; it does not create one. Closing the
gap would need a separate filesystem location, a different user, or a credential helper.
That is new infrastructure and adjacent to `bypassPermissions`, which you ruled out of
scope — so it is your call, not mine.

### 5. Bookkeeping

The spec's *Review disposition* section documents only the first review. Adding this
round would touch a section no finding cited, so I left it. Say the word if you want it
recorded there as well as here.

---

## Ledger

### F1 — Defect — evidence holds — FIXED + SURFACED
**Changed:** decision 2's containment table now states that none of `retryInterval`,
Helm remediation, or alerting halts reconciliation, and marks the rollout workstream
blocked until a halting mechanism exists (was: "Explicit `retryInterval` plus Helm
remediation bounds reapplication"). Mechanism choice surfaced above.

### F2 — Defect — evidence holds — FIXED + SURFACED
**Changed:** the `admin` tier row now reads "Main clone — see the isolation limit below"
(was "Operator only"), followed by an explicit statement that separation is by
convention, that any agent session started in the main clone holds admin, and that
custody is a real control only for worktrees.

### F3 — Defect — evidence holds — FIXED
**Changed:** the Status block now says the author writes `Accepted` in the landing pull
request (was: "A record becomes `Accepted` when it is merged to `main`"), with the
reasoning that git merges content unchanged, so a merged `Draft` stays `Draft` for ever
and the immutability check never engages. Determinate: a post-merge writer would have to
push to `main`, which the approved sole-merge-authority decision rules out, and deriving
status from git contradicts the index contract naming the Status header as source of
truth. Decision 12 updated to match.

### F4 — Defect — evidence holds — FIXED
**Changed:** all workload-level invariants — mutable tags, dropped capabilities,
`NET_ADMIN`, RWO-implies-`Recreate` — moved from the Resource layer to the Rendered
layer, with the verification inline: `kustomize build kubernetes/apps/media/sonarr/app`
emits `ConfigMap`, `HTTPRoute` and `HelmRelease` and no `Deployment` or PVC. The
`AGENTS.md` row for the RWO rule now names the Rendered layer. Determinate on the spec's
own terms — it already defines a Rendered layer for exactly this input.

### F5 — Contradiction — evidence holds — FIXED
**Changed:** the post-merge failure response now opens a revert **pull request** for the
operator to merge (was: "the activating commit is reverted unless the operator
explicitly accepts"). Determinate: only this preserves the approved sole-merge-authority
decision, and the reviewer confirmed the tracked ruleset grants no bypass actor and CI
holds `contents: read`.

### F6 — Ambiguity — evidence holds — SURFACED
**Question:** workstation runner or in-cluster Job. Not determinate — two live
architectures, and the reviewer's finding that no in-cluster evidence ingestion path
exists changes the cost balance. See *For you to decide* 2.

### F7 — Defect — evidence holds — FIXED
**Changed:** link validation now selects records added, or modified **other than by a
status-line-only change**, using the same predicate as the immutability check (was: "added
or modified in the diff"). Determinate: the immutability rule already defines
status-line-only as the single legal modification, so reusing that predicate is the only
resolution that avoids the deadlock the reviewer identified.

### F8 — Ambiguity — evidence holds — SURFACED
**Question:** static shared threshold or generated per-object rules. Not determinate.
The table now records the architecture as unresolved rather than implying the sum is
expressible today. See *For you to decide* 3.

### F9 — Contradiction — evidence holds — FIXED
**Changed:** four rows reclassified from Gotcha to Authoritative — cluster-dependent
suites (`validation.test-harness`), pinned toolchain (`mise.lock`), app layout
(source-layer policy), decision records (`validation.decisions`) — and the worktree
credential row's mechanism column set to "—". Gotcha is defined as backed by nothing, so
a row naming a mechanism was not one. The reviewer said "at least two"; there were four.

### F10 — Defect — evidence holds — FIXED
**Changed:** split into two rows — "Never **push** to `main`" as Authoritative backed by
branch protection, and "Never **commit** on a checked-out `main`" as Operator policy
backed by the `SessionStart` warning only (was one row claiming Authoritative for both).
Branch protection is server-side and cannot intercept a local commit.

### F11 — Ambiguity — evidence holds — FIXED
**Changed:** eligibility criterion 2 now requires a Gatus endpoint that exercises the
function the app's `<app>-verify` proved, explicitly not mere reachability, and states
that an app whose function cannot be expressed as a service endpoint keeps its recipe.
Determinate: the non-goals forbid replacing a control with a weaker one, and a liveness
probe does not establish what a verifier established — which rules out reading 1.

### F12 — Defect — evidence holds — FIXED
**Changed:** the conditional recipe now mints **both** credentials in a worktree — the
30-day observer token to `.kube/config` and a 90-day `os:reader` talosconfig to
`.talos/config` via `talosctl config new --roles os:reader --crt-ttl` — and Appendix B's
command block says so. The `os:reader` tier previously had a source command but no path
that installed it.
