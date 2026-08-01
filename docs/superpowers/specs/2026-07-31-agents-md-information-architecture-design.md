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
| **Scoped** — binds only within named paths or a named domain | nested `AGENTS.md` | `docs/runbooks/` |

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
2. **Nested `AGENTS.md`** — scoped constraints, binding within the paths or domain
   declared by their header and explicitly routed from root.
3. **`docs/runbooks/`** — the final sole canonical owner of procedure within this
   repository, both agent- and operator-facing. Linked from the layers above,
   never restated in them. Until PR 3 moves the 13 existing procedures, each
   current `docs/*.md` procedure remains the sole owner at its valid current path;
   PR 2 therefore routes SOPS editing to `docs/sops.md`.
4. **`docs/`** — descriptive reference, phase history, and design specs. Never
   normative.

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
touched, and placement cannot make a nested file discoverable for a cross-tree
domain such as root `clusterconfig/` or `scripts/test/`. Client behavior is not
something this repository controls. Root therefore carries an explicit obligation
to read a scoped `AGENTS.md` before modifying any path or domain its index routes,
to verify rather than assume, and to stop if it cannot be read.

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
| 7. Scoped instruction index | One line per nested file and per runbook destination: every path/domain it covers and when to read it |

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

The scoped index is transitional in PR 2 and is stated exactly:

```markdown
## Scoped instruction index

- Read `kubernetes/AGENTS.md` before changing Kubernetes or Flux sources.
- Read `talos/AGENTS.md` before changing Talos sources, generation inputs, or root
  `clusterconfig/`.
- Read `tests/AGENTS.md` before changing the test catalog, suites, fixtures, or
  test result and guard machinery, including `scripts/test/`.
- Read the relevant file under `docs/runbooks/` before following a repository procedure.
- Current `docs/phase-*.md` files are completed rollout history, not live procedure.
- `docs/superpowers/specs/` records design rationale and is descriptive, never normative.
```

PR 3 changes only the completed-history route to `docs/phases/` when those files
move; it never advertises the future directory before it exists.

Root ends at roughly its current length: about 15 lines of scoped material leave
and about 12 lines of restored constraints and precedence arrive. Size is not an
acceptance criterion; scope clarity is.

## Nested `AGENTS.md` files

Three files. `.just/` and `scripts/` do not receive additional `AGENTS.md` files.
Adding near-empty files for symmetry would reproduce the catch-all problem in a
new location. A genuine cross-tree domain is instead declared in the owning
scoped file's header and routed explicitly from root; this is why
`tests/AGENTS.md` also binds test result and guard machinery under `scripts/test/`.
Other `.just/` and `scripts/` content remains recipe-authoring procedure or shell
convention routed to runbooks and pre-commit respectively.

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
committed; after Flux bootstrap, steady-state Kubernetes changes are made in Git
and reconciled by Flux. Migrated down from root: new apps begin suspended, are
activated through a guarded rollout, and **the unsuspended state is then persisted
in Git**; no Flux resource is suspended without approval; and a Deployment mounting
a `ReadWriteOnce` PVC uses `Recreate` or a StatefulSet, never `RollingUpdate`.

**One source rule is deliberately not migrated.** `kubernetes/README.md:122–124`
currently reads "Direct `kubectl apply` is reserved for documented bootstrap or
recovery steps." Root §4 prohibits raw `kubectl` against the live cluster with no
exception, so carrying that sentence into `kubernetes/AGENTS.md` would be a
*relaxation* of an ancestor constraint — invalid under additive inheritance. The
two files have quietly disagreed all along; making inheritance explicit is what
surfaced it.

The resolution preserves root: bootstrap and recovery applies happen **through
guarded `just` recipes**, which invoke `kubectl` internally. An agent never invokes
it directly, so no exception is needed. `kubernetes/AGENTS.md` states the
steady-state rule (changes go through Git and Flux) and the README sentence is
rewritten to describe the guarded path rather than grant a carve-out. PR 2 must not
silently drop it — the rewrite is part of that PR's diff and its rationale belongs
in the PR description.

**`talos/AGENTS.md`** (~10 lines). Its header binds both files under `talos/` and
generated machine configs under root `clusterconfig/`; root's scoped index makes
the cross-tree route discoverable. Migrated out of `talos/README.md`: rendered
machine configs contain credentials and must never be moved into a trackable path;
applying a rendered config is a separate guarded operation and never a raw
`talosctl apply-config`; never reuse another node's confirmation value. Migrated
down from root: never hand-edit generated `clusterconfig/`; change
`talconfig.yaml` and `patches/` and regenerate; preserve Talos, Kubernetes, and
Cilium compatibility.

