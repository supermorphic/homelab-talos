#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: media-storage.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"

for n in media media-storage; do
  [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$n" --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
    echo "Media Kustomization $n is not Ready." >&2
    exit 1
  }
done
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace media get pvc media-data --output jsonpath='{.status.phase}' 2>/dev/null)" == 'Bound' ]] || {
  echo 'PVC media/media-data is not Bound.' >&2
  exit 1
}
echo 'Phase 11 media storage acceptance passed: media + media-storage Kustomizations Ready and media-data PVC Bound. Run the hardlink proof in docs/phase-11-media.md next.'
