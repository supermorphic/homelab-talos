# Test Reporting Standard

## Purpose

Define one assurance and evidence contract for repository validation, live acceptance,
integration, disruption, measurement, and Kubernetes conformance. The standard keeps the
framework appropriate to each behavior while giving every coordinated run stable
identity, result semantics, canonical evidence, and clear execution authority.

This specification preserves the design rationale. The current catalog, executable
source, test-report reference, campaign guide, and repository policy remain authoritative.

## Problem and design choice

Before this standard, result formats varied by runner, CI did not retain a complete
canonical artifact, shell constructs could hide failures under `set -e`, ShellCheck did
not cover every executed script, some commands called `verify` changed the cluster, and
a checkout-local lock could not serialize two worktrees. Chainsaw wrappers also hid
meaningful assertion and recovery phases for workflows better expressed directly in
Bash or Python.

One universal test framework was rejected. Framework uniformity would have made the
hard cases less observable without making their evidence more comparable. The chosen
design standardizes identity, metadata, JUnit, lifecycle classification, dispatch,
serialization, and publication while selecting the runner by behavior.

## Assurance classes

The suite class describes what a result proves:

| Class | Contract |
| --- | --- |
| Offline validation | Cluster-independent source, render, schema, policy, lint, and unit checks. |
| Verification | Read-oriented live acceptance with no declared persistent or test-state mutation, using an explicit observer, diagnostic, or operator access tier. |
| Smoke | Routine read-only resource readiness and basic application health. |
| Integration | A focused contract across components or storage/network boundaries; it may create run-owned state. |
| End to end | A complete controlled user or system workflow with functional assertions. |
| Resilience | Deliberate disruption followed by separately recorded recovery and cleanup. |
| Measurement | A probe that captures and analyzes a property without treating the measurement primitive as an assurance tier. |
| Conformance | Upstream Kubernetes behavior exercised by ephemeral Sonobuoy runs. |
| Diagnostics | Troubleshooting evidence and harness self-tests; not an assurance campaign result. |

Always-on Gatus checks and Prometheus alerts provide current observability. They do not
replace controlled run history or become canonical test results.

## CI boundary

`mise exec -- just ci` is the pull-request gate. It is fail-fast,
cluster-independent, and secret-free. It validates repository policy, Talos sources,
Kubernetes renders and schemas, Rego policies, shell and Python tooling, the test
catalog, and component-specific source invariants without a usable kubeconfig or SOPS
age key.

GitHub Actions runs this same command and uploads canonical results on success or
failure. It has no cluster or report-publication path. Live verification, tests,
probes, resilience, and conformance therefore cannot enter the CI execution list even
when their runners are stored and validated by CI.

CI is one canonical multi-suite run. Native JUnit is preserved where a tool supplies it;
adapters retain individual ShellCheck and Python test findings; Bash-only commands
receive explicit wrapper cases. After the first failed or broken suite, the remaining CI
suites are represented as skipped rather than silently omitted.

## Catalog contract

[`tests/catalog.yaml`](../../tests/catalog.yaml) is the machine-validated inventory and
dispatch contract. Each runnable suite has a stable ID and declares:

- source, framework, suite, tier, target, optional scenario, scope, and intent;
- whether it mutates the cluster and whether execution is shared or human-owned;
- a literal `mise exec -- just ...` runner and its existing implementation source;
- confirmation type and, for exact confirmation, the variable and expected shape;
- native-result strategy; and
- dispatch information and verifier access tier where applicable.

The validator rejects duplicate identities or dispatch tuples, unknown values, unsafe or
missing runners, ambiguous campaign membership, unregistered live targets, mutating
suites without confirmation, and scoped verifiers whose commands exceed their declared
credential tier. The scoped-verification campaign's required resource reads are also
compared with the deployed observer RBAC and the negative authorization matrix. This
keeps the catalog, runner behavior, and actual credentials aligned.

