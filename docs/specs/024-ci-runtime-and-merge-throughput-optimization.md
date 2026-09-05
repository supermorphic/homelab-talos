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

The earlier approximately two-minute p95 objective was a diagnostic target used to expose
the cost of a gate that had grown beyond 20 minutes. It is not a Stage 2 acceptance
threshold. Stage 2 instead optimizes for a correct, maintainable, extensible gate that
avoids recomputing unrelated expensive evidence. Measurement must continue to report
validation time separately from checkout, setup, queue, and reporting time, including
p50, p95 when the sample is large enough, runner consumption, and multi-pull-request drain
time. No runtime target overrides correctness or justifies disproportionate orchestration.

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

At the initial investigation commit, the CI implementation had these relevant properties:

- `just ci` executes 39 cataloged suites sequentially and fails fast.
- Repository validation and the test harness repeat parsing and ShellCheck work.
- The test harness executes Conftest once for console output and again for JUnit output.
- The test harness contains at least 45 independently meaningful shell tests plus Python
  test groups.
- Several logging-related shell tests are individually expensive.
- `encode-benchmark` executed 371 Bats tests in one catalog target.
- The GitHub workflow ran one job with a 20-minute timeout, shallow operational
  setup, and a single `mise exec -- just ci` invocation.
- Recent workflow dispatch normally starts immediately. A rare queue outlier exists, so
  queue latency must remain separate from execution time.

### Controlled audit result

The Stage 1 audit fixed the local baseline at commit
`6c42658c54a95ed84fa0abc107ea0847e50bfd2f`. Three complete, sequential, offline
`mise exec -- just ci` runs passed all 39 suites:

| Sample | Total time |
| --- | ---: |
| 1 | 1,352s |
| 2 | 1,276s |
| 3 | 1,352s |

The distribution is count 3, minimum 1,276s, median 1,352s, and maximum 1,352s. No p95
is established from three samples. These measurements are historical local fixed-commit
observations, not a claim about GitHub-hosted performance.

The fixed-commit suite medians confirm the concentration:

| Suite | Median | Share of the 1,352s gate median |
| --- | ---: | ---: |
| `validation.encode-benchmark` | 741.103s | 54.8% |
| `validation.test-harness` | 501.329s | 37.1% |
| Both suites | 1,242.432s | 91.9% |
| `validation.repo-validate` | 20.344s | 1.5% |
| `validation.monitoring` | 9.550s | 0.7% |
| `validation.links` | 7.828s | 0.6% |
| `validation.kubeconform` | 3.946s | 0.3% |

Focused profiles overlap the canonical CI run and each other. They are decomposition
evidence and are never summed into an estimated gate total.

The required controlled GitHub baseline could not be completed. Three fixed-`main`
batches were invalidated when `main` advanced:

| Fixed SHA | Accepted successful runs before discard | Disposition |
| --- | --- | --- |
| `0734b978f156e74723b36ff541f154657304331b` | `33000678906` | Discarded after `main` advanced before run 2. |
| `eb1bd7eb3b4428cd7d37dccda96cb5704fd4f10a` | `33002554203`, `33004276638`, `33005856967`, `33007447835` | Discarded after `main` advanced before run 5. Mismatched-SHA run `33009016143` was cancelled and excluded. |
| `40da2cdc6ea1409cba3d008702e9e150f932b471` | `33009566401`, `33011325436`, `33013054735`, `33014762171` | Discarded after `main` advanced before run 5. |

The discarded partial batches remain descriptive evidence only. They do not provide a
controlled remote queue, workflow, canonical-validation, or end-to-end distribution.
There is no controlled remote p95, and none of the partial samples can substitute for
one. A later rebaseline needs five sequential successful runs on one unchanged SHA in a
quiet merge window or through an explicitly authorized stable-ref workflow.

Local decomposition of `encode-benchmark` produced this fixed-commit distribution:

| Bats file | Tests | Approximate local time |
| --- | ---: | ---: |
| `benchmark.bats` | 111 | 446.394s |
| `dispatch.bats` | 107 | 205.091s |
| `diagnostic-evidence.bats` | 53 | 45.805s |
| `runmeta.bats` | 42 | 15.267s |
| `census.bats` | 21 | 10.498s |
| `bootstrap.bats` | 8 | 5.327s |
| `source-contract.bats` | 15 | 2.989s |
| `selection.bats` | 7 | 1.827s |
| `stills.bats` | 7 | 1.635s |

These local measurements are useful for hotspot decomposition. They are not a controlled
comparison with GitHub-hosted execution. `benchmark.bats` and `dispatch.bats` account for
about 88 percent of the local encode suite median; adding `diagnostic-evidence.bats`
accounts for about 94 percent. The slowest individually profiled general-harness cases
were `monitoring-alloy-logs-validator` at 118.989s, `logging-verifier` at 114.834s,
`monitoring-alloy-events-validator` at 57.768s, `catalog-negative` at 23.930s, and
`monitoring-loki-validator` at 23.246s. These case profiles also overlap the enclosing
test-harness suite and are not an additive savings estimate.

### Focused ICQ harness result after issues 325 and 330

Issues 318-323 expanded the diagnostic evidence surface after the controlled baseline.
At commit `5916f2ed8c22bd52d9be67e41ce3ebe363053183`, Bats registered 401 tests across nine
files. Three controlled complete encode-validator runs took 884.05s, 894.01s, and
894.81s. Their 894.01s median supersedes the earlier 741.103s fixed-commit observation
for the pre-cleanup harness, but both distributions are now historical comparison
evidence.

Issue 325 completed the bounded diagnostic decision and moved the ICQ work from anomaly
diagnosis to one corrected quality selection. Issue 330 commit
`022787bedfd3e32365c3de1701966240e579c045` then applied the lifecycle rule before any
additional scheduling work. It removed completed diagnostics, comparison modes,
historical protocols, unused fixtures, and their operator and source surfaces. The
then-retained offline validator contained exactly 39 high-value Bats tests across five
files:

| Bats file | Tests at the issue-330 boundary |
| --- | ---: |
| `benchmark.bats` | 15 |
| `dispatch.bats` | 8 |
| `quality-evidence.bats` | 11 |
| `runmeta.bats` | 2 |
| `source-contract.bats` | 3 |

The then-retained evidence groups were:

| Group | Tests | Required proof |
| --- | ---: | --- |
| Scientific quality | 12 | Closed VMAF corrections, evaluated statistics, finite SSIM/PSNR, and authoritative HDR classifications |
| Work plan, evidence, ranking, resume, and integration | 17 | Exact 144-row plan, QSV commands, evidence authentication, ranking outcomes, resume, and four representative rows |
| Dispatch and safety | 10 | Confirmation, capability, provenance, source drift, safe Job rendering, confinement, rollback, and bounded results |

At that boundary, no retained offline test simulated all 144 encodes. One independent
planner assertion proved the exact `6 x 3 x 8` work set. Four representative integration
cases covered AVC ICQ 16, HDR10 ICQ 30, row failure and cleanup, and authenticated resume.
Focused oracles covered the remaining scientific, identity, ranking, and safety
invariants.

Three controlled complete-validator runs took 78.25s, 77.10s, and 77.42s. The 77.42s
median is 91.3 percent below the inherited 894.01s median and meets the 60-to-120-second
local target. The final issue-330 canonical `mise exec -- just ci` run passed 780 tests
with no failures. The GitHub workflow now has a 30-minute timeout. That timeout remains
failure headroom, not the runtime objective.

