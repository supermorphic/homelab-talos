# Kubernetes Agent Instructions

Binding constraints for all files under `kubernetes/`. Root `AGENTS.md` remains the
floor and this file may only narrow or strengthen it.

## Source and reconciliation boundaries

- Flux cluster entrypoints belong under `flux/clusters/prod/`.
- Components live under `apps/<namespace>/<app>/` with an explicit `ks.yaml` and
  `app/`; a directory is not deployed merely because it exists.
- Use a `HelmRelease` for a healthy maintained chart and focused native resources
  otherwise. Never commit `helm template`, Kompose, or other generator output as
  declarative source.
- Express ordering with `dependsOn`, readiness waiting, and health checks, never
  implicit directory order or numeric sync waves. Native Kustomizations select
  children explicitly; Flux does not deploy directories recursively.
- Never manually apply `ks.yaml`, `ocirepository.yaml`, or `helmrelease.yaml`.
- After Flux bootstrap, steady-state Kubernetes changes are committed to Git and
  reconciled by Flux. Bootstrap and recovery applies use guarded `just` recipes,
  never raw `kubectl`.

## Networking and secrets

- The Gateway owns the single wildcard certificate. Application routes never copy
  TLS private keys.
- ExternalDNS publishes only routes carrying
  `external-dns.k8s.io/audience=internal`.
- Kubernetes Secret manifests use the `*.sops.yaml` suffix. Never commit a
  decrypted Secret or place the age identity in this tree.

## Rollout and storage invariants

- New apps begin suspended, activate through a guarded rollout, and then persist
  the unsuspended state in Git. Never suspend a Flux resource without approval.
- A Deployment mounting a `ReadWriteOnce` PVC uses `Recreate`, or use a StatefulSet;
  never use `RollingUpdate` for that workload.
