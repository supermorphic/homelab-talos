# Agent Instruction and Skills Architecture

## Status

- Revision: 5 (2026-07-29). Reviewed REVISE AND RESUBMIT four times: revision 1
  (7 MAJOR, 1 MINOR), revision 2 (1 BLOCKER, 4 MAJOR, 4 MINOR), revision 3
  (1 BLOCKER, 2 MAJOR, 2 MINOR), revision 4 (1 BLOCKER, 1 MAJOR, 3 MINOR). All
  dispositions are recorded in "Plan review disposition", including the findings the
  amendments decline or partly decline on verified evidence. **Every technical
  finding across all four passes is now closed; the sole remaining blocker is
  operator evidence that no agent can produce.**
- Status: **Draft — blocked on two operator client-discovery observations, one
  seven-item decision bundle, and decision 8 recorded separately; then a
  fresh-context independent plan review and operator approval. No implementation
  performed.**
- Baseline: `origin/main` at `c1201e6`
- Working branch for this plan document: `docs/agent-skills-architecture-plan`
- Assignment: an operator-supplied planning handoff brief, held outside version
  control. Its requirements are reproduced in this document; no repository file
  depends on it.
- **The remaining blocker is not closable by an agent.** It requires launching both
  clients against a scratch repository outside this worktree, which is operator-run
  by the repository's own boundary rules. Revision 4 reduces it to the smallest
  honest form: **two observations with a ready-to-paste fixture**, and **one
  accept-or-override decision bundle**. Everything else that revision 3 gated on has
  been made conditional or moved to implementation-time validation where it belongs.

## Executive summary

`AGENTS.md` is drifting from a policy control plane into a procedure manual. It was
created at 79 lines on 2026-07-22 and is 162 lines today, and **every net line added
after creation was procedural**, not policy. Forty-three percent of it is now one
Git-worktree procedure. The same rules are independently restated in `README.md`,
where the copies have already diverged — `AGENTS.md` carries the operator-override
carve-out on the never-self-merge rule and `README.md` does not.

This plan separates four things that are currently tangled:

1. **Always-on policy** — a small set of invariants every session must carry.
2. **On-demand procedure** — repeatable workflows loaded only when relevant,
   packaged as Agent Skills under `.agents/skills/`.
3. **Durable documentation** — architecture, topology, and human procedure, which
   stay in `docs/` and `plans/` and are linked from skills, never restated in them.
4. **Deterministic enforcement** — `just` recipes, validators, and guards, the only
   layer that constrains behavior rather than requesting it.

The first implementation phase establishes the **complete core review lifecycle**:
worktree management, project planning, and three sequential gates — plan review
before implementation, code review after it, PR readiness after remediation — each
performed by an independent model family with fresh context, none able to approve
its own work. Domain skills are deliberately deferred until that foundation exists,
because domain skills written first would each invent their own review and evidence
conventions.

The distinguishing bet: **repository policy and validation contracts live in the
repository; the model, client, and Git provider are replaceable execution layers.**
Where instruction and enforcement disagree, enforcement wins by construction.

## Current-state findings

Verified against the working tree at `c1201e6`. Counts re-verified for revision 2.

### Instruction layer

- `AGENTS.md` — 162 lines. L33–101 (69 lines) is worktree procedure. Its own trailer
  (L161) states that "detailed procedures live in `just` recipes and `docs/`" — a
  boundary that block violates.
- Growth history: created at 79 lines in `f321a86`; `+31`, `+38/−17`, `+25/−2`,
  `+10/−2` across four subsequent commits. All growth is procedure.
- `CLAUDE.md` — 10 lines, touched exactly once (initial commit), never updated
  across those four revisions. **It references a `MEMORY.md` that has never existed
  in this repository's history** — a live dangling reference, and the clearest
  argument for deterministic link validation.
- No `.claude/`, `.agents/`, `.codex/`, or skill content exists today. No
  `AGENTS.override.md` exists at any level.
- `.gitignore` ignores neither `.claude/` nor `.agents/`; both are committable. The
  repository tracks **zero symlinks**, so an adapter symlink is a new precedent.

### Duplication clusters

Eight were found. The load-bearing ones:

1. Worktree rules — `AGENTS.md` L33–101 vs `README.md` L96–172.
2. Never-self-merge — `AGENTS.md` L20–27 (with the per-merge operator-override
   carve-out) vs `README.md` L90 and L134 (unqualified). **The two sources actively
   disagree in the exception case.**
3. "`just ci` is cluster-independent and secret-free" — five-plus copies across
   `AGENTS.md`, `README.md`, `.justfile`, `.github/workflows/ci.yml`,
   `tests/README.md`, `docs/testing-layers.md`.
4. Flux app layout — `AGENTS.md` L147–151 is a lossy summary of the more detailed
   `kubernetes/README.md` L6–36.

The counter-example worth preserving as the model: `AGENTS.md` L152–153 **points to**
README's ReadWriteOnce section instead of copying it.

### Enforcement layer

- `just ci` → `scripts/test/run-ci.sh` → reads `executions.ci` from
  `tests/catalog.yaml`, which contains **31 suites** (corrected from revision 1's
  "30"), ordered and fail-fast. CI runs exactly `mise exec -- just ci`; the required
  status check is `ci`. **No workflow edit is ever needed to add a suite** — the
  catalog is the indirection.
- Adding a validator is a five-step pattern: `scripts/validate/<x>.sh` (Bash plus
  `yq`/`rg`, executable, ShellCheck-clean) → recipe in `.just/repository.just` →
  suite in `tests/catalog.yaml` → entry in `executions.ci` (a count assertion
  enforces 1:1) → README recipe-table row. Closest template:
  `scripts/validate/gatus.sh`.
- **The catalog schema is closed.** `scripts/test/validate-catalog.sh:83` restricts
  `tier` to `offline|verification|smoke|integration|e2e|resilience|diagnostics|
  measurement|conformance`, and line 99 restricts `execution_owner` to exactly
  `shared` or `human`. Any new tier or ownership value is a schema change, not a
  data addition — this materially constrains the evaluation design below.
- The Allure tooling renders and publishes JUnit-backed runs. It does not invoke
  models, capture agent traces, or grade behavioral assertions, and non-CI suites
  are reached through fixed campaigns or live dispatch recipes rather than a generic
  runner.
- **No markdown, link, or frontmatter linter exists anywhere in the repository.**
  Precedent for hard structural assertions exists: `just repo verify` asserts a
  literal `require_deployed_source` count of 23.

### Plan retention — a practice, not a documented convention

Nine plan files have been deleted across seven commits, and three of those commit
subjects use the word "retire" explicitly (`#152`, `#101`, `#80`). So a retirement
*practice* is real and evidenced. But it is **undocumented and inconsistently
applied**: six plans remain tracked today, including
`portainer-gitops-observability-deployment-plan.md`, which is complete. Revision 1
overstated this as "the repository's convention". Revision 2 states the evidence and
requires an explicit retention decision rather than invoking an unwritten rule.

### Parallel execution — observed state

Observed 2026-07-29 while drafting revision 1; slot 4 re-observed for revision 3:

```
homelab-talos          c1201e6 [main]                                # primary
homelab-talos-agent-1  c1201e6 [test/tailscale-coverage]             # unmerged
homelab-talos-agent-2  9d1d8c8 [feat/ntfy-credential-lifecycle]      # unmerged
homelab-talos-agent-3  8e2a7de [fix/flux-alert-signal-validation]    # unmerged
homelab-talos-agent-4  c1201e6 [docs/agent-skills-architecture-plan] # this plan
```

Slot state is inherently dynamic. This table is dated evidence for the design
argument below, not a live inventory — `just repo slots` is the live view, and the
plan does not depend on any particular slot being free.

**`README.md` L103–111 documents three slots; four exist.** Three are parked on
unmerged branches at three different base commits — exactly the state where
integration order and rebase discipline decide whether `just ci` results remain
meaningful.

### Scale

492 tracked files; 54 markdown files totalling 10,760 lines; 32 apps across 8
domains; `.just/bootstrap.just` alone is 127 KB.

## Problems being addressed

1. `AGENTS.md` accumulates procedure and will keep growing, spending context in
   every session on material most sessions do not need.
2. Normative agent rules are duplicated into human documentation, where copies drift
   and already contradict each other.
3. There is no deterministic validation of the instruction layer, so dangling
   references and stale recipe names survive indefinitely.
4. Repeatable procedures — planning, review, remediation, readiness — live only in
   prose and session memory, and are re-derived from scratch each session.
5. Parallel agent work is documented as operator setup but has no design for
   ownership, collision detection, or integration order.
6. Nothing measures whether agents actually follow the instructions.

## Goals and non-goals

**Goals.** Single-source normative agent behavior and make it machine-checkable;
minimize always-on context; give each skill non-overlapping ownership; support
Claude Code and Codex intentionally without drift; encode cross-model independence
at planning, code, and readiness boundaries; preserve every existing safety
invariant.

**Non-goals.** Application, Talos, Kubernetes, Flux, networking, storage, or cluster
changes; live validation or rollout; a self-hosted LLM review service; PR-comment
adapters; CodeRabbit or Renovate installation; CI redesign; `SPEC.md` / `ROADMAP.md`
/ `TASKS.md`; wholesale adoption of any external project's configuration or
taxonomy; model-specific logic inside reusable skills; autonomous orchestration.

