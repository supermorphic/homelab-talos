#!/usr/bin/env -S just --justfile

set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]

[group("Repository")]
mod repo ".just/repository.just"

[group("Talos")]
mod talos "talos"

[group("Bootstrap")]
mod bootstrap ".just/bootstrap.just"

[group("Kubernetes")]
mod kube "kubernetes"

[group("Testing")]
mod test "tests"

# Cluster-independent, secret-free validation contract. Run locally before opening a
# PR; GitHub Actions runs the exact same command on PRs and pushes to main. Requires
# the mise toolchain and network egress (Helm pulls public charts) but NO kubeconfig,
# SOPS age key, or cluster access. Cluster-dependent checks (*-verify, *-status,
# bootstrap, pihole-status) are intentionally excluded and remain operator-only.
[group("CI")]
ci:
    just repo lint
    just repo verify
    just test validate
    just kube validator-tests
    just kube kubeconform
    just kube cilium-validate
    just kube metrics-server-validate
    just kube flux-validate
    just kube foundation-validate
    just kube storage-validate
    just kube csi-driver-smb-validate
    just kube media-storage-validate
    just kube plex-validate
    just kube intel-gpu-plugin-validate
    just kube qbittorrent-validate
    just kube arr-validate
    just kube seerr-validate
    just kube flaresolverr-validate
    just kube media-policy-validate
    just kube monitoring-validate
    just kube gatus-validate
    just kube homepage-validate
    just kube trivy-validate
