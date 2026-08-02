# Agent Rules Audit and Repository Retrospective

## Status

- **Status: Accepted.** No implementation performed.
- Date: 2026-08-02
- Branch: `challenge-agent-rules`
- Supersedes: `docs/superpowers/specs/2026-07-31-agents-md-information-architecture-design.md`,
  and with it the four-PR plan in
  `docs/superpowers/plans/2026-07-31-agents-md-information-architecture-implementation-plan.md`.
  PR #171 is closed unmerged; PR #170 (the reference validator) is merged and retained.

This document establishes the convention it follows. Design decisions are recorded in
`docs/decisions/YYYY-MM-DD-<topic>.md`. Status is one of `Draft`, `Accepted`, or
`Superseded by <filename>`. An accepted record is superseded, never revised.

## Problem

The repository's governing rules had been rewritten four times in four days — #162
removed 76 lines of worktree constraints, #163 added a skills section, #165 compressed
162 lines to 75, #169 deleted the skills section — while two successive architecture
plans were written and superseded. Net rule content finished roughly where it started.

The rules were never wrong in a way anyone could name. They were never *tested* either.
No rewrite had an acceptance criterion, so no rewrite could be finished, and the churn
had no natural stopping point.

This audit asks a different question from its predecessor. The 2026-07-31 design asked
where each rule should *live*. This one asks whether each rule should *exist*.

### Current-state findings

Verified against `15bf87f` on 2026-08-01/02.

**Repository mass.** 18,523 lines of cluster payload under `kubernetes/`, against
32,652 lines of machinery (`scripts/`, `tests/`, justfiles, CI, `talos/`) and 14,950
lines of prose. Only 28% of the repository is the thing being managed. `scripts/`
alone, at 23,020 lines, is larger than all of `kubernetes/`.

**Rollout scaffolding.** `.just/bootstrap.just` is 2,635 lines across 28 recipes with
72 `*_CONFIRM` references. Of the 22 resume-style recipes, **18 have a byte-identical
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

**Flux is already configured to do the job.** All 33 Kustomizations carry `wait: true`
and a `timeout` (5m–20m); 32 of 33 declare `dependsOn`; and `suspend` is unset on every
one. Ordered, health-gated, time-bounded rollout is already declarative. The suspended
state exists only in the window between an app's "stage" PR and its "activate" PR — a
window in which `main` states something untrue about the cluster.

**Validation.** Across `scripts/validate/*.sh`, 797 assertions decompose into 22
tautologies (`[[ "$suspend" == 'true' || "$suspend" == 'false' ]]`, which cannot fail),
567 change-detectors comparing a `yq` extraction to a literal from the file it just
read, and 208 structural checks. **73% of assertions provide no independent signal.**

The change-detectors do not function as tripwires: 47 of 119 app-config changes since
2026-06-01 (39%) edited the config and its own validator in the same commit. When one
author moves both sides of an equality, the assertion is not a check.

Meanwhile `tests/policy/media/media.rego` is the correct pattern, already built — one
policy covering nine apps with named, reasoned exemptions (`stateless_internal_apps`,
`uiless_worker_apps`), enforcing pinned images, no mutable tags, dropped capabilities,
and dependency ordering. `kubernetes/mod.just:152` applies it to `kubernetes/apps/media`
only. **Nine of 33 Kustomizations have policy coverage.** The other 24 are the vacuum the
567 assertions grew into.

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
Any reduction in actual safety — where a control is removed, an equal or stronger one
replaces it.

## The admission test

One root `AGENTS.md`. Every rule in it must be:

- **Enforced** — a hook, CI check, guard, or credential backs it; or
- **A gotcha** — non-obvious knowledge an agent cannot infer from the repository.

A rule that is neither is deleted. A rule that *could* be enforced is converted to
enforcement and then removed from the file, rather than stated in both places.

This is the standing test for future rule proposals. It is the mechanism that ends the
churn: a proposed rule now has an answer rather than an argument.

### Why no nested layer

The 2026-07-31 design proposed root plus three nested `AGENTS.md` files plus
`docs/runbooks/` plus `docs/`, governed by a formal admission test, "additive
inheritance", and a precedence block. That is rejected on three grounds:

1. **The size premise does not hold.** 67 lines is far below every published split
   threshold. Splitting to save context optimises a cost that is not being paid.
2. **Additive inheritance contradicts the specification.** AGENTS.md is nearest-wins.
   "Nested may narrow but never relax" is implemented by no harness, so it would run
   entirely on agents reading and honouring a bespoke precedence block.
3. **It adds surfaces without removing rules.** The measured problem was never that
   rules were hard to find.

`docs/runbooks/` is retained. Procedure is descriptive and is not loaded every session,
so it does not compete for the same budget.