The issue-330 result demonstrates the governing optimization order: close the evidence
lifecycle, remove work without a current consumer, and retain cheaper independent
oracles before adding runners or selective execution. It did not establish the final
required-check distribution because the complete Stage 1 gate and GitHub execution still
required remeasurement after the remaining CI work was integrated. Specification 017
subsequently recorded the completed 144-row evaluation and terminal no-go decision, so
these 39 identities and their operational surfaces no longer have a current consumer.

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

Stage 1 is complete. Its retained validation passed and its final GitHub measurement
established the residual cost distribution. The reviewed Stage 2 analysis below authorizes
a small category selector and split execution model. Stage 3 still requires its specified
external prerequisites and a later implementation decision. This living specification is
updated for Stage 2 because selective execution is an evolution of the same CI-runtime
subject rather than a separate design subject.

The reviewed execution boundary is:

- Plan 023a produced the historical audit and controlled baseline.
- Issues 325 and 330 focused the encode harness while the corrected evaluation remained
  pending. Specification 017 subsequently closed that evaluation. Stage 1 therefore
  removes the remaining harness instead of optimizing or scheduling it. This also
  supersedes Plan 023b's proposed split runner, runner-contract fixes, and fixture
  micro-optimizations.
- The remaining Stage 1 work removed duplicate repository and general-harness work,
  optimized retained slow cases, and remeasured the complete gate.
- Bounded concurrency retained all evidence and reduced the general-harness critical path.
- Stage 2 uses only three measured heavyweight breakouts. Smaller domains remain in the
  always-running core rather than creating a category for every cluster responsibility.
- Stage 3 remains gated by the Forgejo deployment and runner-isolation work that superseded
  issue 275, plus its later benchmark decision gate.

## Validation inventory and lifecycle

Stage 1 inventories every current CI suite and its meaningful test groups. A meaningful
group protects one distinct behavior or invariant; the audit does not require a separate
row for every parameter in a table-driven test. The historical fixed-commit audit had 39
suites; later additions must be included in the final refreshed inventory.

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

### Historical completed audit inventory

The fixed-commit audit resolved 500 entries: all 39 CI suites, nine general-harness
setup or validator groups, 47 shell cases, three Python discovery groups, two Ruff
groups, all 371 encode Bats tests, and 29 experimental or diagnostic surfaces. The final
disposition is 494 Active and six Removed. All 39 suite-level entries remain Active;
the Removed entries are duplicate child executions whose coverage has an exact Active
owner.

The six Removed entries and their canonical owners are:

| Removed execution | Canonical Active owner | Required removal boundary |
| --- | --- | --- |
| `harness:conftest-console` | `harness:conftest-junit` | Run the exact Chainsaw policy/input set once with native JUnit and derive its human view without reevaluating Rego. |
| `harness:yaml-parse` | `harness:chainsaw-test-lint` | Delete the generic `yq` parse over the same 19 Chainsaw documents; independently derive and parse only a future set difference. |
| `harness:bash-syntax` | `validation.repo-validate` | Reuse only a matching passed same-run repository result; standalone validation recomputes. |
| `harness:shellcheck-per-file` | `validation.repo-validate` | Replace the per-file rerun with the canonical repository-wide batched machine-readable result. |
| `harness:shellcheck-json` | `validation.repo-validate` | Move machine-readable findings and JUnit production to the canonical repository owner, then consume only its matching passed same-run result. |
| `shell:qbit-manage-policy-shellcheck` | `validation.repo-validate` | Delete the focused rerun because the canonical repository source set already contains the same file and rules. |

At that audit commit, the repository-wide Bash and ShellCheck owner covered 166 sorted
files. The harness set
contains 95 files, all of which are in that repository set. The same-run handoff is one
atomic JSON document bound to the run ID, commit, sorted source-set digest, Bash and
ShellCheck versions, exact arguments, status, and findings. A failed producer in full CI
fails the gate and causes the fail-fast coordinator to record
`validation.test-harness` as skipped; no consumer reads or recomputes the failed
artifact. A direct or standalone consumer rejects a failed, status-inconsistent,
missing, stale, malformed, truncated, schema-invalid, or corrupt artifact and recomputes
canonical validation. A passing result is never reused across runs.

That audit kept the other 494 entries Active. This included the historical 371-test
encode harness and its then-current operational surfaces. Those totals describe the
fixed audit commit only. Active experimental evidence remains maintained and runnable for
its current consumer; Active does not mean permanently required.

Issues 325 and 330 first removed completed diagnostic and unused evaluation work, leaving
39 Bats identities for the pending corrected quality selection. Specification 017 then
recorded the complete corrected 144-row evidence and terminal no-go decision. The
remaining `validation.encode-benchmark` owner and its source, fixture, quality, evidence,
run, dispatch, result, verification, workload, alert, and toolchain surfaces are therefore
Removed by this Stage 1 change. Exact current repository-wide inventory and shell-source
totals still require regeneration after all Stage 1 branches are integrated; historical
totals cannot be used as current acceptance evidence.

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

`encode-benchmark` is Removed. Specification 017 records the completed corrected 144-row
evaluation, independent AVC, VC-1, and HDR10 rankings, and the terminal no-go strategy
decision. It explicitly states that no further ICQ diagnostic or quality run is
justified. The evidence lifecycle is complete and no current feature, operator workflow,
or safety invariant consumes the runnable harness.

The harness originated during the FileFlows movie-encoding strategy work, but its final
purpose was the distinct QSV HEVC ICQ evaluation in specification 017. FileFlows is not
deployed, and the completed harness does not authorize a FileFlows deployment.

The removal boundary deletes the application source and fixtures, offline validator,
live verifier, dispatcher and result scripts, catalog identities, general-harness case,
operator recipes, Flux Kustomization, PrometheusRule and its rule tests, and the now-unused
FFmpeg toolchain entry. Removing the parent media Kustomization reference lets Flux prune
the Git-managed inert ConfigMaps, PriorityClass, alert rule, and child Kustomization after
merge. This change does not perform a live mutation or delete evidence outside Git.

### Pre-removal optimization and evidence

Issue 330 removed approximately 29,751 net lines from the encode application, tests,
fixtures, helpers, and validation surface. It replaced repeated full-path simulations
with independent planners and scientific oracles plus four representative integration
paths. It did not change the encoder, settings, quality panel, source identities,
correction list, HDR oracle, evidence schemas, objective thresholds, ranking, resume
semantics, dispatch guards, or workload boundary.

The earlier split-runner implementation and its report-boundary tests are superseded and
Removed. The five-file, approximately 77-second validator does not justify restoring that
custom runner. The unaccepted immutable dispatch-fixture experiment is also superseded:
its target helpers and 120-test structure no longer exist, and it claims zero retained
savings.

The 78.96s, 76.45s, and 76.72s controlled samples below establish the cost of the final
pre-removal harness. Its removal should eliminate approximately that focused work from a
warm local full gate, but this is an expectation rather than a measured end-to-end saving.
The post-removal controlled baseline supplies the actual result. A future encoding
strategy starts from a new design and current requirements; it does not restore this
completed harness by default.

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

### Reviewed Stage 1 backlog and savings semantics

Stage 1 first implements the six lifecycle removals above. At quiet window QW-4, the
focused pre-change local distributions (three sorted real-second samples each) were:

