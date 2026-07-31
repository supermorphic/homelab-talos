# Catalog Validation Runtime Refactor

Status: needs-triage

## Problem Statement

The canonical full validation command takes approximately five minutes even though
its timeout is twenty minutes. Most of that wall time is not distributed across
Helm rendering or the independent application validators: the test harness spends
the majority of its time repeatedly running catalog validation, whose shell
implementation launches thousands of `yq` processes and reparses the same manifests.

This makes local iteration expensive and will limit the benefit of later GitHub job
parallelism. Validation cannot be removed, weakened, reordered, or skipped because
`main` is the Flux production deployment boundary and the full command is the
cluster-independent validation contract.

## Solution

Replace the catalog validator's repeated shell subprocess model with a holistic
Python implementation that parses each manifest once per invocation and evaluates
the existing rules in their established order. Preserve the current shell-facing
entry point and every externally observable behavior: accepted inputs, rejected
fixtures, rejection reasons, assertion ordering, output, exit status, and fail-fast
semantics.

Benchmark the standalone catalog validator, the complete test harness, and the full
sequential validation command independently across three runs. If a performance
target is missed, profile the remaining measured bottleneck rather than speculating,
weakening validation, or introducing suite skipping. Treat Helm/chart caching and
parallel application validation as later measured decisions, not part of this
refactor.

## User Stories

1. As a contributor, I want catalog validation to complete quickly, so that manifest
   feedback does not dominate my local validation cycle.
2. As a contributor, I want the test harness to avoid repeated subprocess overhead,
   so that fixture coverage remains practical during normal development.
3. As a contributor, I want the full validation command to preserve all 32 suites,
   so that runtime improvements do not reduce production confidence.
4. As a contributor, I want suite order preserved, so that fail-fast reports the same
   cheapest and most general failure first.
5. As a contributor, I want every existing assertion preserved, so that an optimized
   validator accepts and rejects the same repository states.
6. As a contributor, I want every negative fixture preserved, so that malformed
   catalog states retain their regression coverage.
7. As a contributor, I want rejection reasons preserved, so that existing diagnostic
   expectations and developer guidance do not drift.
8. As a contributor, I want output and exit behavior preserved, so that recipes,
   harness code, and CI reporting need no interface migration.
9. As a maintainer, I want each manifest parsed once per validator invocation, so
   that rule evaluation shares a coherent in-memory representation.
10. As a maintainer, I want a holistic validator rather than a line-for-line shell
    translation, so that the implementation removes the measured subprocess cost.
11. As a maintainer, I want the shell entry point retained, so that callers remain
    insulated from the implementation language.
12. As a maintainer, I want deterministic rule evaluation, so that repeated runs
    fail at the same assertion for the same input.
13. As a maintainer, I want equivalence demonstrated at the validator boundary, so
    that performance claims are accompanied by behavior evidence.
14. As a maintainer, I want three-run medians, so that network and machine variance
    do not drive attribution from a single run.
15. As a maintainer, I want standalone validator measurements, so that implementation
    speedup is visible without harness overhead.
16. As a maintainer, I want complete harness measurements, so that repeated fixture
    behavior is measured at the consumer boundary.
17. As a maintainer, I want full sequential CI measurements, so that local wall-clock
    improvement is proven across the unchanged contract.
18. As a repository operator, I want missed targets reported honestly, so that
    validation is not weakened to produce a favorable number.
19. As a repository operator, I want remaining bottlenecks profiled, so that the next
    optimization targets measured cost.
20. As a repository operator, I want chart caching deferred when it cannot materially
    improve the harness, so that effort follows the largest recoverable wall time.
21. As a repository operator, I want final Helm render caching avoided unless output
    determinism is proven, so that charts generating fresh credentials are never
    served stale rendered content.
22. As a repository operator, I want application-validator parallelism proposed
    separately with measurements, so that log interleaving and deterministic
    fail-fast tradeoffs remain an explicit decision.
23. As a contributor, I want no change-aware suite skipping, so that every candidate
    production tree receives the complete validation contract.
24. As a contributor, I want no cluster-dependent checks added, so that full
    validation remains secret-free and reproducible outside the live cluster.
