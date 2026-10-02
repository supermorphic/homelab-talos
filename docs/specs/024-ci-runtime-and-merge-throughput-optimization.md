# CI Runtime and Coverage Ownership

## Purpose

Reduce validation cost without weakening production protection. Remove obsolete work,
assign equivalent evidence one producer, and optimize retained checks before adding
selection or more runners. [Deterministic CI gates](027-deterministic-ci-gates.md)
own selective execution and merge reconciliation.

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

## Offline-CI scope

Offline optimization may change offline tests, fixtures, setup, source validation, parsing, rendering,
linting, report adapters, and behavior-neutral test interfaces. It may remove redundant
cases, batch repeated tool invocations, decompose tests, and add bounded concurrency
after proving isolation. These are changes to how CI obtains evidence, not permission
to change the system behavior that the evidence protects.

Offline optimization does not change live diagnostic or encoding runtime, production settings,
scientific quality methodology, dispatch authority, or operational safety contracts.
Test optimization must preserve relevant run identity, provenance, resume, cleanup,
and evidence-comparability requirements. A narrower fixture or injected clock is valid
only when it still detects the production failure the test is intended to catch.

An experimental harness is reviewed against its own design and evidence consumer.
Neither its age nor its runtime authorizes retirement; lifecycle closure must come
from the owning workstream. CI cleanup implements that disposition without reopening
the scientific or operational decision.

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

## General test harness and canonical ownership

The general harness combines catalog validation, Chainsaw configuration and scenario lint,
policy evaluation, shell and Python test groups, and Ruff checks. It is a collection of
independent validation units, not a reason to repeat all preparation for every case.

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

## Bounded concurrency and failure semantics

Harness concurrency is an execution mechanism independent of provider-level selection;
the required suite list must still be complete for each selected gate.

Concurrency is bounded and measured; more workers do not monotonically improve runtime. Cheap high-signal
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

## Reconsideration boundary

Measure equivalent revisions, tools, caches, and runners before claiming savings.
Separate setup, execution, reporting, queue time, aggregate work, and critical-path
latency; small samples support counts, medians, and ranges rather than a dependable p95.
A focused speedup remains a hypothesis until complete-gate measurement confirms benefit.

Runner placement and cross-run result reuse require a separate measured design and the
Forgejo deployment/isolation prerequisites. More compute does not remove duplicate work;
post-merge checks and merge queues cannot replace current-candidate pre-merge evidence.
Retired executable harnesses belong in Git history once their owning workstream has
closed its evidence consumer, not in runnable archives.