| Removed duplicate execution | Samples | Median |
| --- | --- | ---: |
| Chainsaw Conftest console rerun | 0.04, 0.04, 0.16 | 0.04s |
| Generic YAML parse | 0.13, 0.13, 0.15 | 0.13s |
| Harness Bash subset | 0.47, 0.48, 0.54 | 0.48s |
| Harness per-file ShellCheck | 10.27, 10.28, 10.30 | 10.28s |
| Harness ShellCheck JSON | 8.28, 8.36, 8.37 | 8.36s |
| Focused qbit-manage policy ShellCheck | 0.09, 0.10, 0.10 | 0.10s |

These are separate command measurements. They are not added into one savings claim
because focused profiles overlap other views and were not measured as a combined in-run
delta.

The completed ICQ harness is Removed rather than optimized further. Remaining
semantic-preserving runtime work addresses:

- one native-result evaluation for the remaining Conftest and kubeconform console/JUnit
  pairs;
- run-scoped immutable render and pinned OCI chart inputs while each semantic consumer
  keeps its own assertions;
- repeated locked-environment startup without combining distinct Python or Ruff
  invariants;
- repeated JSON projections and real-time retry waits in the offline logging verifier;
- repeated unrelated render preparation in monitoring mutation suites; and
- bounded parallel trials only if the post-cleanup profile still shows isolated retained
  work on the critical path.

Savings claims remain conservative. A separately profiled removable command can report
its observed range. An enclosing suite provides only a zero-to-container ceiling, not
measured savings. OCI resolution, locked-environment startup, decomposition, and
parallelism claim zero savings until a focused or bounded trial measures them. Overlapping
suite, file, shell-case, and focused profiles are never summed.

### Execution and failure behavior

After work removal and intrinsic optimization, retained suites may run concurrently in
bounded groups. This remains full-suite execution in Stage 1: every retained Active suite
runs for every pull request. `encode-benchmark` has no current execution or reporting
dependency because its complete lifecycle is Removed.

Cheap, high-signal repository invariants run first where ordering materially improves
failure latency. Concurrent execution must preserve deterministic reports, results for
every started suite, reliable cancellation, isolated temporary state, and a failed
required suite causing the complete gate to fail.

## Stage 1 verification and measurement

The pre-issue-330 observational and controlled baselines and the issue-330 encode
distribution remain historical pre-removal evidence. They are not a complete Stage 1
gate or GitHub p95. The Stage 1 protocol therefore required a rebase onto final current
`main`, a refreshed inventory, and controlled complete-gate and GitHub measurements.
Historical and current samples were not combined.

The 2026-08-31 quiet-window remeasurement on the rebased issue-303 branch independently
confirmed the focused encode result. Three complete `encode-benchmark-validate` runs
passed all 39 tests in 78.96s, 76.45s, and 76.72s. Their median was 76.72s and their
observed spread was 2.51s. Time Machine was paused, macOS sleep was inhibited, and a
process guard found no foreign CI or benchmark work during the samples.

One clean complete `mise exec -- just ci` run then passed in 727.76s on the same host and
conditions. This single 12m07.76s observation is not a p95 and does not replace the
required repeated GitHub measurements. It showed that the complete offline gate missed
the then-current approximately two-minute objective while the encode harness remained in
the gate. The later lifecycle removal was expected to eliminate its approximately
77-second focused cost, but the actual full-gate change still needed measurement. Stage 1
therefore continued by profiling and reducing the remaining Active validation and harness
costs. This result did not by itself justify Stage 2 target selection.

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

### 023c duplicate-removal result

At commit `2cc7e3e`, Task 8 independently verified the current canonical repository
shell source set against `git ls-files --cached --others --exclude-standard`: 181 regular,
non-symlinked shell files, including `scripts/talos`, with the 107-file harness set as a
strict subset. All five shell files added by plan 023c are in the canonical set. The
current Chainsaw owner is 20 documents (19 under `tests/chainsaw` and one under
`tests/fixtures/chainsaw`), with no current YAML support-file difference. This is the
implemented current boundary; it does not alter the explicitly historical 166-file and
19-document audit observations above.

The historical plan-023a inventory remains exactly 500 entries: 494 Active and six
Removed. Plan 023c removes exactly those six reviewed duplicate executions:
`harness:conftest-console`, `harness:yaml-parse`, `harness:bash-syntax`,
`harness:shellcheck-per-file`, `harness:shellcheck-json`, and
`shell:qbit-manage-policy-shellcheck`. Issue-330 encode reductions and the later complete
encode lifecycle removal are separate decisions and are not included in this historical
count. Focused positive and negative checks proved
the canonical ownership, exact first-Bash failure behavior, exact ShellCheck findings,
rejection and one-time recomputation of invalid artifacts, producer-failure harness skip,
one Conftest evaluation, 20 Chainsaw lints, and no generic reparse of Chainsaw test
documents.

The QW-4 pre-change samples used revision
`d310285731fdb242fab27986ea334678001c6044`; accepted post-change samples used revision
`2cc7e3e78e61025f01297f1af5d54c9b38c192a4`. Both revisions were measured from the same
linked checkout on the same Darwin 25.6.0 arm64 host with the pinned toolchain, ordinary
warm-cache protocol, sequential samples, Time Machine idle or paused, sleep inhibited,
and process guarding. Accepted post-change samples span QW-5, QW-6, and QW-8; they do not
represent one continuous quiet window. Every accepted command passed. Harness and
complete-gate logs reported `configurations=1 tests=20 yaml_files=0 python_test_dirs=2`;
complete CI also reported zero failures, errors, and skips. The three-sample distributions
below compare the QW-4 pre-change values with the accepted post-change values. They report
medians only; three samples do not establish a p95.

The recorded post-change distributions and harness case inventory are fixed at
`2cc7e3e`. Later branch-review hardening, including permanent execution of two existing
behavior suites, was not included in those samples. It does not change the accepted timing
values or establish performance for the later branch head.

| Command | Pre-change samples | Pre median | Post-change samples | Post median | Median delta |
| --- | --- | ---: | --- | ---: | ---: |
| `mise exec -- just repo validate` | 21.16, 21.22, 22.09 | 21.22s | 19.70, 19.99, 21.74 | 19.99s | -1.23s (-5.8%) |
| `mise exec -- just test validate` | 553.68, 554.15, 560.02 | 554.15s | 631.99, 637.66, 691.62 | 637.66s | +83.51s (+15.1%) |
| `mise exec -- just ci` | 707.08, 744.41, 769.10 | 744.41s | 813.27, 889.29, 906.64 | 889.29s | +144.88s (+19.5%) |

QW-5 accepted repository samples 1--3 and harness sample 1 before a foreign worktree
started CI; its later harness sample 2 was preserved but excluded. QW-6 accepted harness
sample 2 before a guard false-positive on the task's own harness; its later harness sample
3 was preserved but excluded. QW-7 excluded harness sample 3 after a guard race on the
task's own exited ShellCheck. QW-8 accepted harness sample 3 and complete-CI samples
1--3; its final guard was clean. Excluded samples do not enter any distribution.

The six duplicate removals and their canonical owners are correctness-verified. No
end-to-end speedup was claimed at this 023c boundary: the observed repository-validation
median decrease was outweighed by observed median increases for both the retained harness
and full gate. Stage 1 was incomplete, so work continued with intrinsic optimization,
profiling, and later controlled measurements. Stage 2 was not authorized at this boundary
because Stage 1 was incomplete and the residual impact and deterministic-selection case
were not yet established.

