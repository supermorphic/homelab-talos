# Domain discovery

Engineering skills should derive terminology, architecture, constraints, and
current state from repository sources that already exist.

## Before exploring, read the relevant sources

- Start with the root `README.md` and the closest area-specific `README.md` files.
- Read relevant runbooks and explanations under `docs/`.
- Read relevant specs, implementation plans, and handoffs under `plans/`. Plans
  describe intent and may be stale, so verify their claims against current source.
- Inspect the current declarative sources under `kubernetes/` and `talos/`.
  Manifests and their Kustomize, Flux, Helm, and Talos relationships are the
  authoritative implementation context.
- Consult the relevant guarded `just` recipes, scripts, and tests when they define
  operational behavior or validation contracts.

Use terminology consistently with these sources. When sources disagree, surface
the conflict and distinguish planned behavior from the current manifests.

## Optional future sources

If they exist later, also read a root `CONTEXT.md`, a root `CONTEXT-MAP.md` and
its relevant context files, and relevant ADRs under `docs/adr/`. Treat them as
additional domain and decision sources, not as established repository
conventions or substitutes for verifying the current manifests.

Proceed silently when these optional files do not exist. Do not create them
merely because they are absent; add them only when domain-modeling work produces
durable terminology or architectural decisions worth recording.

If a proposed change contradicts an existing ADR or another recorded decision,
surface the conflict explicitly instead of silently overriding it.