Adding a suite does not automatically place it in a campaign. Campaign coverage is an
explicit review decision, and catalog validation fails when a class that requires full
coverage is not represented correctly.

`execution_owner` records who owns normal interactive execution and the base runner's
guard contract. It is not a complete statement of credential capability or task-scoped
agent authorization. Current repository policy authorizes an agent to mint worktree-
local observer, diagnostic, and Talos reader credentials and run the registered
`scoped-verification` campaign for an approved task even though its member entries retain
`execution_owner: human`. That bounded authorization does not grant the agent mutation,
disruptive execution, persistent publication, or administrative credentials.

## Framework and dispatch ownership

The framework follows the behavior under test:

- Conftest and Kubeconform own policy and schema checks over source or rendered objects.
- Chainsaw owns declarative Kubernetes lifecycle scenarios when its step, catch, and
  finally model provides useful resource control.
- Focused Bash and Python runners remain valid for filesystems, APIs, Talos operations,
  probes, and structured temporal workflows.
- Sonobuoy runs only on demand, retrieves the selected E2E result, and is removed after
  the run. It is never a standing or scheduled in-cluster workload.

Live dispatch accepts only catalog-registered target and scenario combinations and
fails closed on unknown input. Test-created resources carry run identity and cleanup is
limited to that owned state.

## Confirmation, access, and serialization

Every cataloged mutating suite declares either an exact environment-variable guard or a
command-level confirmation supplied by its guarded runner. Exact values bind the action
to its intended target; disruptive campaign confirmations additionally bind the source
revision and resolved campaign plan. Canonical metadata records only the confirmation
variable name, never the confirmation value.

Smoke and verification suites whose catalog metadata declares no cluster mutation may
run concurrently. This metadata describes the designed suite effect; it does not make
the diagnostic credential a read-only API identity. Approved diagnostic verifiers may
use their narrow pod subresource capabilities without declaring test-state mutation.
State-changing integration, end-to-end, resilience, mutating probe, and conformance
suites use a renewable Kubernetes Lease. A campaign holds the Lease for its complete
ordered sequence, and mutating child runners join that holder rather than acquiring or
releasing competing leases.

Observer and diagnostic credentials are limited to registered verifiers whose catalog
access tier matches their command behavior. Scoped agent execution, catalog ownership,
exact action confirmation, Kubernetes RBAC, and publication authority are independent
controls. A capability in one layer does not imply authority in another.

## Canonical evidence bundle

Every coordinated run writes a collision-resistant directory:

```text
.test-results/<run-id>/
├── junit.xml
├── summary.json
├── environment.json
├── evidence.json
├── logs/
└── diagnostics/
```

Nothing else is allowed at the run root. The four root documents are the canonical
interface:

- `junit.xml` contains non-vacuous canonical cases, including lifecycle cases.
- `summary.json` records stable catalog dimensions, timestamps, result, JUnit counts,
  source revision, and independent phase outcomes.
- `environment.json` records execution origin, clean or dirty Git state, host and pinned
  tool context, available cluster context, and the confirmation variable name.
- `evidence.json` allowlists every regular file under `logs/` and `diagnostics/` by a
  sanitized relative path.

Native evidence, structured phase records, generated non-secret manifests, and timelines
live below `diagnostics/`. Symlinks, unsafe relative paths, unindexed evidence, unexpected
root entries, malformed metadata, and a finalized zero-case JUnit report invalidate the
bundle. Sensitive raw conformance archives never enter canonical results or Allure;
failed-run archives that are useful for diagnosis stay in the ignored private-results
area.

## Result and phase semantics

Result classification separates an assertion from the machinery around it:

- `passed` means canonical assertions passed and required finalization phases succeeded.
- `failed` means the behavior under test violated an assertion.
- `broken` means the harness, infrastructure, native JUnit, external dependency,
  diagnostics, cleanup, or other required finalization step could not provide a valid
  test conclusion.
- `skipped` means a case was deliberately excluded, not applicable, or not executed
  after fail-fast stopped the parent run.