## Decisions

### 1. Cluster access is governed by effect, not by tool

The rule *"All cluster mutations and health checks use guarded `just` recipes; never run
raw `kubectl`, `talosctl`, `helm`, or `flux`"* bans a tool where the risk is an effect.
`kubectl get pods` and `kubectl delete ns media` carry identical prohibitions, while the
guarded recipes invoke `kubectl` with full admin rights regardless — so the rule
constrains spellings, not blast radius. It is also unenforced, and 53% of what it forces
through wrappers is read-only.

Replaced by:

| Effect | Rule | Enforced by |
|---|---|---|
| **Read** | Unrestricted | `view`-scoped kubeconfig (plus logs/metrics delta); `os:reader` talosconfig |
| **Mutate Flux-managed state** | Forbidden — Git is the interface | The credential; the call fails at the API server |
| **Bootstrap, break-glass, recovery** | Guarded recipe + `*_CONFIRM`, operator-run | Admin config, held by the operator |

This is **stricter than today**, not looser: mutation moves from advisory to
mechanically impossible for an agent. The `view` role also excludes Secrets, closing
secret exposure as a side effect. AGENTS.md retains only what the credential cannot
express — *why* Git is the interface — and drops the prohibition itself.

Worktrees already lack cluster access accidentally, because `bootstrap.just` reads
`.kube/config` relative to the repository root. This makes that deliberate.

The gain is friction, not line count. `scripts/diagnose/` is three files and the
`<app>-verify` scripts are retained as repeatable acceptance checks. What ends is the
requirement to author and commit a script before the cluster can be asked a question.

### 2. App-tier bootstrap recipes are deleted

Scored against Flux's existing configuration, the 15 steps of a bootstrap recipe are:
one already running in CI (`validate`), one genuinely additional (`<app>-verify`, live
acceptance), three duplicating `dependsOn` + `wait: true` + `timeout`, one duplicating
Flux's own failure behaviour, and **nine that exist only because the rollout is manual**
— kubeconfig and git-remote checks, `require_deployed_source` (Flux runs `origin/main`
by definition), the staged-suspended check, the CONFIRM. The guards largely guard
against hazards created by the mechanism they implement.

Measured cost: two PRs per app. Lidarr shipped as #172 then #174, and its own design
spec names the cause — *"Two-PR rollout with an operator bootstrap gate, forced by the
existing Gatus/suspend interlock."*

An app now ships **unsuspended in one PR**. `just ci` validates pre-merge; Flux performs
the rollout; Gatus and the #154 Flux reconciliation alerting detect failure; `git revert`
is the rollback.

`<app>-verify` is retained and is run **after Flux reports the Kustomization Ready**, by
either the operator or an agent, using the read-only credential from decision 1. It is a
check, not a gate: nothing blocks on it, and a failure is handled by fixing forward or
reverting rather than by re-suspending. This is what removes its dependency on the
rollout being manual.

**Platform tier keeps full guards**: `talos`, `cilium`, `flux*`, `foundation`,
`storage`, `csi-driver-smb`, `metrics-server`. Cilium is the CNI, and Flux cannot
bootstrap the layer it runs on.

The corresponding AGENTS.md rules are deleted or narrowed:

| Rule | Fate |
|---|---|
| "New apps begin suspended, roll out through guarded `just bootstrap <app>`, then persist the unsuspended state" | Deleted |
| "If a needed cluster operation has no recipe, add an appropriately guarded recipe" | Narrowed to irreversible or cluster-wide operations |
| "`bootstrap …` recipes require `*_CONFIRM` and are operator-run" | Narrowed to platform tier |
| Root vs `kubernetes/README.md:123` `kubectl apply` contradiction | Resolved — bootstrap and recovery applies run through guarded recipes, so no exception is required |
| Phase-N notation | Dropped on every line touched: 59 sites in `bootstrap.just`, 13 of 18 confirmation strings |

### 3. Policy replaces change-detectors

`conftest` extends from `kubernetes/apps/media` to `kubernetes/apps`, generalising
`media.rego`'s exemption tables in their existing documented style. Coverage goes from
9 to 33 Kustomizations, and newly added apps are covered on arrival rather than when
someone writes a validator.

Per-app bash assertions the policy subsumes are then deleted. Retained, because each
prevents a failure that is not "someone edited this file":

- **External facts learned the hard way** — `infraAssessmentScannerEnabled == false`
  ("cannot run on Talos, read-only host"), FlareSolverr's numeric UID 1000,
  qbit-manage's `directory.root_dir`. These are regression tests for real outages and
  must carry their reason inline.
- **Cross-file consistency** where two files must agree and neither is authoritative —
  the `rg -qx` check that a `ks.yaml` is listed in its parent kustomization, which
  catches the "directory exists but is not deployed" trap.
