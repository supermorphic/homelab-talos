#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
require_bash

for variable in \
  RECOVERY_KUBECONFIG RECOVERY_KUBE_CONTEXT RECOVERY_TALOSCONFIG \
  RECOVERY_TALOS_CONTEXT RECOVERY_SOURCE_REVISION RECOVERY_MODE \
  RECOVERY_NODE RECOVERY_NODES_JSON RECOVERY_TALOS_ENDPOINTS; do
  [[ -n "${!variable:-}" ]] || {
    echo "Missing fixed recovery verifier input: $variable" >&2
    exit 1
  }
done

# These are the existing owner validators and observers. Recovery-specific values are
# explicit environment inputs interpreted only by those fixed scripts.
echo 'recovery verification: validating Flux source' >&2
scripts/validate/flux.sh
echo 'recovery verification: validating Cilium source' >&2
scripts/validate/cilium.sh
echo 'recovery verification: validating foundation source' >&2
scripts/validate/foundation.sh
if [[ "$RECOVERY_MODE" == prepare ]]; then
  exit 0
fi
echo 'recovery verification: observing Cilium' >&2
scripts/verify/cilium.sh "$RECOVERY_KUBECONFIG" \
  kubernetes/apps/kube-system/cilium/app/values.yaml
echo 'recovery verification: observing foundation' >&2
scripts/verify/foundation.sh "$RECOVERY_KUBECONFIG"