**`tests/AGENTS.md`** (~8 lines). Its header binds both files under `tests/` and
test result and guard machinery under `scripts/test/`; root's scoped index makes
the cross-tree route discoverable. Live and cluster-dependent suites never enter
`executions.ci`; suite and `executions.ci` entries stay 1:1; **generated result
artifacts** record only a confirmation variable name, never its value; guards fail
closed; Sonobuoy is ephemeral, never scheduled or standing.

The artifact constraint is scoped precisely, because an earlier draft
over-generalized it to "documentation" and would have been wrong. The source rule
at `tests/README.md:125` governs `summary.json` and `environment.json` — machine
output — not prose. Human documentation *must* carry complete confirmation values
to be usable: `tests/README.md:63` correctly contains
`CLUSTER_E2E_CONFIRM=e2e:qbit-manage-policy`, and the phase runbooks record exact
confirmed commands throughout. A constraint written against "documentation" would
have declared correct, safety-critical operator material to be a violation.

### README migration

Normative content **moves**; it is not copied. Each README gains a pointer line:
"Binding rules for this directory are in `AGENTS.md`; this file is explanatory."

| File | Loses | Keeps |
|---|---|---|
| `kubernetes/README.md` | ~55 lines of normative rules → `kubernetes/AGENTS.md`; exact identity-loading/editing/verification workflow → current `docs/sops.md` | Cilium bootstrap narrative, package tree, the three recipe tables, SOPS field explanation and operator-only route, phase links |
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
| `docs/superpowers/specs/` | 1+ | Dated design specs, this document first |

Twenty-eight existing files move; two are newly extracted. The live documentation
surface — everything that is not frozen phase history — goes from 32 files to 19,
and root `AGENTS.md` §7 can name `docs/runbooks/` as one destination instead of
enumerating files.

`docs/superpowers/specs/` is the canonical home for design specs, named
`YYYY-MM-DD-<topic>-design.md`. Specs are **descriptive, never normative** — a spec
records why an architecture was chosen and is not a source of agent rules, so it
sits under `docs/` rather than becoming a fourth instruction surface. It is
deliberately distinct from `plans/`, which holds time-bounded implementation
sequencing. Root `AGENTS.md` §7 names it as a destination but agents are not
required to read it.

**Cost:** approximately 117 of 124 inbound links require rewriting, across about 20
files including `README.md`, the `plans/` documents, `.just/bootstrap.just`,
`.just/repository.just`, both subtree READMEs, two test fixtures, and cross-links
between the docs themselves.

## Sequencing

Four PRs. Each is independently reviewable and each leaves `main` coherent.

### PR 1 — Link validator and plan removal

- `scripts/validate/links.sh` — Bash plus `rg`, executable, ShellCheck-clean —
  validating **two distinct reference classes**, because checking only the first
  would leave PR 3 unprovable:
  1. **Markdown links** — every relative `[…](…)` target in tracked `.md` files
     resolves to an existing file. Absolute filesystem paths and `file:` URLs are
     rejected. HTTP(S) URLs are out of scope and are not fetched.
  2. **Bare path references** — every `docs/**.md`, `plans/**.md`, or subtree
     `README.md`/`AGENTS.md` path appearing as plain text in **any** tracked text
     source resolves to an existing file. This class covers `.just`, `.sh`,
     `.yaml`, `.toml`, and Markdown prose that names a path without linking it.

  Class 2 is not optional polish. Thirty-one such references exist today outside
  Markdown, including `docs/phase-11-media.md` inside a **runtime echo message** at
  `.just/bootstrap.just:1163` and `docs/tailscale-operator.md` in a comment at
  `.just/repository.just:1033`. PR 3 moves both files. Without class 2, `just ci`
  stays green while a recipe prints a dead path to an operator mid-rollout.
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
  and concurrency constraints, the two new normative blocks, explicit cross-tree
  routes, and the current `docs/phase-*.md` history classification.
- Add `kubernetes/AGENTS.md`, `talos/AGENTS.md`, `tests/AGENTS.md`.
- Strip migrated content from `kubernetes/README.md` and `talos/README.md`; add
  their pointer lines. Route the Kubernetes SOPS procedure to current
  `docs/sops.md` instead of retaining a second ordered workflow, and place the
  exact three-command edit sequence there.
- Reword `CLAUDE.md`'s `MEMORY.md` reference so it is unambiguously the agent's
  external persistent memory and not a repository file.
- No file moves, so the link graph is stable and the diff concerns rule placement
  only.