## Verified client compatibility facts

Revision 1 asserted several client behaviors from secondary sources and got two
wrong. Revision 2 records only facts checked against primary documentation, and
labels each as **client-enforced** (the tool does it) or **instruction-only** (the
repository merely asks).

### Agent Skills specification — the portable floor

| Field | Required | Constraint |
|---|---|---|
| `name` | Yes | 1–64 chars; lowercase `a-z0-9` and hyphens; no leading/trailing hyphen; no consecutive hyphens; **must match the parent directory name** |
| `description` | Yes | 1–**1024** characters, non-empty; should state what the skill does and when to use it |
| `license` | No | Short license name or bundled file reference |
| `compatibility` | No | ≤500 chars; environment requirements |
| `metadata` | No | Arbitrary string map — **the sanctioned place for non-standard keys** |
| `allowed-tools` | No | Space-separated pre-approved tools; explicitly experimental |

The spec defines **no `when_to_use` field**, and defines **no file-size limit**. It
recommends the body stay under 500 lines / ~5,000 tokens and that overflow move to
`references/`. It also ships a reference validator, `skills-ref validate`, which
checks frontmatter and naming conformance.

### Per-client precedence and duplicate handling

| Surface | Behavior | Enforcement |
|---|---|---|
| Codex `AGENTS.md` | Global `~/.codex/AGENTS.override.md` → `~/.codex/AGENTS.md`, then repo root down to cwd, concatenated. **Closer to cwd wins, so repository files override the user's global file.** An `AGENTS.override.md` at a level suppresses that level's `AGENTS.md`. Combined size capped by `project_doc_max_bytes`, default **32 KiB**, then truncated | Client-enforced |
| Codex skills | Discovered from `.agents/skills` in cwd and parents to repo root, plus `$HOME/.agents/skills`, `/etc/codex/skills`, and built-ins. **Duplicate names are not merged and not shadowed — both appear in the selector.** Symlinked skill folders are supported and followed | Client-enforced |
| Claude Code `CLAUDE.md` | Project file, with `@` imports | Client-enforced |
| Claude Code skills | `.claude/skills/<name>/`; **enterprise overrides personal overrides project**, and any of these overrides a bundled skill of the same name. A skill-name entry may be a symlink, which Claude Code follows, loading a shared target once. Nested `.claude/skills/` load after a file in that subtree is touched | Client-enforced |
| Root-prohibition-wins, nearest-wins, fail-closed conflict handling | Repository policy that nested guidance and skills must honor | **Instruction-only** |

Three corrections to revision 1 follow from this. Codex **does not** let a global
file outrank the repository — the reverse is true. Codex skills **do not** shadow by
name. And the "8 KB Codex skill cap" was a secondary-source error: Codex applies a
context budget of 2% of the window, or **8,000 characters when the window is
unknown, to the initial skills *listing*** — and when the budget is exceeded, Codex
**shortens skill descriptions first**. Selected skill bodies still load in full.

That last fact inverts revision 1's reasoning in a useful way: the real cost of a
large roster is not body size but **description truncation, which degrades
activation accuracy exactly when there are the most skills to disambiguate**. It is
an independent, evidence-based argument for a small roster and tight descriptions.

The residual shadowing risk is therefore narrower than revision 1 claimed, but real:
**Claude Code personal and enterprise skills do shadow project skills, and a project
skill replaces a bundled one of the same name.** `code-review` is a bundled Claude
Code skill, so an unprefixed `code-review/` in this repository would replace it.

## The six distinctions this architecture rests on

**1. Always-on policy vs on-demand procedure.** The test is temporal, not topical:
content is always-on only if omitting it would permit an unsafe or irreversible act
*before any skill could load*. A prohibition is always-on; the procedure for
complying with it is on-demand.

**2. Skills vs subagents vs orchestration.** A skill is knowledge the agent loads to
do the work itself. A subagent is delegation of a bounded question into an isolated
context — an execution tactic, never a substitute for a skill. Agent teams are out
of scope. **No skill in this design spawns or supervises another agent.**

**3. Model-neutral canonical content vs client-specific adapters.** Canonical skill
bodies contain no model names, client-specific tool names, or routing logic.
Client-specific material is confined to a thin adapter layer that can be deleted
without loss of meaning.

**4. Probabilistic instruction vs deterministic enforcement.** Instructions are
requests; guards are constraints. Safety-critical rules receive deterministic
enforcement **wherever the platform supports it**, and every rule that cannot is
recorded as an accepted instruction-only residual with its mitigation (see below).
Revision 3 stated this as an absolute — "every safety-critical rule must have a
deterministic backstop" — while also accepting Codex skill-bypass as
instruction-only, which left implementers unable to tell a violation from a known
limitation. `just ci`, the `*_CONFIRM` gates, and branch protection remain
authoritative.

**Accepted instruction-only residuals.** These are known, bounded, and not defects:

| Residual | Why enforcement is unavailable | Mitigation |
|---|---|---|
| An agent may edit files without loading `worktree-management` | Codex has no pre-tool hook mechanism; Claude Code hooks are client-specific and optional | The prohibition and stop condition live in `AGENTS.md`; where hooks are available they turn it into a hard stop; `just repo agent-preflight` gives the operator the same facts |
| A personal Claude Code skill can shadow a repository skill | Precedence is client-enforced in the wrong direction and not configurable per repository | Distinctive `homelab-` prefix makes collision improbable; no instruction is the sole control for anything irreversible |
| An agent may read another worktree slot | The boundary is instruction, not a sandbox | The explicit `AGENTS.md` prohibition; runtime filesystem sandboxing where the client offers it; the rule that agents consume only operator-supplied derived slot output; and a prohibition on any recipe or skill that exposes another slot's content. **No deterministic detection exists where the runtime lacks filesystem isolation** — `just repo slots` detects overlapping *changed paths*, which is not the same thing and is not a mitigation for unauthorized reads |
| Skill content can be ignored once loaded | No platform enforces adherence to loaded text | Deterministic gates (`just ci`, `*_CONFIRM`, branch protection) sit downstream of every skill; behavioral evaluation measures adherence as a trend |

Anything not on this list that lacks a deterministic backstop is a gap to be fixed,
not a residual to be accepted.

**5. Agent-only workflow vs durable documentation.** `AGENTS.md` and
`.agents/skills/` own normative agent behavior and nothing else owns it. `docs/` and
`plans/` own architecture, decision records, topology, and human procedure. A skill
may require an agent to read a document, but links rather than restates.

**6. Structural validation vs behavioral evaluation.** Structural checks are
mechanical, cheap, and gate CI. Behavioral evaluation is probabilistic, costs model
calls, and **never gates CI**. Conflating them would either block PRs on model
variance or leave real compliance unmeasured. Revision 2 additionally splits a third
category out of the first: **semantic judgments that look mechanical but are not**,
which belong in review or evaluation, never in a validator.

## Architectural options considered

| Option | Summary | Verdict |
|---|---|---|
| A. Status quo plus discipline | Keep one growing `AGENTS.md` | **Rejected** — four commits of evidence show discipline alone loses |
| B. Shorten `AGENTS.md`, move procedure to `docs/` | No new mechanism | **Rejected** — `docs/` is human-facing and not loaded on demand |
| C. Canonical skills at repo root (`skills/`) | Maximum neutrality | **Rejected** — no client discovers a bare root `skills/`, so every client needs an adapter |
| D. Canonical `.claude/skills/`, generate the rest | Matches wshobson | **Rejected** — makes a vendor directory canonical and needs a generator plus a drift gate |
| E. **Canonical `.agents/skills/`, symlink adapter for Claude Code** | Codex reads it natively; both clients document symlink following | **Selected** — one editable copy, no generator, drift structurally impossible |

## Target architecture

### Layer responsibilities

**`AGENTS.md` and `.agents/skills/` are the only canonical homes for normative agent
behavior.**

| Layer | Owns | Belonging test |
|---|---|---|
| `AGENTS.md` (root; scoped if justified) | Universal invariants, prohibitions, approval boundaries, routing rules, fail-closed preconditions, precedence, change classification, and the skill index | "If an agent reads nothing else, would omitting this permit an unsafe or irreversible act?" |
| `.agents/skills/<name>/SKILL.md` | One repeatable task-specific procedure, with evidence and completion contracts | "Needed in a subset of sessions, repeated across tasks, owned by no other skill" |
| `.agents/skills/<name>/references/`, `scripts/`, `assets/` | Troubleshooting, recovery cases, escalation, skill-owned helpers — **part of the skill, not a third instruction system** | Loaded only when the skill needs it |
| `docs/` | Architecture, accepted designs, decision records, topology, operational knowledge, human-facing procedure | Descriptive; never normative for agents |
| `plans/` | Requirements, design, status | Time-bounded |
| `.just/`, `scripts/`, CI, guards, hooks | Deterministic truth | Anything assertable instead of describable |

Two consequences:

- **No `docs/` worktree runbook.** The complete procedure and every recovery case
  live in the worktree skill. `AGENTS.md` keeps the prohibition and the
  skill-loading requirement.
- **`README.md` stops restating agent-only workflow.** Removed and replaced with a
  link: the agent-side worktree/rebase paragraphs (L131–141), the agent PR-loop
  table (L79–86), and the two unqualified self-merge restatements (L90, L134). Kept,
  as human-facing operator procedure: slot creation (L103–121), VS Code steps
  (L123–129), slot retirement (L162–171), the operator-rollout paragraph
  (L143–153), the recipe reference, the confirmation model, ReadWriteOnce, and
  repository boundaries. The slot count is corrected from three to four.

