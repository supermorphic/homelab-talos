# Operate test campaigns

Test campaigns run an ordered group of existing canonical test suites. Use them when one
suite is too narrow and you want a repeatable assurance pass across several parts of the
cluster.

This guide explains how to choose, plan, run, publish, and resume campaigns. Repository
policy in [`AGENTS.md`](../../AGENTS.md), executable membership in
[`tests/catalog.yaml`](../../tests/catalog.yaml), and the campaign scripts remain
authoritative.

## Mental model

```text
individual canonical suite
        ↓
canonical local run and report
        ↓
campaign coordinator
  ├─ freezes an ordered member list and source revision
  ├─ acquires the shared test Lease for published campaigns
  ├─ runs each existing suite
  ├─ validates each canonical result
  ├─ publishes each child report
  └─ records progress in a local journal
        ↓
retained Allure child reports
```

A campaign is an orchestrator, not a second aggregate test result. Each child suite keeps
its own canonical run and remains the authoritative retained report. The campaign journal
records orchestration state only.

## Choose an execution mode

| Mode | Cluster access | Publication | Use it for |
| --- | --- | --- | --- |
| `mise exec -- just ci` | None | None | Required pull-request and source validation |
| Standalone suite | Depends on the suite | Manual, when wanted | Focused investigation or one assurance target |
| Scoped campaign | Worktree-local observer/diagnostic credentials | None | Agent-autonomous, read-oriented live verification |
| Published campaign | Operator cluster access | Automatic for each child | Ordered retained assurance across several suites |

`mise exec -- just ...` is the repository execution interface. It does not determine who
has authority to run a workflow. Authority comes from `AGENTS.md`, the catalog's execution
metadata, and the effects of the command.

## Recommended assurance cadence

These are operator recommendations. The repository does not schedule nightly, weekly, or
monthly campaigns by itself.

| When | Choice | Coverage |
| --- | --- | --- |
| Every pull request | `mise exec -- just ci` | Required cluster-independent validation; no publication |
| Routine periodic assurance | `standard` | Validation, smoke, qbit_manage E2E, and quick conformance |
| Broader periodic assurance | `weekly` | `standard` plus live verification, integration, probes, and resilience |
| Deep or upgrade assurance | `full` | `weekly` plus certified Kubernetes conformance |

Use `full` before or after changes to Kubernetes, Talos, Cilium, storage, networking, or
cluster topology when the deeper cost is justified. Diagnostics and the intentionally
failing diagnostics self-test are troubleshooting tools, not assurance members.

For focused investigation, use the relevant focused campaign or standalone suite instead
of automatically running `full`. Do not rely on a manually maintained guide inventory.
List the current campaign names from the authoritative catalog:

```bash
mise exec -- yq -r '.campaigns | keys | .[]' tests/catalog.yaml
```

Then inspect one campaign's exact ordered membership with `campaign-plan`.

## Command effects and authority

| Command | What it does | Effect and authority |
| --- | --- | --- |
| `mise exec -- just test scoped-campaign-plan` | Optionally previews the current scoped-verification inputs and membership | Read-only; agent-autonomous |
| `mise exec -- just test scoped-campaign` | Runs approved scoped verifiers and retains results locally | Read-oriented live campaign; agent-autonomous with worktree-scoped credentials |
| `mise exec -- just test campaign-plan <name>` | Resolves source, ordered membership, plan digest, effects, and the required confirmation | Read-only operator preflight |
| `mise exec -- just test campaign <name>` | Holds the shared test Lease, runs children, publishes each report, and journals progress | Operator-run live and publication workflow |
| `mise exec -- just test campaign-resume <id>` | Continues only a campaign stopped by supported publication failure | Operator-run controlled resume |
| `mise exec -- just kube conformance` | Runs standalone quick Sonobuoy conformance | Operator-run state-changing suite; no automatic publication |
| `mise exec -- just test publish <run-id>` | Publishes one finalized canonical run | Operator-run report-state mutation |