- **Acceptance:** the rule-by-rule mapping below is worked as a checklist and every
  row ticked — each constraint in force before the PR has exactly one named home
  after it, none dropped and none duplicated. Sections B, C, and D cover the README
  migrations; a constraint that cannot be placed without relaxing an ancestor is a
  blocker, not a rounding error.

### PR 3 — The `docs/` split

- Create `docs/phases/`; `git mv` 28 files into `docs/runbooks/` and
  `docs/phases/`; retain the two Talos runbooks extracted by PR 2; rewrite
  approximately 117 links.
- In the same move, change root's completed-history route from current
  `docs/phase-*.md` files to `docs/phases/`, update the Talos installation-evidence
  link, and change the Kubernetes SOPS route to `docs/runbooks/sops.md`.
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

Every constraint in force on 2026-07-31 and its single home after this plan. This
table is **PR 2's executable checklist**, not illustration: the PR is incomplete
until every row is ticked, and a row that cannot be ticked is a blocker rather than
a cleanup item. It covers all four sources — root `AGENTS.md` and the three READMEs
being migrated — because a mapping that omitted the READMEs would assert
completeness it had not checked.

### A. From root `AGENTS.md` (in force today)

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
| Never edit generated `clusterconfig/`; regenerate from `talconfig.yaml` | `talos/AGENTS.md`, whose declared scope includes root `clusterconfig/` and is routed there by root |
| Preserve Talos/Kubernetes/Cilium compatibility | `talos/AGENTS.md` |
| Follow the `apps/<domain>/<app>/` layout and Flux patterns | `kubernetes/AGENTS.md` |
| New apps begin suspended, roll out through guarded `just bootstrap <app>`, **then persist the unsuspended state** | `kubernetes/AGENTS.md` |
| Do not suspend Flux resources without approval | `kubernetes/AGENTS.md` |
| RWO PVC requires `Recreate` or a StatefulSet | `kubernetes/AGENTS.md` |

### B. From `kubernetes/README.md` (migrated by PR 2)

| Source rule | Line | Destination |
|---|---|---|
| Flux cluster entrypoints belong under `flux/clusters/prod/` | L8 | `kubernetes/AGENTS.md` |
| Components own their manifests and config under `apps/<namespace>/<app>/` | L9–11 | `kubernetes/AGENTS.md` |
| Explicit `ks.yaml` and `app/`; a directory is not deployed merely by existing | L12–14 | `kubernetes/AGENTS.md` |
| Rendered Helm output is validation material, not declarative source | L17–18 | `kubernetes/AGENTS.md` |
| `HelmRelease` for maintained charts; focused native resources otherwise | L20–22 | `kubernetes/AGENTS.md` |
| Never commit `helm template`, Kompose, or generator output as source | L22–24 | `kubernetes/AGENTS.md` |
| `dependsOn`, readiness waiting, health checks — not implicit ordering or sync waves | L26–30 | `kubernetes/AGENTS.md` |
| Explicit Kustomizations select children; Flux does not recurse into directories | L32–34 | `kubernetes/AGENTS.md` |
| Never manually apply `ks.yaml`, `ocirepository.yaml`, or `helmrelease.yaml` | L60–61 | `kubernetes/AGENTS.md` |
| Gateway owns one wildcard cert; routes never copy TLS private keys | L102–104 | `kubernetes/AGENTS.md` |
| ExternalDNS publishes only `external-dns.k8s.io/audience=internal` | L104 | `kubernetes/AGENTS.md` |
| Secret manifests use `*.sops.yaml` | L108 | `kubernetes/AGENTS.md` |
| Never commit a decrypted Secret or place the age identity in this tree | L119–120 | `kubernetes/AGENTS.md` |
| Steady state is Git plus Flux reconciliation | L122–124 | `kubernetes/AGENTS.md`, **rewritten** — see the additive-inheritance resolution above |
| Shared bases deferred; `deletionPolicy: Orphan`; SOPS encrypts `data`/`stringData` only | L15–16, L35–36, L109–110 | `kubernetes/README.md` — descriptive, not constraints |
| Repository identity loading and interactive SOPS editing workflow | L111–118 | current `docs/sops.md`; PR 3 moves it to `docs/runbooks/sops.md` |

### C. From `talos/README.md` (migrated by PR 2)

| Source rule | Line | Destination |
|---|---|---|
| Rendered configs contain credentials; never move them into a trackable path | L16–18 | `talos/AGENTS.md` |
| Applying is a separate guarded operation; never raw `talosctl apply-config` | L31–33 | `talos/AGENTS.md` |
| Never reuse another node's confirmation value | L69–70 | `talos/AGENTS.md` |
| Generation and validation workflow | L20–43 | `docs/runbooks/talos-generate.md` |
| Phase 3 installation workflow | L45–75 | `docs/runbooks/talos-install.md` |
| Source-versus-generated explanation | L8–18 | `talos/README.md` — retained |