The primary assertion, external dependency, cleanup, recovery, diagnostics, and
finalization outcomes remain distinct. Successful cleanup cannot overwrite a failed
experiment, and a failed cleanup or diagnostic collection cannot turn the experiment
into a pass. Recovery is recorded independently because restoring the system is an
operational obligation even when the original resilience assertion already failed.

## Allure and persistent publication

Allure generates static reports from canonical JUnit plus only the evidence paths named
by `evidence.json`. Native diagnostic JUnit is not ingested a second time. Local report
generation is available for any valid run, but persistent publication is an explicitly
guarded operator workstation push.

Allure was selected as a presentation layer because it can consume generic JUnit and
generate static output. Canonical JUnit and the four root metadata documents remain the
durable evidence interface, so the human report can be regenerated without introducing
a report database, stateful reporting API, or second result schema; Caddy serves only
the resulting inert files.

The in-cluster report service is a static Caddy server. It has no upload API,
credentials, ServiceAccount token, or Kubernetes RBAC. A workstation publisher:

1. validates the canonical run and catalog metadata;
2. generates the static report;
3. scans the exact canonical input and output bundle for secrets;
4. rejects unsafe paths, symlinks, unexpected content, oversize output, or checksum
   mismatches;
5. builds a deterministic checksummed archive; and
6. streams it through a guarded pod execution while holding a dedicated publication
   Lease.

This static push model was chosen over an upload API or CI-to-cluster bridge so the
report service does not become an authenticated write endpoint and CI does not gain a
cluster credential.

The server installs exact run paths and switches the active generation atomically. Its
checksum manifest uses byte ordering of complete relative paths on both the publisher
and installer, so archive integrity checks do not depend on host locale or programming
language path-ordering conventions.

The server's retained Longhorn `ReadWriteOnce` claim is mounted by a one-replica `Recreate`
Deployment, and Flux prune protection prevents Kustomization removal from implicitly
authorizing archive deletion.

A run is authoritative only when it is finalized from a clean checkout and its Git
commit equals both current `origin/main` and the deployed Flux artifact revision.
Historical or feature-commit runs may be retained as candidates, but they do not update
stable latest links, Homepage summaries, or last-run metrics. Candidate publications do
contribute to the lifetime published-run and test-case counters. Republishing the same
run and digest is idempotent; reusing an ID with different content is rejected.

Retention uses both age and count limits: ordinary entries remain only when they are
within 90 days and among the newest 200. The newest run for each logical key and the
newest authoritative run for each key remain protected so pruning cannot erase the only
current comparison point. Publication state keeps monotonic lifetime counters even when
individual report artifacts age out.

Presentation deliberately separates exact-run evidence from operational summaries.
Homepage exposes only a small set of latest authoritative categories, while Grafana uses
low-cardinality rollups keyed by stable dimensions such as tier, target, and scenario.
Run IDs, Git SHAs, node identities, and report URLs stay out of Prometheus labels; stable
links lead from the summaries to the exact canonical report when detail is needed.

## Campaign model

Catalog campaigns provide ordered execution and automatic publication without replacing
the child run as the unit of evidence.

- Focused campaigns select validation, verification, smoke, integration, end-to-end,
  resilience, probes, or one conformance mode.
- `standard` composes validation, non-duplicated smoke entrypoints, end-to-end workflows,
  and quick conformance.
- `weekly` adds live verification, integration, probes, and resilience.
- `full` adds certified Kubernetes conformance and represents every implemented assurance
  suite. Diagnostics and intentional harness failures remain excluded.
- `scoped-verification` is local-only and runs the observer/diagnostic-compatible live
  checks without publication authority.

Before execution, a campaign freezes its ordered member list, source revision, deployed
Flux revision, and plan digest. It requires a clean current `origin/main` checkout and a
matching Flux artifact for operator-published mode. Every child emits and validates its
own canonical run, and the coordinator records that run and its publication result in an
ignored local journal.

