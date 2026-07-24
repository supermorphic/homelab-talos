set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

# Validate Chainsaw configuration/tests and test harness scripts without a cluster.
validate:
    @scripts/test/validate-chainsaw.sh
