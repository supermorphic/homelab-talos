# Portainer GitOps observability

## Status

- **Status: Accepted.**
- Date: 2026-08-02

## Context

Portainer was introduced as an internal operational view of the Talos Kubernetes cluster.
The useful capability is inventory and diagnosis; allowing it to compete with Flux for
desired-state ownership would create an unaudited deployment path.

## Decision

- Run Portainer CE internally as a single `Recreate` Deployment over a retained Longhorn
  ReadWriteOnce PVC. Expose only its ClusterIP application port through the internal
  Gateway; do not add a public route, NodePort, Edge tunnel, or Docker Agent in this
  scope.
- Disable the chart's local-management RBAC and bind the rendered workload to the
  repository-owned `portainer-readonly` ServiceAccount.
- Permit only `get`, `list`, and `watch` for the workload, node, event, configuration,
  storage, Gateway API, Flux, selected Longhorn, and metrics inventory needed by the UI,
  plus pod logs. Never grant Secret access, wildcard permissions, mutation, bind,
  escalate, impersonate, exec, attach, or port-forward.
- Treat Kubernetes authorization checks as the authority. Visible UI controls do not
  prove or widen the runtime permission boundary.
- Restrict network paths to internal Envoy ingress, node health probes, CoreDNS, and the
  Kubernetes API. All other ingress and egress remain denied.
- Keep the bootstrap administrator credential SOPS-encrypted. Changing the Secret does
  not rotate an administrator already stored in Portainer's database; runtime rotation
  and disaster-recovery bootstrap state must be kept aligned deliberately.
- Defer Pi Docker-host integration. Standard Agents would carry host-level Docker
  authority and therefore require a separate approved design and source repository.

## Deployment authority

Portainer remains an observability interface and must not become a deployment authority.
Git and Flux remain the source and reconciler of desired state. This invariant is
preserved by the accepted
[`agent rules runtime contract amendment`](2026-08-03-agent-rules-runtime-contract-amendment.md#portainer-disposition),
not duplicated in root `AGENTS.md`.

## Consequences

Loss of Portainer does not affect Flux-managed workloads. Its retained database preserves
UI state, while its Kubernetes view remains least-privilege. Current credential,
verification, persistence, and recovery procedure lives in
[`docs/portainer.md`](../portainer.md).
