<!-- FOR AI AGENTS - Human readability is a side effect, not a goal -->
<!-- Managed by agent: hand-maintained; keep sections and order, edit content -->
<!-- Last updated: 2026-07-31 -->

# Talos node configuration

Scope: `talos/`. The root `AGENTS.md` safety, approval, and merge boundaries still
apply — this file adds the generation procedure, not exceptions.

## Overview

Three nodes: `nuc1`, `nuc2`, `nuc3`. Source of truth is `talconfig.yaml` plus the
patches in `patches/`. `talhelper` renders those into `clusterconfig/` at the
repository root.

**`clusterconfig/` is generated and gitignored. Never edit it, and never treat a
file there as source.** It is absent from a fresh checkout until you generate it.

## Prerequisites

Generation and every node operation run through `talos/mod.just`. Node-applying
recipes are cluster-mutating, require an explicit `*_CONFIRM` value, and are
operator-run — an agent edits sources and validates, then hands off the rollout.

## Commands

| Task | Command |
|------|---------|
| Validate sources only | `mise exec -- just talos source-validate` |
| Regenerate `clusterconfig/` | `mise exec -- just talos generate` |
| Validate rendered configs | `mise exec -- just talos validate` |

`generate` and `validate` both depend on `source-validate`, so run that first when
iterating — it is the fast failure. `generate` removes and recreates
`clusterconfig/` wholesale; anything hand-edited there is lost, which is the point.

## Conventions

- Change `talconfig.yaml` for cluster-wide and per-node settings; use
  `patches/machine.yaml` for machine-level config that talhelper does not model.
- Regenerate in the same commit as the source change so the two never drift.
- Version fields are a compatibility set, not independent knobs: `talosVersion`
  (currently `v1.13.6`) and `kubernetesVersion` (currently `v1.35.6`) must stay
  within Talos's supported matrix, and Cilium's supported kernel/kube-proxy
  replacement range must cover the Talos version. Check all three before bumping
  any one of them.

## Patterns to Follow

`generate` asserts the rendered set is exactly `nuc1.yaml`, `nuc2.yaml`,
`nuc3.yaml` plus `talosconfig`. If you add or rename a node, that expectation in
`mod.just` moves with it — the recipe is the schema check.

## Security

- `talsecret.sops.yaml` holds cluster PKI and bootstrap material. Never decrypt
  it, never print its contents, never commit a plaintext copy.
- Rendered configs under `clusterconfig/` embed those secrets. That is why the
  directory is gitignored — never force-add it.
- `talosconfig` is a credential. Do not copy it out of the generated directory.

## Checklist

- [ ] Only `talconfig.yaml` and `patches/` edited; no `clusterconfig/` files staged
- [ ] `mise exec -- just talos source-validate` passes
- [ ] Regenerated in the same commit if the render changes
- [ ] Version bumps checked against the Talos/Kubernetes/Cilium matrix
- [ ] Rollout left to the operator, and said so in the report

## Troubleshooting

- **`clusterconfig/` missing** — expected; run `generate`.
- **`validate` fails on a file count** — a node was added or renamed without
  updating the expected-file assertion in `mod.just`.
- **Node unreachable after apply** — operator territory; do not reach for raw
  `talosctl`.
