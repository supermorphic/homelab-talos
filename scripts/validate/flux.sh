#!/usr/bin/env bash
set -euo pipefail

expected_flux="$(yq -p=toml -r '.tools.flux2' .mise.toml 2>/dev/null)"
expected_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' .sops.yaml)"
temp_dir="$(mktemp -d /tmp/homelab-talos-flux-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for file in \
  'kubernetes/flux/clusters/prod/apps.yaml' \
  'kubernetes/apps/kustomization.yaml' \
  'kubernetes/apps/flux-system/kustomization.yaml' \
  'kubernetes/apps/flux-system/flux-canary/ks.yaml' \
  'kubernetes/apps/flux-system/flux-canary/app/kustomization.yaml' \
  'kubernetes/apps/flux-system/flux-canary/app/secret.sops.yaml' \
  'kubernetes/apps/kube-system/kustomization.yaml' \
  'kubernetes/apps/kube-system/cilium/ks.yaml'; do
  [[ -f "$file" ]] || {
    echo "Missing required Flux source: $file" >&2
    exit 1
  }
done

[[ "$(flux version --client | awk '{print $2}' | sed 's/^v//')" == "$expected_flux" ]]
[[ "$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .encrypted_regex' .sops.yaml)" == '^(data|stringData)$' ]]
[[ "$expected_recipient" == age1* ]]

canary='kubernetes/apps/flux-system/flux-canary/app/secret.sops.yaml'
[[ "$(sops filestatus "$canary" | yq -r '.encrypted')" == 'true' ]]
[[ "$(yq -r '.sops.age[].recipient' "$canary" | sort -u)" == "$expected_recipient" ]]
[[ "$(yq -r '.kind' "$canary")" == 'Secret' ]]
[[ "$(yq -r '.metadata.name' "$canary")" == 'flux-canary' ]]
[[ "$(yq -r '.stringData.marker' "$canary")" != 'ready' ]]

root='kubernetes/flux/clusters/prod/apps.yaml'
[[ "$(yq -r '.metadata.name' "$root")" == 'cluster-apps' ]]
[[ "$(yq -r '.spec.path' "$root")" == './kubernetes/apps' ]]
[[ "$(yq -r '.spec.sourceRef.name' "$root")" == 'flux-system' ]]
[[ "$(yq -r '.spec.deletionPolicy' "$root")" == 'Orphan' ]]

cilium='kubernetes/apps/kube-system/cilium/ks.yaml'
# ks.yaml now holds a second document (cilium-monitoring), so select the "cilium"
# document explicitly rather than reading the file as a single object.
cilium_ks="$(yq ea -r 'select(.metadata.name == "cilium")' "$cilium")"
[[ "$(yq -r '.metadata.annotations."kustomize.toolkit.fluxcd.io/prune"' - <<<"$cilium_ks")" == 'disabled' ]]
[[ "$(yq -r '.spec.deletionPolicy' - <<<"$cilium_ks")" == 'Orphan' ]]
[[ "$(yq -r '.spec.decryption.provider' - <<<"$cilium_ks")" == 'sops' ]]
[[ "$(yq -r '.spec.decryption.secretRef.name' - <<<"$cilium_ks")" == 'sops-age' ]]
cilium_suspend="$(yq -r '.spec.suspend // false' - <<<"$cilium_ks")"
[[ "$cilium_suspend" == 'true' || "$cilium_suspend" == 'false' ]]
[[ "$(yq -r '.metadata.annotations."kustomize.toolkit.fluxcd.io/prune"' kubernetes/apps/kube-system/cilium/app/helmrelease.yaml)" == 'disabled' ]]

canary_ks='kubernetes/apps/flux-system/flux-canary/ks.yaml'
[[ "$(yq -r '.spec.dependsOn[0].name' "$canary_ks")" == 'cilium' ]]
[[ "$(yq -r '.spec.decryption.provider' "$canary_ks")" == 'sops' ]]
[[ "$(yq -r '.spec.decryption.secretRef.name' "$canary_ks")" == 'sops-age' ]]

kustomize build kubernetes/apps >"$temp_dir/apps.yaml"
kustomize build kubernetes/apps/kube-system >"$temp_dir/kube-system.yaml"
kustomize build kubernetes/apps/flux-system >"$temp_dir/flux-system.yaml"
kustomize build kubernetes/apps/kube-system/cilium/app >"$temp_dir/cilium.yaml"
kustomize build kubernetes/apps/flux-system/flux-canary/app >"$temp_dir/canary.yaml"

# Presence check, not an exact set: adding an app must not require editing this
# assertion (it broke on every Phase 9/10 addition). Confirm the critical
# bootstrap Kustomizations build; app churn is caught by each app's *-validate.
built_kustomizations="$(yq ea -r '[select(.kind == "Kustomization") | .metadata.name] | .[]' "$temp_dir/apps.yaml" | sort -u)"
for required in cilium flux-canary; do
  rg -qx "$required" <<<"$built_kustomizations" || {
    echo "flux-validate: required Kustomization '$required' is missing from the apps build." >&2
    exit 1
  }
done
[[ -z "$(rg '^apiVersion: (apps|extensions)/v1beta|^apiVersion: (networking.k8s.io|policy)/v1beta1' kubernetes --glob '*.yaml' || true)" ]]

just kube cilium-validate
echo "Flux $expected_flux source, SOPS canary, dependency graph, and Cilium adoption guards passed validation."
