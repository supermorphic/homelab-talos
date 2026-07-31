<!-- FOR AI AGENTS - Human readability is a side effect, not a goal -->
<!-- Managed by agent: hand-maintained; keep sections and order, edit content -->
<!-- Last updated: 2026-07-31 -->

# Kubernetes manifests

Scope: `kubernetes/`. The root `AGENTS.md` safety, approval, and merge boundaries
still apply — this file adds the authoring procedure, not exceptions.

## Overview

Flux reconciles this tree from `main`. Two subtrees:

- `flux/clusters/prod/` — the Flux entrypoint that wires the `flux-system`
  `GitRepository` and the top-level Kustomizations. Rarely edited.
- `apps/<domain>/<app>/` — everything else. Domains in use: `flux-system`,
  `kube-system`, `media`, `monitoring`, `networking`, `security`, `storage`,
  `testing`.

An app directory holds `ks.yaml` (the Flux Kustomization), `app/` (the manifests
it points at), and optionally `config/` (data consumed by the app, not applied
directly by that Kustomization).

## Prerequisites

Flux resolves `ks.yaml` `dependsOn` names against other Flux Kustomizations, so a
new app is inert until its dependencies exist and reconcile. Check what the app
actually needs at runtime — storage, gateway, namespace — before writing it.

## Commands

| Task | Command |
|------|---------|
| Schema-validate all manifests | `mise exec -- just kube kubeconform` |
| Policy unit tests (conftest/rego) | `mise exec -- just kube validator-tests` |
| Source validation for one app | `mise exec -- just kube <app>-validate` |
| Full PR gate | `mise exec -- just ci` |

`*-validate` recipes are cluster-independent and run in CI; their cluster-dependent
counterparts are operator-only. `scripts/AGENTS.md` owns that split — check it
before adding a recipe to either side.

## Conventions

- `ks.yaml` is a `kustomize.toolkit.fluxcd.io/v1` Kustomization in namespace
  `flux-system`, with `spec.path: ./kubernetes/apps/<domain>/<app>/app`,
  `sourceRef` the `flux-system` `GitRepository`, `prune: true`, and `wait: true`.
- `app/kustomization.yaml` must list every sibling manifest under `resources:`.
  A file that is not listed is silently not deployed.
- Chart and manifest sources follow the existing pattern: an `OCIRepository` (or
  `HelmRepository`/`GitRepository`) beside the `HelmRelease` that references it.
  Match a neighbouring app rather than introducing a new source kind.
- Chart values go in `values.yaml`, mounted via `configMapGenerator` with
  `disableNameSuffixHash: true` and the `reconcile.fluxcd.io/watch: Enabled`
  label — not inlined into the HelmRelease.
- A namespace that serves an HTTPRoute needs
  `gateway.supermorphic.com/access: internal`. The internal gateway's https
  listener only admits routes from namespaces carrying it; without the label the
  route is accepted and simply never attaches.
- Set `pod-security.kubernetes.io/enforce` on every namespace you create.
- A Deployment mounting a `ReadWriteOnce` PVC uses `Recreate` or a StatefulSet.
  Never `RollingUpdate` — the second pod blocks on the volume forever.
- New apps begin with `suspend: true`, roll out through the operator-run
  `mise exec -- just bootstrap <app>`, then have the unsuspended state committed.

## Patterns to Follow

`apps/monitoring/ntfy/` is the golden sample — it is the only app exercising the
full set: `ocirepository.yaml` + `helmrelease.yaml`, a SOPS secret, `namespace.yaml`
with both labels, `httproute.yaml`, `servicemonitor.yaml`, `prometheusrule.yaml`,
`ciliumnetworkpolicy.yaml`, and a `config/` directory.

For a minimal app, `apps/media/plex/` shows the smaller shape: `ks.yaml` with
`dependsOn` on `media-storage` and `internal-gateway`, and an `app/` of four files.

## Security

- Secrets live as `*.sops.yaml` inside `app/` and are listed in
  `kustomization.yaml` like any other resource. Never decrypt them, never commit
  plaintext, never copy ciphertext between apps.
- Secrets are created only through the operator-run `*-secrets` recipes under
  `scripts/secrets/`.
- Prefer a `CiliumNetworkPolicy` for anything exposed beyond its namespace.

## Checklist

- [ ] Every new file is listed in `app/kustomization.yaml`
- [ ] `ks.yaml` `dependsOn` names real, reconciling Kustomizations
- [ ] Namespace carries the gateway label if an HTTPRoute is present
- [ ] RWO PVC consumers use `Recreate` or a StatefulSet
- [ ] `mise exec -- just kube kubeconform` passes
- [ ] New validation is registered in `tests/catalog.yaml` (see `tests/AGENTS.md`)

## Troubleshooting

- **HTTPRoute accepted but no traffic** — missing namespace access label.
- **Manifest edited but nothing changed in-cluster** — not listed under
  `resources:`, or the Kustomization is still suspended.
- **Pod stuck `ContainerCreating` after a redeploy** — RWO volume held by the old
  replica; the workload needs `Recreate`.
- Diagnosing anything live is operator territory: hand off rather than reaching
  for raw `kubectl`.
