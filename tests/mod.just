set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

# Validate Chainsaw configuration/tests and test harness scripts without a cluster.
validate:
    @scripts/test/validate-chainsaw.sh

# Validate the canonical suite catalog and its dispatch safety invariants.
catalog-validate:
    @scripts/test/validate-catalog.sh

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
resilience target:
    @scripts/test/run-live-suite.sh resilience {{quote(target)}}

# Collect allowlisted read-only diagnostics from the live cluster.
diagnostics target:
    @scripts/test/run-live-suite.sh diagnostics {{quote(target)}}

# Run a single registered read-only network/API probe interactively (a measurement
# primitive, not an assurance tier). Operator-run; needs the live cluster.
probe target:
    @scripts/test/run-probe.sh {{quote(target)}}