### 023d retained-harness result and post-removal rebaseline

PR #342 supplied an intermediate GitHub observation before the complete encode lifecycle
removal: canonical validation took 777 seconds, the general harness reported 593.784
seconds, encode validation reported 64.323 seconds, and the required check completed in
13m26s. This is one evolving-branch observation, not a distribution. At that point the
general harness wrote `time="0"` for every shell case, so it could not identify its own
residual critical path.

Plan 023d added real shell-case duration evidence without changing case order, commands,
failure propagation, or fail-fast behavior. Its matched focused measurements evaluated
two implementation changes before the complete rebaseline:

| Focused test | Pre samples | Pre median | Post samples | Post median | Result |
| --- | --- | ---: | --- | ---: | --- |
| Logging verifier | 122.53, 123.11, 126.77 | 123.11s | 128.63, 128.23, 130.43 | 128.63s | Projection rewrite reverted; zero retained saving. |
| Alloy Logs mutations | 137.66, 132.65, 131.49 | 132.65s | 127.94, 125.54, 125.30 | 125.54s | Fixture reuse retained; observed median decrease 7.11s. |
| Alloy Events mutations | 59.65, 60.50, 59.75 | 59.75s | 54.24, 53.68, 55.31 | 54.24s | Fixture reuse retained; observed median decrease 5.51s. |
| Loki mutations | 37.07, 37.27, 36.30 | 37.07s | 34.86, 33.78, 34.66 | 34.66s | Fixture reuse retained; observed median decrease 2.41s. |

Every focused command passed. These overlapping distributions are not added into an
estimated complete-harness saving. Three samples do not establish p95. The logging
projection rewrite made every measured sample slower than the pre-change maximum, so it
was removed. The monitoring fixture helper retained all 24 Alloy Logs, 18 Alloy Events,
and eight Loki mutation identities while avoiding repeated full-repository fixture copies.

After the terminal ICQ result was recorded in specification 017, the remaining 39-test
encode harness and all of its executable, CI, catalog, operator, GitOps, alert, fixture,
verification, and dedicated FFmpeg toolchain surfaces were Removed. The controlled
post-removal rebaseline used commit `f1bda1893341af8ccd6433d270117a1d3c207ceb`, based on
`origin/main` `f19e57d`, on the same Darwin 25.6.0 arm64 host with the pinned toolchain and
ordinary warm caches. Time Machine was paused, sleep was inhibited, and the controller
required the fixed SHA, clean tracked state, and no foreign CI worker immediately before
and after every accepted sample.

Three complete `mise exec -- just test validate` samples passed the same 54 shell-case
identities, 20 Chainsaw documents, and two Python test directories:

| Sample | Elapsed real | User CPU | System CPU | Disposition |
| --- | ---: | ---: | ---: | --- |
| 9 | 741.35s | 399.38s | 162.76s | Accepted |
| 10 | 1,647.98s | 393.86s | 153.88s | Accepted; Alloy Events case took 980.210s. |
| 11 | 710.69s | 393.68s | 148.89s | Accepted |

The post-removal harness distribution has count 3, minimum 710.69s, median 741.35s,
observed maximum 1,647.98s, and range 937.29s. The nearly constant CPU use and the isolated
980.210-second case in sample 10 show large elapsed-time variance that the CI-worker guard
does not explain. This distribution is valid under the declared protocol, but its maximum
must not be presented as a steady-state estimate or as p95.

The residual top 15 shell cases by three-sample median are:

| Rank | Shell case | Median |
| ---: | --- | ---: |
| 1 | `catalog-negative` | 159.353s |
| 2 | `monitoring-alloy-logs-validator` | 123.262s |
| 3 | `logging-verifier` | 116.474s |
| 4 | `monitoring-alloy-events-validator` | 53.834s |
| 5 | `monitoring-loki-validator` | 33.411s |
| 6 | `gatus-validator` | 21.275s |
| 7 | `campaign-runner` | 18.914s |
| 8 | `monitoring-alerts-validator` | 18.725s |
| 9 | `bootstrap-recovery` | 17.916s |
| 10 | `ntfy-identity` | 15.663s |
| 11 | `agent-access-verifier` | 14.424s |
| 12 | `chainsaw-inputs` | 12.235s |
| 13 | `plex-validator` | 11.311s |
| 14 | `n8n-secrets` | 11.295s |
| 15 | `arr-validator` | 10.629s |

One clean complete-CI observation was required. The first two passing attempts took
840.39s and 959.12s but were excluded because a foreign worker appeared before their
post-run guard. A third attempt stopped after 879.24s when a host-wide DNS outage prevented
resolution of the Tailscale Helm repository; a focused retry reproduced the failure, and
resolution of GitHub and other chart domains also failed. The Tailscale validator passed
after DNS recovered. These three attempts are preserved only as excluded diagnostics.

The fourth `mise exec -- just ci` attempt passed 720 tests with no failures, errors, or
skips and clean before/after guards. It took 2,574.80s, of which the harness reported
2,426.217s. Its `catalog-negative` case alone took 1,768.908s, compared with 156.031s to
161.900s in the three accepted harness samples. This single accepted full-CI observation
is therefore evidence of severe elapsed-time variance, not a complete-gate distribution,
steady-state estimate, or p95.

The post-removal result was not operationally acceptable and did not meet the then-current
approximately two-minute objective. The sum of the 54 shell-case medians was 694.104s and
the largest indivisible measured case is 159.353s. Ignoring all orchestration overhead,
ideal load-balancing floors are 347.052s for two workers, 231.368s for three, and 173.526s
for four. At that measurement boundary, bounded split execution was therefore justified as
the next Stage 1 candidate because several independently meaningful retained groups were
material, but splitting that work alone could not reach two minutes. The 023e result
below records the required isolation, deterministic JUnit, fail-fast, and measured-runtime
decision.

At this 023d boundary, Stage 1 remained full-suite validation: all retained Active evidence
still ran for every pull request. Stage 2 remained unauthorized. The residual bottleneck
was dominated by universally executed harness implementation and variance; the evidence
did not yet show that unrelated component validation was the main remaining cost or that
an impact planner would provide the required saving.

### 023e bounded execution and current-main rebaseline

Plan 023e first tested whether the `catalog-negative` hotspot was dominated by starting the
pinned Python process for every compatibility candidate. Commit `22b733d` added exact
direct-versus-CLI parity tests and reused the validator process for the 61 rejection and
three acceptance cases. All compatibility and fixture checks passed, but the controlled
focused result failed its retention gate:

| Catalog compatibility measurement | Samples | Median |
| --- | --- | ---: |
| Existing implementation | 161.900, 159.353, 156.031 | 159.353s |
| Reused Python process | 397.79, 156.23, 161.57 | 161.57s |

The post-change median was 2.217 seconds slower. Commit `5dfcdca` therefore reverted the
experiment and records zero saving. Process startup is not the dominant cost. The retained
validator repeatedly performs substantive repository analysis for each independently
mutated candidate. Further optimization must reduce or share that analysis without changing
the literal rejection, ordering, fail-fast, and CLI-boundary contracts.