Published campaigns are operator-run because they acquire a live cluster-wide test Lease,
publish retained evidence through the cluster, and can contain state-changing or disruptive
children. Scoped verification is different: repository policy permits an agent to mint
worktree-scoped credentials and run that approved local-only campaign without operator
intervention.

## Run scoped verification

Scoped verification is the normal grouped live check for an agent working in a linked
worktree. First mint credentials on demand as described in
[Agent cluster access](agent-cluster-access.md), then run it directly:

```bash
mise exec -- just test scoped-campaign
```

The run performs scoped preflight, freezes and displays its source revision, plan digest,
effects, and ordered members, and then starts the first verifier. The separate plan is an
optional read-only preview of the same inputs:

```bash
mise exec -- just test scoped-campaign-plan
```

No confirmation is required because the scoped workflow is authorized, observational,
and local-only. This mode retains canonical child runs on the local host. It does not
acquire the shared campaign Lease, query `origin/main` or the Flux source revision,
publish reports, or create a resumable published-campaign journal. Observer is the
default identity. Approved
verifiers that need their narrow `exec` or `port-forward` capability explicitly select
`homelab-diagnostic`.

## Plan a published campaign

Run a published campaign from a clean checkout whose `HEAD` is exactly current
`origin/main`, after Flux has reconciled that same commit. Preview the campaign first:

```bash
mise exec -- just test campaign-plan standard
```

The plan shows:

- the exact ordered child suites;
- local source and Flux source revisions;
- the resolved campaign digest;
- whether any member mutates or disrupts the cluster; and
- the exact confirmation required to run it.

Planning does not run a suite, acquire a Lease, publish a report, create a journal, or
authorize execution. Review the plan before deciding whether to run it.

### Understand the confirmation

Every new published campaign confirmation binds the campaign name, current source SHA,
and resolved plan digest:

```bash
TEST_CAMPAIGN_CONFIRM='run-publish:standard:<source-sha12>:<plan-digest>' \
  mise exec -- just test campaign standard
```

Always copy the exact command printed by the plan rather than reconstructing it:

```bash
mise exec -- just test campaign-plan weekly
# Review the ordered disruptions, then use the exact printed command.
```

The confirmation proves deliberate intent to execute the displayed frozen plan. It does
not grant operator authority. The coordinator resolves the Plex node and IP immediately
before the reboot. An earlier
cross-node resilience scenario may legitimately move Plex, so an earlier target could be
stale. The campaign confirmation authorizes the reviewed sequence; the reboot primitive
still requires its separate exact-node `TALOS_REBOOT_CONFIRM` guard.

## Run and publish a campaign

The coordinator follows this sequence:

```text
freeze membership and source
        ↓
validate the exact plan-bound confirmation
        ↓
acquire the campaign test Lease
        ↓
run and validate one canonical child
        ↓
recheck Lease and source authority
        ↓
publish the child report
        ↓
journal progress and repeat
```

Campaign membership and composition are explicit contracts in `tests/catalog.yaml`.
Catalog validation fails when a new assurance suite lacks reviewed campaign coverage.
Aggregate entry points avoid rerunning child scenarios that they already cover.

The coordinator requires clean local `HEAD`, remote `origin/main`, and the Flux artifact to
identify the same commit. It freezes the member list and source digest, then writes an
ignored local journal at:

```text
.test-campaigns/<campaign-run-id>/campaign.json
```

Each child must return its canonical run ID through the runner contract. The coordinator
validates that result and its suite identity instead of parsing console prose. After a
child finishes and cleanup or recovery is safe, it rechecks source authority before
publishing.

The terminal summary lists every child suite, result, publication state, and Allure URL.
See [Persistent test reports](../reference/test-reports.md) for archive retention, stable
URLs, and observability.

## What the Leases protect

Published campaigns hold `flux-system/homelab-test-run-lock` for the complete ordered
sequence. This prevents other Lease-aware state-changing tests from independently mutating
or measuring the same cluster during the campaign window. Mutating children join the
campaign holder and do not release the Lease themselves. The Lease does not block arbitrary
read commands or workflows that ignore the repository coordination contract.