### The always-on set

`AGENTS.md` retains exactly these classes and nothing else:

1. Repository purpose and the fact that `main` is the Flux production boundary.
2. Never commit or push to `main`; never merge a PR — including the per-merge
   operator-override carve-out, stated once, authoritatively.
3. Worktree invariants: the active slot is an absolute filesystem boundary; never
   run a `git worktree` lifecycle subcommand; never start work in a slot parked on
   an unmerged branch; **do not modify any file before loading the worktree skill,
   and if it cannot be loaded, stop and report.**
4. Concurrency invariants: one slot ⇒ one agent ⇒ one branch; fetch before final
   validation and before every push; rebase, never merge; `--force-with-lease` only,
   and a failed lease is a full stop; the human owns merge order.
5. Cluster interface: all mutation and health checks go through guarded `just`
   recipes; never run raw `kubectl`, `talosctl`, `helm`, or `flux` against the live
   cluster; `*_CONFIRM` recipes are operator-run and agents never invent or guess a
   confirmation value.
6. Secrets: never handle the age private key, decrypt or rewrite `*.sops.yaml`, or
   print secret material in any output.
7. Validation contract: `just ci` is authoritative, cluster-independent, and
   secret-free; the cluster-dependent recipe families never enter it.
8. Precedence and conflict resolution, labelled as repository policy.
9. The skill index — one line per skill: name, when to load it, what it owns.
10. Change classification and the mandatory review boundaries: which gates apply to
    which class, the independence requirement, escalation when a gate cannot be
    satisfied, and the fail-closed rule for ambiguous cases.
11. Routing rules, and the human operator's sole authority over plan approval,
    merge, and rollout.

Size is a **maintainability signal, not an acceptance criterion** — with one
evidence-based exception now available: Codex truncates the concatenated instruction
chain past `project_doc_max_bytes` (32 KiB default). The validator reports the
combined size of `AGENTS.md` plus any scoped files against that budget and **fails
only on exceeding the truncation limit**, which is a correctness boundary rather
than a style preference. Line count is reported, never gated.

### Precedence and conflict resolution

Stated once in `AGENTS.md`, and labelled there as repository policy that agents must
honor, not as platform enforcement:

1. A prohibition beats a procedure. No skill, scoped file, adapter, or client
   default may relax a prohibition in root `AGENTS.md`.
2. Nearest-wins for scoped instruction files, matching Codex's concatenation order.
3. Skills add procedure within policy; they never grant permission.
4. Deterministic enforcement beats every instruction layer. If a guard refuses, the
   answer is no.
5. On any unresolved conflict: stop and ask the operator. Never pick the permissive
   reading.

The validator additionally asserts that **no `AGENTS.override.md` exists anywhere in
the repository**, since such a file would silently suppress the `AGENTS.md` at its
level in Codex.

### Canonical location and the Claude adapter

- **Canonical: `.agents/skills/<name>/SKILL.md`** — read natively by Codex from the
  repository root downward. No adapter is needed on the Codex side.
- **`.claude/skills/<name>` is a committed relative symlink** to
  `../../.agents/skills/<name>`. Both clients document following symlinked skill
  directories, and Claude Code loads a shared target once. **There is no generated
  artifact and no drift to detect** — there is one file.
- **No `.codex/skills/` tree**, and none as a fallback either — the path is not a
  documented Codex discovery location. See "Failure policy".
- `CLAUDE.md` remains a thin adapter importing `AGENTS.md`, with its dangling
  `MEMORY.md` reference removed.
- The minimum supported client versions for both tools are recorded at the
  pre-approval evidence gate and written into `docs/`, so a future discovery-behavior
  change is diagnosable rather than mysterious.

### Skill authoring contract

Three tiers, kept explicitly distinct because revision 1 conflated them.

**Tier 1 — Agent Skills specification (portable, mechanically gated).** `name` and
`description` present; `name` matching the directory and satisfying the character
rules; `description` non-empty and ≤1024 characters.

**Phase 1 restricts frontmatter to exactly `name` and `description`.** Revision 3
permitted the spec's optional fields (`license`, `compatibility`, `metadata`) without
enumerating their constraints, so a spec-invalid optional field could have passed
`just ci` while the validator claimed conformance. Rather than specify and fixture
every optional field's type and length rules for fields no skill currently needs, the
key allowlist is closed to two entries. **Widening it later is a Significant change**
— it alters the skill framework and its validator contract — and must ship the
constraint checks and fixtures for whichever field it adds. `allowed-tools` remains
prohibited independently of this, on permission grounds.

**Tier 2 — client budgets (advisory, reported).** Codex's listing budget (2% of
context, or 8,000 characters when unknown) is shared across *all* skills, and Codex
shortens descriptions when it is exceeded. The validator therefore reports the sum
of all descriptions against 8,000 characters as a **warning**, since the true budget
depends on the runtime model. Claude Code truncates the combined description plus
`when_to_use` at 1,536 characters in its listing.

**Tier 3 — repository choices (mechanically gated where objective).** `SKILL.md`
body ≤500 lines, following the specification's own recommendation and replacing
revision 1's incorrect "8 KB Codex cap"; overflow moves to `references/`. Skills
reference `just` recipes by name and link to `docs/` rather than restating them.
Because loaded skill content **persists in context and is not re-read**, bodies are
written as standing instructions, not one-shot step lists.

**`when_to_use` is not in the specification.** It is a Claude Code extension, read
as a *top-level* field. The plan's default is to **keep all activation information
inside `description`** and not use `when_to_use` at all. Revision 2 offered carrying
it under the spec's `metadata` map as an alternative; revision 3 withdraws that
option, because Claude reads the top-level field only — burying it in `metadata`
would be portable and functionally inert, which is the worst combination. The only
real alternative is to permit top-level `when_to_use` as a documented Claude
extension after the pre-approval gate shows Codex tolerates it. The validator
enforces whichever of those two the operator locks.

**`allowed-tools` is prohibited outright in Phase 1.** Revision 2 proposed allowing
it with a denylist of raw cluster tools; that is not fail-closed. A scoped grant
such as a destructive `git` command, a filesystem deletion, a secret-printing
helper, or an over-broad `mise exec -- just …` pattern contains none of the denied
tokens and would sail through while bypassing an interactive permission prompt.
Since committed project skills take effect after workspace trust, the grant is real
permission, not metadata. Phase 1 therefore bans the key entirely — the validator
rejects its presence. Any future use requires an **exact allowlist** of specific
non-mutating commands or recipes, fixtures, and independent security review; that is
a separate change under the Significant path, not a Phase 1 detail.

### Skill roster and ownership boundaries

The **core lifecycle skills land first**; domain skills follow only once the
planning, review, remediation, and readiness foundation exists.

**Phase 1 — core lifecycle (five skills):**

| Skill | Owns | Does not own |
|---|---|---|
| `worktree-management` | Checkout and slot detection, branch creation and resume, pre-edit verification, the fetch/rebase/revalidate loop, `--force-with-lease` handling, recovery cases, stale-slot detection and escalation | Multi-slot planning; what to change; any review verdict |
| `project-planning` | Turning an approved architecture into an implementation plan: `plans/` house style, phase and exit-gate structure, sequencing, rollback design, validation strategy, acceptance criteria | Deciding whether the plan is good enough; approving anything |
| `plan-review` | The pre-implementation gate: independent assessment of architecture, sequencing, risk, rollback, validation strategy, and acceptance criteria; its evidence requirements, severity criteria, and verdict format | Implementation correctness; branch or CI state; authoring the fix |
| `code-review` | The post-implementation gate: does the diff correctly and safely implement the approved plan; its evidence requirements, severity criteria, and verdict format | Re-litigating the plan; branch completeness; merge decisions |
| `pr-readiness` | The final pre-merge gate: complete branch and diff state, captured validation evidence, CI status, outstanding operator-only checks, documentation, and confirmation that earlier gates were satisfied and their findings closed | Performing code review again; fixing findings; merging |

**Later phases:**

| Skill | Phase | Owns |
|---|---|---|
| `parallel-work-coordination` | 2 | Wave decomposition, task ownership, collision detection, integration order, handoff evidence |
| `gitops-change` | 4 | App layout, `dependsOn` ordering, RWO → `Recreate`, the stage-inert-then-activate pattern, the validator-wiring pattern |
| `cluster-diagnosis` | 4 | Guarded read-only live investigation; escalation when no recipe exists |

Rejected: a skill per lifecycle verb beyond the three gates; a separate
`validation-authoring` skill (folded into `gitops-change`); Rust, Linux/systemd, and
generic Python-AI skills; anything that would restate `docs/`.

**Naming.** Given Claude Code's personal-over-project shadowing and its bundled
`/code-review`, skill directory names should carry a repository-distinctive prefix.
The prefix, and the specific decision about whether to deliberately replace the
bundled `/code-review`, are locked before approval (operator decision 1).

### The three review gates

