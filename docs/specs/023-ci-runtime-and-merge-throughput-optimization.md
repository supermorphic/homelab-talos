# CI Runtime and Merge-Throughput Optimization

## Purpose

Reduce the latency of the repository's required pre-merge CI gate without weakening the
evidence required to merge into `main`. This specification supports
[issue 303](https://github.com/supermorphic/homelab-talos/issues/303).

The primary problem is not only the duration of one CI run. The repository commonly has
three to five independent worktree streams ready or nearly ready to merge. Its strict
workflow serializes those streams:

```text
feature or worktree branch
-> pull request
-> required CI
-> rebase onto current main when required
-> fresh required CI
-> squash merge to main
```

After one pull request merges, each remaining pull request can require another rebase and
another required CI run. A ten-to-fifteen-minute gate therefore becomes a long drain time
for several otherwise-ready changes.

The governing principle is:

> First reduce CI to the smallest set of relevant, non-duplicated, efficiently implemented
> evidence. Selectively execute that evidence only when measurements show that the added
> orchestration is worthwhile.

## Constraints

- Fresh pre-merge evidence against the complete candidate tree rebased onto current
  `main` remains mandatory.
- Post-merge testing can supplement but cannot replace the pre-merge gate.
- A merge queue, merge train, or post-merge queue is outside this initiative.
- GitHub Actions is the current executor, but the design must remain portable to Forgejo
  Actions and Forgejo Runner.
- Runtime classification cannot be delegated to an LLM, coding agent, pull-request
  author, or Renovate. Repository-owned deterministic logic must select any reduced path.
- Human or agent input may escalate validation but cannot de-escalate below the
  deterministic requirement.
- The source of a change does not determine its impact. A Renovate change is classified
  from the files and dependencies it changes.
- A rebase alone does not require deep validation. The current candidate impact determines
  what evidence is invalidated.
- Exceptional platform changes may require materially longer pre-merge validation.
- Correctness and production protection take precedence over a runtime target.

The desired ordinary merge-gate experience is approximately two minutes p95 when that is
realistically achievable without reducing confidence. Approximately three minutes is a
possible upper design target for broader changes. Five minutes is not the ordinary target
because that delay is repeatedly serialized across three to five work streams. These are
design targets, not unconditional acceptance criteria.

## Measured baseline

The initial investigation reviewed 15 successful GitHub pull-request runs. These runs
represent evolving repository states, so they are observational rather than a controlled
benchmark. They establish the scale and concentration of the problem:

| Work | Observed median |
| --- | ---: |
| Total validation | 13m30s |
| `encode-benchmark` | 9m53s |
| General test harness | 2m25s |
| Repository validation | about 22s |
| Repository lint | about 12s |
| Checkout | about 1s |
| Tool setup | about 18s |

In a representative run, `encode-benchmark` and the general test harness consumed about
91 percent of validation time. Checkout, setup, and reporting are visible costs, but the
current critical path is validation work.

The current CI implementation has these relevant properties:

- `just ci` executes 39 cataloged suites sequentially and fails fast.
- Repository validation and the test harness repeat parsing and ShellCheck work.
- The test harness executes Conftest once for console output and again for JUnit output.
- The test harness contains at least 45 independently meaningful shell tests plus Python
  test groups.
- Several logging-related shell tests are individually expensive.
- `encode-benchmark` executes 371 Bats tests in one catalog target.
- The current GitHub workflow runs one job with a 20-minute timeout, shallow operational
  setup, and a single `mise exec -- just ci` invocation.
- Recent workflow dispatch normally starts immediately. A rare queue outlier exists, so
  queue latency must remain separate from execution time.

Local decomposition of `encode-benchmark` showed the following relative distribution:

| Bats file | Tests | Approximate local time |
| --- | ---: | ---: |
| `benchmark.bats` | 111 | 458s |
| `dispatch.bats` | 107 | 209s |
| `diagnostic-evidence.bats` | 53 | 50s |
| All remaining Bats files | 100 | 38s |

These local measurements are useful for hotspot decomposition. They are not a controlled
comparison with GitHub-hosted execution. `benchmark.bats` and `dispatch.bats` account for
about 88 percent of the local Bats runtime.

## Staged decision model

Work proceeds through measurement gates rather than assuming every stage is necessary:

```text
Stage 1: audit, remove, deduplicate, and optimize existing CI
-> controlled measurement
-> stop if the result is operationally acceptable
-> Stage 2 only if unrelated retained validation still dominates ordinary latency
-> controlled measurement
-> Stage 3 only when runner or advanced techniques remain justified
```

Stage 1 is the only immediate implementation scope. Stage 2 and Stage 3 require their
specified evidence and a new implementation decision. This specification describes their
minimum acceptable shape so Stage 1 does not create incompatible foundations. After this
specification merges and becomes historical, either later stage uses a new numbered
specification when its measured decision is material enough to require implementation.

## Validation inventory and lifecycle

Stage 1 inventories all 39 CI suites and their meaningful test groups. A meaningful group
protects one distinct behavior or invariant; the audit does not require a separate row for
every parameter in a table-driven test.

Each inventory entry records:

- the invariant or behavior it protects;
- the current feature, subsystem, operator workflow, or decision that consumes it;
- whether equivalent coverage exists elsewhere;
- approximate runtime and setup cost;
- whether it is permanent validation or experimental evidence generation;
- unresolved work or decisions that depend on it;
- one lifecycle disposition; and
- the proposed action and evidence needed to preserve coverage.

The inventory is initially an analysis and implementation artifact. Stage 1 must not add a
permanent target registry merely to conduct the audit.

### Lifecycle states

Executable validation and experimental harnesses have exactly two lifecycle states:

1. **Active**

   The source is maintained and runnable because it protects a current repository,
   product, operational, or experimental need.

2. **Removed**

   The executable source and its CI, dependency, fixture, GitOps, operator, and other
   operational surfaces are deleted as applicable. Git history, retained evidence, and
   completed specifications preserve the historical record.

There is no Archived state. The repository must not retain unused runnable routines as an
archive. An unresolved audit decision is temporary analysis state, not a third lifecycle
state.

An Active harness does not make every historical test Active. Individual tests and modes
must still identify a current consumer or permanent safety invariant.

## `encode-benchmark` disposition and boundary

`encode-benchmark` is Active. Specification 017 still records unresolved ICQ quality
diagnostics, including objective-quality anomalies and an unavailable HDR10 static
metadata oracle. No terminal diagnostic decision is committed, and the operator confirms
that the diagnostic work remains in progress.

The harness originated during the FileFlows movie-encoding strategy work, but its current
purpose is the distinct QSV HEVC ICQ evaluation in specification 017. FileFlows is not
deployed, and the harness does not authorize a FileFlows deployment.

During Stage 1, `encode-benchmark` remains part of every required `just ci` run. Stage 1
optimizes its intrinsic offline cost before changing when it runs.

### Offline-CI scope

Issue 303 may change:

- Bats tests, fixtures, and test-specific setup;
- offline source validation, parsing, rendering, and linting;
- offline report generation and adapters;
- duplicated test cases or completed historical paths;
- repeated process and tool invocation;
- test decomposition and safe offline parallelism; and
- behavior-neutral test interfaces that do not change live semantics.

Issue 303 does not optimize or alter:

- live ICQ diagnostic Job runtime;
- encoding parameters or quality methodology;
- run identity or evidence comparability;
- diagnostic dispatch authority;
- live operational behavior; or
- production evidence contracts.

The audit groups current encode coverage by consumer:

- ICQ evaluation and selection correctness;
- VMAF and HDR diagnostic classification;
- bounded diagnostic evidence collection;
- immutable run identity, provenance, and resume behavior;
- dispatch authorization, ownership, rollback, and cleanup safety; and
- rendered workload and runtime-contract validation.

Each group must identify which unresolved specification 017 decision, reproducibility
need, or permanent safety invariant consumes it. Old LA-ICQ-only cases are Removed when
they protect neither current ICQ work nor a permanent invariant. Current ICQ code is also
reviewable: completed modes are not retained merely because they are newer than LA-ICQ.

### Encode optimization hypotheses

The current Bats structure exposes several high-value hypotheses:

- `benchmark.bats` extracts the same samples document during setup for about 111 tests.
- `dispatch.bats` reconstructs large `kubectl`, `yq`, Git, Flux, and filesystem stubs for
  about 107 tests.
- Mutation matrices repeatedly start Bash, runtime scripts, `jq`, and `yq`.
- Immutable renders and evidence fixtures are rebuilt repeatedly.
- Some tests exercise a complete end-to-end path when a smaller independent assertion
  may protect the same invariant.

Stage 1 can prepare immutable file-level fixtures once while preserving per-test mutable
isolation, parse source documents once, batch table-driven cases with exact case-level
failure output, reduce repeated full-script startup, and run independent files or groups
concurrently after proving isolation. Test count is not a protected metric. Retained
behavior and safety coverage are.

## Stage 1 optimization design

Stage 1 uses a semantic audit with measured hotspot optimization. It does not limit the
audit to the two slowest targets, but measurements determine where deeper engineering
effort is worthwhile.

The optimization order is mandatory:

1. Delete unnecessary work.
2. Remove duplicate work.
3. Make necessary work faster.
4. Decompose necessary monoliths when that improves profiling, failure latency, or safe
   concurrency.
5. Measure the complete gate again.
6. Decide whether selective execution is still justified.

A focused implementation rewrite is allowed when it preserves the same validation
meaning. Replacing many `yq` subprocesses with one Python parse is an example. A wholesale
harness or test-framework rewrite is deferred until later measurements justify it.

For every retained validation unit, Stage 1:

1. measures suite, setup, test-group, and repeated-command cost;
2. removes tests without a current consumer or permanent invariant;
3. removes equivalent coverage across suites;
4. reuses results within the same run;
5. batches repeated parsing, rendering, and fixture preparation;
6. improves expensive test implementations without weakening assertions;
7. decomposes monoliths where useful;
8. applies bounded parallelism only after unnecessary work is gone;
9. verifies equivalent protection with representative passing and failing fixtures; and
10. remeasures the complete required gate.

### General test harness

`validation.test-harness` is a collection of validation units rather than one permanent
monolith:

- catalog validation;
- Chainsaw configuration and scenario linting;
- Conftest policy evaluation;
- YAML parsing;
- shell syntax and ShellCheck;
- at least 45 shell test programs;
- Python unit-test groups; and
- Ruff lint and format checks.

Stage 1 assigns one canonical owner to each invariant:

- Repository-wide ShellCheck runs once over the required set. A harness subset cannot
  cause a second or third execution in `just ci`.
- Conftest evaluates policy once. One machine-readable result can produce console and
  JUnit views; reporting cannot rerun the policy.
- Chainsaw and YAML files are parsed or linted in batches when the tools support it.
- Repeated `uv run` startup is consolidated when Python import isolation permits.
- Report adapters transform existing results and cannot re-execute validators.

Each shell and Python group receives its own purpose and runtime review. Expensive
logging, polling, timeout, and retry tests should use deterministic injected time when
possible instead of consuming real wall time. Independent cases can use bounded
parallelism only after temporary-file, environment, fixture, and result-fragment
isolation is proved.

Focused commands may become narrower when responsibility moves to another canonical
validator. The complete `just ci` gate must retain the coverage; duplicate coverage in
every subordinate command is not a requirement.

### Remaining suites

Every remaining suite is reviewed for:

- a current invariant and consumer;
- duplicate parsing, rendering, linting, schemas, or policy;
- repeated Helm and Kustomize renders;
- repeated `yq`, `jq`, or subprocess calls inside loops;
- generated-file drift and schema overlap;
- repeated dependency or tool setup; and
- safe batching or concurrency.

Small suites are not rewritten merely because improvement is possible. The audit is
complete, while implementation effort remains proportional to measured runtime,
duplication, and maintenance value.

### Execution and failure behavior

After work removal and intrinsic optimization, retained suites may run concurrently in
bounded groups. This remains full-suite execution in Stage 1: every retained Active suite
runs for every pull request.

Cheap, high-signal repository invariants run first where ordering materially improves
failure latency. Concurrent execution must preserve deterministic reports, results for
every started suite, reliable cancellation, isolated temporary state, and a failed
required suite causing the complete gate to fail.

## Stage 1 verification and measurement

The observational baseline is retained with its sample count and limitations. Stage 1
also records controlled fixed-commit before-and-after measurements.

Measurements separate:

- workflow queue and start latency;
- checkout and pinned-tool setup;
- each suite and significant subtest group;
- reporting and artifact finalization;
- runner execution from start to required-check completion; and
- end-to-end required-check latency from dispatch to completion.

Focused optimizations receive repeated local measurements through the pinned toolchain.
The completed Stage 1 gate receives repeated GitHub executions and reports the median,
observed p95, maximum, variance, and sample count. A small-sample p95 is labeled
provisional rather than presented as statistically settled. Normal pull-request runs can
continue strengthening it.

Correctness verification includes representative positive and negative fixtures,
focused suite execution, and the complete canonical `mise exec -- just ci` gate. No live
cluster test enters `just ci`.

## Stage 2 decision gate

Stage 2 is optional. It proceeds only when all of the following are true:

1. Stage 1 correctness and coverage checks pass.
2. Ordinary merge latency remains operationally unacceptable.
3. A material part of the remaining time comes from Active validation unrelated to
   typical changes.
4. Deterministic target selection offers enough expected savings to justify its
   maintenance and enforcement complexity.

If Stage 1 reaches approximately two minutes p95, or otherwise provides an acceptable
three-to-five-stream drain experience, implementation stops and reassesses before adding
Stage 2.

If the residual bottleneck is universally required validation, an impact planner is not
the remedy. The next action is further intrinsic optimization or a separately justified
focused rewrite.

## Conditional Stage 2 architecture

If the decision gate justifies Stage 2, implement the smallest deterministic
affected-target planner that solves the residual problem. Do not create a general build
system.

The existing test catalog is the preferred metadata owner if it can accept a small impact
block without confusing its assurance and live-dispatch responsibilities. Retained
offline targets need only enough metadata to express:

- input paths;
- dependencies or reverse impacts;
- universal or exceptional behavior; and
- their existing command.

The exact schema follows the Stage 1 inventory and cannot be assumed in advance.

### Plan and execution flow

For each fresh pull-request synchronization or rebase:

```text
always-running required workflow
-> trusted deterministic plan against current main and the complete rebased head
-> universal targets
   + directly affected targets
   + dependency/reverse-impact closure
   + operator-requested escalation
-> execute all planned targets against the complete candidate tree
-> always-running merge-gate reconciliation
```

The plan records the exact current-`main` base and candidate-head identities. Failure to
resolve or verify either identity selects the full suite or fails the gate; it cannot
produce a reduced plan.

Unknown paths, missing mappings, malformed definitions, dependency cycles, deleted
mappings, ambiguous relationships, and CI or planner changes select the full retained
suite. Impact uncertainty fails broad, not narrow.

A rebase triggers a fresh plan but not an automatic deep classification. An unrelated
change already in `main` does not make every candidate target affected. A relevant shared
dependency broadens the target closure, and every selected target executes against the
complete current tree.

The planner does not reuse an earlier passing result. It produces a fresh statement of
which retained evidence this candidate can affect, then obtains that evidence in the
current run.

### Merge enforcement and trust

The required branch-protection name remains a static `merge-gate`. It fails when any
planned target is missing, unexpectedly skipped, cancelled, failed, or bound to another
plan identity.

The required workflow cannot use top-level path filters. Provider workflow files remain
thin wrappers around repository-owned planning, execution, and reconciliation commands.

Planner and CI-framework changes must use trusted current-`main` bootstrap logic and
select full validation. The exact provider mechanism must be proven on both GitHub and
Forgejo before Stage 2 is accepted. If the planner cannot be made trustworthy on Forgejo,
Stage 2 is not deployed.

No LLM, author label, Renovate identity, or declarative risk claim can reduce the plan.
An operator or agent can request full or deep validation as an escalation.

## Stage 3: Forgejo Runner and NUC #4

Stage 3 depends on
[issue 275](https://github.com/supermorphic/homelab-talos/issues/275), which establishes
Forgejo as the canonical self-hosted Git platform on NUC #4. Issue 275 owns Forgejo
installation, repository hosting, GitHub disaster-recovery mirrors, Forgejo Actions,
runner registration, rootless Podman execution, and the access model used by this
benchmark.

Issue 303 does not duplicate that provisioning. Stage 1 and conditional Stage 2 can
proceed before issue 275 completes. The NUC comparison cannot start until issue 275
provides a usable Forgejo repository and runner.

### Comparison scope

NUC #4 runs the same repository-owned offline commands for the same commits. The default
automated experiment includes approximately:

- one or two compatibility runs per executor;
- three cold-cache runs per executor;
- ten warm or normal runs per executor;
- three drain trials with three simultaneous jobs per executor; and
- three drain trials with five simultaneous jobs per executor.

This is about 75--80 full CI-equivalent executions across GitHub and NUC #4, plus focused
repetitions only when full-run data cannot distinguish CPU, I/O, OCI, or setup costs.
Natural pull-request history can continue strengthening p95 estimates.

The comparison records:

- complete wall-clock and target time;
- checkout, queue, and runner-start latency;
- dependency and pinned-tool setup;
- cold and warm cache behavior;
- OCI pull and build behavior;
- CPU-bound and I/O-bound validation;
- runtime variance;
- one-, three-, and five-job concurrency;
- total drain time; and
- CPU, memory, storage, and I/O effects on NUC #4's persistent services.

Runner concurrency and resource limits protect the persistent off-cluster services on
NUC #4. CI workspaces, rootless containers, and caches remain isolated and unprivileged.
Cold trials use task-owned cache namespaces rather than deleting shared caches.

### Operator effort

After issue 275 and NUC #4 setup are complete, the operator should need only to:

- provide task-scoped access to Forgejo, Forgejo Runner, and non-sensitive NUC telemetry;
- authorize a benchmark window if load testing could affect other NUC services; and
- review the resulting recommendation.

Agent-owned automation triggers runs, collects results, verifies commit and tool parity,
calculates statistics, and produces the placement recommendation. The operator does not
manually trigger runs, clear caches, collect logs, or calculate comparisons. The
experiment should not require root access after the runner and task-scoped access exist.

The result selects one outcome:

1. NUC #4 is the primary CI executor.
2. NUC #4 is a capacity-limited supplemental executor.
3. NUC #4 provides insufficient performance or operational benefit for primary CI.

Forgejo workflow compatibility remains mandatory because it is the final Git and CI
destination, regardless of the NUC performance result.

## Cache and advanced-optimization boundary

Normal caches may accelerate toolchains, dependencies, OCI layers, schemas, rendered
manifests, and deterministic intermediate inputs. A cache miss, corruption, or eviction
causes recomputation rather than reduced validation.

Stage 1 and initial Stage 2 do not use cached passing results as fresh evidence. Trusted
cross-run pass-result reuse and attestation storage remain deferred.

Only after Stage 1, any justified Stage 2, and the NUC benchmark may the initiative
separately evaluate:

- a wholesale harness or framework rewrite;
- richer dependency-DAG metadata;
- content-addressed validation artifacts; or
- trusted cross-run attestations and passing-result reuse.

Each requires a separate design because it changes maintenance, trust, or evidence
semantics.

Normal timing instrumentation remains Active while it supports routine CI measurement.
Any one-off runner-benchmark orchestration is Removed after its evidence is retained in
issue 303 and the applicable later decision specification.

## Rejected starting points

### Build the impact planner first

This would encode scheduling around work that may be obsolete, duplicated, or needlessly
slow. Stage 1 must establish the retained evidence set first.

### Optimize only the two slowest targets

The hotspots deserve most implementation effort, but a hotspot-only review can preserve
smaller duplicate or obsolete work and cannot establish trustworthy future impact
metadata.

### Rewrite the complete harness stack immediately

A wholesale migration creates a large semantic-regression surface before measurements
show that framework overhead is the remaining constraint. Focused behavior-preserving
rewrites are sufficient for Stage 1.

### Add more runners without reducing work

Parallel compute can shorten a critical path but does not remove obsolete validation,
duplicate parsing, repeated rendering, or inefficient test implementations. It also does
not by itself solve constrained NUC capacity.

### Move required validation after merge

Post-merge evidence cannot protect the required current-`main` pre-merge decision and
does not solve the repository's stated workflow.

### Add a merge queue

A queue changes merge orchestration rather than reducing the evidence invalidated by a
rebase. It is outside the initiative and is not required by the GitHub-to-Forgejo design.

### Retain completed harnesses as archives

Unused runnable source creates dependency, security, and maintenance cost. Git history,
retained evidence, and completed specifications provide the historical record.

## Completion criteria

Stage 1 is complete when:

1. Every current CI suite and meaningful test group has a recorded purpose, consumer,
   runtime, overlap review, and Active or Removed disposition.
2. Removed work and its operational surfaces are deleted.
3. Retained work has no known duplicate execution without a documented independent
   invariant.
4. The encode harness remains Active for the ongoing ICQ diagnostic purpose, with legacy
   and current modes reviewed individually.
5. Live ICQ behavior and evidence contracts remain unchanged.
6. Representative positive and negative coverage passes.
7. The complete `mise exec -- just ci` gate passes.
8. Controlled post-change timing separates validation, setup, queue, and reporting costs
   and reports sample sizes with its percentiles.
9. The Stage 2 decision gate is evaluated explicitly rather than assumed.

If later stages proceed, their implementation specifications and plans must reconcile
their measured results, provider trust model, and runner-placement decision before merge.
