# Agent Rules Audit and Repository Retrospective

## Status

- **Status: Draft.** Revised 2026-08-02 after independent review. Awaiting operator
  acceptance.
- Date: 2026-08-02
- Branch: `challenge-agent-rules`

**The author sets `Accepted` in the pull request that lands the record**, once the
operator has approved it. Until that commit it is `Draft` and may be revised freely.
Once an `Accepted` record exists on `main` it is superseded, never revised. Status is
one of `Draft`, `Accepted`, or `Superseded by <filename>`.

Acceptance is *written*, not *inferred from merging*. Git merges file content unchanged,
so a record committed as `Draft` and merged stays `Draft` for ever — the immutability
check compares against the merge base and would never see an `Accepted` record to
protect, and the generated index would report every record as a draft. A post-merge
writer was the alternative and is ruled out: it would have to push to `main`, and the
operator is the sole merge authority.

**Implementation already performed.** The commit introducing this record also changed
`scripts/validate/links.sh` to exclude `docs/decisions/*`. That is implementation, not
design, and it is acknowledged as such rather than described as a no-op. It is an
**interim measure**: decision 4 replaces the blanket exclusion with introduce-then-freeze
validation. Nothing else has been implemented.

## Problem

The repository's governing rules had been rewritten four times in four days — #162
removed 76 lines of worktree constraints, #163 added a skills section, #165 compressed
162 lines to 75, #169 deleted the skills section. Net rule content finished roughly
where it started.

The rules were never wrong in a way anyone could name. They were never *tested* either.
No rewrite had an acceptance criterion, so no rewrite could be finished, and the churn
had no natural stopping point.

The question this audit asks is not where each rule should *live*, but whether each rule
should *exist*.

### Current-state findings

