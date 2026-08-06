# Talos and Flux platform architecture

## Status

- **Status: Accepted.**
- Date: 2026-08-02

## Context

The three-node NUC cluster was rebuilt on new system drives before it held workloads or
persistent application data. Preserving the original Talos identity and migrating etcd
would have added risk without preserving useful state. The old installation therefore
served as hardware and Secure Boot evidence, while the replacement established a fresh,
reproducible source of truth.

This record preserves the durable choices from the completed platform plan. Dated rollout
and acceptance evidence lives under [`docs/phases/`](../phases/).

## Decision

- Keep Talos machine configuration and Kubernetes GitOps source in one repository so
  cross-layer changes remain atomic and reviewable. Repository privacy does not replace
  encryption.
- Use Talhelper as the declarative source for topology, schematics, patches, and volume
  policy. Keep the fresh Talos identity SOPS-encrypted and treat generated machine files
  as ignored output, never primary source.
- Run three uniform, schedulable amd64 Talos control-plane nodes. This retains an odd etcd
  quorum, one machine architecture, Secure Boot and TPM protection, and all available
  compute capacity.
- Protect Talos STATE and EPHEMERAL with TPM-backed encryption. Keep the dedicated
  Longhorn user volume unencrypted for operational recovery; application secrets remain
  encrypted independently.
- Use Cilium with kube-proxy replacement and Hubble. Bootstrap it from the tracked values
  before Flux, then let Flux adopt the same release.
- Use MetalLB for mature L2 service advertisement and Envoy Gateway for Gateway API
  ingress. Keep internal and public DNS controllers separate by provider, credentials,
  zone, and exposure policy.
- Use Flux as the sole Kubernetes reconciler, with dependency-ordered Kustomizations,
  HelmRelease ownership, and native SOPS decryption. Do not retain parallel ArgoCD
  ownership or committed rendered chart output.
- Use Longhorn for replicated single-writer application state and SMB for bulk media and
  downloads. One storage system is not forced to serve both failure models.
- Treat HomeOps repositories as pattern libraries, not an upstream template dependency.
  Components are adopted only when they solve a local requirement and have a recovery
  path.
- Keep the Raspberry Pi k3s cluster separate as a possible reduced, Flux-managed staging
  environment. It does not represent Talos, x86 GPU, Secure Boot, or production storage
  behavior.
- Keep component versions pinned and compatibility-checked in the live Talos and
  Kubernetes documentation. Version upgrades require their own approved workflow; this
  architecture record does not freeze the original rollout versions forever.

## Consequences

The repository can recreate ignored Talos configuration from reviewable source plus the
operator-held age identity. Flux owns Kubernetes desired state after the explicit Talos
and Cilium bootstrap boundary. Platform changes remain staged and testable without
copying legacy controllers, credentials, ciphertext, or generated artifacts.

Current procedure belongs in [`talos/README.md`](../../talos/README.md),
[`kubernetes/README.md`](../../kubernetes/README.md), and the
[operator bootstrap runbook](../runbooks/operator-bootstrap.md).