| | **Plan review** | **Code review** | **PR readiness** |
|---|---|---|---|
| When | Before implementation | After implementation | After code-review remediation |
| Question | Is this the right change, sequenced and de-risked well enough for human approval? | Does this diff correctly and safely implement the **approved** plan? | Is the complete branch ready to merge? |
| Inputs | Architecture, proposed plan, repository state | Approved plan, full diff against the correct base, validation output | Whole branch, both prior verdicts and their remediation, CI state, evidence, docs |
| Out of scope | Implementation detail the plan legitimately defers | Whether the plan itself was wise — settled at gate 1 | Re-reviewing code |
| Verdict | Ready for human approval / revise / reject | Approved / changes required | Ready to merge / blocked, with the blocker list |
| Exit condition | Operator approves the plan | All blockers closed; majors closed or explicitly accepted by the operator | No blockers; every outstanding item named as an operator action |

Common properties, owned by the skills:

- **Independence.** Every gate is performed by a different model family than the
  author, with fresh context. The reviewer forms its own view from the repository
  and requirements *before* reading the artifact under review.
- **The author may respond, never approve.** No artifact is approved solely by the
  model that produced it.
- **Severity labels are shared; criteria are per-gate.** All three report
  `blocker` / `major` / `minor`; what constitutes each differs by gate and is defined
  inside each skill. `AGENTS.md` owns only escalation semantics: a blocker stops
  progression, a major requires closure or explicit operator acceptance, a minor is
  recorded.
- **Evidence over assertion.** Each gate separates deterministic evidence from
  reviewer judgment and labels which is which.
- **Fail-closed escalation.** If an independent reviewer is unavailable, work
  **stops at the gate and is handed to the operator.** Self-review is never a
  substitute.

### Change classification and abbreviated paths

| Class | Description | Plan | Plan review | Code review | PR readiness |
|---|---|---|---|---|---|
| **Mechanical** | No behavior change: typo, comment, wording, formatting, additive doc edit | No | No | Optional, operator's call | Abbreviated: diff scope and CI only |
| **Standard** | Bounded change inside an established pattern, adding no new pattern | Brief, may live in the PR description | Only if it introduces a new pattern | Required | Required |
| **Significant** | Cross-cutting, new pattern, or touching the instruction, enforcement, or rollout layers | Required in `plans/` | Required | Required | Required |

**The default fails closed: when significance or risk is ambiguous, the change is
Significant.** These triggers force the Significant path regardless of diff size:

- any edit to `AGENTS.md`, the skill framework, or the adapter/discovery layer;
- any change to a guard, a `*_CONFIRM` value, `executions.ci`, or the catalog schema;
- any change to permissions, approval boundaries, safety controls, the review
  architecture, or model routing;
- anything touching secrets, SOPS configuration, or the age key boundary;
- Talos configuration, Flux `dependsOn` ordering, or a `suspend:` flip;
- storage, RWO, or upgrade/rollback behavior;
- anything the agent cannot validate deterministically before opening the PR.

**Routine skill maintenance is Standard, not Significant.** Revision 3 swept every
edit to any skill onto the Significant path, which would have imposed a separate
human pre-approval ceremony on ordinary upkeep — contrary to the intended operating
model. The split by risk:

| Skill change | Path | Requires |
|---|---|---|
| Adding or editing a skill that follows the established schema and alters no safety policy, permission, human authority, secret handling, live-operation workflow, review gate, model routing, or discovery adapter | **Standard** | Independent `code-review`, `pr-readiness`, `just ci`, human merge. **No separate pre-implementation approval** |
| Changing the skill framework itself, the adapter or discovery layer, `AGENTS.md`, permissions, approval boundaries, safety controls, secret handling, live-operation workflows, or the review architecture | **Significant** | Independent `plan-review` and operator approval before implementation, then the full lifecycle |

**Skill activation is never gated.** An agent loading an existing repository skill
requires no approval of any kind — that is the mechanism working as designed, not a
change. The human operator remains the sole PR merge and live-rollout authority in
both paths.

The agent proposes a classification with reasoning. **The operator may raise a class
at any time; only the operator may lower one.**

### Skills, subagents, hooks, and teams

- **Skills** carry procedure and are the only new instruction artifact.
- **Subagents** stay an execution tactic chosen per session; no skill requires one.
- **Hooks** are the deterministic client-side backstop and live in the adapter layer
  only: a pre-tool guard rejecting writes outside the active slot path, and one
  rejecting raw cluster commands. Because Codex has no equivalent, **every
  hook-enforced rule must also exist as an `AGENTS.md` invariant.**
- **Agent teams** are out of scope.

### Parallel work: the safe initial boundary

The initial boundary is **safe parallel sessions, not orchestration.** A human opens
N client windows on N slots. Nothing spawns, supervises, or messages another agent.

Placement: concurrency invariants in `AGENTS.md`; single-slot mechanics in
`worktree-management`; wave-level concerns in `parallel-work-coordination`.

**Shared-file collision hot spots**, named because they are structural:

- **`tests/catalog.yaml`** — the sharpest. Every new validator appends a suite *and*
  an `executions.ci` entry, and `validate-catalog.sh` asserts the counts match 1:1.
  Two slots adding validators in one wave produce a guaranteed textual conflict
  *and* a count assertion that fails on a careless merge resolution.
- `.just/repository.just` and `kubernetes/mod.just` — recipe additions, plus the
  hardcoded `require_deployed_source` count of 23.
- `README.md`'s recipe table, `kubernetes/apps/<domain>/kustomization.yaml`, and
  `AGENTS.md` itself.

**Collision detection is deterministic and fails closed.** A read-only
`just repo slots` recipe reports, per worktree: branch, dirty state, ahead/behind
versus `origin/main`, and the pairwise intersection of changed paths across slots.
Revision 1's algorithm was `git diff --name-only origin/main...<branch>` alone,
which covers **committed** changes only — two slots could edit the same file with no
overlap reported. Revision 2 requires:

Revision 2 then over-corrected, requiring dirty paths in the union while also
refusing to report whenever a slot was dirty — which would suppress collision
evidence exactly when it is most valuable, since active slots are dirty by
definition. Revision 3 separates four concepts that revision 2 conflated:

| Concept | Meaning | Effect |
|---|---|---|
| **Enumeration completeness** | Was every slot's changed-path set fully determined? | Incomplete ⇒ result is *unknown*, exit non-zero |
| **Collision result** | Do two slots' path sets intersect? | Reported whenever enumeration is complete, dirty or not |
| **Slot cleanliness** | Does a slot have uncommitted work? | Reported per slot; **not** a reason to suppress collision output |
| **Proceed verdict** | Is it safe to start a new wave? | Separate stop condition, e.g. dirty slots block a *new* wave while existing collision evidence is still printed |

Concretely: the changed-path set per slot is the **union** of the committed branch
diff, staged changes, unstaged changes, and untracked non-ignored files. Remote
freshness is established by an explicit `git fetch origin` inside the recipe
invocation, and its completion is recorded in the output; a stale or failed fetch
makes the result *unknown*. Enumeration is incomplete — and therefore *unknown* —
when a slot is detached, has no resolvable branch base, or cannot be read. A clean
"no collisions" verdict is emitted **only** when every slot was fully enumerated;
partial enumeration never reports *clear*.

It is **operator-only**, never in `just ci`, and **agents consume operator-supplied
output rather than inspecting other worktree paths themselves** — reading another
slot would violate the filesystem boundary the recipe exists to protect.

**Status and handoff evidence are derived, never stored.** Status is the branch plus
`gh pr view` state; the PR body records slot id, base commit, and owned path scope.
A checked-in status or lock file is rejected — it would become the worst collision
hot spot in the repository.

**Integration.** Branches merge one at a time in an order the human chooses. After
each merge, every remaining slot rebases and reruns `just ci`; a wave is re-planned
rather than continued if a merge changes a file another slot owns.

### Cross-model routing

| Artifact | Produced by | Independent gate |
|---|---|---|
| Architecture for a significant change | Opus, high | Sol, high — forms its own view first |
| Implementation plan | Sol, high | Opus, high — `plan-review` |
| Significant implementation | Sol, high | Opus, high — `code-review` |
| Mechanical implementation | Sol, medium | `code-review` only when risk warrants |
| Final readiness for Sol-authored work | — | Opus, high — `pr-readiness`, atop deterministic CI |
| Merge and rollout | — | Human operator, exclusively |

**Claude proposes or reviews what should be built; Sol independently challenges
architecture. Sol decides how to implement and performs most execution; Claude
independently challenges the plan and the implementation.** Effort escalation is
justified per change, never a default.

### Deterministic enforcement

Revision 1 listed semantic judgments alongside mechanical checks. Revision 2 splits
them into three explicit buckets, and **only bucket 1 gates CI.**

**Bucket 1 — mechanical, gating.** Implemented in
`scripts/validate/agent-instructions.sh` (Bash + `yq` + `rg`), wired as
`just repo agent-instructions-validate` → `validation.agent-instructions` in
`tests/catalog.yaml` → `executions.ci`:

- frontmatter parses; keys are **exactly** `name` and `description`, with any other
  key — spec-optional or not — rejected in Phase 1;
- `name` matches directory and satisfies the spec's character rules;
- `description` non-empty and ≤1024 characters;
- `SKILL.md` ≤500 lines;
- `allowed-tools` is **absent** — its presence is a failure in Phase 1;
- every canonical skill has exactly one `.claude/skills/<name>` symlink whose
  resolved target equals the canonical directory; no regular files or orphan
  symlinks under `.claude/skills/`;