Ordinary assertion failures can be published and do not prevent later independent suites
when cleanup and recovery are safe. Validation is an exception: a validation failure
stops a composed campaign. Smoke failures are collected, but they prevent all later
state-changing stages. Invalid canonical output, a broken child, lost Lease, failed or
unclassified cleanup or recovery, bounded publication failure, or source drift also stops
the campaign. Only publication failure is resumable; source drift requires a new campaign
against the newly deployed revision.

The failure rules deliberately preserve evidence from a valid failed assertion. Such a
run may be published and the campaign may continue when cleanup and recovery are safe.
Broken or invalid evidence, Lease loss, unsafe cleanup or recovery, source drift, and
publication uncertainty stop the coordinator because later results would no longer have
a trustworthy execution boundary. Only a `publish-failed` journal is resumable. Resume
validates the frozen catalog and source authority, reacquires the campaign Lease,
publishes pending finalized children, skips completed suites, and continues unstarted
members. No other stop reason is resumable, and any catalog, source, or deployed Flux
drift requires a new campaign.

## Implementation discoveries

- Shell `!` around a command under `set -e` can invert status in a way that loses the
  original exit code. Coordinators now capture command status explicitly.
- Bash 5 behavior is part of the harness contract, and Python is the sole owner of XML
  construction and merging. This avoids platform-shell variation and hand-built JUnit.
- Direct runners replaced script-only Chainsaw cases where filesystem state, an API, or
  a temporal recovery controller was the real subject. Chainsaw remains valuable when
  Kubernetes resources and lifecycle steps are the natural model.
- A renewable, resourceVersion-guarded Kubernetes Lease replaced the local lock.
  Renewal failure and holder mismatch are result-invalidating events, and campaign
  children join rather than compete with the campaign holder.
- Raw Sonobuoy archives can contain sensitive diagnostic data. The canonical bundle
  retains validated summaries and allowlisted evidence, not the raw archive.
- Runtime report-service configuration is content-addressed so deployment changes are
  visible to Flux. The Caddy image startup still needs the narrowly bound
  `NET_BIND_SERVICE` capability even though the configured listener is unprivileged; it
  receives no ServiceAccount token or Kubernetes API authority.

### Publication debrief — September 2026

Publishing an automation-data acceptance report exposed a mismatch between Python's
path-component ordering and the installer's full-filename ordering. Valid report assets
could therefore fail manifest verification. Both sides now use the same byte ordering.
Offline validation reproduced the rejection and confirmed successful installation after
the correction; checksum rejection and atomic publication remain intact. Live publication
of the corrected revision was confirmed with automation-data recovery run
`20260906T103531Z-bfd6c1b6793c-operator-1efda0f5`.

## Deferred assurance coverage

The implemented catalog does not yet provide a controlled media-pipeline end-to-end
scenario, isolated Longhorn restore and replica-recovery scenarios, or an isolated SMB
remount and recovery scenario. These remain deliberate gaps: each needs run-owned test
state and cleanup that cannot affect production application data. Current membership,
dispatch, and any future execution procedure belong in the catalog and campaign guide.

## Reconsideration boundaries

A new test framework is justified only when an implemented behavior cannot be expressed
clearly by the current tools and the new framework can still emit the canonical
contract. Giving CI cluster credentials, adding an upload service, or moving publication
into the cluster would create a new trust and authentication surface and requires a
separate design. Load, performance, and soak campaigns should be added only after their
service objectives and failure thresholds are defined. Campaign resume must remain
limited to a frozen campaign whose only stop was publication failure and whose catalog,
source, and deployed authority are unchanged.

## Consequences

Console output and framework-native behavior remain useful to an operator, while every
suite also produces comparable machine-readable evidence. CI stays reproducible and
without cluster credentials. Live mutation remains explicit, serialized, and owned.
Persistent dashboards summarize authoritative runs without becoming the evidence store
or weakening the exact-run audit trail.
