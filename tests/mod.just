set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

# Validate Chainsaw configuration/tests and test harness scripts without a cluster.
validate:
    @scripts/test/validate-chainsaw.sh

# Run registered read-only smoke scenarios against the live cluster.
smoke target="all":
    @scripts/test/run-chainsaw.sh smoke {{quote(target)}}

# Run registered state-changing functional scenarios against the live cluster.
e2e target="all":
    @scripts/test/run-chainsaw.sh e2e {{quote(target)}}

# Run a registered disruptive scenario after validating the exact confirmation.
resilience target:
    @scripts/test/safety/require-chaos-confirmation.sh {{quote(target)}}
    @scripts/test/run-chainsaw.sh resilience {{quote(target)}}

# Collect allowlisted read-only diagnostics from the live cluster.
diagnostics target="cluster":
    @scripts/test/run-chainsaw.sh diagnostics {{quote(target)}}
