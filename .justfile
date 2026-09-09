#!/usr/bin/env -S just --justfile

set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]

[group("Repository")]
mod repo ".just/repository.just"

[group("Talos")]
mod talos "talos"

[group("Bootstrap")]
mod bootstrap ".just/bootstrap.just"

[group("Node lifecycle")]
mod node ".just/node.just"

[group("Established cluster")]
mod cluster ".just/cluster.just"

[group("Kubernetes")]
mod kube "kubernetes"

[group("Testing")]
mod test "tests"

# Canonical full validation fallback, independent of the cluster and secret-free.
# For PR publication use `just test ci-publish`; GitHub selects the same groups. Requires
# the mise toolchain and network egress (Helm pulls public charts) but NO kubeconfig,
# SOPS age key, or cluster access. Cluster-dependent checks (*-verify, *-status,
# bootstrap, pihole-status) are intentionally excluded. AGENTS.md defines their
# authority boundaries, including approved scoped agent verification.
[group("CI")]
ci:
    scripts/test/run-ci.sh