25. As a maintainer, I want comparable Talos/Flux GitOps repositories used as context,
    so that performance expectations are informed without copying weaker gates.

## Implementation Decisions

- Preserve all 32 full-validation suites, their current order, assertions, fixtures,
  rejection reasons, and fail-fast behavior.
- Do not introduce change-aware suite skipping or weaken any validation to meet a
  runtime target.
- Retain the catalog validator's current shell-facing command and treat it as the
  compatibility boundary.
- Implement catalog rule evaluation holistically in Python.
- Parse each YAML manifest once per validator invocation and reuse the resulting
  representation across rules.
- Evaluate rules in the established order and stop at the same first failure as the
  current implementation.
- Preserve standard output, standard error, exit codes, and rejection text relied on
  by the harness.
- Keep the test harness outside any fast staged-file path.
- Measure at least three runs before and after the refactor and report medians.
- Measure the standalone catalog validator independently from the harness and the
  full sequential validation command.
- Use comparable Talos/Flux GitOps repositories as contextual performance baselines,
  while retaining this repository's stronger validation contract.
- Treat a standalone catalog median of at most 2 seconds as the target and at most
  5 seconds as acceptable.
- Treat a test-harness median of at most 60 seconds as the target and at most
  90 seconds as acceptable.
- Treat a full sequential validation median of at most 180 seconds as initial success
  and at most 120 seconds as the stretch target.
- If a target is missed, profile and report the dominant remaining cost before
  proposing another optimization.
- Do not reorder suites. The current lint-to-app sequence is an intentional
  cheapest-and-most-general-first diagnostic order.
- Do not add per-application parallelism silently. It changes deterministic
  fail-fast ordering and log presentation and therefore requires a separate operator
  decision supported by measurements.
- Do not make final rendered Helm output cacheable without proving deterministic
  output. Some current charts generate fresh key material while rendering.
- Shared chart-download or render-input caching may be considered later only after
  the catalog refactor is measured and equivalence is demonstrated for each cached
  boundary.

## Testing Decisions

- Test external validator behavior rather than the internal Python data structures.
- Use the existing shell entry point as the highest compatibility seam.
- Run every existing positive and negative catalog fixture against the refactored
  implementation.
- Compare accepted inputs, rejected inputs, first rejection reason, output streams,
  and exit status with the pre-refactor behavior.
- Preserve and run the existing harness catalog and artifact-contract tests; they are
  the primary prior art for validator behavior.
- Run the complete test harness to verify that repeated fixture execution and report
  production remain unchanged.
- Run all 32 suites through the canonical full validation command to verify suite
  membership, order, fail-fast integration, and downstream application validators.
- Benchmark standalone catalog validation, the test harness, and full sequential
  validation independently across three runs in comparable conditions.
- Report every command run, whether it passed, the individual measurements, median,
  and any validation intentionally skipped with its reason.
- Profile the remaining bottleneck when any acceptable ceiling is exceeded. Do not
  substitute a speculative optimization for profiling evidence.

## Out of Scope

- Removing, weakening, reordering, or conditionally skipping validation suites.
- Changing the full validation command's public contract.
- Adding a fast-CI command or moving the test harness into staged-file feedback.
- Adding cluster-dependent checks, credentials, kubeconfig, or live service access.
- Parallelizing independent application validators.
- Caching nondeterministic final Helm output.
- Reworking all validation scripts into Python.
- Changing GitHub workflow authority, branch protections, hooks, or agent
  instructions; those belong to the separate CI-authority change.
- Combining this refactor with the CI-authority pull request.

## Further Notes

- Three baseline full runs measured approximately 300, 297, and 297 seconds.
- The test harness measured approximately 246 seconds median.
- Profiling attributed approximately 20.5 seconds to one catalog validation and
  approximately 153 seconds to its negative-fixture work, or about 173.5 seconds
  combined.
- One catalog-validator run launched approximately 3,839 `yq` subprocesses, and the
  harness invoked the validator 13 times.
- Helm-related suites combined measured approximately 23–26 seconds, so Helm chart
  caching cannot materially reduce the dominant harness cost.
- Millisecond per-suite wall-clock reporting was added and merged separately to
  support these measurements.
