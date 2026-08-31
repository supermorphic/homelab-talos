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
retained offline validator contains exactly 39 high-value Bats tests across five files:

| Bats file | Current tests |
| --- | ---: |
| `benchmark.bats` | 15 |
| `dispatch.bats` | 8 |
| `quality-evidence.bats` | 11 |
| `runmeta.bats` | 2 |
| `source-contract.bats` | 3 |

The retained evidence groups are:

| Group | Tests | Required proof |
| --- | ---: | --- |
| Scientific quality | 12 | Closed VMAF corrections, evaluated statistics, finite SSIM/PSNR, and authoritative HDR classifications |
| Work plan, evidence, ranking, resume, and integration | 17 | Exact 144-row plan, QSV commands, evidence authentication, ranking outcomes, resume, and four representative rows |
| Dispatch and safety | 10 | Confirmation, capability, provenance, source drift, safe Job rendering, confinement, rollback, and bounded results |

No retained offline test simulates all 144 encodes. One independent planner assertion
proves the exact `6 x 3 x 8` work set. Four representative integration cases cover AVC
ICQ 16, HDR10 ICQ 30, row failure and cleanup, and authenticated resume. Focused oracles
cover the remaining scientific, identity, ranking, and safety invariants.

Three controlled complete-validator runs took 78.25s, 77.10s, and 77.42s. The 77.42s
median is 91.3 percent below the inherited 894.01s median and meets the 60-to-120-second
local target. The final issue-330 canonical `mise exec -- just ci` run passed 780 tests
with no failures. The GitHub workflow now has a 30-minute timeout. That timeout remains
failure headroom, not the runtime objective.

The issue-330 result demonstrates the governing optimization order: close the evidence
lifecycle, remove work without a current consumer, and retain cheaper independent
oracles before adding runners or selective execution. It does not establish the final
required-check p95 because the complete Stage 1 gate and GitHub execution distribution
still require remeasurement after the remaining CI work is integrated.

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

The reviewed execution boundary is:

- Plan 023a produced the historical audit and controlled baseline.
- Issues 325 and 330 completed the encode evidence-lifecycle decision and focused the
  offline harness. They supersede Plan 023b's proposed split runner, runner-contract
  fixes, and fixture micro-optimizations. None of that runner code remains.
- The remaining Stage 1 work removes duplicate repository and general-harness work,
  optimizes retained slow cases, and remeasures the complete gate.
- Bounded concurrency is considered only when retained independent work still dominates
  the measured critical path. The focused encode harness does not justify a custom
  per-file runner.
- Stage 2 gets a plan only if the post-Stage-1 result still justifies impact selection.
- Stage 3 remains gated by issue 275 and its later decision gate.

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

Issues 325 and 330 completed the encode lifecycle review. The bounded diagnostic stage
has a committed terminal decision. The diagnostic producer, collector, reader, terminal
transport, historical protocols, and operator recipes are Removed. The same disposition
applies to x265 comparison, finalist publication, savings and audio inventory, contention
and playback observation, findings rendering, census and sample selection, stills, and
generalized compatibility helpers without a current quality consumer.

The retained `validation.encode-benchmark` owner has 39 Bats identities and only the
source, quality, evidence, run, dispatch, result, verification, and workload surfaces
needed for the corrected quality selection. Exact current repository-wide inventory and
shell-source totals still require regeneration after all Stage 1 branches are integrated;
historical totals cannot be used as current acceptance evidence.

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

`encode-benchmark` is Active. Specification 017 records a terminal diagnostic decision
and one remaining purpose: run the corrected 144-row quality evaluation and rank ICQ
settings independently for AVC, VC-1, and HDR10. No further anomaly diagnostic is
required.

The harness originated during the FileFlows movie-encoding strategy work, but its current
purpose is the distinct QSV HEVC ICQ evaluation in specification 017. FileFlows is not
deployed, and the harness does not authorize a FileFlows deployment.

During Stage 1, `encode-benchmark` remains part of every required `just ci` run. Issue 330
reduced its intrinsic offline cost before changing when it runs. The retained quality,
identity, resume, evidence, dispatch, rollback, confinement, and workload contracts stay
Active. Completed diagnostic and unused evaluation surfaces are Removed.

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

- live ICQ quality Job runtime;
- encoding parameters or quality methodology;
- run identity or evidence comparability;
- quality dispatch authority;
- live operational behavior; or
- production evidence contracts.

The audit groups current encode coverage by consumer:

- exact ICQ quality work planning and selection correctness;
- corrected VMAF and authoritative HDR quality oracles;
- bounded per-row quality evidence;
- immutable run identity, provenance, and resume behavior;
- dispatch authorization, ownership, rollback, and cleanup safety; and
- rendered workload and runtime-contract validation.

Each retained group identifies the corrected quality selection, reproducibility need, or
permanent safety invariant that consumes it. Old LA-ICQ-only cases and completed ICQ
modes are not retained merely for history.

### Implemented encode optimization

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
savings. Any future encode optimization starts from the current 39-test surface and fresh
measurements.

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

The focused ICQ harness reduction is complete. Remaining semantic-preserving runtime work
addresses:

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
runs for every pull request.

The encode validator uses the repository's ordinary suite-level native-result wrapper and
runs its five Bats files together. The discarded split runner provides no current
execution or reporting dependency. Any future decomposition must be justified by a fresh
profile and must preserve deterministic reporting, cancellation, and failure behavior.

Cheap, high-signal repository invariants run first where ordering materially improves
failure latency. Concurrent execution must preserve deterministic reports, results for
every started suite, reliable cancellation, isolated temporary state, and a failed
required suite causing the complete gate to fail.

## Stage 1 verification and measurement

The pre-issue-330 observational and controlled baselines remain historical context. The
issue-330 encode distribution is current focused evidence, but it is not a complete
Stage 1 gate or GitHub p95. After the remaining Stage 1 branches finish, rebase onto final
current `main`, regenerate the exact inventory, and collect controlled complete-gate and
GitHub measurements. Historical and current samples must not be combined.

The 2026-08-31 quiet-window remeasurement on the rebased issue-303 branch independently
confirmed the focused encode result. Three complete `encode-benchmark-validate` runs
passed all 39 tests in 78.96s, 76.45s, and 76.72s. Their median was 76.72s and their
observed spread was 2.51s. Time Machine was paused, macOS sleep was inhibited, and a
process guard found no foreign CI or benchmark work during the samples.

One clean complete `mise exec -- just ci` run then passed in 727.76s on the same host and
conditions. This single 12m07.76s observation is not a p95 and does not replace the
required repeated GitHub measurements. It does show that the complete offline gate still
misses the approximately two-minute objective after the encode harness fell below 80
seconds. Stage 1 must therefore continue by profiling and reducing the remaining Active
validation and harness costs. This result does not by itself justify Stage 2 target
selection.

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
`shell:qbit-manage-policy-shellcheck`. Issue-330 encode removals are a separate lifecycle
decision and are not included in this count. Focused positive and negative checks proved
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
end-to-end speedup is claimed: the observed repository-validation median decrease is
outweighed by observed median increases for both the retained harness and full gate. Stage
1 is not complete. Continue intrinsic optimization and profiling of retained Active heavy
harnesses and the remaining Stage 1 backlog, then collect controlled local and repeated
GitHub measurements. Stage 2 is not authorized: ordinary latency is unacceptable, but the
four-part Stage 2 decision gate remains unmet because Stage 1 is incomplete and the
residual impact and deterministic-selection case are not yet established.

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

No Stage 2 plan exists. The encode reduction removes the former dominant reason to build
selection around that harness, but the missing complete post-Stage-1 remote baseline and
remaining Stage 1 backlog still prevent a final decision. Only measurements that satisfy
all four conditions above authorize a new plan and, after this specification becomes
historical, a new numbered design specification.

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

At the audit boundary, issue 275 is an external blocker for Stage 3. There is no Stage 3
implementation plan and no NUC comparison activity. After issue 275 supplies the usable
Forgejo repository, runner, and scoped access model, a later decision gate must still
authorize the comparison.

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
4. The encode harness remains Active for the corrected ICQ quality selection. Completed
   diagnostics and unused evaluation modes remain Removed.
5. The encode validator retains exactly 39 high-value Bats identities across the five
   current files, unless a later reviewed consumer change updates that boundary.
6. Its planner proves the exact 144-row work set without simulating all 144 encodes, and
   representative integration tests cover AVC, HDR10, row failure, cleanup, and resume.
7. The discarded split runner and immutable dispatch-fixture experiment remain absent.
8. Live ICQ quality behavior and evidence contracts remain unchanged.
9. Representative positive and negative coverage passes.
10. The complete `mise exec -- just ci` gate passes.
11. Controlled post-change timing separates validation, setup, queue, and reporting
   costs, reports sample sizes with its percentiles, and evaluates the ordinary gate
   against the approximately two-minute p95 objective.
12. The Stage 2 decision gate is evaluated explicitly rather than assumed.

If later stages proceed, their implementation specifications and plans must reconcile
their measured results, provider trust model, and runner-placement decision before merge.