Report publication separately uses
`flux-system/homelab-test-report-publish-lock`. That Lease serializes writes to the retained
report archive. The scoped local campaign uses neither Lease because it is read-oriented
and does not publish.

## Run a standalone suite

Use a standalone suite when one focused result is sufficient or when you want to review a
canonical run before deciding whether to publish it.

Quick Sonobuoy conformance:

```bash
mise exec -- just kube conformance
```

Certified conformance:

```bash
MODE=certified mise exec -- just kube conformance
```

Both are operator-run state-changing suites. Each acquires the shared test Lease for its
own run and leaves its canonical report local. Publish a finalized result separately only
when retained evidence is wanted:

```bash
TEST_REPORT_PUBLISH_CONFIRM='publish:test-report:<run-id>' \
  mise exec -- just test publish <run-id>
```

Standalone publication can retain a candidate or historical run according to the report
publisher's rules. Campaign publication is stricter: it requires the frozen revision to
remain authoritative current `main`.

## Understand results and campaign stops

The canonical result states have different meanings:

- `passed` means the suite completed with positive evidence.
- `failed` means the suite completed and produced trustworthy negative assertion evidence.
- `broken` means execution, infrastructure, result integrity, cleanup, or recovery did not
  provide a trustworthy semantic verdict.

A valid `failed` child is still useful evidence. The coordinator publishes it and may
continue to later independent suites when cleanup and recovery are safe. A `broken` child
is published when its canonical result is valid, then the campaign stops.

Use this response model:

```text
child assertion fails, cleanup and recovery safe
→ publish trustworthy negative evidence
→ continue when later suites remain safe

canonical output invalid, Lease lost, cleanup uncertain, or child broken
→ stop the campaign

publication fails after bounded retries
→ preserve the journal
→ resume with the exact printed command

source or Flux revision drifts
→ allow safe child cleanup
→ do not publish stale campaign evidence
→ start a new campaign against deployed main
```

Validation is an early gate: a validation failure stops a composed campaign. Smoke failures
can be collected, but they prevent later state-changing stages. Cheap foundational evidence
runs before mutation or disruption so an unhealthy confidence gate stops riskier work.

## Resume a publication failure

Only a campaign whose journal status is `publish-failed` can resume. The stopped run prints
the exact command:

```bash
TEST_CAMPAIGN_CONFIRM='resume-publish:<campaign-run-id>' \
  mise exec -- just test campaign-resume <campaign-run-id>
```

Resume reacquires the campaign Lease and requires the catalog digest, local source,
`origin/main`, and Flux source to still match the frozen plan. It republishes finalized
unpublished children, then continues unstarted members without rerunning completed suites.

Do not use resume after source drift, unsafe cleanup or recovery, a broken child, or a lost
Lease. Start a new campaign after the underlying condition is resolved. Scoped local
campaigns do not publish and cannot resume.

## Safety rules

- Use the exact plan-produced command for every published campaign.
- Do not manually reconstruct a source- and digest-bound confirmation.
- Do not bypass either cluster Lease.
- Do not publish campaign evidence after source authority drifts.
- Do not resume a campaign stopped for unsafe cleanup, broken execution, or source drift.
- Prefer a standalone suite when focused evidence is sufficient.
- Agents may run approved scoped verification, but published campaigns, standalone
  state-changing suites, report publication, and resilience disruptions remain operator
  workflows under current repository policy.

## Authoritative implementation sources

- [`tests/catalog.yaml`](../../tests/catalog.yaml) — campaign membership, order, effects,
  execution ownership, and suite commands.
- [`tests/mod.just`](../../tests/mod.just) — public campaign and report recipes.
- [`scripts/test/run-campaign.sh`](../../scripts/test/run-campaign.sh) — planning,
  execution, publication, journaling, source checks, and resume behavior.
- [`scripts/lib/lease.sh`](../../scripts/lib/lease.sh) — shared disruption Lease.
- [`scripts/test/publish-report.sh`](../../scripts/test/publish-report.sh) — retained
  report publication and publication Lease.
- [Persistent test reports](../reference/test-reports.md) — report archive authority and
  retention.
