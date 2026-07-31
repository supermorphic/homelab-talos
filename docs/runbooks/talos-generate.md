# Generate Talos Machine Configs

## Purpose

Generate ignored machine configs from tracked Talhelper sources without mutating
the cluster.

## Preconditions

- Run from the repository root.
- Use Bash 5 or newer.
- Install the repository's mise toolchain.
- Have the operator-provided repository age identity available.

## Generate and validate

Run the complete workflow through the pinned interface:

```bash
mise exec -- just repo secrets
mise exec -- just talos generate
mise exec -- just talos validate
mise exec -- just repo verify
```

`talos generate` verifies the age identity, decrypts the Talos bundle only inside
Talhelper, replaces the ignored root `clusterconfig/` directory, and invokes
strict validation. Validation checks all three metal configs plus the endpoint,
network, Secure Boot installer, CNI, kube-proxy, encryption, and volume decisions.

For trackable Talhelper-only edits, run the focused source check:

```bash
mise exec -- just talos source-validate
```

Applying a rendered config is a separate guarded procedure covered only by
[`talos-install.md`](talos-install.md).
