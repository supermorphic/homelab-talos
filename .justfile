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
    scripts/test/run-ci.sh
