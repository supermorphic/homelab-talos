# Agent Instruction Information Architecture

## Status

- Status: **Design approved.** No implementation performed.
- Date: 2026-07-31
- Branch: `docs/refactor-agents-readability`
- Supersedes: `plans/agent-instructions-and-skills-architecture-plan.md`, which is
  no longer under consideration and is deleted by PR 1 of this plan.

## Problem

`AGENTS.md` has become the single home for several unrelated kinds of guidance:
repository-wide safety invariants, Git and approval policy, validation contracts,
operator-only rollout procedure, and domain-specific implementation conventions.
Nothing states which of those belong there, so every future rule is an ad hoc
judgment call.

The goal is clearer rule scope, ownership, and progressive disclosure — not fewer
words and not a stylistic rewrite.

### Current-state findings

Verified against the working tree on 2026-07-31.

- Root `AGENTS.md` is 67 lines across six topic sections. `CLAUDE.md` is a 10-line
  adapter that imports it.
- **No nested `AGENTS.md` exists**, and there is no `.agents/`, `.claude/`, or
  `.codex/` directory. Root is currently the only agent surface.
- `kubernetes/README.md` (132 lines) and `talos/README.md` (79 lines) are already
  normative boundary documents. Root's "Talos and Flux invariants" section is a
  lossy summary of rules stated more completely in those two files.
- `tests/README.md` carries scoped constraints of its own — live commands never
  enter `just ci` (L100), documentation names a confirmation variable but never
  its value (L125), an operator-only suite must not be added to CI (L188).
- `docs/` holds 32 files totalling 6,231 lines. Fifteen of them are `phase-0`
  through `phase-14` rollout records — finished history that an agent scanning the
  directory cannot distinguish from live reference.
- **No markdown link checker exists anywhere in the repository.** Roughly 124
  relative links point into `docs/` from about 20 files, and nothing verifies any
  of them.

### The regression this plan also closes

Root `AGENTS.md` did not drift toward becoming a catch-all. It drifted the other
way, and load-bearing constraints left without a repository home:

| PR | Date | Effect on `AGENTS.md` |
|---|---|---|
| #162 | 2026-07-29 | Removed the 76-line worktree and concurrency block, delegating it to an external "shared persistent worktree skill" |
| #163 | 2026-07-29 | Added an "Agent skills" section pointing at `docs/agents/*.md` |
| #165 | 2026-07-30 | Compressed the remainder from 162 lines to 75 |
| #169 | 2026-07-31 | Removed `docs/agents/*` and the skills section — 108 lines |

The worktree constraints removed by #162 — the slot as an absolute filesystem
boundary, the prohibition on `git worktree` lifecycle subcommands, the
`--force-with-lease`-only rule and its failed-lease stop condition — are now
sourced only from `~/.claude/skills/persistent-git-worktree`, an operator-personal,
unversioned, single-vendor directory. `AGENTS.md` describes itself as canonical and
vendor-neutral, so this is a real gap. PR 2 restores the constraints; the procedure
stays in the external skill.

## Goals and non-goals

**Goals.** State an explicit admission test for the root contract. Give every
existing rule exactly one owner. Make scoped guidance a real surface rather than an
aspiration. Separate live reference from finished history. Make the cross-references
the architecture depends on mechanically verifiable. Preserve every safety
invariant currently in force, and restore those that were lost.

**Non-goals.** Change classification, review gates, or model-routing machinery. Any
`.agents/`, `.claude/`, or `.codex/` skill surface in this repository. Cluster,
Talos, Flux, or application changes. CI redesign beyond one added validator suite.
Rewriting the phase records themselves.

## The layer model

Routing uses **two independent tests**. Root admission requires both.

| | **Constraint** — a prohibition, boundary, or authority | **Procedure** — an ordered way to accomplish something |
|---|---|---|
| **Universal** — binds regardless of directory | root `AGENTS.md` | `docs/runbooks/` |
| **Scoped** — binds only within one subtree | nested `AGENTS.md` | `docs/runbooks/` |

Worked examples:

- "Never commit or push directly to `main`" — universal constraint → root.
- "Agents stage and validate source, then hand off the rollout" — a universal
  authority boundary → root.
- The `*_CONFIRM` rollout sequence itself — universal but procedural → runbook.
- "A `ReadWriteOnce` PVC uses `Recreate`" — a constraint, but only under
  `kubernetes/` → nested.
- "Change `talconfig.yaml`, then run the generate flow" — scoped procedure →
  runbook, while "never hand-edit `clusterconfig/`" stays a scoped constraint.

### Layer ownership

1. **Root `AGENTS.md`** — the constitution. Universal, non-negotiable constraints.
   Loaded every session, so it pays context rent in all of them; that is what earns
   the strict admission test.
2. **Nested `AGENTS.md`** — scoped constraints, binding within their subtree.
3. **`docs/runbooks/`** — the sole canonical owner of procedure within this
   repository, both agent- and operator-facing. Linked from the layers above,
   never restated in them.
4. **`docs/`** — descriptive reference and phase history. Never normative.

External and personal skills are **not a repository surface** and hold no canonical
repository content. This is precisely why the worktree constraints must live in
root regardless of what any external skill contains.

### Additive inheritance

A nested `AGENTS.md` may only **narrow or strengthen** an ancestor constraint. It
may never relax, override, or carve an exception out of one. Relaxation is not a
conflict to be resolved by precedence — it is invalid by construction, which is
what keeps the constitution meaningfully constitutional.

### Required reading

Nested files are **required reading, not an assumed automatic load.** Claude Code
does not reliably load a nested `AGENTS.md` before a file in that subtree is
touched, and client behavior is not something this repository controls. Root
therefore carries an explicit obligation to read a subtree's `AGENTS.md` before
modifying files under it, to verify rather than assume, and to stop if it cannot be
read.

## Root `AGENTS.md`

Seven sections. Every rule in it is universal **and** a constraint.

| § | Holds |
|---|---|
| 1. Purpose and precedence | Repository purpose; `main` as the Flux production boundary; additive inheritance; the required-reading obligation |
| 2. Git and approval authority | Never push to `main`; never merge or enable auto-merge without per-merge authorization; scoped commits; the reporting obligation; the operator owns merge and rollout |
| 3. Worktree and concurrency | The active worktree as an absolute filesystem boundary; no `git worktree` lifecycle subcommands; never start in a slot parked on an unmerged branch; fetch and rebase before every push; `--force-with-lease` only and a failed lease is a full stop; no `reset --hard`, `clean -fd`, or unconditional force-push |
| 4. Tools and cluster access | `mise exec -- just`; no unpinned or system tools; no raw `kubectl`, `talosctl`, `helm`, or `flux` against the live cluster; add a guarded recipe when one is missing; `*_CONFIRM` recipes are operator-run and agents never invent a confirmation value; rollout sources must match current `origin/main`; GitHub protection mutation requires per-invocation authorization through the guarded recipe |
| 5. Secrets | SOPS-encrypted `*.sops.yaml`; the age private key stays with the operator; never handle it, decrypt, rewrite, print, copy legacy ciphertext, or commit plaintext; secrets are created through guarded operator-run `*-secrets` recipes |
| 6. Validation | `just ci` is the authoritative, cluster-independent, secret-free gate; cluster-dependent `*-verify`, `*-status`, `*-preflight`, and diagnostic families are operator-only and never enter it |
| 7. Scoped instruction index | One line per nested file and per runbook destination: what it covers, when to read it |

The two new normative blocks, stated exactly:

```markdown
## Precedence

1. A constraint in this file is a floor. A scoped `AGENTS.md` may narrow or
   strengthen it, never relax or override it. A scoped file that appears to
   permit what this file prohibits is defective — obey this file and report it.
2. Runbooks and skills carry procedure only. They never grant permission.
3. Deterministic enforcement outranks every instruction. If a guard refuses,
   the answer is no.
4. On any unresolved conflict, stop and ask the operator. Never take the
   permissive reading.

## Scoped instructions are required reading

Before modifying any file under a directory that has its own `AGENTS.md`, read
that file. Do not assume your client loaded it automatically — verify. If a
scoped file cannot be read, stop and report rather than proceeding under root
rules alone.
```

