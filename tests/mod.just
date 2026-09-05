set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

# Validate Chainsaw configuration/tests and test harness scripts without a cluster.
validate group="all":
    @scripts/test/validate-chainsaw.sh {{quote(group)}}

# Validate the canonical suite catalog and its dispatch safety invariants.
catalog-validate:
    @scripts/test/validate-catalog.sh

# Plan deterministic validation groups for an exact base and candidate head.
ci-plan base head output:
    @uv run --locked python scripts/test/ci_plan.py plan --base {{quote(base)}} \
      --head {{quote(head)}} --impact tests/impact.yaml --catalog tests/catalog.yaml \
      --output {{quote(output)}}

# Request the complete validation set for an exact base and candidate head.
ci-plan-full base head output:
    @uv run --locked python scripts/test/ci_plan.py plan --base {{quote(base)}} \
      --head {{quote(head)}} --impact tests/impact.yaml --catalog tests/catalog.yaml \
      --output {{quote(output)}} --full

# Run one selected CI group and bind its canonical result to the exact plan.
ci-group group plan:
    #!/usr/bin/env bash
    group={{quote(group)}}
    execution="ci-$group"
    [[ "$group" != ci-framework ]] || execution=ci-framework
    scripts/test/run-ci.sh --execution "$execution" --group "$group" \
      --plan {{quote(plan)}}

# Reconcile downloaded canonical CI runs against their required plan.
ci-reconcile plan results output:
    @uv run --locked python scripts/test/ci_reconcile.py \
      --plan {{quote(plan)}} --results {{quote(results)}} --output {{quote(output)}}

# Validate one canonical run directory by run ID.
result-validate run:
    @scripts/test/validate-run.sh ".test-results/{{run}}"

# Generate the static Allure Awesome report for one finalized canonical run.
report run:
    @scripts/test/generate-allure-report.sh {{quote(run)}}

# Generate the report whose finalized summary has the latest end timestamp.
report-latest:
    @scripts/test/generate-allure-report.sh latest

# Generate and serve one report locally until the operator presses Ctrl+C.
report-open run:
    @scripts/test/open-allure-report.sh {{quote(run)}}

# Guardedly publish one canonical run and its generated report to persistent
# in-cluster storage. Operator-only; requires the exact confirmation.
publish run:
    @scripts/test/publish-report.sh {{quote(run)}}

# Preview an ordered campaign and print its exact plan-bound confirmation.
campaign-plan campaign:
    @scripts/test/run-campaign.sh plan {{quote(campaign)}}

# Optionally preview the read-only worktree campaign. This mode never acquires the
# cluster test Lease or publishes reports.
scoped-campaign-plan:
    @scripts/test/run-campaign.sh scoped-plan scoped-verification

# Run the read-only worktree campaign and retain canonical results only on this host.
scoped-campaign:
    @scripts/test/run-campaign.sh scoped-run scoped-verification

# Run every explicit member of a campaign and publish each canonical child report.
# Operator-only; mutating campaigns share one renewable cluster-wide test Lease.
campaign campaign:
    @scripts/test/run-campaign.sh run {{quote(campaign)}}

# Resume only a campaign stopped by publication failure; completed suites are not rerun.
campaign-resume campaign_run:
    @scripts/test/run-campaign.sh resume {{quote(campaign_run)}}

# Render the latest canonical run as a GitHub-compatible Markdown summary.
summary-latest:
    @scripts/test/allure-markdown-summary.sh latest

# Run registered read-only smoke scenarios against the live cluster.
smoke target scenario="":
    @scripts/test/run-live-suite.sh smoke {{quote(target)}} {{quote(scenario)}}

# Run a registered state-changing integration against the live cluster.
integration target:
    @scripts/test/run-live-suite.sh integration {{quote(target)}}

# Run registered state-changing functional scenarios against the live cluster.
e2e target:
    @scripts/test/run-live-suite.sh e2e {{quote(target)}}

# Run a registered disruptive scenario after validating the exact confirmation.
# node is required only by the attended node-abrupt-loss scenario.
resilience target node='':
    @scripts/test/run-live-suite.sh resilience {{quote(target)}} {{quote(node)}}

# Collect allowlisted read-only diagnostics from the live cluster.
diagnostics target:
    @scripts/test/run-live-suite.sh diagnostics {{quote(target)}}

# Run a single registered read-only network/API probe interactively (a measurement
# primitive, not an assurance tier). Operator-run; needs the live cluster.
probe target:
    @scripts/test/run-probe.sh {{quote(target)}}
