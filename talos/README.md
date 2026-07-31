# Talos Source Boundary

This directory is the declarative source for the NUC Talos cluster. Phase 2
established the Talhelper inputs and enabled local generation and validation.
Phase 3 enables a guarded, one-node-at-a-time installation workflow; it does not
enable etcd bootstrap.

Binding rules for this directory are in [`AGENTS.md`](AGENTS.md); this file is explanatory.

## Source and Generated State

The trackable sources are:

- `talconfig.yaml` for cluster topology, versions, nodes, and patch references
- `talsecret.sops.yaml` for the fully encrypted fresh Talos identity
- `patches/` for reviewed machine configuration fragments

Talhelper renders per-node machine configs into the ignored root
`clusterconfig/` directory.

Generate and validate machine configs with
[`docs/runbooks/talos-generate.md`](../docs/runbooks/talos-generate.md). Install one
node through the guarded workflow in
[`docs/runbooks/talos-install.md`](../docs/runbooks/talos-install.md).

See the root [`README.md`](../README.md) for workstation setup and the canonical
[`plans/talos-flux-platform-plan.md`](../plans/talos-flux-platform-plan.md) for
machine configuration decisions and phase gates.