The retained implementation adds a Bash 5 bounded worker pool inside
`validation.test-harness`; it does not split the provider workflow or select tests by
changed path. Nine cheap, high-signal, or repository-mutating shell checks remain in a
serial preflight. In particular, `catalog-negative` cannot overlap tests that discover the
repository shell source set because it creates short-lived repository fixtures. The
remaining isolated cases run with a configurable one-to-eight-worker bound and a default of
four. Each worker receives a private `TMPDIR` and cannot inherit the outer result-fragment,
shared-result, or run-ID context. Case declaration order owns console replay and JUnit
fragment numbering regardless of completion order. The first observed failure stops new
work, terminates and reaps owned active workers, records canceled started workers as
skipped, and leaves the unstarted tail for the outer fail-fast reporter.

Permanent regression coverage proves real two-worker overlap, private temporary roots,
result-context isolation, stable output and fragment order, offset fragment numbering,
invalid-bound rejection before execution, duplicate and unsafe registration rejection,
failure-code propagation, cancellation, no unstarted tail, and no surviving owned process.
The complete real harness also passed with one and four workers before measurement.

The clean fixed-SHA worker comparison used the implementation immediately before the final
rebase. Every trial passed the same 55 shell identities:

| Parallel workers | Elapsed real | Change from one worker |
| ---: | ---: | ---: |
| 1 | 728.47s | baseline |
| 2 | 475.42s | -34.7% |
| 4 | 349.09s | -52.1% |
| 6 | 356.49s | -51.1% |

Four workers were fastest. Six workers added contention and took 7.40 seconds longer, so
four remains the selected default. This comparison justifies bounded execution, but it
also disproves the ideal load-balancing model: shared host CPU and I/O plus the serial
preflight remain material.

Three clean full-CI samples on pre-rebase implementation SHA `dd374c6` passed 721 tests
with no failures, errors, or skips. Their wall times were 493.09, 490.73, and 471.38 seconds,
for a 490.73-second median and 21.71-second range. Their harness times were 345.456,
348.753, and 331.827 seconds. These samples remain valid evidence for that exact tree, but
they are not the current-main distribution.

While that measurement ran, issue 356 advanced `origin/main` to `1370eff` and added the
`node-lifecycle` and `cluster-commands` offline cases. The branch rebased and placed both
independently isolated cases in the worker pool. The current harness therefore has nine
serial and 48 parallel shell cases, 57 total. The three current-main samples used rebased
implementation SHA `5dfcdca`, Darwin 25.6.0 arm64, the pinned toolchain, ordinary warm
caches, idle Time Machine, per-command sleep inhibition, clean tracked state, and clean
before/after foreign-worker guards:

| Sample | Wall time | Canonical duration | Harness duration | Result |
| --- | ---: | ---: | ---: | --- |
| 1 | 495.48s | 494s | 352.278s | 732 passed; 0 failed/error/skipped |
| 2 | 495.30s | 494s | 352.659s | 732 passed; 0 failed/error/skipped |
| 3 | 494.23s | 493s | 349.144s | 732 passed; 0 failed/error/skipped |

The authoritative local full-CI distribution has count 3, minimum 494.23 seconds, median
495.30 seconds, maximum 495.48 seconds, and range 1.25 seconds. It is 38.9 percent below
the original 810-second median and has substantial headroom below the 20-minute GitHub
timeout. Three local samples still do not establish p95, and they do not include remote
queue or runner startup behavior.

The current-main residual suite medians are 352.278 seconds for the harness, 26.997 seconds
for repository validation, 18.774 seconds for automation-data validation, 16.476 seconds
for monitoring-alert validation, and 15.214 seconds for n8n validation. The residual top
15 harness-case medians are:

| Rank | Shell case | Median |
| ---: | --- | ---: |
| 1 | `catalog-negative` | 174.007s |
| 2 | `monitoring-alloy-logs-validator` | 125.479s |
| 3 | `logging-verifier` | 118.683s |
| 4 | `monitoring-alloy-events-validator` | 54.434s |
| 5 | `monitoring-loki-validator` | 35.389s |
| 6 | `gatus-validator` | 22.862s |
| 7 | `bootstrap-recovery` | 22.644s |
| 8 | `monitoring-alerts-validator` | 20.088s |
| 9 | `campaign-runner` | 18.748s |
| 10 | `ntfy-identity` | 16.710s |
| 11 | `agent-access-verifier` | 16.027s |
| 12 | `plex-validator` | 12.219s |
| 13 | `n8n-secrets` | 12.026s |
| 14 | `chainsaw-inputs` | 11.971s |
| 15 | `arr-validator` | 11.462s |

The then-current approximately two-minute objective was not met: the median was 8m15s, and
the serial `catalog-negative` case alone had a 2m54s median. Stage 1 therefore continued
with intrinsic optimization of the retained catalog, logging, and monitoring harnesses.
The stable result removed the immediate 20-minute timeout failure, but that operational
recovery was not the design target.

At this 023e boundary, the Stage 2 gate remained closed. Correctness passed and latency
remained unacceptable, but the dominant residual work was still universally invoked
harness implementation whose intrinsic optimization was incomplete. The measurements did
not yet show how much retained work was unrelated to representative ordinary changes or
that a planner would save enough to justify its enforcement complexity. Issue 275 was then
the tracked prerequisite for the separate Forgejo/NUC comparison. Natural GitHub and later
Forgejo runs were expected to supply the larger stable sample needed for a remote p95
claim.

### 023f intrinsic hotspot reduction and Stage 2 decision

Plan 023f continued Stage 1 in the required order: delete unnecessary work, remove
duplicate work, make retained work faster, and decompose a retained monolith. It did not
select validation by changed path. Every Active validation target still ran in each full-CI
sample.

The catalog compatibility fixture previously contained a second repository-shell
validation matrix. That matrix rebuilt full-tree shell fixtures and repeated behavior
already owned by `test_repository_shell_validation.py`,
`validate-harness-shell-consumer-test.sh`, and `run-ci-test.sh`. Commit `79c8a1e` removed
339 lines of duplicate fixture and execution code. It retained all 61 catalog rejection
cases, all three catalog acceptance cases, the executable harness-consumer integration,
the native-JUnit catalog assertion, and static guards against restoring the six reviewed
duplicate shell executions. Three focused samples took 30.04, 30.26, and 30.50 seconds,
for a 30.26-second median compared with the former 174.007-second current-main median. The
observed focused decrease was 143.747 seconds, or 82.6 percent.

Commit `f6d15b7` made the existing complete monitoring validator accept one optional,
fail-closed component scope: `loki`, `alloy-logs`, or `alloy-events`. No argument still
runs the complete validator. An unknown scope or extra argument exits 2 with a literal
usage diagnostic before temporary repositories or rendered state are constructed. The
mutation harnesses now call the narrowest canonical validator that can detect the
mutation. Alloy River-only mutations call the existing River validator directly;
render-dependent mutations call the matching monitoring component scope. All 24 Alloy
Logs, 18 Alloy Events, and eight Loki mutation cases remain Active and passed, and the
complete unscoped monitoring validator also passed.

The focused monitoring results were:

| Mutation harness | Samples | Median | Former median | Observed decrease |
| --- | --- | ---: | ---: | ---: |
| Alloy Logs | 15.14, 14.64, 14.86s | 14.86s | 125.479s | 88.2% |
| Alloy Events | 7.94, 7.98, 7.97s | 7.97s | 54.434s | 85.4% |
| Loki | 12.21, 12.22, 12.40s | 12.22s | 35.389s | 65.5% |