- **Render-effect checks** — Trivy asserting `OPERATOR_SBOM_GENERATION_ENABLED` in the
  *rendered ConfigMap* rather than in `values.yaml`. This is the only assertion pattern
  that catches an upstream chart renaming a values key, and it appears once. It should
  be the model.
- **External contracts the repository does not own** — chart repository URLs, and the
  Gateway VIP and Pi-hole resolver IP already centralised in `scripts/lib/network.sh`.

Deleted: literal equality on a freely chosen internal value (hostname, port, image
repository, storage class); file-existence checks that `kustomize build` already fails
on; and the 22 tautologies.

A new rule is added under the admission test: **a validator assertion must be
structural.** An assertion restating a value from the file it reads is not a test.

`plans/talos-validation-refactor-plan.md` is not archived. It is unexecuted, it reached
the same diagnosis independently, and it is input to this work.

### 4. Documentation is split by status, not by tooling

```
docs/decisions/YYYY-MM-DD-<topic>.md   design records; superpowers' spec shape
docs/decisions/README.md               CI-generated index (date, topic, status)
docs/phases/                           15 rollout records — execution evidence
docs/runbooks/                         live procedure
docs/                                  live reference
<gitignored>                           implementation plans — written, never committed
```

Specs record *why* and age well; plans are task lists and age badly, so plans are
written for execution but not tracked. This follows ADR practice, where the decision
record is kept and the schedule is not.

The document shape is **exactly what superpowers already emits** — its sections already
map onto MADR's (Status, Problem, Goals/non-goals, Considered options, Decisions
recorded, Risks and tradeoffs). No template is imposed; imposing one would add ceremony
to a shape that works. What is added is the Status line supporting `Superseded by`, and
the discipline that an accepted record is superseded rather than revised.

Filenames stay date-based rather than MADR's `NNNN-`. Sequential numbering collides
across parallel worktrees, which this repository uses, and numbering was never what
solved the problem — the Status field is.

AGENTS.md gains exactly two lines, both passing the admission test:

```markdown
- Design decisions are recorded in `docs/decisions/YYYY-MM-DD-<topic>.md`, not
  `docs/superpowers/`. Implementation plans are written but never committed.
- A record with `Status: Accepted` is superseded, never revised. Write a new
  record and set the old one to `Superseded by <filename>`.
```

The first is a gotcha — it overrides a hardcoded default at `brainstorming/SKILL.md:107`
and cannot be inferred. The second is a judgment rule; CI catches the mechanical part.

A `validation.decisions` suite asserts that every record carries a Status from the known
vocabulary, that any `Superseded by` target resolves, that a record already `Accepted` on
`origin/main` is unmodified except for its Status flipping, and that the index is
current.

`docs/decisions/` inherits the link-validator exclusion already granted to
`docs/superpowers/*` by #170. Without it, a referenced file moving would make an
immutable record fail the link check with no legal way to repair it.

The seven legacy plans are distilled to roughly 400 lines total, after their live
constraints are extracted to the files that own them — "Seerr, not Overseerr" into the
media policy, "Portainer must not become a deployment authority" into AGENTS.md. Git
preserves the originals.

`docs/superpowers/` is emptied and removed. Its four tracked files resolve as:

| File | Fate |
|---|---|
| `specs/2026-07-31-agents-md-information-architecture-design.md` | Moves to `docs/decisions/`, `Status: Superseded by 2026-08-02-agent-rules-audit.md` |
| `specs/2026-07-31-lidarr-music-stack-design.md` | Moves to `docs/decisions/`, `Status: Accepted` — implemented by #172 and #174 |
| `plans/2026-07-31-agents-md-information-architecture-implementation-plan.md` | Deleted; its design is superseded and plans are no longer tracked |
| `plans/2026-07-31-lidarr-music-stack.md` | Deleted; executed, and plans are no longer tracked |

The link-validator exclusion transfers from `docs/superpowers/*` to `docs/decisions/*`
with them, rather than being added alongside.

## Not in scope

**Test reporting is retained whole.** All 9,587 lines of Allure, JUnit, campaign, and
catalog machinery and the 1,621-line deployed `test-reports` service stay. The operator's
intent is to *expand* testing — more resilience, E2E, and smoke coverage, reported
through Allure — with tuning and streamlining handled as its own design session. This
audit deliberately takes no position on its size.

## Sequencing

Rules first, because they are the licence for everything that follows; then
documentation, which is independent; then the rollout deletion; then validation, which
is the largest and benefits from the policy landing before the assertions leave.

1. **Rules and credentials.** Rewrite root `AGENTS.md` against the admission test. Mint
   the `view`-scoped kubeconfig and `os:reader` talosconfig. Close #171. Resolve the
   `kubectl` contradiction in `kubernetes/README.md`.