- every relative markdown link in `AGENTS.md`, `CLAUDE.md`, and skills resolves to
  an existing path;
- every recipe reference in agent instructions resolves against `just --summary`,
  using an exactly specified grammar (below);
- `AGENTS.md` contains each required always-on section heading, matched as exact
  literal headings from a maintained list;
- no `AGENTS.override.md` exists anywhere in the repository;
- combined instruction size stays under the 32 KiB Codex truncation limit.

**Marker-phrase single-sourcing, narrowed.** The rule is: a maintained list of
**exact literal sentences**, compared after normalizing runs of whitespace to a
single space and lowercasing, must appear in `AGENTS.md` or a skill and must not
appear in `README.md` or `docs/`. Conceptual duplication is explicitly **not** in
scope.

Revision 2's worked example was `*_CONFIRM` variable names, which is exactly wrong.
Measured against the current tree: `README.md` contains 37 `_CONFIRM` occurrences
and 24 files under `docs/` contain them, all of them legitimate operator
documentation — the recipe reference, the confirmation model, and runbooks that must
record the complete confirmed command. That rule would have failed CI against
correct human documentation on day one, and the only ways to make it pass would be
to delete safety-critical operator instructions or to have the builder silently
invent exclusions.

Revision 3 therefore constrains the list to **agent-only normative sentences that
have no human-documentation purpose** — the self-merge prohibition sentence, the
worktree pre-edit stop condition, the "do not modify files before loading the
worktree skill" rule. It **explicitly excludes** recipe names, confirmation variable
names, confirmation values, and any operational command. Where a token legitimately
belongs in both agent and human documentation, the model is *one authoritative
normative home plus approved descriptive references*, not absence.

The final list is **tested against the tree before it is enabled**, and 1C does not
merge unless the enabled list passes against unmodified `README.md` and `docs/`
content that is meant to survive.

**Recipe-reference grammar, specified exactly.** `just --summary` emits root recipes
as bare tokens (`ci`) and module recipes with a `::` separator (`repo::lint`,
`bootstrap::cilium`), while prose writes them as `just ci` and `just repo lint`. The
validator therefore: matches `` `just <tokens>` `` inside backticks only; drops a
leading `mise exec --`; takes the first one or two tokens as the recipe path and
treats any remainder as arguments; normalizes a two-token form `<module> <recipe>`
to `<module>::<recipe>`; and requires the result to appear in `just --summary`.
Fixtures cover root, namespaced, and argument-bearing forms in both directions.

**Bucket 2 — advisory, reported and non-gating.** Total description length against
the 8,000-character listing budget; `AGENTS.md` line count; per-skill body size
trend.

**Bucket 3 — judgment, moved out of CI entirely.** Whether a description usefully
states "what and when"; whether two skills' triggers overlap; whether prose
"normalizes" a forbidden command versus mentioning it in a prohibition; whether gate
boundaries are respected. These are **review responsibilities** — `plan-review` and
`code-review` own them for skill changes — and **evaluation targets** once that tier
exists. Revision 1 proposed them as validator assertions; a Bash implementation
would have required inventing semantic heuristics, with false positives and trivial
bypasses as the likely outcome.

**Fixtures are part of the deliverable.** The validator ships with fixture skills
proving both directions: malformed inputs that must be rejected, and legitimate
negative-context wording — a skill that *prohibits* raw `kubectl` must pass.

**Phase 1 uses the native closed-schema validator.** With frontmatter closed to
`name` and `description`, the whole spec-conformance contract is a key-set equality
check, the `name` character rules, a directory-name comparison, and one length check
— cheap to own and fully specified here. The upstream `skills-ref validate` tool
covers the same ground and tracks the spec, but adopting it would add a pinned
dependency for very little; it is recorded as a future option, **not** as something
the pre-approval gate decides. Swapping the validator toolchain later is a
Significant change, since it alters the framework's validation contract.

### Behavioral evaluation — deferred to its own approved plan

A tier that measures whether agents actually behave as instructed remains the right
idea, but revision 1 under-specified it to the point where a builder would have had
to design model invocation, grading, trace handling, and catalog schema changes
themselves. Two verified constraints make this a genuine architecture problem rather
than a wiring task:

- `validate-catalog.sh` restricts `tier` to a closed enum and `execution_owner` to
  `shared` or `human`, so revision 1's `execution_owner: operator` is invalid today;
- the Allure tooling renders JUnit-backed runs and has no generic non-campaign
  execution path, no model invocation, and no trace capture.

**Revision 2 therefore removes the evaluation design from this plan and makes it a
separate architecture and implementation plan**, authored under `project-planning`
and passing `plan-review` before any of it is built. That plan must specify: catalog
schema changes and ownership vocabulary; the operator recipe and runner; supported
client and model adapters and the authentication boundary; fresh-context isolation
and client-version capture; the trace and evidence schema with secret scanning,
retention, and an explicit prohibition on publishing traces to the cluster without
separate approval; the grading oracle, repetition count, and treatment of variance;
and a mechanical proof that behavioral suites cannot enter `executions.ci` or an
existing campaign.

The scenario classes this plan hands over as requirements: positive activation;
**negative activation, where a near-miss prompt must not load the skill**; refusal
fidelity, preserving exact `*_CONFIRM` variables and values unparaphrased; boundary
compliance, where editing before the worktree skill loads must produce a
stop-and-report; and secret-boundary refusal. In all cases a regression is a signal
to investigate, **never a build failure**.

## Explicit assessments

**Local-over-global skill precedence — client-specific, and weaker than revision 1
claimed.** Codex concatenates instructions with the repository *overriding* the
user's global file, and does not shadow duplicate skill names at all. Claude Code
*does* shadow: enterprise over personal over project, and project over bundled. So
the residual risks are (a) a personal Claude skill silently replacing a repository
one, (b) an unprefixed `code-review` replacing the bundled skill, and (c) duplicate
names creating selector ambiguity in Codex. Mitigations: a distinctive prefix, and
never making an instruction the sole control for anything irreversible. Precedence
is not a security boundary in either client.

**Nested `AGENTS.md` applicability — defer, with evidence.** `kubernetes/README.md`
L6–36 and `talos/README.md` carry normative source-boundary rules that root
`AGENTS.md` summarizes lossily, so the need is real. Against acting now: Codex
resolves nested files by concatenation with nearest-wins, while Claude Code has no
`AGENTS.md` equivalent and loads nested *skills* only after touching a file in that
subtree — so behavior would differ across clients exactly where correctness matters.
Deferred to Phase 5 with a decision required either way.

**Adapter drift prevention — structural.** Symlinks make drift impossible rather
than detectable. The parity check guards the weaker failure mode: a missing,
orphaned, or accidentally-materialized adapter entry.

**Skill activation quality.** Governed by the authoring contract, and now by a
sharper constraint: Codex shortens descriptions first when the listing budget is
exceeded, so a bloated roster degrades activation precisely when disambiguation
matters most. Structural rules keep descriptions inside the spec limit; overlap and
description quality are review and evaluation concerns, not validator assertions.

**Deterministic worktree and safety preflights.** A read-only
`just repo agent-preflight` reports checkout type, slot path, branch, clean/dirty
state, whether `origin/main` is an ancestor, whether the slot is parked on a merged
branch, and which skills resolve from the canonical tree. Local-only, never in
`just ci`. Where hooks are supported, the two highest-risk invariants become hard
stops.

**Cross-model review boundaries.** Three gates, independent lane per gate, own view
formed before reading the artifact, author responds but never approves, fail-closed
when no reviewer is available, human merges.

**Behavioral test scenarios.** Enumerated above and handed to a separate plan.

**Safe initial boundary for parallel work.** Human-orchestrated parallel sessions
with fail-closed collision reporting, derived status, and operator-owned merge order.

## Pre-approval evidence gate

Revision 1 placed discovery in "Phase 0", which both deferred approval-critical
decisions into implementation and contradicted itself by requiring a scratch branch
inside a repository it said it would not change. Revision 2 makes this a
**pre-approval gate, not a phase**: it produces evidence and locked decisions, and
this plan is not approvable until its results are recorded in the Status block.

**This gate is operator-run.** It requires launching both clients against a
**disposable scratch repository outside this repository** — which no agent may
create or work in, since the active worktree slot is an absolute filesystem
boundary. An agent may prepare the fixture contents and the exact commands, but the
operator executes them and records the results. Nothing here requires a branch,
commit, or working-tree change in this repository.

Revision 3 required five observations. Three of them are unnecessary once the
recommended decisions are locked, so revision 4 narrows the gate to the two that are
genuinely approval-critical — the two the entire adapter strategy rests on:

1. **Codex discovers a project skill under `.agents/skills/`.**
2. **Claude Code discovers the same canonical skill through a `.claude/skills`
   symlink.**

Record each client's version alongside the result. **Treat Claude Code v2.1.203 as
the conservative documented floor**: the version marker sits at the end of the
preceding paragraph about nested-variant invocation rather than inside the symlink
paragraph, so the reading is genuinely ambiguous — the risk is asymmetric and the
test settles it.

The other three become conditional or implementation-time:

- `when_to_use` tolerance in Codex — tested **only if** the bundle is overridden to
  select that extension over the recommended description-only default.
- `skills-ref` — not gate material at all; Phase 1 uses the native validator, and
  adopting the upstream tool later is a separate Significant change.