Measured against `15bf87f` on 2026-08-01/02. **These are a dated snapshot, not ongoing
acceptance criteria.** Reproduction commands and classification rules are in
[Appendix A](#appendix-a--methodology).

**Repository mass.** 18,523 lines of cluster payload under `kubernetes/`, against
32,652 lines of machinery (`scripts/`, `tests/`, justfiles, CI, `talos/`) and 14,950
lines of prose. Only 28% of the repository is the thing being managed. `scripts/`
alone, at 23,020 lines, is larger than all of `kubernetes/`.

**Rollout scaffolding.** `.just/bootstrap.just` is 2,635 lines across 28 recipes with
72 `*_CONFIRM` references. Of the 22 resume-style recipes, **18 have an identical
operation sequence**:

```
trap → kubeconfig-exists → git-remote-check → require-deployed-source →
staged-suspended-git → validate → reconcile-source → flux-verify →
reconcile-cluster-apps → live-suspend-check → CONFIRM → resume →
reconcile-app → wait-ready → verify
```

Three of the remaining four are that sequence repeated or with one extra
reconcile-and-wait. Only `flux-adopt-cilium` differs structurally. Variation across the
18 is five parameters: Kustomization name, source-path list, two timeouts, and a
confirmation string. Namespace is `flux-system` in all 18.

No drift has occurred between the copies. The cost has been paid in cross-cutting
edits instead: #39 modified 21 recipes in 48 hunks, #38 modified 13 in 37, a
guard-ordering correctness fix (source-sync before `flux-verify`) was applied by hand to
7, and #111 to 4.

**Flux is already configured for ordered rollout.** All 33 Kustomizations carry
`wait: true` and a `timeout` (5m–20m); 32 of 33 declare `dependsOn`; and `suspend` is
unset on every one. Ordered, health-gated, time-bounded *application* is already
declarative. The suspended state exists only in the window between an app's "stage" PR
and its "activate" PR — a window in which `main` states something untrue about the
cluster.

Flux does **not** replicate the recipes' failure containment. See decision 2.

**Validation.** Across `scripts/validate/*.sh`, 797 assertions decompose into 22
tautologies (`[[ "$suspend" == 'true' || "$suspend" == 'false' ]]`, which cannot fail),
567 change-detectors comparing a `yq` extraction to a literal from the file it just
read, and 208 structural checks. **73% of assertions provide no independent signal.**

The change-detectors do not function as tripwires: 47 of 119 app-config changes since
2026-06-01 (39%) edited the config and its own validator in the same commit. When one
author moves both sides of an equality, the assertion is not a check.

`tests/policy/media/media.rego` is the better pattern — one policy covering nine apps
with named, reasoned exemptions, enforcing pinned images, no mutable tags, dropped
capabilities, and dependency ordering. `kubernetes/mod.just:152` applies it to
`kubernetes/apps/media` only. **Nine of 33 Kustomizations have policy coverage.** It is
not, however, directly extensible — see decision 3.

**Cluster access.** Across scripts and justfiles, 166 cluster invocations are read-only
(53%) and 143 mutate. Of the mutating calls, 116 are Flux orchestration (`reconcile` 71,
`resume` 23, `suspend` 22), most of them inside the bootstrap recipes. Genuinely
destructive invocations in the entire repository: **two `apply` and one `delete`.**
Nothing enforces the prohibition — there is no PreToolUse hook, and neither pre-commit
nor CI mentions it.

**Prose.** `plans/` holds 3,531 lines across seven files with no status markers. Three
carry live content: `talos-validation-refactor-plan.md` is unexecuted and independently
diagnosed this audit's validator finding; `media-stack-architecture-plan.md` carries
"Seerr, not Overseerr"; `portainer-gitops-observability-deployment-plan.md` carries
"Portainer must not become a deployment authority". `docs/` holds 2,397 lines of frozen
`phase-0`–`phase-14` records interleaved with live reference.

**What is working.** `just ci` is a genuinely good gate — 2–5 minutes, 33 suites,
cluster-independent, secret-free, and the required check on every PR. The pinned mise
toolchain with a lockfile is correct. SOPS discipline has held with zero incidents,
backed by gitleaks and a staged-blob encryption check. GitHub protection is code with a
tracked contract. The Flux layout is well-built. The ntfy/Alertmanager/Flux alerting
backbone is real and verified. And agents have not been violating the rules — which is
the finding that reframes everything below.

### What the field says

Anthropic removed **over 80% of Claude Code's own system prompt** for Opus 5 and Fable 5
with no measurable eval loss, concluding: *"we were overconstraining Claude Code, both
through our system prompt and in our CLAUDE.md files and skills."* Their per-line test:
*"Would removing this cause Claude to make mistakes? If not, cut it. Bloated CLAUDE.md
files cause Claude to ignore your actual instructions."* And the disposal rule:
*"If Claude already does something correctly without the instruction, delete it or
convert it to a hook."*

The AGENTS.md specification defines **nearest-wins** precedence for nested files.
Community guidance is consistent on when to split: start with one file, split at
150–200 lines; Codex caps combined agent docs at 32 KiB and suggests a global file
≤5 KiB.

Root `AGENTS.md` is **67 lines / 3.4 KB** — under every published split threshold by a
factor of two to three.

## Goals and non-goals

**Goals.** Give the rule set a pass/fail admission test so rewrites can terminate.
Delete rules that neither enforce nor inform. Convert enforceable rules into
enforcement. Remove machinery whose only justification was a rule being removed.
Separate settled history from live intent so no document silently reads as current.

**Non-goals.** Test reporting, which is retained whole and slated for expansion.
Cluster, Talos, Flux, or application behaviour changes beyond the rollout model.
**Any reduction in actual safety** — where a control is removed, an equal or stronger
one replaces it, and the replacement is named with an owner, a trigger, and a failure
response.

## The admission test

One root `AGENTS.md`. Every rule in it must fall into exactly one of three categories,
and must **state its category and its supporting control inline**:

| Category | Meaning | Backed by |
|---|---|---|
| **Authoritative control** | A boundary, not a judgment call. Backed by a mechanism — whose strength is stated separately, since not every mechanism is absolute | Credential/RBAC, branch protection, SOPS key custody, `PreToolUse` hook |
| **Operator policy** | A judgment boundary the repository cannot decide. Genuinely advisory, and legitimately so | Named human authority; no mechanism claimed |
| **Gotcha** | Non-obvious repository-specific knowledge an agent cannot infer | Nothing — it is information, not a rule |

A rule fitting none of the three is deleted.

**Enforcement mechanisms are not equivalent**, and a rule must not claim more than its
mechanism delivers:

| Mechanism | Strength |
|---|---|
| Credential / RBAC | Hard boundary — the call fails at the API server |
| Branch protection | Merge boundary — enforced server-side by GitHub |
| CI check | **Delayed detection** — catches after the fact, does not prevent |
| Pre-commit hook, shell guard, `PreToolUse` hook | **Bypassable** — `--no-verify`, or editing the guard. Catches accident, not intent |

**Instruction alongside enforcement is permitted, bounded.** Where a bare denial would
leave an agent confused about the correct path, the *workflow* may be stated once. The
*prohibition* is never restated beside its enforcement. Unbounded duplication is what
produced the churn; a one-line signpost is not duplication.

This is the standing test for future rule proposals. It is the mechanism that ends the
churn: a proposed rule now has an answer rather than an argument.

### Why one file and not a nested layer

Splitting root `AGENTS.md` into per-subtree files — `kubernetes/AGENTS.md`,
`talos/AGENTS.md`, and so on — is the obvious next move once a rule set feels
unwieldy, and it is rejected here for three reasons. Recorded explicitly so the
question does not reopen:

1. **The size premise does not hold.** At 67 lines, root is far below every published
   split threshold. Splitting to save context optimises a cost that is not being paid.
2. **Any "narrow but never relax" inheritance model contradicts the specification.**
   AGENTS.md is nearest-wins. A rule that a nested file may only strengthen its parent
   is implemented by no harness, so it would run entirely on agents reading and
   honouring a bespoke precedence block — an instruction pretending to be a mechanism.
3. **It adds surfaces without removing rules.** The measured problem was never that
   rules were hard to find.

A nested layer becomes worth revisiting if root approaches 150–200 lines. It is not
close, and the decisions here make it shorter.

`docs/runbooks/` is **created** by this work; it does not exist today. Procedure is
descriptive and is not loaded every session, so it does not compete for the same budget.

### `CLAUDE.md` is a permitted vendor shim

`CLAUDE.md` currently carries `@AGENTS.md` plus four Claude-specific lines (plan mode,
Explore subagents, repository boundary, memory index). These are **harness operating
guidance, not repository rules** — they describe how to use one client's features and
would be meaningless to Codex or Gemini.

`CLAUDE.md` may therefore contain harness-specific guidance, and is bounded to that: it
must not contain a repository rule, and must not narrow, extend, or contradict
`AGENTS.md`. "Root `AGENTS.md` is the only agent instruction surface" means **the only
surface for repository rules** — restated precisely in decision 10.

## Decisions

### 1. Cluster access is governed by effect, with tiered credentials

The rule *"All cluster mutations and health checks use guarded `just` recipes; never run
raw `kubectl`, `talosctl`, `helm`, or `flux`"* bans a tool where the risk is an effect.
`kubectl get pods` and `kubectl delete ns media` carry identical prohibitions, while the
guarded recipes invoke `kubectl` with full admin rights regardless — so the rule
constrains spellings, not blast radius. It is also unenforced, and 53% of what it forces
through wrappers is read-only.

#### Credential tiers

Three tiers, each an authoritative control:

| Tier | Grants | Holder | Used for |
|---|---|---|---|
| **`observer`** | Kubernetes `view` plus `pods/log`, `metrics.k8s.io`, and explicit read on the CRDs in use (Flux, Cilium, Gatus, Tailscale, Longhorn, Trivy) | Agents, in every worktree | Diagnosis, `flux get`, `cilium status` |
| **`diagnostic`** | `observer` **plus `pods/exec` and `pods/portforward`** | Agents, for named verifiers only | The 5 verifiers that require it |
| **`admin`** | Full cluster-admin; `os:admin` talosconfig | Main clone — see the isolation limit below | Bootstrap, break-glass, recovery |

**The admin tier is separated by convention, not by a boundary.** `.kube/config` and
`.talos/config` are ordinary repository-relative files. Nothing distinguishes an operator
shell from an agent session launched in the same clone: the `SessionStart` hook warns and
never blocks, `bypassPermissions` gates nothing, and working in the main clone is
explicitly legitimate. **Any agent session started there holds admin.**

So "admin credential custody" is a real control against a session in a *worktree* — which
has no admin file to read — and **no control at all** against a session in the main clone.
The spec's own admission test forbids claiming more than a mechanism delivers, so the
claim is stated at its true strength here rather than in the rule table's shorthand.
Closing the gap would need a real boundary — a separate filesystem location, a different
user, or a credential helper — and that is recorded as an open question rather than
assumed.

**`diagnostic` is not read-only and is not described as such.** `pods/exec` is a
`create` verb on a subresource and can mutate container state arbitrarily. It is a
deliberate, named privilege granted because five retained verifiers require it —
`scripts/verify/homepage.sh:31` uses `exec`, `scripts/verify/flaresolverr.sh:27` uses
`port-forward`, and three others. The honest framing is a *reduced-privilege* tier, not
a read-only one.

`view` also **excludes CustomResourceDefinitions and custom resources** unless granted
explicitly or via aggregation. Flux `Kustomization`/`HelmRelease`, Cilium policies, Gatus
`Endpoint`, Longhorn volumes and Trivy reports all require explicit rules. A tier that
omits them cannot diagnose this cluster.

#### Where each credential comes from

The tiers are not variants of one mechanism. `talosctl kubeconfig` is documented as
*"Download the **admin** kubeconfig from the node"* and has no scope option, so the
existing recipe cannot be made read-only:

| Credential | Source | Scope control | Lifetime |
|---|---|---|---|
| admin kubeconfig | `talosctl kubeconfig` | none — admin only | Talos PKI cert |
| observer/diagnostic kubeconfig | Kubernetes ServiceAccount + RBAC | ClusterRole | 30-day token |
| admin talosconfig | talhelper, via `just talos generate` | `os:admin` | cert |
| reader talosconfig | `talosctl config new --roles os:reader --crt-ttl` | roles flag | **90 days** |

#### Starting position

Only the main clone holds credentials today. All four agent worktrees have neither
`.kube/config` nor `.talos/config`, so **agents currently have zero cluster access.**
This decision is a privilege increase from nothing, not a reduction from admin, and the
work is minting the new lower tier rather than relocating the existing one.

#### Path strategy: same path, different content by location

`.kube/config` and `.talos/config` stay repository-root-relative, so each worktree has
its own. **The main clone's hold admin; every worktree's hold observer/diagnostic.**

No recipe changes, and `.just/repository.just:1206`'s centralised-path assertion stands
unmodified. A rollout recipe run from a worktree fails at the API server rather than
being refused by an instruction — the guard becomes real. This aligns with
`require_deployed_source`, which already makes the main clone the natural home for
rollouts.

`just talos kubeconfig` **resolves conditionally** on where it runs:

- **In the main clone** — downloads the admin kubeconfig from Talos. Unchanged.
- **In a worktree** — mints **both** scoped credentials using the main clone's admin
  config: a 30-day observer/diagnostic ServiceAccount token written to `.kube/config`,
  **and a 90-day `os:reader` talosconfig written to `.talos/config`** via
  `talosctl config new --roles os:reader --crt-ttl`, which requires admin authority
  against a control-plane node. Fails with a clear message if the main clone holds no
  admin config.

Both files are required. `.kube/config` alone leaves every Talos-backed diagnostic
broken for want of a talosconfig, even after the operator has run the documented
command — the `os:reader` tier would exist on paper with no path that installs it.

The same command is therefore the **token refresh recipe**: when a token expires,
re-running it re-mints. `README.md` documents the mapping explicitly — main clone →
admin, worktree → observer — because a credential whose scope depends on directory is
exactly the kind of thing that must not be inferred.

#### Credentials are minted on demand, not at worktree creation

**A worktree starts with no cluster credentials.** When a session needs cluster access,
the agent **stops and asks the operator to mint it**, and the operator runs the recipe
above in that worktree. Agents never mint their own, because minting reads the main
clone's admin config.

This is deliberate signal rather than friction. Cluster access becomes a visible event
the operator is told about, instead of an ambient capability every session silently
holds.

The evidence supports it. All four live worktree branches touch only `docs/` and
`scripts/` — authoring work that `just ci` covers offline. Against that, 10 of 32 `fix:`
commits (31%) trace to behaviour only visible at runtime: FlareSolverr's UID,
qbit-manage's `root_dir`, hardened Caddy startup, Lease timestamps, connector route
parsing, Cilium tombstones. **Most sessions never query the cluster; a minority need it
badly, and which is which is not knowable when the worktree is created.** Minting on
demand is the only distribution that matches that shape.

It also resolves an interaction that per-worktree credentials plus bounded tokens would
otherwise create. Issuing at creation would mean *N* worktrees × *N* refresh commands per
expiry cycle, for credentials most of those worktrees never use. On demand, most
worktrees never receive one, and a feature branch rarely outlives a 30-day token — so
refresh is a rare event rather than a recurring chore. A shared credential symlinked
across worktrees was considered and rejected: it would restore ambient access and remove
the signal that is the point of asking.

#### Lifetime, revocation, rotation

- **Kubernetes:** a **30-day** ServiceAccount token, re-minted by the recipe above.
  Chosen over a long-lived Secret-backed token so a leaked worktree config expires on
  its own. Thirty days is long enough that most feature branches finish inside one
  token's life, and on-demand minting means only worktrees that actually needed access
  ever hold one. The cost is acknowledged in the risks: a token can expire
  mid-diagnosis, and the remedy is one operator command.
- **Talos:** `os:reader` at a **90-day** TTL — short enough that a stale or leaked
  config self-heals within a quarter, long enough that renewal is a rare chore.
- **Revocation** is deleting the ClusterRoleBinding and rotating the ServiceAccount for
  Kubernetes, and letting the certificate lapse or rotating Talos PKI for `os:reader`.

#### Tier visibility

An agent cannot otherwise tell which tier it holds, and will report its own capabilities
incorrectly. A **`SessionStart` hook announces the tier and branch**, and warns when a
session is running in the main clone on `main` with admin credentials:

> `main clone · branch main · admin credentials in effect — repository work belongs on a
> feature branch in a worktree`

**This is a warning, not a guard.** Working in the main clone is legitimate — it is
where rollouts belong. The irreversible half is already covered: branch protection
blocks pushing to `main` server-side.

The same hook asserts the session environment carries **no SOPS key material**. This
holds today — `SOPS_AGE_KEY` and `SOPS_AGE_KEY_FILE` are absent from agent sessions —
but only incidentally, because Claude Code is launched from a shell that has not
exported them. There is no automation populating them: no `[env]` in `.mise.toml`, no
`.envrc`, no direnv, just a manual `export` documented at `docs/sops.md:12,19`. Put that
export in a shell profile and every agent session would inherit the key silently. The
check turns an accident of launch context into something visible.

Nothing else about SOPS changes. The key stays with the operator; `just ci` remains
secret-free (chainsaw, the one SOPS-touching test path, is not in `executions.ci`); and
the recipes needing the key — `just talos generate`, every `*-secrets` recipe,
`just bootstrap flux-sops`, `just bootstrap foundation`, and the `scripts/secrets/ntfy-*`
scripts — stay operator-run under the redrawn division of labour below.
`scripts/test/validate-chainsaw.sh:37` already unsets both variables defensively and is
the model for any future path that must prove it never touches them.

#### Consequence: the operator/agent division of labour changes

The current division exists *because* the operator holds the credentials. Once the
observer and diagnostic tiers exist, it is redrawn:

| Work | Before | After |
|---|---|---|
| Offline validation, `just ci` | Operator | **Agent** |
| Live `<app>-verify`, diagnostics | Operator | **Agent**, under observer/diagnostic |
| `*-secrets`, platform `bootstrap` | Operator | Operator — SOPS key and admin |
| Credential minting | — | Operator |
| Merging pull requests | Operator | Operator |

This is a deliberate consequence of decision 1, not a side effect, and it is what makes
decision 2's post-merge acceptance runnable by automation rather than by the operator.

#### Command-to-permission matrix and tests

Every retained verifier and diagnostic script is mapped to the exact verbs and resources
it needs, and to its tier. A verifier that cannot be satisfied by `diagnostic` is
reworked or becomes operator-only. Positive tests confirm each retained verifier
succeeds under its declared tier; **negative authorization tests** confirm `observer`
cannot exec, cannot read Secrets, and cannot mutate, and that `diagnostic` cannot mutate
Flux-managed state.

#### What is and is not claimed

AGENTS.md retains only the workflow signpost — *reads are direct; changes go through
Git* — as an authoritative-control-backed rule, and drops the prohibition itself.

**The security claim is narrow.** Denying the Secret API is the only guarantee made.
Logs, events, ConfigMaps, workload specifications, and application endpoints can still
disclose credential material, and Kubernetes documents that read-oriented permissions
carry disclosure and escalation risk. The correct statement is: *direct diagnostic
commands are permitted within an explicit least-privilege allowlist, and Secret API
reads are denied.* Not: *secret exposure is closed.*

Worktrees already lack cluster access accidentally, because `bootstrap.just` reads
`.kube/config` relative to the repository root. This makes that deliberate.

### 2. App-tier bootstrap recipes are deleted, with a named containment replacement

Scored against Flux's existing configuration, the 15 steps of a bootstrap recipe are:
one already running in CI (`validate`), one genuinely additional (`<app>-verify`), three
duplicating `dependsOn` + `wait: true` + `timeout`, **one providing containment Flux does
not provide**, and nine that exist only because the rollout is manual — kubeconfig and
git-remote checks, `require_deployed_source` (Flux runs `origin/main` by definition), the
staged-suspended check, the CONFIRM.

#### Correction: the failure trap is not redundant

An earlier draft of this record claimed the cleanup trap duplicated Flux's own failure
behaviour. **That was wrong.** On failure Flux leaves the Kustomization `NotReady` and
**keeps retrying at its interval**, reapplying indefinitely. The trap instead *suspends*
the Kustomization, halting reconciliation while preserving resources. Those are different
outcomes, and the trap is a real containment mechanism that must be replaced rather than
assumed away.

#### The replacement

An app ships **unsuspended in one PR**, under a named containment contract:

| Property | Value |
|---|---|
| **Retry** | Flux `spec.retryInterval`, set explicitly per Kustomization rather than inherited |
| **Maximum failure duration** | An alert fires when a Kustomization is `NotReady` beyond a threshold. **The threshold's architecture is unresolved — see the open question below.** Extends the #154 `gotk_resource_info` rules |
| **Remediation** | `HelmRelease` `install.remediation` / `upgrade.remediation` with a bounded retry count, so a failing *Helm action* stops retrying |
| **Rollback trigger** | Alert fires → a revert of the activating commit is prepared as a pull request → **the operator merges it** → Flux converges to the prior state |
| **Containment of a thrashing app** | **None of the above halts reconciliation.** Suspension by the operator remains the only mechanism that does |

**This replacement is weaker than what it removes, and the gap is stated rather than
argued away.** Flux's `retryInterval` sets the *cadence* of another failed
reconciliation; it does not terminate one. Bounded Helm remediation stops retrying a
Helm action but leaves the parent Kustomization reconciling, and a non-Helm failure has
no remediation counter at all. An alert notifies. The deleted trap called
`flux suspend`, which halts reconciliation outright — **no element of the replacement
does that.**

The non-goals require that a removed control be replaced by an equal or stronger one.
On the evidence above this contract does not yet meet that bar, so **the rollout
workstream is blocked until it does.** The open question is which halting mechanism to
adopt; it is recorded for the operator rather than chosen here.

This must be implemented **before** the recipes are deleted, not after. Deleting first
and replacing later is the reduction in safety the non-goals forbid.

#### Eligibility for the one-PR path

An app qualifies only if **all** hold:

1. It has no app-specific safety gate beyond Kustomization readiness.
2. It has a Gatus endpoint that **exercises the function its `<app>-verify` proved** —
   not merely TCP or HTTP reachability. The non-goals forbid replacing a control with a
   weaker one, and a liveness probe does not establish what a verifier established. An
   app whose function cannot be expressed as a service endpoint — GPU scheduling, SMB
   mounting, alert delivery — **fails this criterion and keeps its recipe** rather than
   qualifying on a shallow check.
3. Its `<app>-verify` runs under the `observer` or `diagnostic` tier.

**qBittorrent is exempt** and keeps its guarded recipe until separately reviewed. It is
the only app carrying a blocking post-bootstrap gate: `bootstrap.just` emits *"NOW run
the BLOCKING gate: `CLUSTER_CHAOS_CONFIRM='chaos:qbittorrent-vpn-disconnect'` … Only
after it passes, set `suspend=false`."* A VPN-disconnect chaos test is not expressible as
a Kustomization health check.

**Gatus coverage is currently insufficient.** Its 17 endpoints omit roughly 10 of the 18
apps losing a recipe — `qbit-manage`, `intel-gpu-plugin`, `homepage`, `trivy`,
`tailscale-subnet-router`, `csi-driver-smb`, `media-storage`, `gatus` itself,
`foundation`, and `alertmanager-ntfy`. Each must gain an endpoint, or be exempted and
keep its recipe. Criterion 2 is not waivable by assertion.

#### Post-merge acceptance is a defined mechanism, not a suggestion

An earlier draft said `<app>-verify` runs "by either the operator or an agent" and that
"nothing blocks on it". That cannot substitute for a removed control. The contract:

| | |
|---|---|
| **Actor** | Automation, triggered by the merge to `main` |
| **Trigger** | Flux reports the Kustomization `Ready`, or the readiness timeout expires |
| **Timeout** | `spec.timeout + spec.retryInterval` — the same bound as the failure-duration alert, so acceptance and alerting cannot disagree about whether a rollout finished |
| **Evidence** | A run record under the existing `.test-results/` canonical structure, so it lands in the reporting pipeline that is being retained and expanded |
| **Failure response** | Alert via the existing ntfy path, and a revert of the activating commit **opened as a pull request**. The operator merges it or explicitly accepts the failure. Automation never writes to `main` — the operator is the sole merge authority, and the tracked ruleset grants no bypass actor |

Where automation is not yet available, the operator runs it — but the obligation is
recorded and its absence is visible, rather than being optional by construction.

**Open conflict with decision 1: where does the automation get credentials?** On-demand
minting gives credentials to a *worktree* when a session asks. Post-merge acceptance
runs after the branch is merged, when that worktree is gone. None of the three obvious
homes works:

- a feature worktree — no longer exists at that point;
- CI — cluster-independent and secret-free by contract, which `just ci` must stay;
- the main clone — holds **admin**, and using admin for routine acceptance defeats the
  tiering entirely.

The candidate resolution is to run acceptance **in-cluster**, as a Kubernetes Job with
its own ServiceAccount scoped to exactly the verifier's permissions. Flux creates it, no
workstation credential is involved, and results land in the retained reporting pipeline.
This is recorded as unresolved rather than assumed: it changes decision 2's actor from
workstation automation to an in-cluster Job, and that is a design change requiring
operator approval, not an implementation detail.

#### Platform tier, by criteria rather than label

"Platform" is defined by objective tests, not by a list. A recipe is retained if **any**
apply:

1. Flux cannot deploy it, because Flux depends on it (`cilium`, `flux*`).
2. Its failure is cluster-wide and not cheaply reversible (`talos`, `storage`,
   `csi-driver-smb`).
3. It is required before GitOps is operational (`foundation`).
4. It carries an app-specific blocking gate (`qbittorrent`).

`metrics-server` is retained pending its own review — it is the largest and most
irregular recipe at 345 lines with three confirmation gates, and it is not obvious that
it satisfies any criterion above.

#### AGENTS.md rules deleted or narrowed

| Rule | Fate |
|---|---|
| "New apps begin suspended, roll out through guarded `just bootstrap <app>`, then persist the unsuspended state" | Deleted |
| "If a needed cluster operation has no recipe, add an appropriately guarded recipe" | Narrowed to operations meeting the platform criteria |
| "`bootstrap …` recipes require `*_CONFIRM` and are operator-run" | Narrowed to the retained recipes |
| Root vs `kubernetes/README.md:123` `kubectl apply` contradiction | Resolved — bootstrap and recovery applies run through guarded recipes |
| Phase-N notation | Dropped on every line touched: 59 sites in `bootstrap.just`, 13 of 18 confirmation strings |

#### Known implementation blocker

`.just/repository.just:1206` asserts
`rg -c 'require_deployed_source ' … -eq 24`. Deleting any rollout recipe breaks
`just repo verify`, which is the `validation.repo-verify` CI suite. The count must be
updated in the same change, and is a reason the rollout workstream cannot be split
across PRs arbitrarily.

#### How many recipes this actually removes

**No fixed number is committed here**, deliberately. The eligibility criteria decide
per recipe, and they cannot be fully applied until workstream 3 lands the missing Gatus
endpoints.

An earlier draft said "the 18 app-tier bootstrap recipes are deleted". That figure came
from the *structural* finding — 18 recipes share an identical operation sequence — and
carried over into a decision where it does not apply. **Three of those 18 are platform
tier by the criteria above**: `foundation` (required before GitOps is operational), and
`storage` and `csi-driver-smb` (cluster-wide, not cheaply reversible). A structural
similarity is not a tier.

For scale rather than commitment: of **68 distinct `*_CONFIRM` variables** in the
repository, 35 are in `bootstrap.just` and 33 are not — `GITHUB_PROTECTION_CONFIRM`,
thirteen `*_SECRETS_CONFIRM`, `TALOS_APPLY_CONFIRM`, the test-suite confirmations, and
others, none of which this audit touches. Of the 35, roughly half are retained by the
platform criteria. **The confirmation model is narrowed, not removed** — on the order of
a quarter of the repository's confirmation gates, all of them app-tier rollouts.

### 3. A policy architecture replaces change-detectors

`media.rego` **cannot simply be extended.** It discovers apps via
`endswith(document.path, "/app/values.yaml")` and then reads `controllers`,
`persistence`, `globalMounts`, and `advancedMounts` — the **app-template chart schema**.
Charts such as kube-prometheus-stack, longhorn, cilium, trivy-operator, cert-manager,
metallb, and envoy-gateway share none of that structure. Extending its exemption tables
to 33 heterogeneous Kustomizations is not architecturally possible.

The replacement is a layered policy set, each layer declaring its **input form**:

**Workload checks cannot live at the Resource layer.** Verified on 2026-08-02:
`kustomize build kubernetes/apps/media/sonarr/app` emits a `ConfigMap`, an `HTTPRoute`
and a `HelmRelease` — **no `Deployment`, `Pod`, or `PersistentVolumeClaim`.** For every
Helm-managed app, which is most of them, the workload does not exist until Helm renders
it. A capability, image-tag, `NET_ADMIN`, or RWO-strategy check placed at that layer
would pass while the actual running workload violated it. Those checks therefore belong
to the Rendered layer, and the RWO-implies-`Recreate` rule in the `AGENTS.md` table is
backed by that layer specifically.

| Layer | Input form | Scope | Examples |
|---|---|---|---|
| **Source** | Raw tracked YAML | All of `kubernetes/apps` | `ks.yaml` listed in its parent kustomization; `dependsOn` declared; `wait`/`timeout` present; no `suspend: true` on `main` |
| **Resource** | `kustomize build` output | All of `kubernetes/apps` | Only checks on objects this output actually contains — `HelmRelease` chart pinning and `chartRef`, `HTTPRoute` parent and audience, `CiliumNetworkPolicy` shape, native workloads where an app declares them directly |
| **Rendered** | `helm template` output | Per chart family | **All workload-level invariants**: no mutable image tags, capabilities dropped, no `NET_ADMIN` outside an allowlist, RWO PVC implies `Recreate` or StatefulSet. Plus values-reach-the-object checks — the Trivy `OPERATOR_SBOM_GENERATION_ENABLED` pattern, generalised |
| **Domain** | Chart-specific | One chart family | The existing app-template rules, retained as the media/app-template domain policy |

Every rule ships with **negative fixtures** proving it fails closed, matching the
existing `validation.policy-unit` practice.

#### Retained assertions and the coverage matrix

Retained because each prevents a failure that is not "someone edited this file":

- **External facts learned the hard way** — `infraAssessmentScannerEnabled == false`
  ("cannot run on Talos, read-only host"), FlareSolverr's numeric UID 1000,
  qbit-manage's `directory.root_dir`. Regression tests for real outages; each must carry
  its reason inline.
- **Cross-file consistency** where two files must agree and neither is authoritative.
- **Render-effect checks** — the only pattern that catches an upstream chart renaming a
  values key.
- **External contracts the repository does not own** — chart repository URLs, and the
  Gateway VIP and Pi-hole resolver IP already centralised in `scripts/lib/network.sh`.

Before any assertion is deleted, a **coverage matrix** records, **per assertion class**,
which policy layer independently detects the original failure. Per-*assertion*
granularity across 567 rows was considered and rejected: a matrix that size will be
rubber-stamped rather than read. Each class carries its definition, its replacement, and
one worked example verified by hand.

#### Wording correction

An earlier draft said *"a validator assertion must be structural"*. That contradicted
the retained external-fact category, since `infraAssessmentScannerEnabled == false` is
precisely a literal comparison and is legitimate. The rule is:

> **An assertion must have an independent oracle or encode an invariant.** Restating a
> freely chosen value from the file the assertion just read is neither.

`plans/talos-validation-refactor-plan.md` reached the same diagnosis independently and
is input to this workstream. Its destination is given in the fate table below.

### 4. Documentation is split by status, not by tooling

```
docs/decisions/YYYY-MM-DD-<topic>.md   design records; superpowers' spec shape
docs/decisions/README.md               generated index (date, topic, status)
docs/phases/                           15 rollout records — execution evidence
docs/runbooks/                         live procedure (created by this work)
docs/                                  live reference
<gitignored>                           implementation plans — written, never committed
```

Specs record *why* and age well; plans are task lists and age badly, so plans are
written for execution but not tracked. This follows ADR practice, where the decision
record is kept and the schedule is not.

The document shape is what superpowers already emits; its sections map onto MADR's. No
template is imposed. What is added is the Status line and the supersession discipline.
Filenames stay date-based rather than MADR's `NNNN-`, because sequential numbering
collides across the parallel worktrees this repository uses.

#### Record identity and immutability semantics

Path-based comparison against `origin/main` is ambiguous. The contract:

- **Identity** is the filename, which is immutable. A rename is a delete plus an add and
  is rejected by the check; superseding a record never renames it.
- **Comparison base** is the PR merge-base with `origin/main`, fetched in CI. Locally the
  recipe fetches first, so a stale ref cannot produce a false pass.
- **A newly added record** in the diff is unconstrained — it is `Draft` by definition.
- **An `Accepted` record present in the base** may change only by its Status line
  becoming `Superseded by <existing filename>`. Any other diff fails.
- **A deletion** of an `Accepted` record fails.
- **Migration exception:** the four files moving out of `docs/superpowers/` are added,
  not modified, so they enter as new records under their assigned Status.

Tests cover modification, deletion, rename, legal supersession, a missing supersession
target, and a stale base.

#### Link validation: introduce-then-freeze

The blanket `docs/decisions/*` exclusion committed with this record is **interim**. A
blanket exclusion means a broken link in a *new* record passes immediately, not merely
decays later — it sacrifices admission-time correctness for a problem that only arises
after acceptance.

The replacement: **records are link-validated when their content changes; that result is
frozen at acceptance.** Concretely, the validator scans `docs/decisions/*.md` files that
are added in the diff, or modified in any way **other than a status-line-only change**.
It uses the same predicate the immutability check uses, so the two cannot disagree.

The status-line exception is load-bearing, not tidiness. Superseding a record modifies
it, which would otherwise re-validate every link it contains. If any target had since
moved, the record could not be superseded without repairing content the immutability
rule forbids touching — a deadlock with no legal exit. Selecting on *content* change
rather than *any* change avoids it.

#### Index contract

`docs/decisions/README.md` is **generated and committed**. `just repo decisions-index`
regenerates it; `validation.decisions` regenerates into a temporary file and fails if it
differs from the tracked one, the same compare-don't-write pattern used elsewhere in the
repository.

- **Source of truth:** the Status headers of `docs/decisions/*.md`.
- **Sort:** date descending, then filename ascending — deterministic when two records
  share a date.
- **Columns:** date, topic, status, superseded-by.
- **Failure:** a dirty index fails CI with the diff shown.

#### Final `AGENTS.md` rule set

Replacing the earlier and incorrect claim that "AGENTS.md gains exactly two lines". Every
rule carries its category and control:

| Rule | Category | Control |
|---|---|---|
| Never **push** to `main` | Authoritative | Branch protection (server-side) |
| Never **commit** on a checked-out `main` | **Operator policy** | `SessionStart` warning only — no mechanism intercepts a local commit |
| Never merge or enable auto-merge without per-merge authorization | **Operator policy** | Named human authority |
| Work on the assigned branch in the current worktree; preserve unrelated changes | **Operator policy** | — |
| Worktree lifecycle (`wt switch --create`, `wt remove`) is operator-run | **Operator policy** | — |
| Keep commits scoped and reviewable | **Operator policy** | — |
| Report changed files, validation performed, remaining risk | **Operator policy** | — |
| Fetch and rebase before every push | **Operator policy** | — |
| Never `reset --hard`, `clean -fd`, unqualified `checkout .`/`restore .`, or force-push without a lease | Authoritative (bypassable) | `PreToolUse` hook (decision 5) |
| Reads are direct; changes to Flux-managed state go through Git | Authoritative | Credential tiers (decision 1) |
| A worktree has no cluster credentials until asked for. Stop and ask the operator to mint them | Gotcha | — |
| Platform rollouts, break-glass, recovery, secrets and protection changes are operator-run under `*_CONFIRM` | Authoritative | Admin credential custody |
| GitHub protection mutation needs per-invocation authorization | Authoritative | Guarded recipe + token scope |
| Secrets are SOPS-encrypted; the age key stays with the operator | Authoritative | Key custody; gitleaks; staged-blob check |
| `just ci` is the authoritative cluster-independent gate | Authoritative | Required GitHub check |
| Cluster-dependent suites never enter `just ci` | Authoritative | `validation.test-harness` |
| Run workflows through `mise exec -- just`; no unpinned tools | Authoritative | `mise.lock` |
| Never hand-edit `clusterconfig/`; regenerate from `talconfig.yaml` | Gotcha | — |
| Follow the `apps/<domain>/<app>/` layout | Authoritative | Source-layer policy (decision 3) |
| A Deployment mounting an RWO PVC uses `Recreate` or a StatefulSet | Authoritative | **Rendered**-layer policy (decision 3) |
| Portainer must not become a deployment authority | **Operator policy** | Extracted from the legacy plan |
| Design decisions go in `docs/decisions/`; plans are not committed | Authoritative | `validation.decisions` |
| An `Accepted` record is superseded, never revised | Authoritative | `validation.decisions` |
| An assertion must have an independent oracle or encode an invariant | **Operator policy** | Reviewed at PR time |

The operator-policy category is what the earlier binary test would have deleted. Five of
those rules are the repository's actual governance, and removing them would have breached
the safety non-goal.

#### Fate of every tracked plan and spec

| File | Fate |
|---|---|
| `plans/talos-flux-platform-plan.md` | Distil → `docs/decisions/`, `Status: Accepted` (implemented) |
| `plans/ntfy-flux-implementation-plan.md` | Distil → `docs/decisions/`, `Status: Accepted`; its numbered Decisions are the durable content |
| `plans/media-stack-architecture-plan.md` | Distil → `docs/decisions/`, `Status: Accepted`; "Seerr, not Overseerr" extracted to the app-template domain policy first |
| `plans/portainer-gitops-observability-deployment-plan.md` | Distil → `docs/decisions/`, `Status: Accepted`; "not a deployment authority" extracted to `AGENTS.md` first |
| `plans/test-reporting-standardization-plan.md` | Distil → `docs/decisions/`, `Status: Accepted` |
| `plans/flux-reconciliation-alerting-handoff.md` | Distil → `docs/decisions/`, `Status: Accepted`; residual phone-delivery E2E moves to the testing-expansion session |
| `plans/talos-validation-refactor-plan.md` | **Not distilled.** Unexecuted live intent. Its content becomes input to decision 3's workstream; the file is deleted once that workstream's record exists |
| `docs/superpowers/specs/2026-07-31-lidarr-music-stack-design.md` | → `docs/decisions/`, `Status: Accepted` — implemented by #172 and #174 |
| `docs/superpowers/plans/2026-07-31-lidarr-music-stack.md` | Deleted — executed, and plans are not tracked |

Distilled content lives in the `docs/decisions/` record named in each row. Git preserves
the originals. `docs/superpowers/` is then removed.

### 5. Worktree lifecycle is operator-run; destructive git commands are hooked

The `persistent-git-worktree` skill has been deleted and replaced by
[worktrunk](https://worktrunk.dev/) (`wt`, v0.71.0). The constraints that skill held —
the worktree as a filesystem boundary, no raw `git worktree` lifecycle subcommands,
`--force-with-lease` only, no `reset --hard` or `clean -fd` — currently live nowhere.
`AGENTS.md` retains one line: *"Stay within the assigned worktree and branch."*

#### Agents do not manage worktrees

`wt switch --create` and `wt remove` are **operator-run**. Agents neither create nor
remove worktrees, and no skill is added for it. The reasoning:

- **An agent cannot work in a worktree it creates.** A session is bound to its launch
  directory. Worktrunk's auto-cd relies on interactive shell integration, which an
  agent's non-interactive tool calls do not have. A created worktree is one the agent
  must then *not* enter, and that the operator must open regardless.
- **The window-title problem is solved without automation.** VS Code supports
  `${activeRepositoryBranchName}` and `${activeRepositoryName}` in `window.title`
  (verified in the installed build). One user-level setting placing the branch first
  distinguishes every window, which is the actual problem — the folder names all share
  a `homelab-talos.` prefix and truncate to identical stubs. `.vscode/` is gitignored
  (`.gitignore:35`), so no per-worktree file could be committed anyway.
- **Removal is the risky half and has no upside.** Uncommitted work is unrecoverable;
  removing a worktree the operator has open leaves VS Code pointed at nothing; and
  `wt remove` deletes the branch only *if merged*, so a closed-unmerged PR leaves both
  behind and still needs a human decision.

#### What is hooked, and what it is worth

A `PreToolUse` hook rejects four Bash patterns, all irreversible and none legitimate
for an agent:

| Pattern | Destroys |
|---|---|
| `git reset --hard` | Uncommitted work in the worktree |
| `git clean -fd` (any `-f` with `-d`/`-x`) | Untracked files |
| `git checkout .` / `git restore .` with no limiting pathspec | Working-tree changes |
| `git push --force` / `-f` without `--force-with-lease` | Remote history |

**A boundary hook was considered and rejected.** Blocking paths outside the worktree
root would false-positive on legitimate work: agent sessions routinely read the
installed skill cache and the toolchain, and **write** to the external persistent memory
directory. The boundary was never the risk; irreversibility is, and none of the four
patterns above involves crossing one.

**The hook's strength is "bypassable"** under the table in *The admission test* — an
agent could edit the settings file that defines it. That is accepted, because the threat
model here is **accident, not intent**: agents have not been violating rules, so the
control that pays is the one that catches a destructive command issued in good faith.

#### Known condition: permissions are bypassed

`~/.claude/settings.json` sets `"permissions": { "defaultMode": "bypassPermissions" }`.
No tool call is gated, and every sibling worktree and the main clone are writable
without a prompt. This is a deliberate operator choice and is **out of scope** for this
audit, but it is recorded because it changes what the rules are worth: with no
permission gate, `AGENTS.md` plus this hook are the only controls present.

#### Worktree layout

Two naming schemes coexist — one `homelab-talos-worktrees/…` slot left from the deleted
skill, and four worktrunk-style siblings at `homelab-talos.<branch>`. The worktrunk
convention is adopted; the leftover slot is removed by the operator. Project-level
worktree configuration belongs in `.config/wt.toml`, which worktrunk tracks in the
repository — unlike the personal skill it replaces, which could be and was deleted.

## Not in scope

**Test reporting is retained whole.** All 9,587 lines of Allure, JUnit, campaign, and
catalog machinery and the 1,621-line deployed `test-reports` service stay. The operator's
intent is to *expand* testing — more resilience, E2E, and smoke coverage, reported
through Allure — with tuning and streamlining handled as its own design session. The
post-merge acceptance evidence in decision 2 deliberately lands in that pipeline rather
than beside it.

## Sequencing

Dependencies are strict: containment must exist before the recipes it replaces are
deleted, and policy must exist before the assertions it replaces are deleted.

1. **Rules and credentials.** Rewrite root `AGENTS.md` to the categorised rule set. Bound
   `CLAUDE.md` to harness guidance. Mint the `observer`, `diagnostic`, and `admin` tiers;
   relocate admin credentials; build the command-to-permission matrix; add positive and
   negative authorization tests. Add the destructive-git `PreToolUse` hook and its
   tests. Resolve the `kubectl` contradiction in `kubernetes/README.md`.
2. **Documentation.** Create `docs/decisions/`, `docs/phases/`, `docs/runbooks/`; add
   `validation.decisions` with the identity and immutability semantics above; replace the
   interim link exclusion with introduce-then-freeze; add the generated index; gitignore
   plans; distil per the fate table; retire `docs/superpowers/`.
3. **Containment.** Set explicit `retryInterval` and Helm remediation per Kustomization;
   extend the #154 alert rules with a `NotReady`-duration alert; add Gatus endpoints for
   the ~10 uncovered apps; build post-merge acceptance automation. **No recipe is deleted
   in this step.**
4. **Rollout.** Delete the app-tier bootstrap recipes for apps meeting all three
   eligibility criteria; update `.just/repository.just:1206`; retain qBittorrent, the
   platform tier, and any app that failed eligibility.
5. **Validation.** Build the layered policy set with negative fixtures; produce the
   per-class coverage matrix; then strip subsumed assertions.

## Risks and tradeoffs

- **Deleting the app-tier gate increases agent authority.** Mitigated by the named
  containment contract in decision 2, which must land first, and by CI validation,
  per-app blast radius, Gatus, #154 alerting, and `git revert`. The residual is accepted
  deliberately: the operator reports the gate as toil rather than judgment, and it has
  never vetoed a rollout.
- **Containment replacement may not be equivalent.** Explicit `retryInterval` plus Helm
  remediation bounds thrashing but does not stop reconciliation the way suspension does.
  The compensating control is alerting on `NotReady` duration plus operator break-glass.
  If that proves insufficient in practice, the honest response is to reinstate
  suspension as an automated remediation rather than to accept the gap.
- **The `diagnostic` tier grants `exec`.** That is a real privilege increase over the
  status quo, where agents had no cluster access at all from worktrees. It is bounded to
  five named verifiers and is labelled accurately rather than described as read-only.
- **Scoped credentials are new infrastructure** to mint, rotate, and debug. Choosing a
  bounded token over a long-lived one means it *will* expire mid-diagnosis at some
  point; the remedy is one operator command, and the alternative was a standing
  credential. The admin path remains available to the operator throughout.
- **Credential scope now depends on directory**, which is implicit state. A worktree
  that never received a scoped config simply has no access, and a main-clone session
  silently has admin. The `SessionStart` hook exists to make that visible, and
  `README.md` documents it; neither makes it explicit at the moment of use.
- **A layered policy set is a single point of failure per layer.** Mitigated by negative
  fixtures per rule and by `validation.policy-unit`.
- **Stripping assertions could drop one that mattered.** Mitigated by the per-class
  coverage matrix, which is a precondition for deletion rather than a follow-up.
- **Distillation is judgment.** Six documents are compressed substantially, and the
  compressor decides what mattered. Git preserves the originals, and live constraints are
  extracted before distillation rather than during it.
- **The admission test is itself an instruction.** Nothing mechanically prevents a future
  rule that fits no category. Accepted; the test's value is that it makes the question
  answerable, not automatic.
- **This record is large.** Splitting it into per-subsystem decisions was proposed in
  review and declined — see the disposition below. The mitigation is that each workstream
  in Sequencing has its own acceptance criteria stated inline.

## Decisions recorded

1. Root `AGENTS.md` is the only surface for **repository rules**. `CLAUDE.md` is a
   permitted vendor shim bounded to harness-specific operating guidance.
2. Every rule is an authoritative control, an operator policy, or a gotcha, and states
   its category and supporting control. Anything else is deleted.
3. Enforcement mechanisms are not equivalent; a rule may not claim more than its
   mechanism delivers. Workflow may be stated once alongside enforcement; a prohibition
   may not be restated.
4. Cluster access is governed by effect and enforced by three credential tiers:
   `observer`, `diagnostic`, `admin`.
5. `diagnostic` grants `exec` and `port-forward` and is **not** read-only. The security
   claim is limited to denying the Secret API.
6. App-tier bootstrap recipes are deleted **only after** the containment contract exists,
   and only for apps meeting all three eligibility criteria.
7. Platform tier is defined by objective criteria, not a list. qBittorrent is exempt;
   `metrics-server` is retained pending its own review.
8. Post-merge acceptance has a named actor, trigger, timeout, evidence location, and
   failure response.
9. A layered policy set — source, resource, rendered, domain — replaces change-detectors.
   `media.rego` is retained as the app-template domain layer, not extended repo-wide.
10. An assertion must have an independent oracle or encode an invariant.
11. A per-assertion-class coverage matrix is a precondition for deleting any assertion.
12. Design decisions live in `docs/decisions/` with defined identity, comparison base,
    and immutability semantics. The author writes `Accepted` in the landing pull
    request; acceptance is never inferred from merging.
13. Link validation is introduce-then-freeze, replacing the interim blanket exclusion.
14. The index is generated and committed, with CI comparing rather than writing.
15. Implementation plans are written but not committed.
16. Filenames are date-based, not sequentially numbered, because worktrees run in
    parallel.
17. Test reporting is out of scope and slated for expansion, not reduction.
18. Agents neither create nor remove worktrees. Worktree lifecycle is operator-run
    through worktrunk, and no skill is added for it.
19. A `PreToolUse` hook blocks four irreversible git patterns. A worktree-boundary hook
    is rejected: the boundary is not the risk, and blocking it would break legitimate
    out-of-tree reads and memory writes.
20. `bypassPermissions` is recorded as a known condition, not changed here. It is why
    `AGENTS.md` and the hook are the only controls present.
21. Credential tier follows directory: main clone holds admin, worktrees hold
    observer/diagnostic, at the same repository-relative paths. `just talos kubeconfig`
    resolves conditionally and doubles as the token-refresh recipe. `README.md`
    documents the mapping.
22. Kubernetes tokens carry a 30-day TTL; the `os:reader` talosconfig carries 90 days.
    Credentials are minted **on demand**, never at worktree creation: a worktree starts
    with none, and an agent needing cluster access stops and asks the operator to mint
    it. Shared or symlinked credentials are rejected — the ask is the signal.
23. A `SessionStart` hook announces the credential tier and branch, warns when a session
    runs in the main clone on `main`, and warns when SOPS key material is present in the
    environment. It warns; it does not block.
24. The operator/agent division of labour is redrawn as a consequence: agents run
    offline validation and live verification; the operator keeps secrets, platform
    rollouts, credential minting, and merges.
25. SOPS handling is unchanged: the age key stays with the operator, is populated only
    by a manual `export`, and never enters an agent session. `just ci` remains
    secret-free.

## Review disposition

Independent review of 2026-08-02 raised seven blocking findings, six important, and three
optional. All seven blocking findings were verified against the repository and accepted;
two were accepted with modification, and two non-blocking findings were declined by the
operator.

**Accepted with modification:**

- *Policy coverage matrix* — accepted, but at per-assertion-**class** granularity. A
  567-row matrix would be rubber-stamped rather than read.
- *Instruction alongside enforcement* — accepted, but bounded to stating the workflow
  once. Restating a prohibition beside its enforcement is what produced the churn.

**Declined by the operator, recorded so they are not silently reopened:**

- *Split into separate decisions per subsystem.* Declined in favour of one record with
  the missing detail filled in. Rationale: cross-subsystem dependencies — containment
  before rollout deletion, policy before assertion deletion, credentials before verifier
  changes — are the substance of the design, and separate records would put them in
  cross-references rather than in one sequence.
- *Defer phase relocation and plan distillation.* Declined. The stale-prose defect is
  real and present, the work is largely mechanical, and deferring leaves 3,531 lines
  reading as current guidance.

**Found during verification, not in the review:** `.just/repository.just:1206` hardcodes
`-eq 24` for `require_deployed_source` occurrences and breaks when recipes are deleted.

## Follow-up

Each is its own design session:

- **Testing expansion** — resilience, E2E, and smoke coverage through Allure; tuning and
  streamlining the existing reporting machinery; absorbing the residual Flux
  phone-delivery E2E.
- **`metrics-server`** — 345 lines with three confirmation gates; does it satisfy any
  platform criterion?
- **Platform-tier consolidation** — whether registry-driven generation pays for the
  surviving guarded recipes.
- **qBittorrent** — whether the VPN-disconnect chaos gate can become an automated
  post-merge acceptance check, which would make it eligible for the one-PR path.

## Appendix A — Methodology

Counts in *Current-state findings* are a snapshot at `15bf87f`. They motivate the
decisions; they are **not** acceptance criteria, and implementation is not judged by
reproducing them.

| Figure | Method |
|---|---|
| Repository mass | `git ls-files <dir> \| xargs wc -l`, summed per top-level directory |
| Identical rollout sequences | Each recipe body reduced to an ordered tag sequence by matching 15 fixed patterns (trap, kubeconfig check, git remote, `require_deployed_source`, staged-suspended, validate, source reconcile, `flux-verify`, cluster-apps reconcile, live-suspend, CONFIRM, resume, app reconcile, wait, verify); sequences compared for equality |
| Assertion classification | Lines beginning `[[` in `scripts/validate/*.sh`. **Tautology** = matches `== 'true' \|\| … == 'false'`. **Change-detector** = a `yq` extraction compared to a string literal. **Structural** = everything else, plus counts of `kustomize build`, `helm template`, `conftest`, `kubeconform` |
| Same-commit validator edits | For each commit since 2026-06-01 touching `kubernetes/apps/<ns>/<app>/`, whether it also touched `scripts/validate/<app>.sh` |
| Read vs mutating calls | Verb following `kubectl\|flux\|talosctl\|helm\|cilium` and any flags, bucketed by a fixed read/write verb list |
| Cross-cutting recipe edits | Distinct recipe names appearing in `git show -U0` hunk headers per commit |

Classification is heuristic. The change-detector count in particular depends on a
regular expression and should be treated as approximate; the qualitative finding — that
a large majority of assertions restate values from the files they read — is what the
decisions rest on.

## Appendix B — Operator bootstrap

Source material for the `docs/runbooks/` entry that workstream 2 creates. Steps marked
**(proposed)** do not exist until workstream 1 lands; everything else works today.

### Fresh clone of `main` — once

```bash
# Clone over HTTPS. Bootstrap guards assert
# https://github.com/7yXwscXEzv6phzUnKfrw/homelab-talos.git, so an SSH clone
# fails every require_deployed_source check.
git clone https://github.com/7yXwscXEzv6phzUnKfrw/homelab-talos.git
cd homelab-talos

mise trust
mise install --locked
mise exec -- just repo tools          # installs and prints every pinned version
mise exec -- just repo hooks          # pre-commit — see the known gap below

export SOPS_AGE_KEY='AGE-SECRET-KEY-…'   # operator shell only, never a shell profile
mise exec -- just repo secrets           # asserts the identity matches .sops.yaml

mise exec -- just talos generate      # → .talos/config  (requires the age key)
mise exec -- just talos kubeconfig    # → .kube/config   (admin, from Talos PKI)

mise exec -- just ci
```

Git resolves hooks from `$GIT_COMMON_DIR/hooks`, which every worktree shares, so
`just repo hooks` is run once in the main clone and covers all of them.

### New worktree — per worktree

```bash
cd ~/Development/homelab-talos        # run wt from the main clone
wt switch -c my-feature
mise trust                            # idempotent; avoids a first-run prompt
mise exec -- just ci                  # first run builds .venv: slow, needs network

# NOT run at creation. Only when a session turns out to need the cluster:
mise exec -- just talos kubeconfig    # (proposed) in a worktree mints BOTH:
                                      #   .kube/config   30-day observer token
                                      #   .talos/config  90-day os:reader
                                      # unchanged admin download in the main clone.
                                      # Re-run to refresh an expired credential.
```

No `.kube/config` or `.talos/config` is created in a worktree — today because nothing
creates one, and after workstream 1 because credentials are minted **on demand**. An
agent that needs cluster access stops and asks; the operator runs the recipe above in
that worktree. Most worktrees never need it: all four current branches touch only
`docs/` and `scripts/`.

### First-run failure modes in a fresh worktree

| Cause | Symptom | Prevention |
|---|---|---|
| `.venv` absent | First `uv run` inside `just ci` stalls building the environment | Run `just ci` once after creating the worktree |
| `mise` config untrusted | Prompt or refusal on first tool call — **an unattended agent hangs** | `mise trust` |
| Pre-commit not installed | Commits silently unchecked | `just repo hooks`, once, in the main clone |

The trust prompt is the only hard failure for automation; the others cost time or
coverage rather than blocking.

### Known gap: pre-commit is not installed

Verified on 2026-08-02: no pre-commit hook exists in the main clone, in any worktree
gitdir, or in the shared common dir. `just repo hooks` exists but has never taken
effect, so the staged-file layer described in `AGENTS.md` currently provides nothing.
`just ci` still gates every pull request, so this is a loss of local fast feedback
rather than of enforcement.

Workstream 1 fixes it, and the fix must **confirm empirically** that `pre-commit
install` targets `$GIT_COMMON_DIR/hooks` rather than the per-worktree gitdir. If it
targets the latter, the hook covers one worktree while appearing installed, and
`core.hooksPath` must be set explicitly instead. This is a test, not a command.

## Appendix C — Expected size

Non-binding, and deliberately not a design signal. Roughly −1,100 lines of rollout
scaffolding, −1,500 to −1,900 validators, and −3,131 of prose, against additions for
policy layers, credentials, containment configuration, post-merge automation, and CI.
Success is judged by the named safety and maintenance outcomes in each decision, not by
net lines. A retained control that costs lines is not a failure.
