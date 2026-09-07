# CI Runtime and Merge-Throughput Optimization — Stage 1

## Purpose

Reduce required pre-merge CI latency without weakening production protection. This
specification records the Stage 1 design and completed outcome for
[issue 303](https://github.com/supermorphic/homelab-talos/issues/303).

The repository commonly has three to five worktree streams ready to merge. Each merge
can invalidate the remaining branches' ancestry and require another validation cycle:

```text
feature/worktree branch -> PR -> required CI
-> rebase onto current main when required -> fresh CI -> squash merge
```

The governing principle is:

> First reduce CI to relevant, non-duplicated, efficiently implemented evidence.
> Selectively execute that evidence only when measured savings justify the complexity.

Stage 1 changes the work performed by the full gate, not which changes receive it.
The separate [Stage 2 specification](027-deterministic-ci-gates.md) owns selective
execution. Runner placement remains deferred.

## Governing constraints

- Fresh pre-merge evidence must cover the complete candidate tree containing current
  main. Post-merge checks may supplement, never replace, that evidence.
- Merge queues, merge trains, and post-merge queues are outside this initiative.
- `mise exec -- just ci` is the canonical full, cluster-independent, secret-free gate.
  Live verification, diagnostics, encoding, and production mutations stay outside it.
- Pinned repository commands and canonical result contracts remain the common interface
  across GitHub and the intended Forgejo destination.
- Meaningful regression coverage, independent assertions, and failure detection take
  precedence over runtime. Test count alone is not a measure of protection.
- The trusted-contributor model does not relax public-artifact or secret-handling rules.
  CI does not gain deployment credentials or broader host access for performance.
- Normal input and dependency caches may reduce setup work. Cached passing results do
  not substitute for fresh validation; invalid or missing cache entries require recomputation.

The earlier two-minute objective exposed excessive CI cost; it is not an acceptance
threshold. The objective is useful reduction in validation and serialized merge-drain
latency without disproportionate maintenance cost.

## Initial measured baseline

The initial review of 15 successful GitHub PR runs found concentrated validation cost:

| Work | Observed median |
| --- | ---: |
| Complete validation | 13m30s |
| Encode benchmark | 9m53s |
| General harness | 2m25s |

The encode benchmark and general harness accounted for about 91 percent of one
representative run. Setup and checkout were much smaller contributors. These observations
covered evolving revisions, not one controlled distribution. A subsequent fixed-revision
local baseline exceeded 20 minutes, confirming the timeout and merge-throughput problem.

The causal findings were redundant parsing and linting, repeated policy evaluation for
different report formats, expensive repeated fixture/render preparation, and obsolete
experimental work. More runners alone would not remove those costs.

## Staged decision model

```text
Stage 1: audit -> remove -> deduplicate -> optimize -> measure
  -> stop if operationally acceptable
  -> Stage 2 only when unrelated retained work justifies selective execution
  -> Stage 3 only when a later runner/advanced-optimization decision is justified
```

Stage 1 was the only immediate implementation scope authorized by this specification.
Later stages require their own measured decision. A material later-stage architecture
receives a new numbered specification rather than expanding this record into a journal.

Stage 1 is complete, and its evidence satisfied the Stage 2 decision gate.
[Specification 027](027-deterministic-ci-gates.md) owns that architecture and rollout.
Stage 3 remains deferred.

## Validation inventory and lifecycle

The audit covers every meaningful suite, validator, test group, and experimental
harness, not only the largest hotspots. Each unit must have an identifiable:

- invariant and current consumer;
- permanent or experimental purpose;
- overlap with other coverage;
- approximate validation and setup cost;
- unresolved evidence requirement; and
- lifecycle disposition and coverage-preserving action.

The detailed inventory is an audit artifact, not a permanent scheduling registry.
A parameterized case needs its own entry only when it protects a distinct invariant.

Executable validation has exactly two lifecycle states:

| State | Meaning |
| --- | --- |
| Active | Maintained and runnable for a current product, repository, operational, or experimental need. |
| Removed | Executable source and associated CI, fixtures, dependencies, GitOps, and operator surfaces are deleted as applicable. |

There is no Archived state. Pending review is temporary audit work, not a third state.
An Active harness does not make every historical mode or test necessary.

Removal requires reviewing unresolved decisions, unique safety coverage, reconstruction
cost, retained evidence, live resources, and ongoing dependency/security burden.
Expense alone does not justify deletion. Git history, retained evidence, completed
specifications, issues, PRs, and implementation plans preserve the historical record;
unused executable or documentary history need not remain in the active source tree.

### Completed encode lifecycle

The encode benchmark remained Active while the ICQ evaluation consumed its evidence.
[Specification 017](017-fileflows-qsv-hevc-icq-evaluation.md) subsequently closed that
evaluation with a no-go decision and no justified further diagnostic work. With no
remaining consumer or independent safety invariant, the harness became Removed.

Its executable, validation, dependency, reporting, operator, and GitOps surfaces were
removed rather than archived. Retained scientific evidence was not deleted. CI work
did not alter live encoding parameters, quality methodology, dispatch authority, or
the experiment's evidence contract to obtain a shorter runtime.

A future encoding strategy requires a current design; it does not restore this completed
harness by default.

## Stage 1 design

The optimization order is:

1. Delete work with no current consumer or independent invariant.
2. Remove equivalent duplicate execution.
3. Make necessary work faster without changing its meaning.
4. Decompose necessary monoliths when profiling, isolation, or concurrency benefits.
5. Measure the complete gate again.
6. Decide whether selective execution is worthwhile.

Implementation effort follows measured cost and maintenance value. Small suites remain
in scope for audit but do not require speculative rewrites.

### Canonical ownership and same-run reuse

Each invariant has a canonical producer:

- Repository validation owns Bash syntax and batched machine-readable ShellCheck.
  Harness consumers reuse only matching, passed, same-run evidence for the relevant
  source set and tool inputs. Standalone execution or invalid evidence recomputes;
  a failed producer cannot authorize a passing consumer.
- Chainsaw lint owns its test documents. Generic parsing covers only independently
  derived support inputs not already covered, rather than parsing those documents again.
- Conftest and schema validation evaluate their inputs once. Native machine-readable
  results supply both human and JUnit views; report adapters do not rerun validators.
- Independent consumers may share immutable renders or dependencies while retaining
  their own assertions. Mutable fixtures remain isolated.

A narrower subordinate command is acceptable when the full gate retains its canonical
coverage. Duplicating a check in every entry point is not a protection requirement.

### Intrinsic optimization

The retained implementation reduces repeated fixture preparation, rendering, parsing,
subprocess startup, and equivalent compatibility checks. Monitoring mutation tests use
the narrowest canonical component validator that detects their mutation; complete
validation remains available. Logging tests are decomposed where that improves isolation
and execution without removing their behavioral cases.

Focused rewrites and deterministic test-time controls are appropriate when they preserve
the independent oracle and relevant failure behavior. A framework replacement is not a
prerequisite. Overlapping suite and subtest measurements are not additive savings claims.

### Bounded concurrency and failure semantics

Stage 1 retains full-suite execution for every candidate. Its selected concurrency is
inside the offline harness, not provider-level conditional jobs.

Measurement selected four workers as the default; the bounded interface allows one
through eight. More workers did not monotonically improve runtime. Cheap high-signal
checks and repository-mutating tests remain in serial preflight where overlap would
invalidate another test's source discovery or fixtures.

Workers receive private temporary roots and isolated result context. Declaration order
controls console replay and result fragments, independently of completion order.
A failure stops new work, cancels and reaps owned active workers, accounts for started
work, and leaves unstarted work to the outer fail-fast reporter. No child may silently
outlive its run or convert cancellation into passing evidence.

The coordinator resolves a complete nonempty suite list before execution and prevents
individual commands from consuming later suite identities through stdin. Every required
suite must be accounted for; a partial run cannot pass as a complete gate.
Canonical reports preserve native assertions, failures, errors, and skips rather than
collapsing them into a misleading aggregate success.

## Final Stage 1 outcome

Stage 1 delivered:

- removal of obsolete encode validation after its evidence consumer completed;
- canonical ownership replacing duplicate parsing, ShellCheck, policy, report, and
  compatibility work;
- intrinsic optimization of retained monitoring and harness coverage;
- measured bounded concurrency with deterministic output and failure handling; and
- preserved retained correctness, including positive and negative regression evidence
  and complete-gate identity checks.

Representative final evidence was:

| Measurement | Final Stage 1 result |
| --- | --- |
| Controlled local full gate, three comparable samples | Median 319.31s; range 293.26–321.97s |
| GitHub-hosted validation, one representative run | 323s |
| Complete hosted job, including overhead | 346s |
| Retained gate correctness | All required suites passed with no failures, errors, or skips |

The local and hosted results are separate observations, not interchangeable runner
benchmarks. Neither three local samples nor one hosted run establishes a dependable p95.
These final Stage 1 facts explain the decision below; they are not promises about future
repository revisions or current Stage 2 runtime.

## Stage 2 decision and handoff

The decision gate requires retained correctness, material remaining merge latency,
expensive Active evidence unrelated to ordinary changes, and expected savings that
justify selection's maintenance cost.

That gate was satisfied. The optimized full gate still took roughly five minutes, which
is repeatedly serialized across ready branches. Retained observability and framework
tests were substantial coherent costs that many application changes do not affect.
Selective execution therefore became a distinct architecture worth implementing.

The next design must preserve fresh base/head-bound evidence, deterministic
repository-owned classification, conservative handling of uncertainty, exact coverage
ownership, reliable required-check reconciliation, and escalation-only overrides.
A rebase is not itself a reason to run every expensive test; relevant changed inputs
determine what can be affected. Author identity or a claimed risk level cannot reduce
validation.

[Specification 027](027-deterministic-ci-gates.md) owns the chosen groups, mappings,
execution contracts, trust assumptions, measurement, and rollout. If always-required
work dominates later measurements, optimize that work rather than adding categories.

## Deferred Stage 3 boundary

Runner-placement work remains deferred. It depends on Forgejo deployment and runner
isolation: [homelab-playbook issue 7](https://github.com/supermorphic/homelab-playbook/issues/7)
and [issue 292](https://github.com/supermorphic/homelab-talos/issues/292), which supersede
the historical issue 275 dependency.

Any executor must preserve the same repository-owned validation semantics and protection
boundary. A later measured decision and new numbered implementation specification must
authorize runner placement and any advanced evidence-reuse design. This specification
does not prescribe benchmark quotas, orchestration, operator procedures, or a NUC placement.

## Rejected alternatives and debrief

- **Scheduling before cleanup:** encodes obsolete or duplicated work into orchestration.
  Lifecycle and semantic ownership come first.
- **Hotspot-only audit:** misses smaller redundant or obsolete coverage. Audit broadly,
  then focus engineering effort on measured costs.
- **Wholesale harness migration or more workers first:** adds regression surface or
  contention without necessarily reducing required work. Retain changes only when
  correctness and measured benefit justify them.
- **Post-merge substitution or a merge queue:** changes the required workflow rather than
  solving its stated pre-merge evidence cost.
- **Archived runnable experiments:** retains dependency and maintenance burden after the
  consumer is gone. Preserve the decision and evidence, not unused operational surfaces.

The durable lesson is that validation semantics, execution completeness, and lifecycle
ownership matter more than test counts or theoretical parallel speedups. Complete-gate
measurement must confirm a benefit; a fast subtest does not establish a faster CI gate.

## Review and completion criteria

Stage 1 is complete. Future changes to its retained design must continue to establish:

1. A current consumer and independent invariant for Active validation.
2. Complete removal of obsolete operational surfaces with required evidence preserved.
3. Canonical ownership without unneeded duplicate evaluation.
4. Equivalent positive and negative protection after implementation changes.
5. Full offline gate completeness, deterministic reports, isolation, and failure propagation.
6. Measurements that distinguish validation from setup/reporting and disclose sample limits.
7. An explicit measured decision before introducing another stage's architecture.

Detailed audit rows, experiment attempts, sample exclusions, execution transcripts,
commit identities, and rollout mechanics belong in Git history, retained evidence,
issue 303, PRs, plans, and the relevant guides—not in this durable Stage 1 record.