- Repository symlink compatibility with pre-commit and `just repo verify` — proven in
  the Phase 1 branch by `just ci` before 1A merges, where it belongs.

### Failure policy

**Observation 1 fails closed with no fallback.** Revision 3 offered a project-local
`.codex/skills/` symlink adapter if Codex discovery failed. That path is withdrawn:
official Codex documentation lists repository `.agents/skills` (cwd through repo
root), `$HOME/.agents/skills`, `/etc/codex/skills`, and bundled skills — **there is
no documented project-local `.codex/skills`**. Falling back to an undocumented path
could fail identically while appearing to be a remedy, and it would contradict this
plan's own canonical-location section. If Codex does not discover `.agents/skills`,
the gate stays closed until either the operator upgrades to and records a Codex
version that does, or a different repository adapter is independently verified and
documented **before** approval.

**Observation 2 has a real fallback**, because the canonical location is unaffected:
if Claude Code does not follow the symlink, generate copies under `.claude/skills/`
with a `--check` parity gate in CI. More machinery, same guarantee.

### Fixture and commands

Operator-run, in a disposable directory outside this repository:

```bash
PROBE_DIR="$(mktemp -d)"; echo "probe dir: $PROBE_DIR"
mkdir -p "$PROBE_DIR/.agents/skills/homelab-probe" "$PROBE_DIR/.claude/skills"
git -C "$PROBE_DIR" init -q
cat > "$PROBE_DIR/.agents/skills/homelab-probe/SKILL.md" <<'EOF'
---
name: homelab-probe
description: Reports a fixed discovery token. Use this skill whenever the user asks
  to run the homelab skill discovery probe, or mentions the discovery probe or the
  token PROBE-7F3A.
---
When this skill is invoked, reply with exactly: PROBE-7F3A
EOF
ln -s ../../.agents/skills/homelab-probe "$PROBE_DIR/.claude/skills/homelab-probe"
```

`mktemp -d` allocates a fresh directory each run and prints it. Revision 3 opened
with an unconditional `rm -rf` of a fixed path, which would have destroyed unrelated
material without inspection — not an acceptable shape for a command whose purpose is
producing approval evidence.

Then, from `$PROBE_DIR`, in each client, with the prompt
`run the homelab skill discovery probe`:

| Client | Command | Pass condition | Record |
|---|---|---|---|
| Codex | `codex` | Replies `PROBE-7F3A`, or lists `homelab-probe` as available | `codex --version` |
| Claude Code | `claude` | Replies `PROBE-7F3A`, or `/homelab-probe` is available. Accept the workspace-trust prompt if shown | `claude --version` |

Failure handling is asymmetric — see "Failure policy" above.

Clean up with `rm -rf "$PROBE_DIR"`, which removes only the directory this invocation
created.

## Phased implementation

Phases are **review units**; each consists of one or more PRs, and every PR is
independently reviewable and independently validated. Only Phase 1 is a hard
prerequisite for the others; Phases 3 and 4 may proceed in either order.

### Phase 1 — Core review lifecycle (3 PRs)

- **Purpose.** Establish the instruction architecture *and* the full
  planning/review/readiness lifecycle in one coherent phase, so every later phase is
  developed under the gates it defines.
- **Scope.** Skill substrate and validator; five lifecycle skills; `AGENTS.md`
  refactor; README de-duplication. Domain knowledge deliberately excluded.
- **Dependencies.** The pre-approval evidence gate, closed.

**1A — Substrate.** `.agents/skills/` scaffold; `.claude/skills/` symlink adapter;
`scripts/validate/agent-instructions.sh` with its fixtures; the
`just repo agent-instructions-validate` recipe; its catalog suite and `executions.ci`
entry; the read-only `just repo agent-preflight` recipe; README recipe-table rows.
Ships with `worktree-management` as the first real skill.

**1B — Lifecycle skills.** `project-planning`, `plan-review`, `code-review`,
`pr-readiness`, each with its ownership boundary, evidence requirements, severity
criteria, and verdict format. Authored together because their boundaries are defined
by mutual exclusion.

**1C — Instruction refactor.** Rewrite `AGENTS.md` to the always-on set plus skill
index, precedence, change classification, review boundaries, and routing matrix;
remove agent-only workflow from `README.md` and link instead; correct the slot count;
fix `CLAUDE.md`'s dangling reference; activate the marker-phrase and required-section
assertions.

**Skills are live the moment they land — 1A and 1B are behavior-changing.** Both
clients discover repository skills directly from the filesystem; no `AGENTS.md`
index is required, and descriptions become available for implicit model invocation
as soon as the files are committed. Revision 2 called 1A and 1B "inert until 1C
references them", which was wrong. Three consequences, all adopted:

- 1A and 1B are reviewed as behavior-changing additions, not as scaffolding.
- Every skill landing before 1C **must be correct against the *existing*,
  un-refactored `AGENTS.md`**, since that is the policy in force when it first
  becomes loadable. A skill that only makes sense after the refactor cannot land
  before it.
- Rollback claims are corrected accordingly (see "Migration and rollback").

- **Deterministic validation.** `just ci` green at each PR; the validator rejects
  every malformed fixture and accepts every legitimate one; the catalog count
  assertion holds; the enabled marker list passes against unmodified `README.md` and
  `docs/`.
- **Review — bootstrap procedure.** Every PR here is Significant, including 1A, and
  **all three receive independent cross-model review**. Because the repository's own
  review skills are not yet authoritative, 1A and 1B are reviewed against an interim
  review brief: the gate definitions in this plan's "three review gates" section,
  supplied to the independent reviewer directly. From 1C onward the repository skills
  are authoritative, and 1C is the first change reviewed by the gates it establishes.
  Revision 1 exempted 1A from independent review, which would have let the substrate
  PR bypass the independence rule it introduces.
- **Acceptance.** Both clients observed loading the skills; the five ownership
  boundaries hold with no two skills claiming the same procedure; every rule present
  at `c1201e6` traceable to a named home via a rule-by-rule mapping attached to 1C;
  no rule dropped; `AGENTS.md` authoritative wherever it previously disagreed with
  `README.md`.
- **Rollback.** Dependency-aware and reverse-order — see "Migration and rollback".

### Phase 2 — Parallel-work coordination (1 PR)

- **Purpose.** Make concurrent work across the four slots safe.
- **Scope.** `parallel-work-coordination`; the read-only `just repo slots` recipe
  with its fail-closed semantics; optionally the Claude-side hooks.
- **Dependencies.** Phase 1.
- **Deterministic validation.** `just ci` green; `just repo slots` reports a
  synthetic overlap between two scratch branches; reports collisions correctly while
  slots are dirty; and returns *unknown* with a non-zero exit when a slot is
  detached, unreadable, or the fetch did not complete.
- **Review.** Full lifecycle; independent review required.
- **Acceptance.** Collision detection demonstrated across all four path classes —
  committed, staged, unstaged, untracked — with dirty slots **included in** rather
  than suppressing the report; the four output concepts (enumeration completeness,
  collision result, slot cleanliness, proceed verdict) are separately observable;
  and the *unknown* path is demonstrated to fail closed.
- **Rollback.** Additive; single revert.

### Phase 3 — Behavioral evaluation (separate plan first)

- **Purpose.** Measure observed reliability of the lifecycle.
- **Scope.** **Gated on a separate approved architecture plan** covering the
  contracts enumerated above. Nothing is built in this repository until that plan
  passes `plan-review` and operator approval.
- **Dependencies.** Phase 1. Independent of Phase 4.
- **Acceptance.** Every scenario class has positive and negative cases; a baseline is
  recorded; a mechanical proof that evaluation suites cannot enter `executions.ci`.
- **Rollback.** Non-gating by construction.

### Phase 4 — Domain skills (1–2 PRs)

- **Purpose.** Move repeated domain procedure out of prose, now that a common
  planning, review, and evidence foundation exists.
- **Scope.** `gitops-change` and `cluster-diagnosis`. Any Talos, Flux-diagnostic, or
  observability skill is justified individually against the belonging test rather
  than assumed here.
- **Dependencies.** Phase 1.
- **Deterministic validation.** `just ci` green across the full roster.
- **Review.** Full lifecycle; `plan-review` confirms each skill earns its place
  rather than restating `docs/`.
- **Acceptance.** No skill duplicates documentation; ownership entries hold.
- **Rollback.** Individually revertable.

### Phase 5 — Scoped instructions and plan retention (1 PR)

- **Purpose.** Resolve the two deferred questions and close the program.
- **Scope.** Either scoped `kubernetes/AGENTS.md` and `talos/AGENTS.md` or a recorded
  deferral; an explicit plan-retention policy; disposition of this plan under that
  policy.
- **Dependencies.** Phase 4.
- **Deterministic validation.** `just ci` green; combined instruction size under the
  32 KiB Codex limit; no file references a removed plan by path.
- **Acceptance.** If scoped files land, precedence behaves as documented in both
  clients, demonstrated by observation. The retention policy is written down —
  options being retain-with-status, migrate durable content to `docs/` and remove, or
  retain indefinitely — rather than invoking an unwritten convention.
- **Rollback.** Individually revertable; any removal is recoverable from history.

## Files and areas expected to change

