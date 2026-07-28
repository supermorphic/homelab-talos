# Test campaigns

Test campaigns are the operator-facing way to run an ordered group of canonical
test suites and publish every child report to the retained Allure archive. They
remove the manual loop of running a suite, copying its run ID, and invoking
`just test publish` for each result.

Campaigns are intentionally local and operator-run. GitHub Actions runs only
`just ci`; it has no cluster credentials and cannot publish to
`tests.lab.supermorphic.com`.

## Recommended cadence

| Cadence | Command | Coverage |
| --- | --- | --- |
| Every commit and PR | `mise exec -- just ci` | Cluster-independent validation; this remains the required GitHub status check and does not publish to the cluster archive |
| Nightly | `standard` campaign | Validation, non-duplicated smoke coverage, qbit-manage E2E, and Sonobuoy quick conformance |
| Weekly | `weekly` campaign | The nightly contract plus all live verifications, integrations, probes, and disruptive resilience scenarios |
| Full | `full` campaign | Every weekly suite plus certified Kubernetes conformance; run monthly and before or after Kubernetes, Talos, Cilium, storage, networking, or topology upgrades |

`full` is the repository's complete implemented test suite. Diagnostics and the
intentionally failing `chainsaw.smoke.cluster.diagnostics-self-test` are
troubleshooting or harness tools rather than assurance suites, so they are not
part of `full`.

## Running a campaign

Run from a clean checkout whose `HEAD` is exactly the current remote
`origin/main`, after Flux has reconciled that same commit. Preview the campaign:

```bash
mise exec -- just test campaign-plan standard
```

For non-disruptive campaign compositions, use the stable confirmation printed
by the plan:

```bash
TEST_CAMPAIGN_CONFIRM=run-publish:standard \
  mise exec -- just test campaign standard
```

Available focused campaigns are:

- `validation`
- `verification`
- `smoke`
- `integration`
- `e2e`
- `resilience`
- `probes`
- `conformance-quick`
- `conformance-certified`
- `standard`
- `weekly`
- `full`

To run and publish only quick Sonobuoy rather than the complete `standard`
campaign:

```bash
mise exec -- just test campaign-plan conformance-quick
TEST_CAMPAIGN_CONFIRM=run-publish:conformance-quick \
  mise exec -- just test campaign conformance-quick
```

For a standalone quick run without automatic publication, use:

```bash
mise exec -- just kube conformance
```

Its final output prints the canonical run ID. To publish only that result
afterward:

```bash
TEST_REPORT_PUBLISH_CONFIRM=publish:test-report:<run-id> \
  mise exec -- just test publish <run-id>
```

`resilience`, `weekly`, and `full` include the Plex node-reboot scenario. Their
confirmation contains the current source SHA and resolved campaign digest, so
always copy the exact command printed by `campaign-plan` rather than constructing
it manually:

```bash
mise exec -- just test campaign-plan weekly
# Review the ordered disruptions, then run the exact printed command.
```

The runner derives the exact Plex node and IP immediately before the reboot
scenario and supplies the existing `TALOS_REBOOT_CONFIRM` guard. This late
resolution is required because the earlier Plex cross-node resilience scenario
can legitimately change Plex placement. The campaign-level confirmation
authorizes the reviewed, source-pinned sequence; the reboot primitive remains
exact-node guarded.

## Execution and publication behavior

Campaign membership is an explicit, ordered contract in `tests/catalog.yaml`.
Adding a suite to the catalog does not make it run automatically: catalog
validation fails until its campaign coverage is reviewed and updated. Aggregate
smoke entrypoints are used instead of rerunning their covered leaf scenarios.

At runtime the coordinator:

1. Freezes the resolved member list and source digest.
2. Requires clean local `HEAD`, remote `origin/main`, and the Flux artifact to
   identify the same commit.
3. Holds the cluster-wide test Lease for the complete campaign. Mutating child
   runners verify and join that Lease without releasing it.
4. Runs each existing guarded suite through its catalog command.
5. Captures and validates the canonical child run without parsing console text.
6. Rechecks source authority and automatically publishes the child report.
7. Records the result, publication status, and URL in a local campaign journal.

Canonical child reports remain the authoritative reporting unit for retention,
Homepage, Grafana, stable links, and diagnosis. A campaign does not create a
second aggregate Allure run. Its ignored local journal is written to:

```text
.test-campaigns/<campaign-run-id>/campaign.json
```

The terminal summary lists every child suite, canonical run result, publication
state, and Allure URL.

## Failures, drift, and resume

Valid finalized `passed`, `failed`, and `broken` runs are published while their
Git revision remains authoritative. Ordinary assertion failures do not prevent
later independent suites from producing evidence when cleanup and recovery are
safe.

The coordinator stops when:

- canonical output is missing or invalid;
- the campaign Lease is lost;
- cleanup or recovery is failed or unclassified;
- a child is `broken`;
- publication fails after bounded retries; or
- `origin/main` or the Flux artifact moves away from the frozen source revision.

Validation is a gate. In composed campaigns, validation failures stop the
campaign; smoke failures are collected but prevent the later state-changing
stages. Source drift allows an active child to finish its cleanup but prevents
that stale child from being published.

Only publication failures are resumable. The failed command prints the exact
resume invocation:

```bash
TEST_CAMPAIGN_CONFIRM=resume-publish:<campaign-run-id> \
  mise exec -- just test campaign-resume <campaign-run-id>
```

Resume republishes finalized unpublished children, then continues unstarted
members without rerunning completed suites. A campaign stopped by source drift
must be restarted from the new deployed `main`.

## Safety boundary

Campaign recipes are operator-only. Agents may implement, validate, and document
them, but do not run live campaigns, publish evidence, or execute resilience
disruptions. Existing standalone suite confirmations remain unchanged; the
campaign confirmation delegates only the confirmations belonging to its
source-reviewed member list.

See [Persistent test reports](test-reports.md) for archive authority, retention,
URLs, and observability.