Commit `ff44c79` retained all 64 logging live-acceptance fixture layouts and assigned each
layout to exactly one repository-owned group: 31 topology/storage/runtime cases, 11 label
cases, nine count/compaction cases, and 13 Prometheus-target cases. A contract test invokes
the real selector path with a harmless verifier and proves complete membership, no
duplicates, exact-layout compatibility, `all` compatibility, group order, and unknown
selector rejection. The outer four-worker harness replaced the former single
`logging-verifier` identity with the four group identities. It remains the only owner of
concurrency, cancellation, console order, and JUnit order; the logging fixture does not
create nested workers.

Three focused grouped samples took 36.79, 36.84, and 36.65 seconds, for a 36.79-second
median compared with the former serial 118.683-second median. The corresponding sums of
the four JUnit case durations were 118.321, 118.200, and 117.935 seconds. The 69.0 percent
wall-time reduction is bounded parallelism over the complete retained case set, not
deleted logging evidence.

The branch then rebased onto `origin/main` `4ce63dd`, which added an automation-data
contract fix but did not change the focused logging inputs. The complete current-main
rebaseline used implementation SHA `ff44c79`, Darwin 25.6.0 arm64, the pinned toolchain,
ordinary warm caches, idle Time Machine, per-command sleep inhibition, clean tracked
state, and clean before/after foreign-worker guards. Three other passing attempts took
322.68, 293.36, and 291.68 seconds but were excluded because CI from the
`homelab-talos.automation-data-db` worktree was active at their post-run guard. The final
accepted sample followed a five-minute clear-host guard after that worktree repeatedly
restarted CI during shorter windows.

| Sample | Wall time | Canonical duration | Harness duration | Result |
| --- | ---: | ---: | ---: | --- |
| 1 | 319.31s | 318s | 166.464s | 735 passed; 0 failed/error/skipped |
| 2 | 321.97s | 321s | 165.438s | 735 passed; 0 failed/error/skipped |
| 3 | 293.26s | 293s | 153.201s | 735 passed; 0 failed/error/skipped |

The distribution has count 3, minimum 293.26 seconds, median 319.31 seconds, maximum
321.97 seconds, and range 28.71 seconds. The median is 35.5 percent below the preceding
495.30-second current-main median. All three samples have the same 735-test identity
multiset, the same ordered 60 shell identities inside the 296-test harness report, and no
failure, error, or skip. Three local samples do not establish p95 and do not include remote
queue or runner-start behavior.

PR #361 GitHub run `33829906089` supplied the final Stage 1 hosted-runner observation at
candidate SHA `0eceb5aad8ba3a42418c4c84be317128e7936646`. The job passed in 346 seconds:
checkout took about two seconds, pinned-tool setup took ten seconds, and the complete
cluster-independent validation step took 323 seconds. The canonical result contained all
40 suites and 735 passing tests with no failure, error, or skip. This one run validates the
hosted critical-path model but is not a remote distribution or p95.

A later rebase onto `origin/main` `110feaa` exposed a coordinator correctness defect
before publication. The new automation-data exporter-grant fixture intentionally consumes
its command stdin. `run-ci.sh` was still reading suite IDs from a process substitution
attached to the coordinator loop, so the ninth suite could consume IDs 10 through 40 and
the coordinator could finalize a partial run as passed. Two 9-of-40 verification runs were
rejected despite their internally valid partial reports. The coordinator now resolves the
complete ordered execution list before any suite starts, rejects a failed or empty list,
iterates the in-memory list, and gives every noninteractive suite `/dev/null` as stdin. A
permanent three-suite regression test places an stdin consumer between two passing suites
and requires all three identities and reports. This correctness fix does not change the
three-sample benchmark distribution above, which predates `110feaa` and completed all 40
suites.

The residual suite medians are:

| Rank | Suite | Median |
| ---: | --- | ---: |
| 1 | `validation.test-harness` | 165.438s |
| 2 | `validation.repo-validate` | 28.186s |
| 3 | `validation.automation-data` | 19.421s |
| 4 | `validation.monitoring-alerts` | 17.028s |
| 5 | `validation.n8n` | 15.782s |
| 6 | `validation.monitoring` | 9.848s |
| 7 | `validation.links` | 7.873s |
| 8 | `validation.kubeconform` | 4.816s |
| 9 | `validation.arr` | 4.288s |
| 10 | `validation.foundation` | 3.529s |

The residual top 15 shell-case medians are:

| Rank | Shell case | Median |
| ---: | --- | ---: |
| 1 | `logging-verifier-topology-storage-runtime` | 38.127s |
| 2 | `logging-verifier-counts-compaction` | 30.094s |
| 3 | `catalog-negative` | 30.020s |
| 4 | `logging-verifier-prometheus-targets` | 28.756s |
| 5 | `logging-verifier-labels` | 24.449s |
| 6 | `bootstrap-recovery` | 23.634s |
| 7 | `gatus-validator` | 23.187s |
| 8 | `monitoring-alerts-validator` | 20.412s |
| 9 | `campaign-runner` | 19.689s |
| 10 | `ntfy-identity` | 17.843s |
| 11 | `monitoring-alloy-logs-validator` | 16.816s |
| 12 | `agent-access-verifier` | 16.801s |
| 13 | `monitoring-loki-validator` | 13.471s |
| 14 | `chainsaw-inputs` | 12.985s |
| 15 | `arr-validator` | 12.199s |

Stage 1 produced a material and stable improvement. The residual evidence is no longer
dominated by obsolete or duplicated encode work or by one unsplit test. It contains
retained component-specific validators, fixture groups, and CI-framework contracts.
Further global concurrency does not remove their CPU and I/O cost, and four workers
already outperformed six in the 023e comparison.

The Stage 2 review allocated the 60 shell identities in the general harness to coherent
owners and combined those results with the separately cataloged suites. The resulting
GitHub-timing model identifies three useful breakouts:

| Breakout | Current evidence | Estimated marginal full-lane saving |
| --- | --- | ---: |
| `observability` | 17 harness cases plus monitoring, logging, Loki, Alloy, Gatus, and alert validation | about 113.2s |
| `ci-framework` | 18 harness cases covering the catalog, coordinators, campaigns, reporting, dispatch, result contracts, and harness behavior | about 65.4s after `observability` is removed |
| `automation` | Three harness cases plus n8n and automation-data validation | about 21.4s after the first two breakouts |

After those breakouts, the modeled always-running core is about 122 seconds of validation.
The next candidate breakouts have materially smaller marginal savings: media about 17.6
seconds, platform about 13.1 seconds, documentation about five seconds, security about
five seconds, networking about four seconds, and storage about 1.6 seconds. Those domains
remain in the core. They are ownership descriptions, not initial execution categories.

A coherent validation group that contributes at least 30 seconds of measured marginal
wall time must be reviewed for conditional extraction. The threshold is a review trigger,
not an automatic split: the group also needs clear ownership, useful skip frequency, low
classification ambiguity, and savings that justify another enforcement surface. Groups
below the trigger normally remain in the core. `automation` is the explicit initial
exception because its current boundary is clear and the planned NocoDB and other
automation consumers will increase its responsibility and runtime. This measured,
runner-dependent threshold belongs in this specification, not as a fixed numeric rule in
`AGENTS.md`.

The approximately two-minute target is no longer used to decide whether the architecture
succeeds. The relevant outcome is a safe reduction in unrelated recomputation with bounded
configuration and enforcement cost. Runtime distributions remain required evidence.