Root ends at roughly its current length: about 15 lines of scoped material leave
and about 12 lines of restored constraints and precedence arrive. Size is not an
acceptance criterion; scope clarity is.

## Nested `AGENTS.md` files

Three files. `.just/` and `scripts/` are **deliberately excluded** — their content
is recipe-authoring procedure and shell convention, which route to runbooks and
pre-commit respectively. Adding near-empty scoped files for symmetry would
reproduce the catch-all problem in a new location. They can be added when a genuine
scoped constraint appears.

**`kubernetes/AGENTS.md`** (~25 lines). Migrated out of `kubernetes/README.md`:
Flux entrypoints under `flux/clusters/prod/`; the `apps/<namespace>/<app>/` layout
with an explicit `ks.yaml` and `app/`; a directory is not deployed merely because
it exists; `HelmRelease` for maintained charts versus focused native resources
otherwise; never commit `helm template`, Kompose, or other generator output as
declarative source; `dependsOn` and health checks instead of implicit ordering or
numeric sync waves; explicit native Kustomizations select children and Flux does
not deploy directories recursively; never manually apply `ks.yaml`,
`ocirepository.yaml`, or `helmrelease.yaml`; the Gateway owns the single wildcard
certificate and application routes never copy TLS private keys; ExternalDNS
publishes only routes carrying `external-dns.k8s.io/audience=internal`; Kubernetes
Secret manifests use the `*.sops.yaml` suffix and a decrypted Secret is never
committed; direct `kubectl apply` is reserved for documented bootstrap or recovery.
Migrated down from root: new apps begin suspended and are activated through a
guarded rollout, no Flux resource is suspended without approval, and a Deployment
mounting a `ReadWriteOnce` PVC uses `Recreate` or a StatefulSet, never
`RollingUpdate`.

**`talos/AGENTS.md`** (~10 lines). Migrated out of `talos/README.md`: rendered
machine configs contain credentials and must never be moved into a trackable path;
applying a rendered config is a separate guarded operation and never a raw
`talosctl apply-config`; never reuse another node's confirmation value. Migrated
down from root: never hand-edit generated `clusterconfig/`; change
`talconfig.yaml` and `patches/` and regenerate; preserve Talos, Kubernetes, and
Cilium compatibility.

**`tests/AGENTS.md`** (~8 lines). Live and cluster-dependent suites never enter
`executions.ci`; suite and `executions.ci` entries stay 1:1; documentation names a
confirmation variable but never its value; guards fail closed; Sonobuoy is
ephemeral, never scheduled or standing.

### README migration

Normative content **moves**; it is not copied. Each README gains a pointer line:
"Binding rules for this directory are in `AGENTS.md`; this file is explanatory."

| File | Loses | Keeps |
|---|---|---|
| `kubernetes/README.md` | ~55 lines of normative rules → `kubernetes/AGENTS.md` | Cilium bootstrap narrative, package tree, the four recipe tables, phase links |
| `talos/README.md` | ~15 lines of constraint → `talos/AGENTS.md`; ~55 lines of workflow → `docs/runbooks/talos-generate.md` and `docs/runbooks/talos-install.md` | Purpose, the source-versus-generated explanation, links |

`talos/README.md` ends at roughly 20 lines of orientation. The source-versus-
generated explanation is retained there rather than moved, so the file keeps enough
narrative to stand on its own.

## The `docs/` split

Sorted by what the reader is doing, not by topic.

| Destination | Count | Files |
|---|---|---|
| `docs/runbooks/` | 15 | 13 moved — `sops`, `recovery`, `github-protection`, `pihole-integration`, `portainer`, `protonvpn-gluetun`, `tailscale-operator`, `tailscale-lab-domain`, `tailscale-single-user-setup`, `ntfy-startup-guide`, `arr-stack-startup`, `qbit-manage`, `qbit-manage-czteam` — plus 2 new, `talos-generate` and `talos-install` |
| `docs/phases/` | 15 | `phase-0-preflight` through `phase-14-media` |
| `docs/` root | 4 | `nuc-cluster`, `testing-layers`, `test-campaigns`, `test-reports` |