2. **Documentation.** Create `docs/decisions/`, `docs/phases/`, `docs/runbooks/`; retire
   `docs/superpowers/`; add the `validation.decisions` suite and generated index;
   gitignore plans; distil the seven legacy plans after extracting their live
   constraints.

   The `docs/decisions/*` link-validator exclusion lands **with this record** rather
   than in this step, because the record names `docs/phases/` and `docs/runbooks/`
   before they exist and would otherwise fail `validation.links` on commit.
3. **Rollout.** Delete the 18 app-tier bootstrap recipes and their confirmation
   variables; retain `<app>-verify` as post-merge checks; keep the platform tier intact.
4. **Validation.** Extend `conftest` repo-wide; then strip subsumed assertions,
   retaining the four categories above with their reasons stated inline.

Expected net change is roughly **−5,000 lines**: −1,100 rollout scaffolding, −1,500 to
−1,900 validators, −3,131 prose, against approximately +550 of policy, credentials, and
CI. Line count is a consequence, not a target.

## Risks and tradeoffs

- **Deleting the app-tier gate increases agent authority.** Mitigated by controls that
  already exist and are already proven: CI validation pre-merge, per-app blast radius
  via independent Kustomizations, Gatus probing, #154 Flux reconciliation alerting, and
  `git revert`. The residual is accepted deliberately: the operator reports the gate as
  toil rather than judgment, and it has never vetoed a rollout.
- **Stripping assertions could drop one that mattered.** Mitigated by extending policy
  *before* deleting anything, and by classifying every retained assertion into one of
  four named categories with its reason inline. An assertion that fits no category and
  cannot be justified is the one being removed.
- **A single shared policy is a single point of failure.** A defect in the repo-wide
  rego reaches all 33 apps at once, where a per-app bash bug reached one. Mitigated by
  `validation.policy-unit`, which already unit-tests the rego, and by the fact that the
  media policy has run this way for nine apps without incident.
- **Scoped credentials are new infrastructure to mint, rotate, and debug.** Small — a
  ServiceAccount, a ClusterRoleBinding, and one guarded recipe — but non-zero, and a
  broken read-only config blocks diagnosis at exactly the wrong moment. The admin path
  remains available to the operator throughout.
- **Distillation is judgment.** Seven documents are compressed by roughly 90%, and the
  compressor decides what mattered. Git preserves the originals, and live constraints
  are extracted before distillation rather than during it.
- **The admission test is itself an instruction.** Nothing mechanically prevents a
  future rule that is neither enforced nor a gotcha. This is accepted; the test's value
  is that it makes the question answerable, not that it makes it automatic.

## Decisions recorded

1. Root `AGENTS.md` is the only agent instruction surface. No nested files.
2. Every rule must be enforced or a gotcha; anything else is deleted or converted.
3. A rule that can be enforced is converted to enforcement and removed from the file,
   not stated in both places.
4. Cluster access is governed by effect, not by tool, and enforced by scoped
   credentials rather than instruction.
5. Reads are unrestricted. Mutation of Flux-managed state is prevented by the
   credential. Bootstrap and break-glass keep guarded recipes.
6. The 18 app-tier bootstrap recipes are deleted; apps ship unsuspended in one PR.
7. The platform tier retains full `*_CONFIRM` guards.
8. Policy as code is extended repo-wide; subsumed per-app assertions are deleted.
9. A validator assertion must be structural; restating a value from the file it reads
   is not a test.
10. Design decisions live in `docs/decisions/` with a Status field; accepted records are
    superseded, never revised.
11. Implementation plans are written but not committed.
12. Filenames are date-based, not sequentially numbered, because worktrees run in
    parallel.
13. Test reporting is out of scope and slated for expansion, not reduction.
14. The 2026-07-31 information architecture design is superseded and PR #171 is closed
    unmerged. PR #170's reference validator is retained.

## Follow-up

Each of these is its own design session, not a task in this one:

- **Testing expansion** — resilience, E2E, and smoke coverage, reported through Allure;
  including tuning and streamlining the existing 9,587 lines of reporting machinery.
- **`metrics-server`** — 345 lines with three separate confirmation gates, the largest
  and most irregular recipe in `bootstrap.just`. It survives the app-tier deletion as
  platform tier, but its shape is an outlier worth examining.
- **Platform-tier consolidation** — whether registry-driven generation still pays for
  the roughly five surviving guarded recipes, or whether duplication is acceptable at
  that count.
- **`qbittorrent`'s two-stage rollout** — the only recipe running the standard sequence
  twice, tied to the Gluetun VPN sidecar. Its staging needs may not survive the app-tier
  change unexamined.