## Stage 2 decision gate

Stage 2 proceeds only when measurements satisfy all of the following conditions:

1. Stage 1 correctness and coverage checks pass.
2. Ordinary merge latency remains operationally unacceptable.
3. A material part of the remaining time comes from Active validation unrelated to
   typical changes.
4. Deterministic target selection offers enough expected savings to justify its
   maintenance and enforcement complexity.

The Stage 1 result and the reviewed allocation above satisfy this gate. Retained coverage
passed, the 319.31-second controlled local median and approximately 322-second GitHub
validation step remain a material merge-drain cost, and the two largest coherent groups
have estimated marginal savings above the review trigger. `automation` is the approved
growth exception. The selected model adds three categories rather than reproducing the
repository's full domain taxonomy as scheduling configuration. Stage 2 planning and
implementation are therefore authorized after this specification is approved.

If later evidence shows that the residual selected path is dominated by always-required
validation, the classifier is not the remedy for that portion. Intrinsic optimization
remains valid alongside Stage 2 when it preserves the same evidence.

## Stage 2 architecture

Implement a small deterministic category selector, not a generalized affected-target DAG
or build system. The execution groups are:

| Group | Behavior |
| --- | --- |
| `core` | Always runs. It contains every retained offline target not explicitly assigned to a conditional group. |
| `observability` | Runs when monitoring, logging, Loki, Alloy, Gatus, alerting, or their owned fixtures and validators can be affected. |
| `automation` | Runs when n8n, automation-data, or their owned fixtures and validators can be affected. |
| `ci-framework` | Contains the test catalog, coordinator, campaign, reporting, dispatch, result-contract, and harness-control evidence. CI-framework input changes select `full`. |
| `full` | Selects the exact union of `core`, `observability`, `automation`, and `ci-framework`. It is a fallback plan, not another implementation of the tests. |

The repository owns one small category-level impact map, initially `tests/impact.yaml`.
It records category input paths, catalog members, and paths that require `full`. It does
not add path metadata to every test. `tests/catalog.yaml` remains authoritative for
commands, execution ownership, safety guards, and result contracts.

New validation belongs to `core` unless a later measured review approves another
breakout. Missing optimization metadata must cause extra work, never missing evidence.

### General-harness decomposition

`validation.test-harness` is one mixed suite inside the current 40-suite CI flow; it is
not the complete CI flow. Its `scripts/test/validate-chainsaw.sh` entry point currently
owns Chainsaw and Conftest setup, repository-shell result consumption, approximately 60
shell cases, Python groups, and Ruff checks spanning multiple subsystems.

Stage 2 splits that mixed content into category-selectable catalog identities:

- `validation.test-harness-core`;
- `validation.test-harness-observability`;
- `validation.test-harness-automation`; and
- `validation.test-harness-ci-framework`.

The identities may share runner libraries, but each has one deterministic case list and
its own canonical result. Every existing test-harness case belongs to exactly one group.
The category executor combines its harness identity with existing standalone catalog
suites. For example, `observability` combines its harness cases with
`validation.monitoring`, `validation.monitoring-alerts`, `validation.gatus`, and the other
owned observability suites. `automation` combines its harness cases with
`validation.n8n` and `validation.automation-data`. Tests are not deleted, weakened, or
duplicated by this decomposition.

`mise exec -- just ci` remains the canonical full, cluster-independent, secret-free gate.
Its execution set is the exact union of all four groups.

### Input ownership

The current directory structure supports coarse selection without one mapping per
application:

- `kubernetes/apps/monitoring/**` and explicitly owned monitoring or logging test fixtures
  select `observability` in addition to `core`.
- `kubernetes/apps/automation/**`, `kubernetes/apps/automation-data/**`, and their
  explicitly owned test fixtures select `automation` in addition to `core`.
- Direct validator inputs retain cross-domain ownership. The public webhook gateway,
  ExternalDNS values, networking graph, selected Gatus and alert resources, PostgreSQL
  dashboard packaging, and consumed operations documentation also select `automation`.
  Gatus's echo route/service, internal gateway, and n8n/PostgreSQL/public-route Flux
  entrypoints also select `observability`. The SOPS policy selects both conditional groups.
- Foundation validation in `core` owns the repository-wide public webhook route and
  internal-audience `DNSEndpoint` uniqueness checks. n8n validation retains its direct
  route, workflow, ExternalDNS, and endpoint assertions.
  This keeps the global invariant active for changes in every application domain.
- Existing application and domain paths outside those breakouts select `core` unless an
  explicit foundational rule below selects `full`.
- `.github/workflows/**`, the impact map, the planner, the merge gate, the catalog,
  shared coordinators, shared result code, and shared harness-control code select `full`.
- The campaign runner's direct documentation inputs (`README.md`, `tests/README.md`,
  the campaign operations guide, and the agent cluster-access guide) also select `full`.
  Synthetic unconsumed documentation fixtures prove the default `core` classification.
- `kubernetes/apps/kustomization.yaml`, `kubernetes/apps/flux-system/**`,
  `kubernetes/apps/kube-system/**`, `kubernetes/flux/**`, `talos/**`, foundational Cilium
  wiring, unknown top-level paths, and ambiguous shared inputs select `full`.

The flat `scripts/test/**` and fixture trees are not classified from filenames. Their
existing files receive explicit group ownership during decomposition. New shared or
unmapped test infrastructure selects `full`. The implementation does not require a bulk
directory move.

### Plan and execution flow

For each fresh pull-request synchronization or rebase:

```text
always-running required workflow
-> deterministic plan against current main and the complete rebased head
-> core
   + affected conditional groups
   + operator-requested escalation
-> execute all planned targets against the complete candidate tree
-> always-running merge-gate reconciliation
```

The plan records the exact current-`main` base and candidate-head identities. Failure to
resolve or verify either identity selects the full suite or fails the gate; it cannot
produce a reduced plan.

Unknown paths, missing mappings, malformed definitions, deleted mappings, ambiguous
relationships, and CI or planner changes select `full`. Renames and copies classify both
the old and new paths. Impact uncertainty fails broad, not narrow.

A rebase triggers a fresh plan but not an automatic deep classification. An unrelated
change already in `main` does not make every candidate group affected. A relevant shared
input selects every group it can affect, and every selected target executes against the
complete current tree.

The plan records the base SHA, candidate-head SHA, plan identity, selected groups, and
selection reasons. Each group result is bound to that identity. The planner does not reuse
an earlier passing result. It produces a fresh statement of which retained evidence this
candidate can affect, then obtains that evidence in the current run.

### Merge enforcement and trust

The required branch-protection name remains a static `merge-gate`. It fails when any
planned target is missing, unexpectedly skipped, cancelled, failed, or bound to another
plan identity.

Reconciliation resolves `tests/catalog.yaml` from the immutable Git commit recorded in
the plan's `head_sha` and validates it through the established catalog validator. The
plan schema stays unchanged: its identity already binds that exact candidate commit.
An unavailable commit or missing, inaccessible, or malformed catalog is a configuration
error. Each group must report exactly the suites in its catalog execution, with every
suite marked `passed`, independently of aggregate status or JUnit counts. All reported
groups, including unexpected groups, use the complete canonical group order.

The required workflow cannot use top-level path filters. Provider workflow files remain
thin wrappers around repository-owned planning, execution, and reconciliation commands.