New, Phase 1: `.agents/skills/{worktree-management, project-planning, plan-review,
code-review, pr-readiness}/SKILL.md` plus `references/`; matching
`.claude/skills/<name>` symlinks; `scripts/validate/agent-instructions.sh` plus its
fixture tree.

New, later: `.agents/skills/{parallel-work-coordination, gitops-change,
cluster-diagnosis}/`; a separate evaluation architecture plan under `plans/`.

Modified: `AGENTS.md` (rewrite), `CLAUDE.md` (dangling reference), `README.md`
(remove agent-only workflow, correct slot count, add recipe rows),
`.just/repository.just` (three read-only recipes), `tests/catalog.yaml` (one CI
suite), `docs/` (recorded client versions and compatibility notes), optionally
`.claude/settings.json` (hooks, Phase 2 decision).

**`.mise.toml` is not modified.** Phase 1 uses the native validator, so no new tool
is pinned; adopting `skills-ref` later would be a separate Significant change.

Explicitly **not** modified by this plan: `scripts/test/validate-catalog.sh` — its
schema change belongs to the separate evaluation plan.

Unchanged by design: `.github/workflows/ci.yml`, every `bootstrap` recipe, every
`*_CONFIRM` guard, all Talos, Kubernetes, and Flux manifests.

## Validation strategy and acceptance criteria

Every PR passes `mise exec -- just ci` locally and shows a green `ci` check. Beyond
that, acceptance is evidence-based per phase. Three global criteria:

- **No safety regression.** Every invariant present at `c1201e6` is traceable to a
  named home after 1C, demonstrated by an explicit mapping in that PR.
- **Deterministic before probabilistic.** No rule ends the program relying solely on
  a skill when a guard, validator, or CI suite could assert it. Where a rule remains
  instruction-only, the plan says so.
- **No semantic check gates CI.** Every gating assertion is mechanical and has a
  fixture proving both rejection and acceptance.

## Migration and rollback

Migration is **staged, not inert-then-active**. Each PR changes agent behavior when
it lands: 1A and 1B by making skills discoverable and implicitly invocable, 1C by
replacing the policy those skills operate under. The ordering exists so that policy
never references a skill that does not yet exist, not because the earlier steps are
harmless.

**Rollback is dependency-aware and performed in reverse order.** Revision 1 called
1C "a single-file restore", which was wrong: 1C changes `AGENTS.md`, `README.md`,
and `CLAUDE.md`, and activates validator policy. Reverting 1C restores all three
files **and** deactivates the marker-phrase and required-section assertions,
enumerated explicitly in that PR's description so the revert is mechanical.

Reverting 1A or 1B is only safe *after* 1C is reverted, because 1C's `AGENTS.md`
references them. Reverting 1A additionally removes the catalog suite and its
`executions.ci` entry together, or the count assertion fails.

**Reverting 1C alone does not restore pre-Phase-1 client behavior**, because the
skills from 1A and 1B remain discoverable. A full behavioral rollback is
1C → 1B → 1A. A partial rollback that stops at 1C leaves the repository in a state
where the old policy is in force and the new skills are still loadable — acceptable
only because every skill is required to be correct against the old policy as well.

Each phase's PR description carries its own revert order and file list.

## Risks and tradeoffs

- **Skill bypass is real.** A session that never loads the worktree skill still edits
  files. Mitigated by keeping the prohibition in `AGENTS.md` and by hooks where
  available — but in Codex this remains instruction-only, and the plan says so.
- **Claude personal-skill shadowing.** Not eliminable; mitigated by a distinctive
  prefix and by never making instructions the sole control.
- **Gate overlap is the main way this design fails in practice.** If `code-review`
  drifts into re-litigating the plan, or `pr-readiness` into re-reviewing code, the
  gates stop meaning anything. Mitigated by authoring the three together and by
  explicit "does not own" lines — but this is a review and evaluation concern, not
  something a validator can catch.
- **Roster growth degrades activation** via Codex's description-shortening behavior.
  An argument for restraint that did not exist in revision 1.
- **1C is the highest-regression edit**, because it touches the self-merge exception
  wording where the two current sources already disagree.
- **Skills are live on landing, so there is a window** between 1A/1B and 1C where new
  skills operate under the old policy. Mitigated by requiring every pre-1C skill to be
  correct under the un-refactored `AGENTS.md`, but the window is real and is the
  reason 1A and 1B get independent review rather than being treated as scaffolding.
- **Three gates cost wall-clock time.** The abbreviated paths keep mechanical work
  cheap; the risk is classification being gamed downward, which is why only the
  operator may lower a class.
- **Trade-off accepted.** Symlinks add a repository-first construct in exchange for
  eliminating a generator and a drift class. If a client stops following them, the
  fallback is a generator plus a CI parity gate — more machinery, same guarantee.

## Deferred work

Autonomous orchestration and agent teams; an external review service as anything
more than an optional complement to `pr-readiness`; Forgejo migration (the
architecture avoids Git-provider coupling, so this stays open); Renovate; CI
redesign; per-app scoped instruction files below the domain level.

## Operator decisions — all required before approval

**Decisions 1–7 are a single accept-or-override bundle.** They are mutually
consistent — each recommendation assumes the others — so accepting them individually
buys nothing. The operator records either "bundle accepted" or the specific
overrides. Decision 8 is separate because it constrains who may approve the result.

Nothing is treated as decided until the operator records it here.