Twenty-eight existing files move; two are newly extracted. The live documentation
surface — everything that is not frozen phase history — goes from 32 files to 19,
and root `AGENTS.md` §7 can name `docs/runbooks/` as one destination instead of
enumerating files.

**Cost:** approximately 117 of 124 inbound links require rewriting, across about 20
files including `README.md`, the `plans/` documents, `.just/bootstrap.just`,
`.just/repository.just`, both subtree READMEs, two test fixtures, and cross-links
between the docs themselves.

## Sequencing

Four PRs. Each is independently reviewable and each leaves `main` coherent.

### PR 1 — Link validator and plan removal

- `scripts/validate/links.sh` — Bash plus `rg`, executable, ShellCheck-clean —
  asserting every relative Markdown link in tracked `.md` files resolves to an
  existing target. Absolute filesystem paths and `file:` URLs are rejected. HTTP(S)
  URLs are out of scope and are not fetched.
- Recipe in `.just/repository.just`; suite in `tests/catalog.yaml`; matching
  `executions.ci` entry, since the catalog asserts these 1:1; README recipe-table row.
- Delete `plans/agent-instructions-and-skills-architecture-plan.md`. It is
  externally unreferenced — the only match is a self-reference at line 1326 — and
  it contains 23 `docs/` mentions that would otherwise be rewritten by PR 3 in a
  file destined for removal.
- **Acceptance: green against the unmodified tree before anything moves.** This
  baseline is what makes PR 3's completeness provable rather than asserted.

### PR 2 — Constitution and nested layer

- Rewrite root `AGENTS.md` to the seven sections, including the restored worktree
  and concurrency constraints and the two new normative blocks.
- Add `kubernetes/AGENTS.md`, `talos/AGENTS.md`, `tests/AGENTS.md`.
- Strip migrated content from `kubernetes/README.md` and `talos/README.md`; add
  their pointer lines.
- Reword `CLAUDE.md`'s `MEMORY.md` reference so it is unambiguously the agent's
  external persistent memory and not a repository file.
- No file moves, so the link graph is stable and the diff concerns rule placement
  only.
- **Acceptance:** the rule-by-rule mapping below holds — every constraint in force
  before the PR has exactly one named home after it, with none dropped and none
  duplicated.

### PR 3 — The `docs/` split

- Create `docs/runbooks/` and `docs/phases/`; `git mv` 28 files; extract the two
  `talos-*` runbooks; rewrite approximately 117 links.
- **Acceptance:** `just ci` green, which is now meaningful because PR 1's validator
  is watching.

### PR 4 — Root README de-duplication

- Remove the rules `README.md` restates that now live in `AGENTS.md`, replacing
  each with a link. Kept as human-facing operator material: slot creation, VS Code
  setup, the recipe reference, the confirmation safety model, and repository
  boundaries.
- Separated from PR 3 because agent rules and human onboarding genuinely overlap
  here and the tradeoffs deserve their own review rather than riding along with a
  28-file move.

## Rule-by-rule mapping

Every rule in force on 2026-07-31, and its home after this plan.