### D. From `tests/README.md` (migrated by PR 2)

| Source rule | Line | Destination |
|---|---|---|
| Live commands must never enter `just ci` | L100 | `tests/AGENTS.md`, whose declared scope includes test result/guard machinery under `scripts/test/` and is routed there by root |
| Generated artifacts record a confirmation variable name, never its value | L125 | `tests/AGENTS.md`, with the same declared cross-tree scope |
| Operator-only suites must not be added to CI | L188 | `tests/AGENTS.md`, with the same declared cross-tree scope |
| Sonobuoy is ephemeral — never scheduled or standing | L26 | `tests/AGENTS.md`, with the same declared cross-tree scope |
| Validation-tier suite count and `executions.ci` count stay 1:1 | `catalog_validator.py:557` | `tests/AGENTS.md`, with the same declared cross-tree scope |

### E. Restored by PR 2 — currently absent from the repository

| Restored constraint | Destination |
|---|---|
| The active worktree is an absolute filesystem boundary | root §3 |
| Never run `git worktree add\|remove\|move\|prune\|lock\|unlock\|repair` | root §3 |
| Never start work in a slot parked on an unmerged branch | root §3 |
| `--force-with-lease` only; a failed lease is a full stop | root §3 |
| No `reset --hard`, `clean -fd`, or unconditional force-push | root §3 |

### F. New in PR 2

| New content | Destination |
|---|---|
| Precedence and additive inheritance | root §1 |
| Required-reading obligation for scoped files | root §1 |
| Scoped instruction index | root §7 |
| Cross-tree route from root `clusterconfig/` to `talos/AGENTS.md` | root §7 |
| Cross-tree route from test result/guard machinery under `scripts/test/` to `tests/AGENTS.md` | root §7 |
| Current `docs/phase-*.md` files classified as completed history until PR 3 moves them | root §7; PR 3 changes the route to `docs/phases/` |

## Validation strategy

- Every PR passes `mise exec -- just ci` locally and shows a green `ci` check.
- PR 1's validator must accept the unmodified tree and reject a deliberately broken
  fixture in **each** reference class — a dead Markdown link and a dead bare path
  inside a non-Markdown source. A validator that only proves class 1 would pass
  while leaving PR 3 unverifiable. Both fixtures ship with it.
- PR 2 attaches the rule-by-rule mapping as its completeness evidence. No rule may
  end without a home, and no rule may appear in two.
- PR 3 relies on the validator for link completeness rather than manual review.

## Risks and tradeoffs

- **Link rewriting is the bulk of PR 3 and can half-succeed silently.** Mitigated
  by landing the validator first, which is the reason for that ordering, and by
  validating bare path references rather than Markdown links alone — 31 of the
  references at risk are not links at all.
- **PR 2 may surface further latent contradictions.** The `kubectl apply` conflict
  between root and `kubernetes/README.md` was found only because additive
  inheritance forced the question. Others may exist in the ~70 lines being migrated.
  This is the mechanism working, but it means PR 2's scope is not fully knowable
  until the mapping is worked row by row. Each contradiction found is resolved
  explicitly in that PR, never by silently choosing the permissive reading.
- **Nested files depend on agents actually reading them.** Nothing enforces this;
  it is an instruction, and cross-tree domains cannot rely on ancestor discovery.
  The required-reading block plus explicit root routes make every declared domain
  discoverable rather than implied. The residual is accepted.
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
11. Design specs live in `docs/superpowers/specs/` as
    `YYYY-MM-DD-<topic>-design.md`, separate from `plans/` implementation
    sequencing. This document is the first, and establishes the convention.
12. A scoped file may bind a cross-tree domain only when its header declares that
    domain and root's scoped index routes readers to it.
13. PR 2 names only current paths. PR 3 changes the phase-history, SOPS-runbook,
    and Talos-install evidence routes atomically with the corresponding moves.

## Open follow-up

`plans/` needs a cleanup pass and is not yet a reliable reference. Eight files are
tracked; #168 removed completed plans once already, and at least
`portainer-gitops-observability-deployment-plan.md` describes finished work. PR 1
removes exactly one file — the superseded agent-instructions plan — and takes no
position on the rest. A retention convention for `plans/` (retain with status,
migrate durable content into `docs/` and remove, or retain indefinitely) is
**explicitly out of scope here** and left as recorded follow-up so it is not
silently resolved by precedent.