| # | Decision | Recommendation | Rationale |
|---|---|---|---|
| 1 | Skill-name prefix | `homelab-` on all skills — `homelab-code-review`, `homelab-worktree-management`, … | Distinctive enough to make personal-skill shadowing improbable, accurate for a repository named `homelab-talos`, and it leaves Claude Code's bundled `/code-review` intact. `talos-` is the alternative but misleads for lifecycle skills that have nothing to do with Talos |
| 2 | Bundled `/code-review` | Do **not** replace it | Replacing a client's built-in review skill repository-wide is a large, surprising side effect for a change whose purpose is clarity. Prefixing costs nothing |
| 3 | `when_to_use` | Keep all activation information in `description` | Portable, spec-conformant, and avoids depending on a Claude extension in a file shared byte-for-byte with Codex. Revisit only if the gate shows the extension materially improves activation |
| 4 | `skills-ref` | Implement the spec checks natively in Bash; do not pin a new tool | With Phase 1 frontmatter closed to `name` and `description`, the native contract is a key-set equality check, the `name` character rules, a directory-name comparison, and one length check — small and fully specified. (Revision 3's rationale understated this by omitting the key-set check; it is still well under the cost of a new pinned dependency and its `.mise.toml` / `mise.lock` / `just repo versions` churn.) Revisit if the allowlist widens |
| 5 | Claude-side hooks | Defer the decision to Phase 2 | They are Claude-only and additive; deciding now would front-load client-specific machinery into the phase that should stay portable |
| 6 | Client version floors | Record observed versions; adopt Claude Code **v2.1.203** as the conservative documented floor | Asymmetric risk: assuming no floor and being wrong breaks discovery silently |
| 7 | Plan retention | Codify existing practice: a plan is removed only when its durable content has been migrated to `docs/`, and the removing commit names the migration target | Matches the evidenced behavior of the nine retired plans without inventing a new convention, and prevents losing architectural traceability |
| 8 | Final approval review | **Two distinct roles.** *Remediation verification* may be performed by the existing reviewer, which has the context to confirm each finding was actually closed. *Final approval* must come from a **fresh session** in the independent model family, without the prior review transcript or accumulated conversation | Revision 3 recommended reviewer continuity "for accumulated context", which directly contradicted this plan's own fresh-context independence requirement — an anchored reviewer effectively approves its own reading of the revisions. The review *lane* may be reused; the contextualized conversation may not |

## Plan review disposition — fourth pass (revision 4 → 5)

| Finding | Disposition | Where |
|---|---|---|
| BLOCKER — evidence and decisions unrecorded | **Accepted, still operator-only.** Status wording corrected to "one seven-item bundle plus decision 8". The probe and fallback defects below are fixed first, so the observations are run against a corrected fixture | Status; "Pre-approval evidence gate" |
| MAJOR — `.codex/skills` fallback unsupported and self-contradictory | **Accepted in full.** Official Codex documentation lists repository `.agents/skills`, `$HOME/.agents/skills`, `/etc/codex/skills`, and bundled skills — no project-local `.codex/skills`. The fallback is withdrawn; observation 1 now **fails closed**, resolvable only by a recorded Codex version that works or an independently verified adapter. Observation 2 keeps its generated-copy fallback, which is genuinely supported | "Failure policy"; "Canonical location and the Claude adapter" |
| MINOR — probe begins with destructive deletion of a fixed path | **Accepted in full, and it was my own safety ethos violated in my own fixture.** `mktemp -d` allocates and prints a fresh directory; cleanup removes only what that invocation created | "Fixture and commands" |
| MINOR — native-validator decision not propagated | **Accepted in full.** The statement that the gate selects `skills-ref` is removed; Phase 1 uses the native closed-schema validator; `.mise.toml` is explicitly not modified; and frontmatter-schema or validator-toolchain changes are classified **Significant**, not Standard, since they alter the framework | "Deterministic enforcement"; "Skill authoring contract"; "Files and areas expected to change" |
| MINOR — cross-worktree read mitigation overstated | **Accepted in full.** `just repo slots` detects overlapping changed paths, not unauthorized reads. Replaced with the `AGENTS.md` prohibition, runtime sandboxing where available, operator-supplied derived output only, and a ban on recipes or skills exposing other-slot content — plus a plain statement that **no deterministic detection exists without filesystem isolation** | Residuals table, distinction 4 |

## Plan review disposition — third pass (revision 3 → 4)

| Finding | Disposition | Where |
|---|---|---|
| BLOCKER — evidence and decisions unrecorded, and the gate is wider than the architecture needs | **Accepted.** The gate narrows from five observations to the two the adapter strategy actually rests on, with an exact disposable fixture and copy-paste commands; the other three become conditional (`when_to_use`, `skills-ref`) or implementation-time (`just ci` in the Phase 1 branch). Decisions 1–7 become one accept-or-override bundle. Still not agent-closable — it requires running both clients outside this worktree | "Pre-approval evidence gate" incl. "Fixture and commands"; "Operator decisions" |
| MAJOR — routine skill changes wrongly require human pre-approval | **Accepted in full.** Skill changes now split by risk: schema-conforming, policy-preserving skill work is **Standard** (independent code review, PR readiness, `just ci`, human merge — no separate pre-implementation approval), while framework, adapter, policy, permission, safety, and review-architecture changes stay Significant. **Skill activation is explicitly never gated** | "Change classification and abbreviated paths" |
| MAJOR — reviewer continuity conflicts with fresh-context independence | **Accepted in full; this was a self-contradiction.** Revision 3 recommended reusing the reviewer "for accumulated context" while the gate contract demands fresh context. Decision 8 now splits the roles: the existing reviewer may verify remediation; **final approval requires a fresh session in the independent lane without the prior transcript.** Same model family permitted, same conversation not | Decision 8; "Approval boundary" |
| MINOR — native frontmatter validation incomplete | **Accepted, resolved by narrowing rather than enumerating.** Phase 1 frontmatter is closed to exactly `name` and `description`; every other key, spec-optional or not, is rejected. Widening is a Standard change that must ship the constraint checks and fixtures for the field it adds. Decision 4's rationale is corrected to include the key-set check | "Skill authoring contract"; bucket 1; decision 4 |
| MINOR — deterministic-enforcement principle contradicts accepted residuals | **Accepted in full.** Reworded to "wherever the platform supports it", with a table enumerating the four accepted instruction-only residuals, why enforcement is unavailable, and each mitigation — plus the rule that anything not on that list is a gap, not a residual | "The six distinctions", distinction 4 |

## Plan review disposition — second pass (revision 2 → 3)

| Finding | Disposition | Where |
|---|---|---|
| BLOCKER — pre-approval gate and seven decisions still open | **Accepted, and not closable by an agent.** The experiments require launching both clients against a scratch repository outside this worktree, which the repository's own boundary rules make operator-run. Revision 3 states that explicitly and pre-fills a recommended answer for every decision so the gate is a confirm-or-override pass | Status; "Pre-approval evidence gate"; "Operator decisions" |
| MAJOR — 1A/1B skills are not inert | **Accepted in full.** Both clients discover repository skills from the filesystem with no index required, so skills are live on landing. 1A and 1B are now reviewed as behavior-changing, every pre-1C skill must be correct against the *un-refactored* `AGENTS.md`, and rollback states that reverting 1C alone does not restore prior client behavior | Phase 1 "Skills are live the moment they land"; "Migration and rollback" |
| MAJOR — `allowed-tools` denylist is not a permission boundary | **Accepted in full.** A denylist is not fail-closed: a scoped destructive `git`, `rm`, or over-broad `mise exec -- just` grant contains none of the denied tokens. Phase 1 now **prohibits the key entirely**; future use requires an exact allowlist, fixtures, and independent security review | "Skill authoring contract"; bucket 1 |
| MAJOR — marker enforcement conflicts with operator documentation | **Accepted, and the reviewer understated it.** Measured: `README.md` contains 37 `_CONFIRM` occurrences and 24 files under `docs/` contain them — all legitimate. Revision 2's worked example would have failed CI against correct documentation immediately. The list is now restricted to agent-only normative sentences, explicitly excludes recipe names, confirmation variables, values, and commands, and must be tested against the tree before 1C merges | "Deterministic enforcement" |
| MAJOR — dirty-worktree collision behavior contradictory | **Accepted in full.** Revision 2 required dirty paths in the union while refusing to report on dirty slots. Four concepts are now separated — enumeration completeness, collision result, slot cleanliness, proceed verdict — with dirty-but-enumerable slots participating in reporting and only unenumerable or stale state producing *unknown* | "Parallel work"; Phase 2 |
| MINOR — `metadata.when_to_use` would be inert | **Accepted.** Claude reads the top-level field only, so the `metadata` route is portable and non-functional at once. That option is withdrawn; the choice is description-only (recommended) or a documented top-level Claude extension | "Skill authoring contract"; decision 3 |
| MINOR — recipe-reference grammar incomplete | **Accepted.** Verified: `just --summary` emits `ci` as a bare token and module recipes as `repo::lint`, `bootstrap::cilium`. An exact grammar with `mise exec --` stripping, one/two-token handling, `::` normalization, and fixtures for all three forms is now specified | "Deterministic enforcement" |
| MINOR — Claude symlink version floor | **Accepted on risk grounds, while noting the textual disagreement stands.** The `v2.1.203` marker terminates the preceding nested-variant paragraph rather than appearing inside the symlink paragraph; the placement is genuinely ambiguous. Since the cost of assuming a floor is zero and the cost of wrongly assuming none is silent breakage, the plan adopts 2.1.203 as the conservative floor | "Pre-approval evidence gate", item 2; decision 6 |
| MINOR — stale worktree-state evidence | **Accepted.** Table refreshed and dated, with a note that slot state is dynamic evidence for an argument rather than a live inventory | "Parallel execution — observed state" |

## Plan review disposition — first pass (revision 1 → 2)

| Finding | Disposition | Where |
|---|---|---|
| MAJOR — skill schema is not the open standard | **Accepted.** Verified against the specification: `description` ≤1024, `when_to_use` absent, `license`/`compatibility`/`metadata`/`allowed-tools` defined, no size limit, ≤500-line recommendation, `skills-ref` validator exists | "Verified client compatibility facts"; "Skill authoring contract"; bucket 1 |
| MAJOR — Codex precedence/shadowing incorrect | **Accepted.** Verified: repository files override the user's global file; Codex does not shadow duplicate skill names; the 8 KB figure is an 8,000-character *listing* budget | "Per-client precedence and duplicate handling"; assessments rewritten |
| MAJOR — approval-critical decisions deferred | **Accepted.** Discovery becomes a pre-approval gate; seven decisions must close before approval (eight as of revision 4); the scratch-branch contradiction is resolved by using a disposable repository outside this one; phase/PR terminology reconciled | "Pre-approval evidence gate"; "Operator decisions"; "Phased implementation" preamble |
| MAJOR — semantic assertions posing as deterministic | **Accepted.** Three buckets; only mechanical checks gate CI; marker-phrase matching defined as exact literals with stated normalization; overlap and description quality moved to review and evaluation; fixtures required in both directions | "Deterministic enforcement" |
| MAJOR — evaluation tier not executable or safe | **Accepted.** Removed from this plan and made a separate approved architecture plan; verified that the catalog rejects `execution_owner: operator` and that no generic runner exists; required contracts enumerated including trace redaction and retention | "Behavioral evaluation"; Phase 3 |
| MAJOR — Phase 1 bootstrap review and rollback conflict with policy | **Accepted.** 1A now receives independent review under an interim review brief; rollback is dependency-aware, reverse-order, with 1C's full file and assertion list | Phase 1 "Review — bootstrap procedure"; "Migration and rollback" |
| MAJOR — collision detection gives false assurance | **Accepted**, then **refined in the second pass** — revision 2's "refuse to report when dirty" over-corrected and is superseded by the four-concept model above | "Parallel work" |
| MINOR — plan-retirement convention and CI count | **Partly accepted.** CI count corrected to **31** — the reviewer is right. On retirement the plan **declines the premise that no practice exists**: nine plan files were deleted across seven commits and three subjects say "retire". The accurate statement, now used, is that the practice is real but undocumented and inconsistently applied, and an explicit policy is required | "Plan retention"; Phase 5 |
| Claimed Claude symlink floor of v2.1.203 | **Declined on evidence.** In the Claude Code documentation that version marker attaches to the preceding paragraph about nested skill-variant invocation, not to the symlink paragraph, which carries no version floor. The observation is still recorded at the pre-approval gate rather than assumed | "Pre-approval evidence gate", item 2 |

## Approval boundary

No implementation proceeds until:

1. the two client-discovery observations are executed and their results and client
   versions recorded here, and **any failed observation has a verified, supported
   resolution** — not an undocumented workaround;
2. the decision bundle 1–7 is accepted or overridden, and decision 8 recorded;
3. a **fresh-context** independent plan review — a new session in the independent
   model family, without the prior review transcript — returns APPROVE or APPROVE
   WITH MINOR REVISIONS. The existing reviewer may separately verify that each
   finding was closed, but may not perform the approving review;
4. the operator explicitly approves the resulting revision.

The approving reviewer should form its own view from the repository and the
requirements first, then compare it against the architecture proposed here.

**After implementation begins**, routine skill activation and policy-preserving skill
maintenance need no separate operator approval. The operator remains the sole
authority for PR merge and live rollout.