| Current rule | Destination |
|---|---|
| Repository purpose; `main` is the Flux production boundary | root §1 |
| Never commit or push directly to `main` | root §2 |
| Never merge or enable auto-merge without per-merge authorization | root §2 |
| Keep commits scoped and reviewable | root §2 |
| Report changed files, validation performed, remaining risk | root §2 |
| Stay within the assigned worktree and branch; preserve unrelated changes | root §3 |
| Fetch and rebase onto `origin/main` before every push | root §3 |
| Run workflows through `mise exec -- just`; no unpinned tools | root §4 |
| Guarded recipes for all cluster mutation and health checks; no raw CLI | root §4 |
| Add a guarded recipe when a cluster operation lacks one | root §4 |
| `bootstrap` recipes need `*_CONFIRM` and are operator-run; agents hand off | root §4 |
| Rollout sources must match current `origin/main` | root §4 |
| GitHub protection mutation needs per-invocation authorization | root §4 |
| `just ci` is the canonical cluster-independent secret-free gate | root §6 |
| Cluster-dependent recipe families stay out of `just ci` | root §6 |
| All secrets SOPS-encrypted; age key stays with the operator | root §5 |
| Never handle the age key, decrypt, expose, or commit plaintext | root §5 |
| Secrets created through guarded operator-run `*-secrets` recipes | root §5 |
| Pre-commit hooks are staged-file fast feedback; `just repo lint` runs repo-wide | `README.md` — descriptive, not a constraint |
| Never edit generated `clusterconfig/`; regenerate from `talconfig.yaml` | `talos/AGENTS.md` |
| Preserve Talos/Kubernetes/Cilium compatibility | `talos/AGENTS.md` |
| Follow the `apps/<domain>/<app>/` layout and Flux patterns | `kubernetes/AGENTS.md` |
| New apps begin suspended; no unapproved `suspend:` | `kubernetes/AGENTS.md` |
| RWO PVC requires `Recreate` or a StatefulSet | `kubernetes/AGENTS.md` |

Restored by PR 2, currently absent from the repository:

| Restored constraint | Destination |
|---|---|
| The active worktree is an absolute filesystem boundary | root §3 |
| Never run `git worktree add\|remove\|move\|prune\|lock\|unlock\|repair` | root §3 |
| Never start work in a slot parked on an unmerged branch | root §3 |
| `--force-with-lease` only; a failed lease is a full stop | root §3 |
| No `reset --hard`, `clean -fd`, or unconditional force-push | root §3 |

New in PR 2:

| New content | Destination |
|---|---|
| Precedence and additive inheritance | root §1 |
| Required-reading obligation for scoped files | root §1 |
| Scoped instruction index | root §7 |

## Validation strategy

- Every PR passes `mise exec -- just ci` locally and shows a green `ci` check.
- PR 1's validator must reject a deliberately broken fixture link and accept the
  unmodified tree. Both cases ship with it.
- PR 2 attaches the rule-by-rule mapping as its completeness evidence. No rule may
  end without a home, and no rule may appear in two.
- PR 3 relies on the validator for link completeness rather than manual review.

## Risks and tradeoffs

- **Link rewriting is the bulk of PR 3 and can half-succeed silently.** Mitigated
  by landing the validator first, which is the reason for that ordering.
- **Nested files depend on agents actually reading them.** Nothing enforces this;
  it is an instruction, and the required-reading block is written to make the
  obligation explicit rather than implied. The residual is accepted.
- **Additive inheritance is instruction-only.** Nothing mechanically prevents a
  nested file from contradicting root. The precedence block tells agents to obey
  root and report the defect. A future validator could assert this; it is out of
  scope here.
- **The worktree procedure remains in an external personal skill.** Root holds the
  constraints, so a session without that skill is still bound. But the procedure is
  unavailable to a fresh clone or a non-Claude client. Accepted deliberately;
  revisit if a second client or contributor is onboarded.
- **`docs/phases/` churns 72 links for content that is effectively frozen.** The
  benefit is separating finished history from live reference, which is the larger
  half of the progressive-disclosure gain.

## Decisions recorded

1. Scoped guidance uses nested `AGENTS.md` files, not doc links alone.
2. The root admission test is universality **and** constraint-versus-procedure.
   Both must pass.
3. Destinations are nested `AGENTS.md` and `docs/runbooks/`, with `docs/`
   reorganized to separate procedure, phase history, and reference.
4. Runbooks are the sole canonical owner of procedure within the repository.
5. Nested files are populated by migration out of the existing READMEs, never by
   duplication beside them.
6. Additive inheritance replaces nearest-wins.
7. Nested files are required reading, not an assumed automatic load.
8. Root keeps the worktree constraints; the external skill keeps the procedure.
9. A relative-link validator lands first, before any file moves.
10. `plans/agent-instructions-and-skills-architecture-plan.md` is out of
    consideration and is deleted by PR 1.
