<!-- FOR AI AGENTS - Human readability is a side effect, not a goal -->
<!-- Managed by agent: hand-maintained; keep sections and order, edit content -->
<!-- Last updated: 2026-07-31 -->

# Test assets

Scope: `tests/`. The root `AGENTS.md` safety, approval, and merge boundaries still
apply — this file adds the layer taxonomy and registration step, not exceptions.

## Overview

Pick the layer first; the directory follows from it.

| Layer | Directory | Cluster? | What it is for |
|-------|-----------|----------|----------------|
| Policy unit | `policy/` | No | Rego rules + `_test.rego` over repo sources |
| Prometheus rules | `prometheus/` | No | `promtool` unit tests for alerting rules; invoked by the matching `scripts/validate/*.sh`, which extracts the rule from its `PrometheusRule` first |
| Smoke | `chainsaw/smoke/` | Yes | Is the thing up and serving — `cluster/`, `platform/`, `media/` |
| Resilience | `chainsaw/resilience/` | Yes | Kill something, assert recovery |
| Probes | `probes/` | Yes | Long-running or sampling checks (VPN leak sentinel, DNS) |

`fixtures/` holds inputs for the harness itself, `config/` the runner configs
(`chainsaw.yaml`, `allurerc.yaml`). Background on the layering, including what is
deliberately not tested, is in `docs/testing-layers.md` — read it rather than
re-deriving the boundaries.

## Prerequisites

`catalog.yaml` (`schema_version: 2`) is authoritative for dispatch. A test file on
disk that is not in the catalog is dead weight — nothing runs it. Adding a test is
two steps: write it, then register it.

## Commands

| Task | Command |
|------|---------|
| Validate harness + test sources | `mise exec -- just test validate` |
| Validate the catalog itself | `mise exec -- just test catalog-validate` |
| Full PR gate | `mise exec -- just ci` |
| Inspect the last run | `mise exec -- just test report-latest` |
| Summarise the last run | `mise exec -- just test summary-latest` |

Cluster-dependent layers do not run in `just ci`; they are dispatched by campaign
and are operator-run.

## Conventions

A catalog entry is one list item under `suites:` with four keys:

- `metadata` — `id` is dotted and starts with the `source`, widening left to
  right: `validation.kubeconform`, `chainsaw.smoke.media.qbittorrent`.
  `tier: offline` means no cluster. `mutates_cluster` must be honest; it gates
  where the suite may run.
- `confirmation` — `{type: none, ...}` unless the suite mutates the cluster.
- `runner` — the exact `mise exec -- just …` command plus the `implementation`
  file backing it.
- `native_results` — `native-junit` if the tool emits JUnit, `wrapper-junit` if
  the coordinator must synthesise a case, `aggregate` for `validation.ci` itself.

Then add the `id` to the relevant list under `executions:` (`ci`) or `campaigns:`
(`validation`, `verification`, `smoke`, `integration`, `resilience`, `probes`,
`standard`, `weekly`, `full`, `conformance-*`).

## Patterns to Follow

- Catalog entry: `validation.kubeconform` — minimal offline suite with native
  JUnit.
- Chainsaw case: `chainsaw/resilience/qbittorrent-vpn-disconnect/` — disrupt,
  then assert recovery rather than asserting steady state.
- Probe: `probes/qbittorrent/probe.sh` with its paired `probe-test.sh`; probes get
  their own tests because they run unattended.
- Rego: every `*.rego` has a sibling `*_test.rego`.

## Security

- Tests read cluster state; they must never print secret values into JUnit or
  Allure output, which is published to the test-reports app.
- No plaintext credentials in fixtures. Use the SOPS-encrypted sources.
- A test that mutates the cluster must declare `mutates_cluster: true` and carry a
  `confirmation` block — misdeclaring it is how an agent-run suite ends up
  changing production.

## Checklist

- [ ] Test placed in the layer directory matching its cluster dependency
- [ ] Registered in `catalog.yaml` under `suites:` **and** an `executions`/`campaigns` list
- [ ] `mutates_cluster` and `tier` accurate
- [ ] Rego and probe additions have a paired test file
- [ ] `mise exec -- just test catalog-validate` and `mise exec -- just ci` pass

## Troubleshooting

- **New test never runs** — not in the catalog, or in `suites:` but not in any
  execution or campaign list.
- **`just ci` suddenly needs a cluster** — an entry with `tier` other than
  `offline` was added to `executions.ci`.
- **Missing suite in the report** — check `native_results.strategy`; a tool
  without native JUnit needs `wrapper-junit`.