The present single-operator, private-repository threat model does not require a protected
base-owned planner or hostile-pull-request bootstrap architecture. Branch and review policy
protect CI and planner changes, those changes select `full`, and the static required check
is sufficient. The design accepts that a trusted repository administrator can weaken
their own validation policy. Repository commands and result contracts remain compatible
with a later base-owned planner if the contributor trust model changes.

No LLM, author label, Renovate identity, or declarative risk claim can reduce the plan.
An operator or agent can request full or deep validation as an escalation.

### Verification and rollout

Stage 2 earns trust before it skips validation:

1. **Offline verification:** classifier, category membership, plan identity, and merge-gate
   tests run while the existing required workflow remains unchanged.
2. **Shadow planning:** the complete current gate remains required while the planner
   reports what it would select. Evidence covers core-only, each conditional category, a
   combined change, and the `full` fallback; synthetic change fixtures cover paths not
   present in natural pull requests.
3. **Split-all execution:** all four groups run as separate jobs regardless of the plan.
   This proves concurrency, complete test identity, result publication, and reconciliation
   without relying on reduced selection.
4. **Selective enforcement:** conditional execution is enabled and the static
   `merge-gate` becomes the required branch check. Any uncertainty selects `full`.
5. **Post-enable review:** measurements cover selected groups, validation wall time,
   setup and reconciliation overhead, runner consumption, failures, variance, and
   three-to-five-pull-request drain time.

Stage 2 is now in shadow planning. The `ci` job remains the only pass-authoritative job
and still runs the complete `mise exec -- just ci` gate. The advisory `plan-shadow` job
plans from the exact pull-request base and head SHAs, or requests a full plan for the exact
manual-dispatch SHA, and uploads its plan for review. It does not select, skip, approve, or
reduce required validation.

At this rollout boundary, the general harness contains 61 unique shell identities: 22
`core`, 17 `observability`, three `automation`, and 19 `ci-framework`. The original 60
identities are unchanged, and `ci-workflow-contract` is the one new permanent identity.
The complete harness list also contains six setup identities, three Python discovery
identities, and two Ruff identities, for 72 listed work identities. The catalog contains
120 unique suite identities. Its full `ci` execution contains 43 suite identities: 32
`core`, seven `observability`, three `automation`, and one `ci-framework`.

The permanent tests prove that every tracked path resolves to `core`, one or more
conditional groups, or `full`; every target in the canonical CI execution list belongs to
exactly one group; the full group union equals `just ci`; representative changes select
the expected groups; renames and copies use both paths; escalation cannot reduce a plan;
and malformed input, missing results, failed results, cancellation, unexpected skips, or
mismatched plan identity fail the gate. Workflow-contract tests reject a top-level path
filter on the required workflow.

Rollback forces the selector to return `full`. This restores complete validation without
undoing the useful harness decomposition.

The current planning estimates, excluding checkout, are about 122 seconds for `core`, 115
seconds for `observability`, 88 seconds for `ci-framework`, and 25 seconds for
`automation`. A full concurrent gate should approach the slowest selected lane plus setup
and reconciliation rather than their sum. These figures guide measurement; they are not
acceptance thresholds and must be replaced or qualified by controlled execution results.

## Stage 3: Forgejo Runner and NUC #4

Stage 3 depends on the Forgejo deployment and runner-isolation initiatives. Closed
[issue 275](https://github.com/supermorphic/homelab-talos/issues/275) is the historical
origin of that dependency. It is superseded by
[`homelab-playbook` issue 7](https://github.com/supermorphic/homelab-playbook/issues/7),
which owns Forgejo deployment on NUC #4, and
[issue 292](https://github.com/supermorphic/homelab-talos/issues/292), which owns Forgejo
CI quality gates and runner isolation.

Issue 303 does not duplicate that provisioning. Stage 2 can proceed on GitHub with
provider-neutral commands and result contracts. The NUC comparison cannot start until
the other initiatives provide a usable Forgejo repository, runner, rootless Podman job
boundary, and task-scoped access.

There is no Stage 3 implementation plan or NUC comparison activity at this design
boundary. After those prerequisites exist, a later decision gate must still authorize
the comparison. Before Forgejo becomes the authoritative merge gate, issue 292 must prove
pull-request execution and required-check semantics and verify that candidate jobs cannot
obtain cluster or deployment credentials, access a privileged socket, or receive
unnecessary host access.

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

After the Forgejo deployment, runner-isolation work, and NUC #4 setup are complete, the
operator should need only to:

- provide task-scoped access to Forgejo, Forgejo Runner, and non-sensitive NUC telemetry;
- authorize a benchmark window if load testing could affect other NUC services; and
- review the resulting recommendation.

Agent-owned automation triggers runs, collects results, verifies commit and tool parity,
calculates statistics, and produces the placement recommendation. The operator does not
manually trigger runs, clear caches, collect logs, or calculate comparisons. The
experiment should not require root access after the runner and task-scoped access exist.

This operator/automation boundary is mandatory for any later Stage 3 plan. The operator
provides scoped access, authorizes a benchmark window when NUC service load requires it,
and reviews the recommendation. Automation owns all compatible run dispatch, task-owned
cache namespaces, evidence collection, parity checks, calculations, cleanup, and the
placement report.

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

1. After the final Stage 1 rebase, every current CI suite and meaningful test group has a
   refreshed recorded purpose, consumer, runtime, overlap review, and Active or Removed
   disposition.
2. Removed work and its operational surfaces are deleted.
3. Retained work has no known duplicate execution without a documented independent
   invariant.
4. Specification 017 preserves the terminal ICQ evidence and no executable encode source,
   fixture, CI, catalog, GitOps, alert, operator, verification, or dedicated toolchain
   surface remains.
5. The discarded split runner and immutable dispatch-fixture experiment remain absent.
6. Retained representative positive and negative coverage passes.
7. The complete `mise exec -- just ci` gate passes.
8. Controlled post-change timing separates validation, setup, queue, and reporting
   costs and reports sample sizes with its supported percentiles.
9. The Stage 2 decision gate is evaluated explicitly rather than assumed; the reviewed
   residual category model records why Stage 2 now proceeds.

Stage 2 is complete when:

1. The general harness has deterministic `core`, `observability`, `automation`, and
   `ci-framework` groups, with every existing case assigned exactly once.
2. Every target in the canonical CI execution list belongs to exactly one group, and the
   category executors combine their harness groups and standalone catalog suites without
   deleting or duplicating evidence.
3. `mise exec -- just ci` remains the exact full union and passes.
4. Classifier tests prove representative selection, complete path handling, old-and-new
   rename handling, escalation-only overrides, and fail-closed behavior.
5. Merge-gate tests reject every missing, failed, cancelled, unexpectedly skipped, or
   wrong-plan required result.
6. Shadow planning and split-all execution prove plan accuracy, complete test identity,
   provider result transport, and reconciliation before reduced selection is required.
7. The static `merge-gate` is the only branch-protection result needed for the conditional
   workflow, and the required workflow has no top-level path filter.
8. Controlled post-enable measurements report category selection, validation wall time,
   setup and reconciliation overhead, runner consumption, variance, and representative
   multi-pull-request drain time without treating two minutes as a pass/fail threshold.
9. Specification 024 is reconciled with the implemented groups, exact input mappings,
   measured results, and any retained exceptions before merge.

Stage 3 must reconcile its measured Forgejo compatibility, runner-isolation evidence,
and runner-placement decision in an approved implementation specification before merge.
